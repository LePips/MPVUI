#include <assert.h>
#include <stdio.h>
#include <string.h>
#include <libavutil/frame.h>
#include <libavutil/dovi_meta.h>
#include <libavutil/mem.h>
#include "libavcodec/dovi_rpu.h"
#define CONFIG_LIBDOVI 1
// Extracted directly from the locked FFmpeg source by run.py.
#include "native_dovi_functions.h"

int main(int argc, char **argv)
{
    assert(argc == 2);
    AVDOVIDecoderConfigurationRecord conf = {0};
    conf.rpu_present_flag = conf.bl_present_flag = 1;
    conf.dv_profile = 5;
    assert(videotoolbox_dovi_is_apple_hevc(&conf));
    conf.dv_profile = 8;
    assert(!videotoolbox_dovi_is_apple_hevc(&conf));
    conf.dv_bl_signal_compatibility_id = 1;
    assert(videotoolbox_dovi_is_apple_hevc(&conf));
    conf.dv_bl_signal_compatibility_id = 4;
    assert(videotoolbox_dovi_is_apple_hevc(&conf));
    conf.dv_md_compression = 1;
    assert(!videotoolbox_dovi_is_apple_hevc(&conf));
    conf.dv_md_compression = AV_DOVI_COMPRESSION_NONE;
    conf.dv_profile = 7;
    conf.el_present_flag = 1;
    conf.dv_bl_signal_compatibility_id = 6;
    assert(!videotoolbox_dovi_is_apple_hevc(&conf));
    assert(!videotoolbox_dovi_p7_allowed(1, 0, &conf));
    assert(!videotoolbox_dovi_p7_allowed(0, 1, &conf));
    assert(videotoolbox_dovi_p7_allowed(1, 1, &conf));
    conf.dv_bl_signal_compatibility_id = 1;
    assert(!videotoolbox_dovi_p7_allowed(1, 1, &conf));
    conf.dv_bl_signal_compatibility_id = 6;
    conf.rpu_present_flag = 0;
    assert(!videotoolbox_dovi_p7_allowed(1, 1, &conf));

    // Tests association with bytes already accepted by FFmpeg's real RPU
    // parser, not the parser's bitstream semantics or a hardware DV display.
    uint8_t original[] = {0x7c, 1, 0x19, 0x08, 0x09, 0x04};
    const uint8_t unchanged[] = {0x7c, 1, 0x19, 0x08, 0x09, 0x04};
    uint8_t validated[] = {0x19, 0x08, 0x09, 0x04};
    AVFrameSideData sd = {.data = validated, .size = sizeof(validated)};
    assert(videotoolbox_dovi_rpu_matches(&sd, original, sizeof(original)));
    assert(!videotoolbox_dovi_rpu_matches(NULL, original, sizeof(original)));
    assert(!videotoolbox_dovi_rpu_matches(&sd, NULL, sizeof(original)));
    assert(!videotoolbox_dovi_rpu_matches(&sd, original, 0));
    assert(!videotoolbox_dovi_rpu_matches(&sd, original, 2));
    assert(!videotoolbox_dovi_rpu_matches(&sd, original, sizeof(original) - 1));
    validated[0] ^= 1;
    assert(!videotoolbox_dovi_rpu_matches(&sd, original, sizeof(original)));
    sd.data = NULL;
    assert(!videotoolbox_dovi_rpu_matches(&sd, original, sizeof(original)));
    assert(!memcmp(original, unchanged, sizeof(original)));

    // Real first-frame Profile 5 metadata from the repository's bundled clip.
    // No picture/audio data is needed to exercise FFmpeg's RPU parser.
    FILE *file = fopen(argv[1], "rb");
    assert(file);
    uint8_t rpu[4096];
    size_t size = fread(rpu, 1, sizeof(rpu), file);
    assert(!ferror(file) && size == 237);
    fclose(file);
    DOVIContext context = {0};
    int strict = AV_EF_CRCCHECK | AV_EF_EXPLODE;
    assert(ff_dovi_rpu_parse(&context, rpu, size, strict) == 0);
    assert(ff_dovi_guess_profile_hevc(&context.header) == 5);
    assert(context.mapping && context.color);
    ff_dovi_ctx_flush(&context);
    assert(!context.mapping && !context.color);
    assert(ff_dovi_rpu_parse(&context, rpu, size, strict) == 0);
    ff_dovi_ctx_flush(&context);
    assert(ff_dovi_rpu_parse(&context, rpu, 2, strict) < 0);
    ff_dovi_ctx_flush(&context);
    rpu[0] = 0;
    assert(ff_dovi_rpu_parse(&context, rpu, size, strict) < 0);
    ff_dovi_ctx_unref(&context);
    puts("Native DV: strict/opt-in profile contract, original/current association, real P5 RPU parse/flush/malformed checks passed");
}
