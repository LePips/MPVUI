#import <CoreVideo/CoreVideo.h>
#include <assert.h>
#include <stdbool.h>
#include <stdarg.h>
#include <stdio.h>
#include <string.h>
#include <libavutil/frame.h>
#include <libplacebo/colorspace.h>

// Minimal storage for the fields read by the exact production validation gate.
enum { IMGFMT_VIDEOTOOLBOX = 1 };
struct options {
    int native_dovi_profile7;
};
struct priv {
    struct options *opts;
    bool dovi_unsupported_logged;
    int dovi_validated_state;
};
struct vo {
    struct priv *priv;
};
struct side_data {
    enum AVFrameSideDataType type;
};
struct mp_image {
    int imgfmt;
    struct {
        struct {
            enum pl_color_system sys;
        } repr;
    } params;
    struct side_data *ff_side_data;
    int num_ff_side_data;
};

static char message[512];
static int info_count;
static void record_log(bool info, const char *format, ...) {
    va_list args;
    va_start(args, format);
    vsnprintf(message, sizeof(message), format, args);
    va_end(args);
    info_count += info;
}
#define MP_INFO(vo, ...) record_log(true, __VA_ARGS__)
#define MP_ERR(vo, ...) record_log(false, __VA_ARGS__)
#define MP_VERBOSE(vo, ...) record_log(false, __VA_ARGS__)
#include "native_dovi_validation.h"

int main(void) {
    @autoreleasepool {
        struct options options = {0};
        struct priv state = {.opts = &options};
        struct vo vo = {.priv = &state};
        struct mp_image frame = {.imgfmt = IMGFMT_VIDEOTOOLBOX};
        CVPixelBufferRef buffer = NULL;
        assert(CVPixelBufferCreate(NULL, 16, 8, kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange, NULL, &buffer) == kCVReturnSuccess);

        // Every type of DV evidence requires validation, including P7 metadata
        // that cannot map to libplacebo's Dolby Vision color representation.
        struct side_data side_data = {.type = AV_FRAME_DATA_DOVI_METADATA};
        frame.ff_side_data = &side_data;
        frame.num_ff_side_data = 1;
        for (int type = 0; type < 3; type++) {
            state.dovi_unsupported_logged = false;
            frame.num_ff_side_data = type < 2;
            side_data.type = type == 0 ? AV_FRAME_DATA_DOVI_METADATA : AV_FRAME_DATA_DOVI_RPU_BUFFER;
            frame.params.repr.sys = type == 2 ? PL_COLOR_SYSTEM_DOLBYVISION : PL_COLOR_SYSTEM_BT_2020_NC;
            assert(!validate_native_dovi_frame(&vo, &frame, buffer));
            assert(strstr(message, "MPVUI_NATIVE_DOLBY_VISION_UNSUPPORTED:"));
        }
        state.dovi_unsupported_logged = false;
        frame.imgfmt = 0;
        assert(!validate_native_dovi_frame(&vo, &frame, NULL));
        assert(strstr(message, "software Dolby Vision"));

        frame.imgfmt = IMGFMT_VIDEOTOOLBOX;
        frame.params.repr.sys = PL_COLOR_SYSTEM_BT_2020_NC;
        frame.num_ff_side_data = 1;
        CVBufferSetAttachment(buffer, CFSTR("MPVUI.NativeDolbyVisionSession"), kCFBooleanTrue, kCVAttachmentMode_ShouldPropagate);
        uint8_t bytes[] = {0x19};
        CFDataRef rpu = CFDataCreate(NULL, bytes, sizeof(bytes));
        CVBufferSetAttachment(buffer, CFSTR("DolbyVisionRPUData"), rpu, kCVAttachmentMode_ShouldPropagate);
        CFRelease(rpu);
        CVBufferSetAttachment(buffer, CFSTR("MPVUI.NativeDolbyVisionProfile7To81"), kCFBooleanTrue, kCVAttachmentMode_ShouldPropagate);
        state.dovi_unsupported_logged = false;
        assert(!validate_native_dovi_frame(&vo, &frame, buffer));
        assert(strstr(message, "P7 conversion was not explicitly enabled"));
        options.native_dovi_profile7 = 1;
        assert(validate_native_dovi_frame(&vo, &frame, buffer));
        assert(strstr(message, "MPVUI_NATIVE_DOLBY_VISION_VALIDATED: profile7-to81=yes"));
        int validated_count = info_count;
        assert(validate_native_dovi_frame(&vo, &frame, buffer));
        assert(info_count == validated_count);

        // Ordinary HDR clears old evidence once, even if reconfiguration has
        // already reset the native validation state before this frame arrives.
        CVBufferRemoveAllAttachments(buffer);
        frame.num_ff_side_data = 0;
        for (int reset = 0; reset < 2; reset++) {
            if (reset)
                state.dovi_validated_state = 0;
            int before = info_count;
            assert(validate_native_dovi_frame(&vo, &frame, buffer));
            assert(strstr(message, "MPVUI_NATIVE_DOLBY_VISION_CLEARED:"));
            assert(info_count == before + 1);
            assert(validate_native_dovi_frame(&vo, &frame, buffer));
            assert(info_count == before + 1);
        }
        CVPixelBufferRelease(buffer);
        puts("Native DV frame gate: residual/RPU/software rejection, conversion opt-in, ordinary-frame clearing and log deduplication "
             "passed");
    }
}
