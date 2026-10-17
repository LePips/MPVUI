/* Exercise the production metadata queue and GPU capability gating on Android. */
#include <assert.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include "libavcodec/avcodec.h"
#include "libavcodec/dovi_rpu.h"
#include "libavcodec/h2645_parse.h"
#include "libavcodec/hevc/parse.h"
#include "libavcodec/mediacodec.h"
#include "libavcodec/mediacodecdec_common.h"
#include "libavutil/hwcontext_mediacodec.h"
#include "libavutil/intreadwrite.h"
#include "dovi-gpu-production.inc"

static AVPacket fixture(const char *path) {
    FILE *file = fopen(path, "rb");
    assert(file);
    fseek(file, 0, SEEK_END);
    long size = ftell(file);
    assert(size > 4 && size < 65536);
    rewind(file);
    AVPacket packet = {0};
    assert(av_new_packet(&packet, size + 9) == 0);
    const uint8_t prefix[] = {0, 0, 0, 1, 0x26, 1, 0x80, 0, 0, 0, 1, 0x7c, 1};
    memcpy(packet.data, prefix, sizeof(prefix));
    fseek(file, 4, SEEK_SET);
    assert(fread(packet.data + sizeof(prefix), 1, size - 4, file) == (size_t)size - 4);
    fclose(file);
    packet.pts = 1000;
    return packet;
}

static int capability_status(void *opaque) { return *(int *)opaque; }

static void metadata_tests(const char *p5, const char *p5_alternate, const char *p7) {
    AVCodecContext *avctx = avcodec_alloc_context3(NULL);
    assert(avctx);
    assert(!mediacodec_dovi_surface_available(avctx));
    avctx->hw_device_ctx = av_hwdevice_ctx_alloc(AV_HWDEVICE_TYPE_MEDIACODEC);
    assert(avctx->hw_device_ctx);
    AVMediaCodecDeviceContext *device = mediacodec_dovi_device(avctx);
    assert(device);
    device->surface = (void *)1; // Ordinary RGB surfaces must never opt in.
    assert(!mediacodec_dovi_surface_available(avctx));
    device->dolby_vision_surface = (void *)2;
    assert(!mediacodec_dovi_surface_available(avctx));
    int ready = 1;
    device->dolby_vision_status = capability_status;
    device->dolby_vision_opaque = &ready;
    assert(mediacodec_dovi_surface_available(avctx));
    ready = 0;
    assert(!mediacodec_dovi_surface_available(avctx));
    device->surface = device->dolby_vision_surface = NULL;
    avctx->pkt_timebase = (AVRational){1, 60000};
    MediaCodecH264DecContext s = {0};
    s.gpu_dovi_ctx.logctx = avctx;
    s.source_range = AVCOL_RANGE_JPEG;
    AVDOVIDecoderConfigurationRecord conf = {
        .dv_profile = 5,
        .rpu_present_flag = 1,
        .bl_present_flag = 1,
    };
    assert(mediacodec_gpu_dovi_allowed(&conf));
    conf.dv_profile = 8;
    assert(!mediacodec_gpu_dovi_allowed(&conf));
    conf.dv_profile = 5;
    conf.el_present_flag = 1;
    assert(!mediacodec_gpu_dovi_allowed(&conf));
    conf.el_present_flag = 0;
    conf.dv_profile = 7;
    assert(!mediacodec_gpu_dovi_allowed(&conf));

    AVPacket packet = fixture(p5);
    assert(mediacodec_gpu_dovi_queue(avctx, &s, &packet) == 0);
    packet.pts = 3000;
    assert(mediacodec_gpu_dovi_queue(avctx, &s, &packet) == 0);
    AVPacket alternate = fixture(p5_alternate);
    alternate.pts = 2000;
    assert(mediacodec_gpu_dovi_queue(avctx, &s, &alternate) == 0);
    assert(mediacodec_gpu_dovi_queue(avctx, &s, &alternate) < 0); // ambiguous PTS
    AVFrame *frame = av_frame_alloc();
    assert(frame);
    for (int i = 1; i <= 3; i++) {
        frame->pts = 1000 * i;
        frame->format = AV_PIX_FMT_MEDIACODEC;
        assert(mediacodec_gpu_dovi_output(&s, frame) == 0);
        assert(frame->color_range == AVCOL_RANGE_JPEG);
        assert(av_frame_get_side_data(frame, AV_FRAME_DATA_DOVI_METADATA));
        AVFrameSideData *raw = av_frame_get_side_data(frame, AV_FRAME_DATA_DOVI_RPU_BUFFER);
        const AVPacket *expected = i == 2 ? &alternate : &packet;
        assert(raw && raw->size == (size_t)expected->size - 13);
        assert(!memcmp(raw->data, expected->data + 13, raw->size));
        av_frame_unref(frame);
    }
    frame->format = AV_PIX_FMT_MEDIACODEC;
    frame->pts = 99999;
    assert(mediacodec_gpu_dovi_output(&s, frame) < 0); // never reuse latest RPU
    packet.pts = 4000;
    assert(mediacodec_gpu_dovi_queue(avctx, &s, &packet) == 0);
    frame->pts = 4000;
    frame->format = AV_PIX_FMT_NV12;
    assert(mediacodec_gpu_dovi_output(&s, frame) < 0); // no silent 8-bit conversion
    mediacodec_gpu_dovi_clear(&s);
    for (unsigned i = 0; i < FF_ARRAY_ELEMS(s.gpu_metadata); i++)
        assert(!s.gpu_metadata[i]);
    assert(!s.gpu_dovi_ctx.mapping); // seek must discard old metadata
    for (unsigned i = 0; i < FF_ARRAY_ELEMS(s.gpu_metadata); i++) {
        packet.pts = i * 1000;
        assert(mediacodec_gpu_dovi_queue(avctx, &s, &packet) == 0);
    }
    packet.pts = 64000;
    assert(mediacodec_gpu_dovi_queue(avctx, &s, &packet) < 0); // bounded allocation
    mediacodec_gpu_dovi_clear(&s);
    packet.pts = AV_NOPTS_VALUE;
    assert(mediacodec_gpu_dovi_queue(avctx, &s, &packet) < 0);
    packet.pts = 1000;
    packet.data[packet.size - 4] ^= 1;
    assert(mediacodec_gpu_dovi_queue(avctx, &s, &packet) < 0); // CRC validation
    av_packet_unref(&packet);
    av_packet_unref(&alternate);
    mediacodec_gpu_dovi_clear(&s);
    packet = fixture(p7);
    assert(mediacodec_gpu_dovi_queue(avctx, &s, &packet) < 0);
    av_packet_unref(&packet);
    av_frame_free(&frame);
    mediacodec_gpu_dovi_clear(&s);
    ff_dovi_ctx_unref(&s.gpu_dovi_ctx);
    avcodec_free_context(&avctx);
}

int main(int argc, char **argv) {
    assert(argc == 4);
    metadata_tests(argv[1], argv[2], argv[3]);
    puts("PASS: Dolby metadata reorder, seek reset, malformed/unsupported rejection, bounded queue, and GPU capability fallback");
    return 0;
}
