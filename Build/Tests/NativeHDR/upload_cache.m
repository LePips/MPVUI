/* Exercise production upload-cache ownership with explicit metadata inputs. */
#import <Foundation/Foundation.h>
#import <CoreVideo/CoreVideo.h>
#include <assert.h>
#include <stdbool.h>
#include <stdio.h>

// Only the cache's dependencies are stubbed. Real color metadata mapping is
// covered by metadata.m; production mp_image_params_equal compares dimensions,
// color/HDR, range, crop, pixel aspect and chroma location semantically.
struct mp_image_params {
    struct {
        void *dovi;
    } repr;
    const char *imgfmt_name;
    int metadata_generation;
};

struct priv {
    CFDictionaryRef sw_upload_attachments;
    struct mp_image_params sw_upload_params;
    OSType sw_upload_metadata_format;
};
struct vo {
    struct priv *priv;
};

static bool mp_image_params_equal(const struct mp_image_params *a, const struct mp_image_params *b) {
    assert(!a->repr.dovi && !b->repr.dovi);
    assert(!a->imgfmt_name && !b->imgfmt_name);
    return a->metadata_generation == b->metadata_generation;
}

static int metadata_builds;
static void tag_pixel_buffer_color_metadata(CVPixelBufferRef buffer, const struct mp_image_params *params) {
    metadata_builds++;
    CFNumberRef value = CFNumberCreate(NULL, kCFNumberIntType, &params->metadata_generation);
    CVBufferSetAttachment(buffer, CFSTR("source-metadata"), value, kCVAttachmentMode_ShouldPropagate);
    CFRelease(value);
}

#include "upload_cache_functions.h"

static CVPixelBufferRef buffer(OSType format) {
    CVPixelBufferRef result = NULL;
    assert(CVPixelBufferCreate(NULL, 64, 36, format, NULL, &result) == kCVReturnSuccess);
    return result;
}

static int generation(CFDictionaryRef attachments) {
    CFNumberRef value = CFDictionaryGetValue(attachments, CFSTR("source-metadata"));
    int result = 0;
    assert(value && CFNumberGetValue(value, kCFNumberIntType, &result));
    return result;
}

int main(void) {
    struct priv p = {0};
    struct vo vo = {.priv = &p};
    struct mp_image_params params = {
        .repr.dovi = (void *)1,
        .imgfmt_name = "decoder-owned",
        .metadata_generation = 1,
    };
    CVPixelBufferRef first = buffer(kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange);
    CVPixelBufferRef second = buffer(kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange);
    CVPixelBufferRef p010 = buffer(kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange);

    tag_sw_upload_metadata(&vo, first, &params);
    assert(metadata_builds == 1 && generation(p.sw_upload_attachments) == 1);
    assert(!p.sw_upload_params.repr.dovi && !p.sw_upload_params.imgfmt_name);

    // An in-place composite removes source tags. Its mutations must leave the
    // cached snapshot intact and must not leak into the next pooled upload.
    CVBufferRemoveAllAttachments(first);
    assert(generation(p.sw_upload_attachments) == 1);
    CVBufferSetAttachment(second, CFSTR("stale-propagating"), kCFBooleanTrue, kCVAttachmentMode_ShouldPropagate);
    CVBufferSetAttachment(second, CFSTR("stale-private"), kCFBooleanTrue, kCVAttachmentMode_ShouldNotPropagate);
    params.repr.dovi = (void *)2;
    // upload_software_frame clears pooled attachments before copying pixels
    // and calling this metadata helper.
    CVBufferRemoveAllAttachments(second);
    tag_sw_upload_metadata(&vo, second, &params);
    assert(metadata_builds == 1);
    assert(generation(CVBufferGetAttachments(second, kCVAttachmentMode_ShouldPropagate)) == 1);
    assert(!CVBufferGetAttachment(second, CFSTR("stale-propagating"), NULL));
    assert(!CVBufferGetAttachment(second, CFSTR("stale-private"), NULL));

    // A metadata-key or output-format change must rebuild the snapshot.
    params.metadata_generation = 2;
    tag_sw_upload_metadata(&vo, first, &params);
    assert(metadata_builds == 2 && generation(p.sw_upload_attachments) == 2);
    assert(generation(CVBufferGetAttachments(second, kCVAttachmentMode_ShouldPropagate)) == 1);
    tag_sw_upload_metadata(&vo, p010, &params);
    assert(metadata_builds == 3 && p.sw_upload_metadata_format == kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange);

    clear_sw_upload_metadata(&p);
    assert(!p.sw_upload_attachments);
    tag_sw_upload_metadata(&vo, p010, &params);
    assert(metadata_builds == 4);
    clear_sw_upload_metadata(&p);
    clear_sw_upload_metadata(&p);
    CVPixelBufferRelease(first);
    CVPixelBufferRelease(second);
    CVPixelBufferRelease(p010);
    puts("Upload metadata cache: reuse, immutable snapshots and invalidation passed");
    return 0;
}
