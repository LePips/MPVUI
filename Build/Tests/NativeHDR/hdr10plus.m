#include <assert.h>
#include <stdio.h>
#include <libavutil/frame.h>
#include "avfoundation_hdr10plus.h"

static AVDynamicHDRPlus fixture(int windows, int version, int scene)
{
    AVDynamicHDRPlus h = {0};
    h.num_windows = windows;
    h.application_version = version;
    h.targeted_system_display_maximum_luminance = (AVRational){1000 + scene, 1};
    for (int w = 0; w < windows; w++) {
        AVHDRPlusColorTransformParams *p = &h.params[w];
        p->window_upper_left_corner_x = (AVRational){w * 10, 1};
        p->window_upper_left_corner_y = (AVRational){w * 20, 1};
        p->window_lower_right_corner_x = (AVRational){1000, 1};
        p->window_lower_right_corner_y = (AVRational){500, 1};
        for (int c = 0; c < 3; c++) p->maxscl[c] = (AVRational){10000 + scene + w + c, 100000};
        p->average_maxrgb = (AVRational){5000 + scene, 100000};
        p->fraction_bright_pixels = (AVRational){250, 1000};
        p->num_distribution_maxrgb_percentiles = 2;
        p->distribution_maxrgb[0] = (AVHDRPlusPercentile){10, {1000, 100000}};
        p->distribution_maxrgb[1] = (AVHDRPlusPercentile){90, {90000, 100000}};
        // Saturation without tone mapping previously corrupted following windows.
        p->tone_mapping_flag = w & 1;
        p->color_saturation_mapping_flag = !(w & 1);
        p->color_saturation_weight = (AVRational){12, 8};
        p->knee_point_x = (AVRational){1000, 4095};
        p->knee_point_y = (AVRational){2000, 4095};
        p->num_bezier_curve_anchors = 2;
        p->bezier_curve_anchors[0] = (AVRational){200, 1023};
        p->bezier_curve_anchors[1] = (AVRational){800, 1023};
    }
    return h;
}

static CMSampleBufferRef sample(int pts)
{
    CVPixelBufferRef pixels = NULL;
    assert(CVPixelBufferCreate(NULL, 2, 2, kCVPixelFormatType_32BGRA, NULL, &pixels) == noErr);
    CMVideoFormatDescriptionRef format = NULL;
    assert(CMVideoFormatDescriptionCreateForImageBuffer(NULL, pixels, &format) == noErr);
    CMSampleTimingInfo timing = {kCMTimeInvalid, CMTimeMake(pts, 24), kCMTimeInvalid};
    CMSampleBufferRef out = NULL;
    assert(CMSampleBufferCreateReadyWithImageBuffer(NULL, pixels, format, &timing, &out) == noErr);
    CFRelease(format);
    CVPixelBufferRelease(pixels);
    return out;
}

static CFDataRef payload(CMSampleBufferRef s)
{
    CFArrayRef array = CMSampleBufferGetSampleAttachmentsArray(s, false);
    if (!array) return NULL;
    CFDictionaryRef d = CFArrayGetValueAtIndex(array, 0);
    return CFDictionaryGetValue(d, kCMSampleAttachmentKey_HDR10PlusPerFrameData);
}

static AVDynamicHDRPlus readback(CMSampleBufferRef s)
{
    CFDataRef data = payload(s);
    assert(data && CFGetTypeID(data) == CFDataGetTypeID());
    const uint8_t *bytes = CFDataGetBytePtr(data);
    const uint8_t header[] = {0xb5, 0, 0x3c, 0, 1, 4};
    assert(CFDataGetLength(data) > 6 && !memcmp(bytes, header, sizeof(header)));
    AVDynamicHDRPlus out = {0};
    assert(av_dynamic_hdr_plus_from_t35(&out, bytes + 6, CFDataGetLength(data) - 6) == 0);
    uint8_t serialized[AV_HDR_PLUS_MAX_PAYLOAD_SIZE], *dst = serialized;
    size_t size = sizeof(serialized);
    assert(av_dynamic_hdr_plus_to_t35(&out, &dst, &size) == 0);
    assert(size == (size_t)CFDataGetLength(data) - 6);
    assert(!memcmp(serialized, bytes + 6, size));
    return out;
}

static void serialization(void)
{
    for (int version = 0; version <= 1; version++) {
        for (int windows = 1; windows <= 3; windows++) {
            AVDynamicHDRPlus h = fixture(windows, version, 17);
            CMSampleBufferRef s = sample(0);
            assert(avf_attach_hdr10plus(s, &h, sizeof(h), false) == AVF_HDR10PLUS_ATTACHED);
            AVDynamicHDRPlus out = readback(s);
            assert(out.application_version == version && out.num_windows == windows);
            assert(out.targeted_system_display_maximum_luminance.num == 1017);
            for (int w = 0; w < windows; w++) {
                assert(out.params[w].tone_mapping_flag == (w & 1));
                assert(out.params[w].color_saturation_mapping_flag == !(w & 1));
                assert(out.params[w].maxscl[2].num == 10019 + w);
                if (w & 1) assert(out.params[w].bezier_curve_anchors[1].num == 800);
                else assert(out.params[w].color_saturation_weight.num == 12);
            }
            CFRelease(s);
        }
    }
    // Max-sized legal arrays exercise every serializer bound under ASan/UBSan.
    AVDynamicHDRPlus h = fixture(3, 1, 0);
    h.targeted_system_display_actual_peak_luminance_flag = 1;
    h.mastering_display_actual_peak_luminance_flag = 1;
    h.num_rows_targeted_system_display_actual_peak_luminance = 25;
    h.num_cols_targeted_system_display_actual_peak_luminance = 25;
    h.num_rows_mastering_display_actual_peak_luminance = 25;
    h.num_cols_mastering_display_actual_peak_luminance = 25;
    for (int i = 0; i < 25; i++) for (int j = 0; j < 25; j++) {
        h.targeted_system_display_actual_peak_luminance[i][j] = (AVRational){15, 15};
        h.mastering_display_actual_peak_luminance[i][j] = (AVRational){7, 15};
    }
    for (int w = 0; w < 3; w++) {
        AVHDRPlusColorTransformParams *p = &h.params[w];
        p->tone_mapping_flag = p->color_saturation_mapping_flag = 1;
        p->num_distribution_maxrgb_percentiles = p->num_bezier_curve_anchors = 15;
        for (int i = 0; i < 15; i++) {
            p->distribution_maxrgb[i] = (AVHDRPlusPercentile){i * 7, {50000, 100000}};
            p->bezier_curve_anchors[i] = (AVRational){i * 50, 1023};
        }
    }
    CMSampleBufferRef s = sample(0);
    assert(avf_attach_hdr10plus(s, &h, sizeof(h), false) == AVF_HDR10PLUS_ATTACHED);
    assert(CFDataGetLength(payload(s)) == 6 + AV_HDR_PLUS_MAX_PAYLOAD_SIZE);
    AVDynamicHDRPlus out = readback(s);
    assert(out.mastering_display_actual_peak_luminance[24][24].num == 7);
    CFRelease(s);
}

static void association(void)
{
    AVFrame *decoded[3];
    for (int i = 0; i < 3; i++) {
        AVFrame *f = decoded[i] = av_frame_alloc();
        f->format = AV_PIX_FMT_BGRA;
        f->width = f->height = 2;
        assert(av_frame_get_buffer(f, 0) == 0);
        f->pts = i;
        AVDynamicHDRPlus *h = av_dynamic_hdr_plus_create_side_data(f);
        assert(h);
        *h = fixture(1, 1, i * 100);
    }
    // Decode order differs from presentation order. References retain each
    // frame's side data after decoder-owned frames are released.
    const int order[] = {2, 0, 1};
    AVFrame *reordered[3];
    for (int i = 0; i < 3; i++) reordered[i] = av_frame_clone(decoded[order[i]]);
    for (int i = 0; i < 3; i++) av_frame_free(&decoded[i]);
    CMSampleBufferRef queued[3];
    for (int i = 0; i < 3; i++) {
        assert(reordered[i]);
        AVFrameSideData *sd = av_frame_get_side_data(reordered[i], AV_FRAME_DATA_DYNAMIC_HDR_PLUS);
        queued[i] = sample((int)reordered[i]->pts);
        assert(avf_attach_hdr10plus(queued[i], sd->data, sd->size, false) == AVF_HDR10PLUS_ATTACHED);
        // A queued CMSample owns an immutable snapshot, even if the producer
        // mutates or releases its structured side data immediately afterward.
        memset(sd->data, 0, sd->size);
        av_frame_free(&reordered[i]);
    }
    for (int i = 0; i < 3; i++) {
        AVDynamicHDRPlus h = readback(queued[i]);
        assert(CMSampleBufferGetPresentationTimeStamp(queued[i]).value == order[i]);
        assert(h.targeted_system_display_maximum_luminance.num == 1000 + order[i] * 100);
        CFRelease(queued[i]); // renderer flush/seek releases queued samples
    }
    CMSampleBufferRef next = sample(240);
    assert(avf_attach_hdr10plus(next, NULL, 0, false) == AVF_HDR10PLUS_NONE);
    assert(!payload(next));
    CFRelease(next);
}

static void invalidation(void)
{
    CMSampleBufferRef s = sample(0);
    AVDynamicHDRPlus h = fixture(1, 1, 0);
    assert(avf_attach_hdr10plus(s, &h, sizeof(h), false) == AVF_HDR10PLUS_ATTACHED);
    assert(avf_attach_hdr10plus(s, &h, sizeof(h), true) == AVF_HDR10PLUS_TRANSFORMED);
    assert(!payload(s));
    assert(avf_attach_hdr10plus(s, &h, sizeof(h) - 1, false) == AVF_HDR10PLUS_INVALID);
    assert(!payload(s));
    for (int n = 0; n < 7; n++) {
        h = fixture(1, 1, 0);
        switch (n) {
        case 0: h.num_windows = 4; break;
        case 1: h.params[0].num_distribution_maxrgb_percentiles = 16; break;
        case 2: h.params[0].maxscl[0].den = 0; break;
        case 3: h.params[0].fraction_bright_pixels.num = INT_MAX; break;
        case 4: h.params[0].tone_mapping_flag = 1; h.params[0].num_bezier_curve_anchors = 16; break;
        case 5: h.targeted_system_display_actual_peak_luminance_flag = 1;
                h.num_rows_targeted_system_display_actual_peak_luminance = 26; break;
        case 6: h.application_version = 2; break;
        }
        assert(avf_attach_hdr10plus(s, &h, sizeof(h), false) == AVF_HDR10PLUS_INVALID);
        assert(!payload(s));
    }
    h = fixture(1, 1, 0);
    assert(avf_attach_hdr10plus(s, &h, sizeof(h), false) == AVF_HDR10PLUS_ATTACHED);
    assert(avf_attach_hdr10plus(s, NULL, 0, false) == AVF_HDR10PLUS_NONE && !payload(s));
    CFRelease(s);
}

int main(void)
{
    serialization();
    association();
    invalidation();
    puts("Native HDR10+: T.35 roundtrip/version/windows, per-sample readback/reorder/flush, invalidation passed");
}
