#include <assert.h>
#include <stdio.h>
#include <string.h>
#include "avfoundation_color_math.h"

static void near(double got, double expected, double eps) {
    if (!isfinite(got) || !isfinite(expected) || fabs(got - expected) > eps) {
        fprintf(stderr, "got %.12g expected %.12g ± %.3g\n", got, expected, eps);
        assert(0);
    }
}
static struct avf_overlay_color setup(enum avf_transfer trc) {
    return (struct avf_overlay_color){
        .transfer = trc,
        .kr = .2627,
        .kb = .0593,
        .white_nits = 203,
        .rgb_matrix = {{.627403896, .329283038, .043313066}, {.069097289, .919540395, .011362316}, {.016391439, .088013308, .895595253}}};
}

// Original per-channel conversion, independent of the grayscale fast path and
// production decode/clamp helpers, including alpha-zero artwork with dirty RGB.
static void reference_subtitle_nits(const struct avf_overlay_color *color, const uint8_t bgra[4], double rgb[3]) {
    double alpha = bgra[3] / 255.0, linear[3] = {0};
    if (alpha > 0) {
        for (int channel = 0; channel < 3; channel++) {
            double value = fmin(1, fmax(0, bgra[2 - channel] / (255.0 * alpha)));
            linear[channel] = value <= .04045 ? value / 12.92 : pow((value + .055) / 1.055, 2.4);
        }
    }
    double white = color->transfer == AVF_PQ || color->transfer == AVF_HLG ? color->white_nits : 100;
    for (int channel = 0; channel < 3; channel++) {
        rgb[channel] = 0;
        for (int input = 0; input < 3; input++)
            rgb[channel] += color->rgb_matrix[channel][input] * linear[input];
        rgb[channel] = fmax(rgb[channel], 0) * white;
    }
}

static void expect_subtitle_conversion(const struct avf_overlay_color *color, const uint8_t bgra[4]) {
    double actual[3], expected[3];
    avf_subtitle_nits(color, bgra, actual);
    reference_subtitle_nits(color, bgra, expected);
    for (int channel = 0; channel < 3; channel++)
        near(actual[channel], expected[channel], 1e-12);
}

static void test_grayscale_subtitles(void) {
    const double matrices[][3][3] = {
        {{1, 0, 0}, {0, 1, 0}, {0, 0, 1}},
        {{.627403896, .329283038, .043313066}, {.069097289, .919540395, .011362316}, {.016391439, .088013308, .895595253}},
        {{1.660491, -.587641, -.072850}, {-.124550, 1.132900, -.008349}, {-.018151, -.100579, 1.118730}},
    };
    const double white_levels[] = {100, 203, 400};
    const uint8_t colors[][3] = {{255, 0, 0}, {0, 255, 0}, {0, 0, 255}, {37, 151, 229}, {128, 128, 127}, {127, 128, 128}};
    for (int transfer = AVF_SRGB; transfer <= AVF_LINEAR; transfer++) {
        struct avf_overlay_color color = setup(transfer);
        for (size_t matrix = 0; matrix < sizeof(matrices) / sizeof(matrices[0]); matrix++) {
            memcpy(color.rgb_matrix, matrices[matrix], sizeof(color.rgb_matrix));
            for (size_t white = 0; white < sizeof(white_levels) / sizeof(white_levels[0]); white++) {
                color.white_nits = white_levels[white];
                for (int alpha = 0; alpha <= 255; alpha++) {
                    for (int gray = 0; gray <= alpha; gray++) {
                        uint8_t bgra[4] = {gray, gray, gray, alpha};
                        expect_subtitle_conversion(&color, bgra);
                    }
                    for (size_t c = 0; c < sizeof(colors) / sizeof(colors[0]); c++) {
                        uint8_t bgra[4] = {0, 0, 0, alpha};
                        for (int channel = 0; channel < 3; channel++)
                            bgra[channel] = (colors[c][channel] * alpha + 127) / 255;
                        expect_subtitle_conversion(&color, bgra);
                    }
                    // Out-of-coverage bytes and values above alpha retain the
                    // previous clamping behavior rather than creating color.
                    uint8_t dirty_gray[4] = {255, 255, 255, alpha};
                    uint8_t dirty_color[4] = {11, 227, 93, alpha};
                    expect_subtitle_conversion(&color, dirty_gray);
                    expect_subtitle_conversion(&color, dirty_color);
                }
            }
        }
    }
}

// Reference the original full blend, including conversion of the background
// for opaque pixels, so fast paths must preserve the same visible result.
static void reference_blend_pixel(const struct avf_overlay_color *color, const uint8_t bgra[4], double yuv[3]) {
    double alpha = bgra[3] / 255.0;
    if (alpha == 0)
        return;
    double kr = color->kr, kb = color->kb, kg = 1 - kr - kb;
    double rgb[3] = {
        yuv[0] + 2 * (1 - kr) * yuv[2],
        yuv[0] - 2 * kb * (1 - kb) / kg * yuv[1] - 2 * kr * (1 - kr) / kg * yuv[2],
        yuv[0] + 2 * (1 - kb) * yuv[1],
    };
    avf_to_nits(color->transfer, rgb, kr, kb);
    double subtitle[3];
    reference_subtitle_nits(color, bgra, subtitle);
    for (int channel = 0; channel < 3; channel++)
        rgb[channel] = rgb[channel] * (1 - alpha) + subtitle[channel] * alpha;
    avf_from_nits(color->transfer, rgb, kr, kb);
    yuv[0] = kr * rgb[0] + kg * rgb[1] + kb * rgb[2];
    yuv[1] = (rgb[2] - yuv[0]) / (2 * (1 - kb));
    yuv[2] = (rgb[0] - yuv[0]) / (2 * (1 - kr));
}

static void test_blend_fast_paths(void) {
    const uint8_t alphas[] = {0, 1, 64, 128, 254, 255};
    const uint8_t colors[][3] = {{255, 0, 0}, {0, 255, 0}, {0, 0, 255}, {37, 151, 229}, {255, 255, 255}, {0, 0, 0}};
    const double sources[][3] = {{.03, -.15, .28}, {.85, .25, -.17}, {-.1, .8, -.7}, {.99, 0, 0}};
    for (int transfer = AVF_SRGB; transfer <= AVF_LINEAR; transfer++) {
        struct avf_overlay_color color = setup(transfer);
        for (size_t a = 0; a < sizeof(alphas); a++) {
            for (size_t c = 0; c < sizeof(colors) / sizeof(colors[0]); c++) {
                uint8_t bgra[4] = {0, 0, 0, alphas[a]};
                for (int channel = 0; channel < 3; channel++)
                    bgra[channel] = (colors[c][channel] * alphas[a] + 127) / 255;
                // RGB outside zero coverage is deliberately unspecified.
                if (!alphas[a])
                    memset(bgra, 0xa5, 3);
                for (size_t s = 0; s < sizeof(sources) / sizeof(sources[0]); s++) {
                    double actual[3], expected[3];
                    memcpy(actual, sources[s], sizeof(actual));
                    memcpy(expected, actual, sizeof(expected));
                    avf_blend_pixel(&color, bgra, actual);
                    reference_blend_pixel(&color, bgra, expected);
                    for (int channel = 0; channel < 3; channel++)
                        near(actual[channel], expected[channel], 1e-14);
                    if (!alphas[a])
                        assert(!memcmp(actual, sources[s], sizeof(actual)));
                }
            }
        }
        // Every coverage mask, including clipped cells, preserves uncovered
        // luma and averages chroma over all extant pixels rather than ink only.
        for (int count = 1; count <= 4; count++) {
            for (unsigned mask = 0; mask < (1u << count); mask++) {
                uint8_t bgra[4][4] = {{0}};
                double actual_y[4] = {-.03, .27, .58, 1.04};
                double expected_y[4];
                memcpy(expected_y, actual_y, sizeof(expected_y));
                double actual_uv[2] = {.12, -.07}, delta[2] = {0};
                for (int pixel = 0; pixel < count; pixel++) {
                    if (!(mask & (1u << pixel))) {
                        memset(bgra[pixel], 0x5a, 3);
                        continue;
                    }
                    const uint8_t alpha = alphas[pixel + 2];
                    bgra[pixel][0] = alpha / 3;
                    bgra[pixel][1] = alpha / 2;
                    bgra[pixel][2] = alpha;
                    bgra[pixel][3] = alpha;
                    double sample[3] = {expected_y[pixel], actual_uv[0], actual_uv[1]};
                    reference_blend_pixel(&color, bgra[pixel], sample);
                    expected_y[pixel] = sample[0];
                    delta[0] += sample[1] - actual_uv[0];
                    delta[1] += sample[2] - actual_uv[1];
                }
                assert(avf_blend_chroma_cell(&color, bgra, actual_y, actual_uv, count) == (mask != 0));
                for (int pixel = 0; pixel < 4; pixel++)
                    near(actual_y[pixel], expected_y[pixel], 1e-14);
                near(actual_uv[0], .12 + delta[0] / count, 1e-14);
                near(actual_uv[1], -.07 + delta[1] / count, 1e-14);
            }
        }
    }
}
int main(void) {
    test_grayscale_subtitles();
    test_blend_fast_paths();
    // Independent BT.2100 reference anchors, not just forward/inverse agreement.
    double pq[3] = {100, 203, 1000};
    avf_from_nits(AVF_PQ, pq, .2627, .0593);
    near(pq[0], .5080784215, 1e-9);
    near(pq[1], .5806888810, 1e-9);
    near(pq[2], .7518270962, 1e-9);
    double hlg[3] = {.75, .75, .75};
    avf_to_nits(AVF_HLG, hlg, .2627, .0593);
    near(hlg[0], 203.1521459, 1e-5);
    for (int trc = AVF_SRGB; trc <= AVF_LINEAR; trc++) {
        double rgb[3] = {.13, .42, .79}, original[3];
        memcpy(original, rgb, sizeof(rgb));
        avf_to_nits(trc, rgb, .2627, .0593);
        avf_from_nits(trc, rgb, .2627, .0593);
        for (int c = 0; c < 3; c++)
            near(rgb[c], original[c], 1e-7);
    }
    uint8_t white[4] = {255, 255, 255, 255}, red[4] = {0, 0, 255, 255}, half[4] = {128, 128, 128, 128}, clear[4] = {0};
    for (int trc = AVF_PQ; trc <= AVF_HLG; trc++) {
        struct avf_overlay_color color = setup(trc);
        double yuv[3] = {0, 0, 0};
        avf_blend_pixel(&color, white, yuv);
        double rgb[3] = {yuv[0], yuv[0], yuv[0]};
        avf_to_nits(trc, rgb, color.kr, color.kb);
        near(rgb[0], 203, 1e-5);
        near(yuv[1], 0, 1e-8);
        near(yuv[2], 0, 1e-8);
        color.white_nits = 100;
        yuv[0] = yuv[1] = yuv[2] = 0;
        avf_blend_pixel(&color, white, yuv);
        rgb[0] = rgb[1] = rgb[2] = yuv[0];
        avf_to_nits(trc, rgb, color.kr, color.kb);
        near(rgb[0], 100, 1e-5);
        color.white_nits = 203;
        yuv[0] = yuv[1] = yuv[2] = 0;
        avf_blend_pixel(&color, half, yuv);
        rgb[0] = rgb[1] = rgb[2] = yuv[0];
        avf_to_nits(trc, rgb, color.kr, color.kb);
        near(rgb[0], 203 * 128.0 / 255, 1e-5);
        // Black translucent background over 1000 nit white must halve display light.
        uint8_t black[4] = {0, 0, 0, 128};
        rgb[0] = rgb[1] = rgb[2] = 1000;
        avf_from_nits(trc, rgb, color.kr, color.kb);
        yuv[0] = rgb[0];
        yuv[1] = yuv[2] = 0;
        avf_blend_pixel(&color, black, yuv);
        rgb[0] = rgb[1] = rgb[2] = yuv[0];
        avf_to_nits(trc, rgb, color.kr, color.kb);
        near(rgb[0], 1000 * 127.0 / 255, 1e-4);
        yuv[0] = yuv[1] = yuv[2] = 0;
        avf_blend_pixel(&color, red, yuv);
        rgb[0] = yuv[0] + 2 * (1 - color.kr) * yuv[2];
        rgb[2] = yuv[0] + 2 * (1 - color.kb) * yuv[1];
        rgb[1] = (yuv[0] - color.kr * rgb[0] - color.kb * rgb[2]) / (1 - color.kr - color.kb);
        avf_to_nits(trc, rgb, color.kr, color.kb);
        near(rgb[0], 203 * .627403896, 1e-4);
        near(rgb[1], 203 * .069097289, 1e-4);
        near(rgb[2], 203 * .016391439, 1e-4);
        // Odd-position red coverage; all other luma stays bit-exact.
        uint8_t cell[4][4] = {{0}};
        memcpy(cell[3], red, 4);
        double ys[4] = {.1, .2, .3, .4}, uv[2] = {.1, -.05}, single[3] = {.4, .1, -.05};
        avf_blend_pixel(&color, red, single);
        assert(avf_blend_chroma_cell(&color, cell, ys, uv, 4));
        assert(ys[0] == .1 && ys[1] == .2 && ys[2] == .3);
        near(ys[3], single[0], 1e-15);
        near(uv[0], .1 + (single[1] - .1) / 4, 1e-15);
        near(uv[1], -.05 + (single[2] + .05) / 4, 1e-15);
        // Empty and clipped edge cells, and superblack outside overlay.
        memset(cell, 0, sizeof(cell));
        double origy[4], origuv[2];
        memcpy(origy, ys, sizeof(ys));
        memcpy(origuv, uv, sizeof(uv));
        assert(!avf_blend_chroma_cell(&color, cell, ys, uv, 4));
        assert(!memcmp(origy, ys, sizeof(ys)));
        assert(!memcmp(origuv, uv, sizeof(uv)));
        double untouched[3] = {-.1, .8, -.7}, before[3];
        memcpy(before, untouched, sizeof(before));
        avf_blend_pixel(&color, clear, untouched);
        assert(!memcmp(before, untouched, sizeof(before)));
        memcpy(cell[0], red, 4);
        ys[0] = .4;
        uv[0] = .1;
        uv[1] = -.05;
        avf_blend_chroma_cell(&color, cell, ys, uv, 1);
        near(uv[0], single[1], 1e-15);
    }
    puts("Native HDR math: PQ/HLG anchors, gamut, reference white, exhaustive grayscale conversion, linear alpha, opaque/transparent fast "
         "paths, clipped chroma coverage, untouched pixels passed");
}
