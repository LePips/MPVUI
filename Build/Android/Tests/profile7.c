/* Regression checks compiled with the exact production conversion functions. */
#include <assert.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include "libavcodec/avcodec.h"
#include "libavutil/dovi_meta.h"
#include "libavutil/intreadwrite.h"
#include "profile7-production.inc"

static AVDOVIDecoderConfigurationRecord source = {
    .dv_profile = 7,
    .dv_level = 6,
    .rpu_present_flag = 1,
    .el_present_flag = 1,
    .bl_present_flag = 1,
    .dv_bl_signal_compatibility_id = 6,
};

static AVPacket fixture(const char *path, int duplicates, int enhancement) {
    FILE *file = fopen(path, "rb");
    assert(file);
    fseek(file, 0, SEEK_END);
    long length = ftell(file);
    assert(length > 4 && length < 65536);
    rewind(file);
    uint8_t rpu[65536];
    assert(fread(rpu, 1, length, file) == (size_t)length);
    fclose(file);
    assert(AV_RB32(rpu) == 1);
    // Minimal base/EL NAL headers; conversion does not decode slice pixels.
    static const uint8_t base[] = {0, 0, 0, 1, 0x26, 1, 0x80};
    static const uint8_t el[] = {0, 0, 0, 1, 0x26, 9, 0x80, 0, 0, 0, 1, 0x7e, 1, 0x80};
    AVPacket packet = {0};
    int size = sizeof(base) + duplicates * (length + 2) + (enhancement ? sizeof(el) : 0);
    assert(av_new_packet(&packet, size) == 0);
    memcpy(packet.data, base, sizeof(base));
    int offset = sizeof(base);
    if (enhancement) {
        memcpy(packet.data + offset, el, sizeof(el));
        offset += sizeof(el);
    }
    for (int i = 0; i < duplicates; i++) {
        AV_WB32(packet.data + offset, 1);
        packet.data[offset + 4] = 0x7c;
        packet.data[offset + 5] = 1;
        memcpy(packet.data + offset + 6, rpu + 4, length - 4);
        offset += length + 2;
    }
    packet.pts = 1234;
    packet.dts = 1200;
    packet.duration = 40;
    packet.flags = AV_PKT_FLAG_KEY;
    return packet;
}

static void rejected(AVPacket *packet) {
    int size = packet->size;
    uint8_t *copy = malloc(size);
    memcpy(copy, packet->data, size);
    assert(mediacodec_dovi_convert_packet(NULL, packet, &source) < 0);
    assert(packet->size == size && !memcmp(copy, packet->data, size));
    assert(packet->pts == 1234);
    free(copy);
    av_packet_unref(packet);
}

int main(int argc, char **argv) {
    assert(argc == 4); // MEL, FEL, Profile 5 metadata from pinned libdovi.
    assert(!mediacodec_dovi_p7_allowed(1, 0, &source));
    assert(!mediacodec_dovi_p7_allowed(0, 1, &source));
    assert(!mediacodec_dovi_p7_allowed(1, 1, NULL));
    assert(mediacodec_dovi_p7_allowed(1, 1, &source));
    AVDOVIDecoderConfigurationRecord bad = source;
    bad.dv_bl_signal_compatibility_id = 1;
    assert(!mediacodec_dovi_p7_allowed(1, 1, &bad));
    bad = source;
    bad.dv_md_compression = 1;
    assert(!mediacodec_dovi_p7_allowed(1, 1, &bad));
    for (int i = 1; i <= 2; i++) {
        AVPacket packet = fixture(argv[i], 1, 1);
        assert(mediacodec_dovi_convert_packet(NULL, &packet, &source) == 0);
        assert(packet.pts == 1234 && packet.dts == 1200 && packet.duration == 40 && packet.flags == AV_PKT_FLAG_KEY);
        assert(source.dv_profile == 7 && source.el_present_flag == 1);
        H2645Packet split = {0};
        assert(ff_h2645_packet_split(&split, packet.data, packet.size, NULL, 0, AV_CODEC_ID_HEVC, H2645_FLAG_SMALL_PADDING) == 0);
        assert(split.nb_nals == 2 && split.nals[0].type == 19 && split.nals[0].nuh_layer_id == 0);
        H2645NAL *nal = &split.nals[1];
        assert(nal->type == 62 && nal->nuh_layer_id == 0);
        DoviRpuOpaque *rpu = dovi_parse_unspec62_nalu(nal->raw_data, nal->raw_size);
        assert(rpu && !dovi_rpu_get_error(rpu));
        const DoviRpuDataHeader *header = dovi_rpu_get_header(rpu);
        assert(header && header->guessed_profile == 8 && !header->use_prev_vdr_rpu_flag);
        dovi_rpu_free_header(header);
        dovi_rpu_free(rpu);
        ff_h2645_packet_uninit(&split);
        av_packet_unref(&packet);
    }
    AVPacket packet = fixture(argv[1], 0, 1);
    rejected(&packet);
    packet = fixture(argv[1], 2, 0);
    rejected(&packet);
    packet = fixture(argv[3], 1, 0);
    rejected(&packet);
    packet = fixture(argv[1], 1, 0);
    packet.size = 14;
    rejected(&packet);
    packet = fixture(argv[1], 1, 0);
    packet.data[13] = 0;
    rejected(&packet);
    puts("PASS: MEL/FEL metadata -> P8.1, EL removal, timing, strict policy, source preservation, missing/duplicate/P5/truncated/malformed "
         "RPU rejection");
    return 0;
}
