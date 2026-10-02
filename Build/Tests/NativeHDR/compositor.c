/* Exercise the production YUV compositor loop against a scalar reference. */
#include <assert.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#include "avfoundation_color_math.h"

#define MPMIN(a, b) ((a) < (b) ? (a) : (b))
#define MPCLAMP(x, a, b) ((x) < (a) ? (a) : (x) > (b) ? (b) : (x))

struct rect {
    int x0, y0, x1, y1;
};

// Test format bits select precisely the range and sample depth that the
// CoreVideo format helpers supply to the production loop.
static bool is_full_range_yuv_format(int format) { return (format & 1) != 0; }
static bool is_p010_format(int format) { return (format & 2) != 0; }
static int clip_u8(double value) { return MPCLAMP((int)(value + 0.5), 0, 255); }
static int clip_u10(double value) { return MPCLAMP((int)(value + 0.5), 0, 1023); }

static void composite(struct avf_overlay_color color, uint8_t *subBase, int subW, int subH, size_t subStride, uint8_t *yBase,
                      uint8_t *uvBase, size_t yStride, size_t uvStride, int videoW, int videoH, struct rect src, struct rect dst,
                      struct rect target, int sourceFormat) {
    int srcW = src.x1 - src.x0, srcH = src.y1 - src.y0;
    int dstW = dst.x1 - dst.x0, dstH = dst.y1 - dst.y0;
    int vx0 = target.x0, vy0 = target.y0, vx1 = target.x1, vy1 = target.y1;
#include "compositor_loop.h"
}

static double sample(const uint8_t *row, int x, bool p010) { return p010 ? ((const uint16_t *)row)[x] >> 6 : row[x]; }

static void store_sample(uint8_t *row, int x, bool p010, double value) {
    if (p010)
        ((uint16_t *)row)[x] = clip_u10(value) << 6;
    else
        row[x] = clip_u8(value);
}

// Resolve every destination pixel independently. Keep chroma immutable until
// all covered luma pixels in its cell have contributed their chroma deltas.
static void reference(struct avf_overlay_color color, uint8_t *sub, int sw, int sh, size_t ss, uint8_t *luma, uint8_t *chroma, size_t ys,
                      size_t us, int w, int h, struct rect src, struct rect dst, struct rect target, int format) {
    bool p010 = is_p010_format(format);
    bool full = is_full_range_yuv_format(format);
    double y_offset = full ? 0 : p010 ? 64 : 16;
    double y_range = full ? (p010 ? 1023 : 255) : (p010 ? 876 : 219);
    double c_center = p010 ? 512 : 128;
    double c_range = full ? (p010 ? 1023 : 255) : (p010 ? 896 : 224);
    for (int cy = target.y0 / 2; cy < (target.y1 + 1) / 2; cy++) {
        for (int cx = target.x0 / 2; cx < (target.x1 + 1) / 2; cx++) {
            uint8_t *uv_row = chroma + cy * us;
            double original[2] = {
                (sample(uv_row, cx * 2, p010) - c_center) / c_range,
                (sample(uv_row, cx * 2 + 1, p010) - c_center) / c_range,
            };
            double delta[2] = {0};
            int count = 0;
            bool changed = false;
            for (int y = cy * 2; y < MPMIN(cy * 2 + 2, h); y++) {
                for (int x = cx * 2; x < MPMIN(cx * 2 + 2, w); x++) {
                    count++;
                    if (x < target.x0 || x >= target.x1 || y < target.y0 || y >= target.y1)
                        continue;
                    int sx = dst.x0 + (int)((int64_t)(x - src.x0) * (dst.x1 - dst.x0) / (src.x1 - src.x0));
                    int sy = dst.y0 + (int)((int64_t)(y - src.y0) * (dst.y1 - dst.y0) / (src.y1 - src.y0));
                    const uint8_t *bgra = sub + MPCLAMP(sy, 0, sh - 1) * ss + MPCLAMP(sx, 0, sw - 1) * 4;
                    if (!bgra[3])
                        continue;
                    uint8_t *y_row = luma + y * ys;
                    double pixel[3] = {
                        (sample(y_row, x, p010) - y_offset) / y_range,
                        original[0],
                        original[1],
                    };
                    avf_blend_pixel(&color, bgra, pixel);
                    store_sample(y_row, x, p010, y_offset + y_range * pixel[0]);
                    delta[0] += pixel[1] - original[0];
                    delta[1] += pixel[2] - original[1];
                    changed = true;
                }
            }
            if (changed) {
                for (int k = 0; k < 2; k++) {
                    double result = original[k] + delta[k] / count;
                    store_sample(uv_row, cx * 2 + k, p010, c_center + c_range * result);
                }
            }
        }
    }
}

static unsigned random_state = 42;
static unsigned random_value(void) {
    random_state = random_state * 1664525 + 1013904223;
    return random_state;
}

int main(void) {
    for (int iteration = 0; iteration < 1200; iteration++) {
        int w = 1 + random_value() % 127, h = 1 + random_value() % 93;
        int sw = 1 + random_value() % 140, sh = 1 + random_value() % 100;
        int format = iteration % 4, bpp = is_p010_format(format) ? 2 : 1;
        size_t ys = (w + 3) * bpp, us = ((w + 1) / 2 * 2 + 5) * bpp;
        size_t ss = (sw + 2) * 4;
        size_t y_size = ys * h, total = y_size + us * ((h + 1) / 2);
        uint8_t *expected = malloc(total), *actual = malloc(total);
        uint8_t *sub = calloc(ss * sh, 1);
        assert(expected && actual && sub);
        for (size_t i = 0; i < total; i++)
            expected[i] = random_value() >> 24;
        memcpy(actual, expected, total);
        for (int y = 0; y < sh; y++) {
            for (int x = 0; x < sw; x++) {
                uint8_t *pixel = sub + y * ss + x * 4;
                switch ((iteration / 5) % 5) {
                case 0:
                    pixel[3] = 0;
                    break;
                case 1:
                    pixel[3] = 255;
                    break;
                case 2:
                    pixel[3] = random_value() % 8 ? 0 : random_value() >> 24;
                    break;
                default:
                    pixel[3] = random_value() >> 24;
                    break;
                }
                for (int k = 0; k < 3; k++)
                    pixel[k] = random_value() % (pixel[3] + 1);
            }
        }
        struct rect src = {0, 0, w, h}, dst = {0, 0, sw, sh};
        if (iteration % 3 == 0) {
            dst = src;
        } else if (iteration % 3 == 1) {
            src.x0 = w / 4;
            src.y0 = h / 4;
            dst.x0 = sw / 5;
            dst.y0 = sh / 5;
        }
        struct rect target = {random_value() % w, random_value() % h, w, h};
        struct avf_overlay_color color = {
            .transfer = iteration % 5,
            .kr = 0.2627,
            .kb = 0.0593,
            .white_nits = 203,
            .rgb_matrix = {{0.627404, 0.329283, 0.0433136}, {0.069097, 0.919541, 0.0113612}, {0.0163916, 0.0880133, 0.895595}},
        };
        reference(color, sub, sw, sh, ss, expected, expected + y_size, ys, us, w, h, src, dst, target, format);
        composite(color, sub, sw, sh, ss, actual, actual + y_size, ys, us, w, h, src, dst, target, format);
        if (memcmp(expected, actual, total)) {
            fprintf(stderr, "YUV compositor mismatch: iteration=%d size=%dx%d format=%d\n", iteration, w, h, format);
            return 1;
        }
        free(expected);
        free(actual);
        free(sub);
    }
    puts("YUV compositor: 1200 byte-exact sparse/opaque, odd-size, range and geometry cases passed");
    return 0;
}
