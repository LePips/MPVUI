// Microbenchmark the production CPU subtitle conversion and cache lookup.
// The header is extracted from the ordered, checksum-validated native patches.
#import <CoreMedia/CoreMedia.h>
#import <CoreText/CoreText.h>
#include <CommonCrypto/CommonDigest.h>
#include <errno.h>
#include <inttypes.h>
#include <stdio.h>
#include <stdlib.h>
#include <time.h>
#include "avfoundation_color.h"

static volatile uintptr_t image_sink;

static void require(bool condition, const char *message)
{
    if (!condition) {
        fprintf(stderr, "Native subtitle benchmark: %s\n", message);
        exit(1);
    }
}

static uint64_t nanoseconds(clockid_t clock)
{
    struct timespec value;
    require(clock_gettime(clock, &value) == 0, "clock_gettime failed");
    return (uint64_t)value.tv_sec * UINT64_C(1000000000) + value.tv_nsec;
}

static NSString *sha256(const void *bytes, size_t length)
{
    require(length <= UINT32_MAX, "checksum input exceeds CommonCrypto limit");
    unsigned char digest[CC_SHA256_DIGEST_LENGTH];
    CC_SHA256(bytes, (CC_LONG)length, digest);
    NSMutableString *hex = [NSMutableString stringWithCapacity:64];
    for (size_t i = 0; i < sizeof(digest); i++) [hex appendFormat:@"%02x", digest[i]];
    return hex;
}

static CVPixelBufferRef make_canvas(size_t width, size_t height,
                                    NSString **fingerprint, size_t *active_pixels)
{
    CVPixelBufferRef buffer = NULL;
    require(CVPixelBufferCreate(NULL, width, height, kCVPixelFormatType_32BGRA,
                               NULL, &buffer) == kCVReturnSuccess, "canvas allocation failed");
    require(CVPixelBufferLockBaseAddress(buffer, 0) == kCVReturnSuccess,
            "cannot lock canvas");
    uint8_t *bytes = CVPixelBufferGetBaseAddress(buffer);
    const size_t stride = CVPixelBufferGetBytesPerRow(buffer);
    require(bytes != NULL, "canvas has no base address");
    memset(bytes, 0, stride * height);
    CGColorSpaceRef srgb = CGColorSpaceCreateWithName(kCGColorSpaceSRGB);
    CGContextRef context = CGBitmapContextCreate(bytes, width, height, 8, stride, srgb,
        kCGImageAlphaPremultipliedFirst | kCGBitmapByteOrder32Little);
    require(context != NULL, "cannot create caption drawing context");
    // Real antialiased glyphs and outlines on an otherwise transparent canvas.
    // Font rendering is setup work; the bitmap digest detects OS/font changes.
    const CGFloat font_size = fmin(width / 34.0, height / 20.0);
    CTFontRef font = CTFontCreateWithName(CFSTR("Helvetica-Bold"), font_size, NULL);
    CGFloat white_components[] = {1, 1, 1, 1}, black_components[] = {0, 0, 0, 1};
    CGColorRef white = CGColorCreate(srgb, white_components);
    CGColorRef black = CGColorCreate(srgb, black_components);
    NSArray *lines = @[@"Local subtitle benchmark", @"The same cue stays on screen"];
    NSDictionary *attributes = @{
        (__bridge id)kCTFontAttributeName: (__bridge id)font,
        (__bridge id)kCTForegroundColorAttributeName: (__bridge id)white,
        (__bridge id)kCTStrokeColorAttributeName: (__bridge id)black,
        (__bridge id)kCTStrokeWidthAttributeName: @-5,
    };
    for (NSUInteger i = 0; i < lines.count; i++) {
        NSAttributedString *text = [[NSAttributedString alloc] initWithString:lines[i]
                                                                  attributes:attributes];
        CTLineRef line = CTLineCreateWithAttributedString((__bridge CFAttributedStringRef)text);
        const double line_width = CTLineGetTypographicBounds(line, NULL, NULL, NULL);
        CGContextSetTextPosition(context, (width - line_width) / 2,
                                 height * .08 + (1 - i) * font_size * 1.35);
        CTLineDraw(line, context);
        CFRelease(line);
        [text release];
    }
    CGContextRelease(context);
    CGColorRelease(white);
    CGColorRelease(black);
    CFRelease(font);
    CGColorSpaceRelease(srgb);
    *active_pixels = 0;
    for (size_t y = 0; y < height; y++) {
        for (size_t x = 0; x < width; x++) {
            const uint8_t *pixel = bytes + y * stride + x * 4;
            require(pixel[0] <= pixel[3] && pixel[1] <= pixel[3] && pixel[2] <= pixel[3],
                    "caption canvas is not premultiplied BGRA");
            *active_pixels += pixel[3] != 0;
        }
    }
    require(*active_pixels > 0 && *active_pixels < width * height / 2,
            "caption fixture must be sparse and nonempty");
    *fingerprint = sha256(bytes, stride * height);
    CVPixelBufferUnlockBaseAddress(buffer, 0);
    return buffer;
}

// This non-inlined call and volatile sink keep release builds from eliminating
// repeated cache lookups. Each operation includes a frame-local autorelease pool.
__attribute__((noinline))
static CIImage *frame(struct avf_subtitle_image_cache *cache, CVPixelBufferRef canvas,
                      CGColorSpaceRef space, const struct avf_overlay_color *color, bool cold)
{
    @autoreleasepool {
        if (cold) avf_subtitle_image_cache_clear(cache);
        CIImage *image = avf_cached_subtitle_image(cache, canvas, space, color);
        image_sink ^= (uintptr_t)image;
        return image; // Cache owns the image after the frame's pool drains.
    }
}

static NSString *render_digest(CIContext *context, CIImage *image, CGColorSpaceRef space,
                                size_t width, size_t height)
{
    // Force the backed pixel data to be consumed outside measured samples.
    // A small preview keeps this validation independent of GPU performance.
    uint8_t pixels[64 * 36 * 4] = {0};
    CIImage *preview = [image imageByApplyingTransform:
        CGAffineTransformMakeScale(64.0 / width, 36.0 / height)];
    [context render:preview toBitmap:pixels rowBytes:64 * 4 bounds:CGRectMake(0, 0, 64, 36)
             format:kCIFormatRGBA8 colorSpace:space];
    bool visible = false;
    for (size_t i = 0; i < 64 * 36; i++) visible |= pixels[i * 4 + 3] != 0;
    require(visible, "rendered caption checksum was empty");
    return sha256(pixels, sizeof(pixels));
}

static NSString *validate_cache(CVPixelBufferRef canvas, CGColorSpaceRef space,
                                 const struct avf_overlay_color *color,
                                 size_t width, size_t height)
{
    NSString *result;
    @autoreleasepool {
        struct avf_subtitle_image_cache cache = {0};
        CIContext *context = [CIContext contextWithOptions:@{kCIContextUseSoftwareRenderer: @YES}];
        CIImage *first = [frame(&cache, canvas, space, color, true) retain];
        require(first != nil, "cold conversion returned no image");
        require(first.extent.size.width == width && first.extent.size.height == height,
                "converted canvas dimensions do not match");
        NSString *initial = render_digest(context, first, space, width, height);
        for (int i = 0; i < 120; i++)
            require(frame(&cache, canvas, space, color, false) == first,
                    "an unchanged frame missed the image cache");
        CIImage *replacement = frame(&cache, canvas, space, color, true);
        require(replacement && replacement != first, "cache invalidation did not rebuild the image");
        require([initial isEqualToString:render_digest(context, replacement, space, width, height)],
                "cold conversions produced different pixels");
        result = [initial copy];
        avf_subtitle_image_cache_clear(&cache);
        [first release];
    }
    return [result autorelease];
}

static void sample(struct avf_subtitle_image_cache *cache, CVPixelBufferRef canvas,
                    CGColorSpaceRef space, const struct avf_overlay_color *color, bool cold,
                    size_t iterations, NSMutableArray *wall, NSMutableArray *cpu)
{
    CIImage *expected = cache->image;
    require(expected != nil, "sample cache was not initialized");
    size_t valid_frames = 0;
    uint64_t wall_start = nanoseconds(CLOCK_MONOTONIC_RAW);
    uint64_t cpu_start = nanoseconds(CLOCK_PROCESS_CPUTIME_ID);
    for (size_t i = 0; i < iterations; i++) {
        CIImage *image = frame(cache, canvas, space, color, cold);
        valid_frames += image != nil && (cold || image == expected);
    }
    uint64_t cpu_end = nanoseconds(CLOCK_PROCESS_CPUTIME_ID);
    uint64_t wall_end = nanoseconds(CLOCK_MONOTONIC_RAW);
    require(valid_frames == iterations, "a measured frame failed conversion or cache identity");
    [wall addObject:@((double)(wall_end - wall_start) / iterations)];
    [cpu addObject:@((double)(cpu_end - cpu_start) / iterations)];
}

static size_t argument(const char *text, size_t minimum, size_t maximum)
{
    errno = 0;
    char *end = NULL;
    unsigned long long value = strtoull(text, &end, 10);
    require(!errno && end != text && *end == '\0' && value >= minimum && value <= maximum,
            "numeric argument outside supported bounds");
    return (size_t)value;
}

int main(int argc, const char *argv[])
{
    @autoreleasepool {
        require(argc == 7, "expected width height repetitions warmup cold-iterations cached-iterations");
        size_t width = argument(argv[1], 128, 4096), height = argument(argv[2], 72, 2160);
        size_t repetitions = argument(argv[3], 1, 31), warmup = argument(argv[4], 1, 20);
        size_t cold_iterations = argument(argv[5], 1, 100), cached_iterations = argument(argv[6], 1, 5000000);
        require(width * height * (repetitions * cold_iterations + warmup) <= UINT64_C(2000000000),
                "requested cold workload exceeds two billion pixel visits");
        require(repetitions * cached_iterations <= 50000000,
                "requested cached workload exceeds fifty million frames");
        size_t active_pixels;
        NSString *fixture_hash;
        CVPixelBufferRef canvas = make_canvas(width, height, &fixture_hash, &active_pixels);
        CGColorSpaceRef space = CGColorSpaceCreateWithName(kCGColorSpaceITUR_2100_PQ);
        require(space != NULL, "PQ color space is unavailable");
        struct avf_overlay_color color = {.transfer = AVF_PQ, .white_nits = 203,
            .kr = .2627, .kb = .0593, .rgb_matrix = {{1, 0, 0}, {0, 1, 0}, {0, 0, 1}}};
        NSString *render_hash = validate_cache(canvas, space, &color, width, height);
        struct avf_subtitle_image_cache cold_cache = {0}, hit_cache = {0};
        for (size_t i = 0; i < warmup; i++) {
            require(frame(&cold_cache, canvas, space, &color, true) != nil, "cold warmup failed");
            require(frame(&hit_cache, canvas, space, &color, false) != nil, "cached warmup failed");
        }
        NSMutableArray *cold_wall = [NSMutableArray array], *cold_cpu = [NSMutableArray array];
        NSMutableArray *cached_wall = [NSMutableArray array], *cached_cpu = [NSMutableArray array];
        // Alternate ordering to reduce a systematic first/second workload bias.
        for (size_t i = 0; i < repetitions; i++) {
            if (i % 2) sample(&hit_cache, canvas, space, &color, false, cached_iterations, cached_wall, cached_cpu);
            sample(&cold_cache, canvas, space, &color, true, cold_iterations, cold_wall, cold_cpu);
            if (!(i % 2)) sample(&hit_cache, canvas, space, &color, false, cached_iterations, cached_wall, cached_cpu);
        }
        NSMutableArray *workloads = [NSMutableArray array];
        for (NSUInteger i = 0; i < 2; i++) {
            [workloads addObject:@{
                @"id": i == 0 ? @"native_subtitle_cold" : @"native_subtitle_cached",
                @"parameters": @{@"width": @(width), @"height": @(height), @"transfer": @"pq",
                    @"whiteNits": @203, @"patternVersion": @1, @"warmupIterations": @(warmup),
                    @"iterations": @(i == 0 ? cold_iterations : cached_iterations),
                    @"activePixels": @(active_pixels), @"canvasSHA256": fixture_hash},
                @"metrics": @{
                    @"wallNanosecondsPerOperation": @{@"unit": @"ns/op", @"direction": @"lower",
                        @"samples": i == 0 ? cold_wall : cached_wall},
                    @"cpuNanosecondsPerOperation": @{@"unit": @"ns/op", @"direction": @"lower",
                        @"samples": i == 0 ? cold_cpu : cached_cpu}},
            }];
        }
        avf_subtitle_image_cache_clear(&cold_cache);
        avf_subtitle_image_cache_clear(&hit_cache);
        CVPixelBufferRelease(canvas);
        CGColorSpaceRelease(space);
        NSDictionary *result = @{@"workloads": workloads,
            @"validation": @{@"renderSHA256": render_hash, @"unchangedFramesChecked": @120,
                @"coldOutputMatches": @YES, @"cacheRetainsAcrossAutoreleasePools": @YES}};
        NSError *error = nil;
        NSData *json = [NSJSONSerialization dataWithJSONObject:result options:NSJSONWritingSortedKeys error:&error];
        require(json != nil && error == nil, "cannot serialize benchmark results");
        require(fwrite(json.bytes, 1, json.length, stdout) == json.length, "cannot write benchmark results");
        putchar('\n');
    }
    return 0;
}
