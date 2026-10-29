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

// Wraps the extracted videotoolbox_dovi_rpu_is_compressed for an HEVC NAL.
int native_dovi_rpu_is_compressed(const uint8_t *data, int size);

static size_t read_rpu(const char *path, uint8_t *rpu, size_t capacity) {
    FILE *file = fopen(path, "rb");
    assert(file);
    size_t size = fread(rpu, 1, capacity, file);
    assert(!ferror(file) && size > 2 && size < capacity);
    fclose(file);
    return size;
}

// Removes emulation prevention from a generated NAL payload in place.
static int unescape(uint8_t *data, int size) {
    int length = 0, zeros = 0;
    for (int i = 0; i < size; i++) {
        if (zeros >= 2 && data[i] == 3) {
            zeros = 0;
            continue;
        }
        zeros = data[i] ? 0 : zeros + 1;
        data[length++] = data[i];
    }
    return length;
}

// Wraps a generated NAL-prefixed RPU as the parsed, padded UNSPEC62 unit.
static int rpu_is_compressed(const uint8_t *rpu, int size) {
    uint8_t unit[4096] = {0x7c, 1};
    assert(size > 0 && size + 2 + AV_INPUT_BUFFER_PADDING_SIZE <= (int)sizeof(unit));
    memcpy(unit + 2, rpu, size);
    return native_dovi_rpu_is_compressed(unit, unescape(unit + 2, size) + 2);
}

static void profile_matrix(void) {
    assert(!videotoolbox_dovi_is_apple_hevc(NULL));
    for (int profile = 0; profile <= 31; profile++) {
        for (int compatibility = 0; compatibility <= 15; compatibility++) {
            for (int compression = 0; compression <= 7; compression++) {
                for (int flags = 0; flags < 8; flags++) {
                    AVDOVIDecoderConfigurationRecord conf = {
                        .dv_profile = profile,
                        .dv_bl_signal_compatibility_id = compatibility,
                        .dv_md_compression = compression,
                        .rpu_present_flag = !!(flags & 4),
                        .el_present_flag = !!(flags & 2),
                        .bl_present_flag = !!(flags & 1),
                    };
                    int supported =
                        flags == 5 && ((profile == 5 && compatibility == 0 && compression == AV_DOVI_COMPRESSION_NONE) ||
                                       (profile == 8 && (compatibility == 1 || compatibility == 4) &&
                                        (compression == AV_DOVI_COMPRESSION_NONE || compression == AV_DOVI_COMPRESSION_LIMITED ||
                                         compression == AV_DOVI_COMPRESSION_EXTENDED)));
                    assert(videotoolbox_dovi_is_apple_hevc(&conf) == supported);
                    assert(!videotoolbox_dovi_p7_allowed(1, 0, &conf));
                    assert(!videotoolbox_dovi_p7_allowed(0, 1, &conf));
                    assert(videotoolbox_dovi_p7_allowed(1, 1, &conf) ==
                           (profile == 7 && compatibility == 6 && compression == AV_DOVI_COMPRESSION_NONE && (flags & 5) == 5));
                }
            }
        }
    }
}

static void recovered_profile(AVCodecParameters *par, const AVDOVIMetadata *metadata, int profile, int compatibility) {
    AVDOVIDecoderConfigurationRecord conf = {.dv_profile = 99};
    assert(videotoolbox_dovi_configure_from_metadata(NULL, par, metadata, &conf) == 0);
    assert(conf.dv_profile == profile);
    if (profile) {
        assert(conf.dv_bl_signal_compatibility_id == compatibility);
        assert(conf.rpu_present_flag && conf.bl_present_flag);
        assert(conf.el_present_flag == (profile == 7));
        assert(conf.dv_level > 0 && conf.dv_md_compression == AV_DOVI_COMPRESSION_NONE);
    }
    av_packet_side_data_free(&par->coded_side_data, &par->nb_coded_side_data);
}

int main(int argc, char **argv) {
    assert(argc == 4);
    profile_matrix();
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
    // Compressed P8 metadata is expanded before submission; P5 cannot be compressed.
    conf.dv_md_compression = AV_DOVI_COMPRESSION_LIMITED;
    assert(videotoolbox_dovi_is_apple_hevc(&conf));
    conf.dv_md_compression = AV_DOVI_COMPRESSION_EXTENDED;
    assert(videotoolbox_dovi_is_apple_hevc(&conf));
    conf.dv_md_compression = AV_DOVI_COMPRESSION_RESERVED;
    assert(!videotoolbox_dovi_is_apple_hevc(&conf));
    conf.dv_profile = 5;
    conf.dv_md_compression = AV_DOVI_COMPRESSION_EXTENDED;
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

    // Synthetic Profile 5 metadata generated by dovi_tool on the test host.
    // No picture/audio data is needed to exercise FFmpeg's RPU parser.
    uint8_t rpu[4096];
    size_t size = read_rpu(argv[1], rpu, sizeof(rpu));
    DOVIContext context = {0};
    int strict = AV_EF_CRCCHECK | AV_EF_EXPLODE;
    assert(ff_dovi_rpu_parse(&context, rpu, size, strict) == 0);
    assert(ff_dovi_guess_profile_hevc(&context.header) == 5);
    assert(context.mapping && context.color);
    AVDOVIMetadata *p5_metadata = NULL;
    assert(ff_dovi_get_metadata(&context, &p5_metadata) > 0);
    AVCodecParameters p5_par = {
        .codec_id = AV_CODEC_ID_HEVC,
        .format = AV_PIX_FMT_YUV420P10,
        .width = 320,
        .height = 180,
        .framerate = {120, 1},
    };
    recovered_profile(&p5_par, p5_metadata, 5, 0);
    av_free(p5_metadata);
    ff_dovi_ctx_flush(&context);
    assert(!context.mapping && !context.color);
    assert(ff_dovi_rpu_parse(&context, rpu, size, strict) == 0);
    ff_dovi_ctx_flush(&context);
    assert(ff_dovi_rpu_parse(&context, rpu, 2, strict) < 0);
    ff_dovi_ctx_flush(&context);
    rpu[0] = 0;
    assert(ff_dovi_rpu_parse(&context, rpu, size, strict) < 0);
    ff_dovi_ctx_unref(&context);

    // Synthetic P8.1 metadata. A compressed RPU refers to the previous RPU;
    // expansion must yield a standalone RPU carrying the same metadata.
    size = read_rpu(argv[2], rpu, sizeof(rpu));
    DOVIContext decoder = {.cfg = {.dv_profile = 8, .dv_bl_signal_compatibility_id = 1, .dv_md_compression = AV_DOVI_COMPRESSION_EXTENDED}};
    DOVIContext writer = {.cfg = decoder.cfg};
    AVDOVIMetadata *source = NULL;
    assert(ff_dovi_rpu_parse(&decoder, rpu, size, strict) == 0);
    assert(ff_dovi_get_metadata(&decoder, &source) > 0);
    AVCodecParameters par = {
        .codec_id = AV_CODEC_ID_HEVC,
        .format = AV_PIX_FMT_YUV420P10,
        .width = 320,
        .height = 180,
        .framerate = {120, 1},
        .color_space = AVCOL_SPC_BT2020_NCL,
        .color_primaries = AVCOL_PRI_BT2020,
        .color_trc = AVCOL_TRC_SMPTE2084,
    };
    recovered_profile(&par, source, 8, 1);
    par.color_trc = AVCOL_TRC_ARIB_STD_B67;
    recovered_profile(&par, source, 8, 4);
    par.color_space = AVCOL_SPC_BT709;
    par.color_primaries = AVCOL_PRI_BT709;
    par.color_trc = AVCOL_TRC_BT709;
    recovered_profile(&par, source, 8, 2); // Detected, but rejected by the native profile gate.
    par.color_space = AVCOL_SPC_BT2020_NCL;
    par.color_primaries = AVCOL_PRI_BT2020;
    par.color_trc = AVCOL_TRC_SMPTE2084;
    recovered_profile(&par, NULL, 0, 0); // HDR tags alone cannot establish DV.
    par.format = AV_PIX_FMT_YUV420P;
    recovered_profile(&par, source, 0, 0);
    par.format = AV_PIX_FMT_YUV420P10;
    par.codec_id = AV_CODEC_ID_AV1;
    recovered_profile(&par, source, 0, 0);
    par.codec_id = AV_CODEC_ID_HEVC;

    // Synthetic P7 MEL metadata: identity mapping plus zero enhancement residual.
    // Only metadata is generated here, not a full enhancement-layer image.
    AVDOVIRpuDataHeader *header = av_dovi_get_header(source);
    AVDOVIRpuDataHeader original_header = *header;
    header->vdr_bit_depth = 12;
    header->el_spatial_resampling_filter_flag = 1;
    header->disable_residual_flag = 0;
    recovered_profile(&par, source, 7, 6);
    par.color_trc = AVCOL_TRC_ARIB_STD_B67;
    recovered_profile(&par, source, 0, 0);
    par.color_trc = AVCOL_TRC_SMPTE2084;
    header->vdr_bit_depth = 10; // Profile 4 is not native-compatible.
    recovered_profile(&par, source, 0, 0);
    header->vdr_rpu_profile = 2;
    recovered_profile(&par, source, 0, 0);
    header->vdr_rpu_profile = 1;
    header->vdr_bit_depth = 12;
    AVDOVIDataMapping *mapping = av_dovi_get_mapping(source);
    AVDOVIDataMapping original_mapping = *mapping;
    mapping->nlq_method_idc = AV_DOVI_NLQ_LINEAR_DZ;
    mapping->nlq_pivots[0] = 0;
    mapping->nlq_pivots[1] = 1023;
    for (int c = 0; c < 3; c++) {
        mapping->nlq[c].nlq_offset = 0;
        mapping->nlq[c].vdr_in_max = 1ULL << header->coef_log2_denom;
        mapping->nlq[c].linear_deadzone_slope = 0;
        mapping->nlq[c].linear_deadzone_threshold = 0;
    }
    DOVIContext p7writer = {.cfg = {.dv_profile = 7, .dv_bl_signal_compatibility_id = 6}};
    uint8_t *p7 = NULL;
    int p7_size = 0;
    assert(ff_dovi_rpu_generate(&p7writer, source, FF_DOVI_WRAP_NAL, &p7, &p7_size) == 0);
    int p7_payload_size = unescape(p7, p7_size);
    uint8_t p7_fixture[4096];
    size_t p7_fixture_size = read_rpu(argv[3], p7_fixture, sizeof(p7_fixture));
    assert(p7_fixture_size == (size_t)p7_payload_size && !memcmp(p7_fixture, p7, p7_fixture_size));
    DOVIContext p7decoder = {0};
    assert(ff_dovi_rpu_parse(&p7decoder, p7, p7_payload_size, strict) == 0);
    assert(ff_dovi_guess_profile_hevc(&p7decoder.header) == 7);
    av_free(p7);
    ff_dovi_ctx_unref(&p7writer);
    ff_dovi_ctx_unref(&p7decoder);
    *header = original_header;
    *mapping = original_mapping;
    uint8_t *standalone = NULL, *compressed = NULL;
    int standalone_size = 0, compressed_size = 0;
    assert(ff_dovi_rpu_generate(&writer, source, FF_DOVI_WRAP_NAL, &standalone, &standalone_size) == 0);
    assert(ff_dovi_rpu_generate(&writer, source, FF_DOVI_WRAP_NAL | FF_DOVI_COMPRESS_RPU, &compressed, &compressed_size) == 0);
    assert(compressed_size < standalone_size);
    assert(!rpu_is_compressed(standalone, standalone_size));
    assert(rpu_is_compressed(compressed, compressed_size));
    // FFmpeg pads parsed NAL payloads for its bit reader.
    uint8_t truncated[4 + AV_INPUT_BUFFER_PADDING_SIZE] = {0x7c, 1, 0x19, 0x08};
    assert(!native_dovi_rpu_is_compressed(truncated, 4));

    ff_dovi_ctx_flush(&decoder);
    uint8_t payload[4096];
    assert(standalone_size <= (int)sizeof(payload) && compressed_size <= (int)sizeof(payload));
    memcpy(payload, standalone, standalone_size);
    assert(ff_dovi_rpu_parse(&decoder, payload, unescape(payload, standalone_size), strict) == 0);
    memcpy(payload, compressed, compressed_size);
    assert(ff_dovi_rpu_parse(&decoder, payload, unescape(payload, compressed_size), strict) == 0);
    AVDOVIMetadata *resolved = NULL;
    assert(ff_dovi_get_metadata(&decoder, &resolved) > 0);
    DOVIContext expander = {.cfg = decoder.cfg};
    expander.cfg.dv_md_compression = AV_DOVI_COMPRESSION_NONE;
    uint8_t *expanded = NULL;
    int expanded_size = 0;
    assert(ff_dovi_rpu_generate(&expander, resolved, FF_DOVI_WRAP_NAL, &expanded, &expanded_size) == 0);
    assert(!rpu_is_compressed(expanded, expanded_size));
    assert(expanded_size == standalone_size && !memcmp(expanded, standalone, standalone_size));
    av_free(source);
    av_free(resolved);
    av_free(standalone);
    av_free(compressed);
    av_free(expanded);
    ff_dovi_ctx_unref(&decoder);
    ff_dovi_ctx_unref(&writer);
    ff_dovi_ctx_unref(&expander);
    puts("Native DV: profile/compatibility matrix, in-band P5/P7/P8 recovery, strict/opt-in policy, synthetic P7 fixture, "
         "original/current association, P5 parse/flush/malformed checks, P8.1 compression detection and expansion passed");
}
