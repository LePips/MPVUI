#import <CoreMedia/CoreMedia.h>
#include <assert.h>
#include <stdio.h>
#include "avfoundation_color.h"

static void expect_subtitle_cache_miss(struct avf_subtitle_image_cache *cache,
                                      CVPixelBufferRef source, CGColorSpaceRef cs,
                                      const struct avf_overlay_color *color)
{
    // Retain the old object so an allocator cannot reuse its address.
    CIImage *previous = [cache->image retain];
    CIImage *image = avf_cached_subtitle_image(cache, source, cs, color);
    assert(image && image != previous);
    assert(avf_cached_subtitle_image(cache, source, cs, color) == image);
    [previous release];
}

static void test_subtitle_cache(CVPixelBufferRef source, CGColorSpaceRef cs,
                               const struct avf_overlay_color *color)
{
    struct avf_subtitle_image_cache cache = {0};
    CIImage *first;
    @autoreleasepool {
        first = avf_cached_subtitle_image(&cache, source, cs, color);
        assert(first);
    }
    // Frame-local autorelease pools must not discard the cached image.
    for (int frame = 0; frame < 120; frame++) {
        @autoreleasepool {
            assert(avf_cached_subtitle_image(&cache, source, cs, color) == first);
        }
    }
    CGColorSpaceRef equivalent = CGColorSpaceCreateWithName(kCGColorSpaceITUR_2100_PQ);
    assert(CFEqual(cs, equivalent));
    assert(avf_cached_subtitle_image(&cache, source, equivalent, color) == first);
    CGColorSpaceRelease(equivalent);
    struct avf_overlay_color equivalent_color;
    memset(&equivalent_color, 0xa5, sizeof(equivalent_color));
    equivalent_color.transfer = color->transfer;
    equivalent_color.white_nits = color->white_nits;
    equivalent_color.kr = color->kr;
    equivalent_color.kb = color->kb;
    for (int row = 0; row < 3; row++)
        for (int col = 0; col < 3; col++)
            equivalent_color.rgb_matrix[row][col] = color->rgb_matrix[row][col];
    assert(avf_cached_subtitle_image(&cache, source, cs, &equivalent_color) == first);

    struct avf_overlay_color changed = *color;
    changed.white_nits = 100;
    expect_subtitle_cache_miss(&cache, source, cs, &changed);
    changed.transfer = AVF_HLG;
    expect_subtitle_cache_miss(&cache, source, cs, &changed);
    changed.kr = .2126;
    expect_subtitle_cache_miss(&cache, source, cs, &changed);
    changed.kb = .0722;
    expect_subtitle_cache_miss(&cache, source, cs, &changed);
    for (int row = 0; row < 3; row++) {
        for (int col = 0; col < 3; col++) {
            changed.rgb_matrix[row][col] += .01;
            expect_subtitle_cache_miss(&cache, source, cs, &changed);
        }
    }
    CGColorSpaceRef srgb = CGColorSpaceCreateWithName(kCGColorSpaceSRGB);
    expect_subtitle_cache_miss(&cache, source, srgb, &changed);
    CGColorSpaceRelease(srgb);
    assert(cache.color_space); // cache owns the color space independently

    CVPixelBufferRef replacement = NULL;
    assert(CVPixelBufferCreate(NULL, 2, 2, kCVPixelFormatType_32BGRA, NULL,
                              &replacement) == kCVReturnSuccess);
    CVPixelBufferLockBaseAddress(replacement, 0);
    memset(CVPixelBufferGetBaseAddress(replacement), 0,
           CVPixelBufferGetBytesPerRow(replacement) * CVPixelBufferGetHeight(replacement));
    CVPixelBufferUnlockBaseAddress(replacement, 0);
    expect_subtitle_cache_miss(&cache, replacement, cs, color);
    CVPixelBufferRelease(replacement);
    assert(CVPixelBufferGetWidth(cache.source) == 2); // cache retains source identity
    assert(avf_cached_subtitle_image(&cache, cache.source, cs, color) == cache.image);
    changed = *color;
    changed.white_nits = 100;
    expect_subtitle_cache_miss(&cache, cache.source, cache.color_space, &changed);
    assert(CVPixelBufferGetWidth(cache.source) == 2); // miss retains inputs before clearing

    assert(!avf_cached_subtitle_image(&cache, NULL, cs, color));
    assert(!cache.image && !cache.source && !cache.color_space);
    avf_subtitle_image_cache_clear(&cache);
    avf_subtitle_image_cache_clear(&cache);
    expect_subtitle_cache_miss(&cache, source, cs, color);
    avf_subtitle_image_cache_clear(&cache);
    assert(!cache.image && !cache.source && !cache.color_space);
}

int main(void) { @autoreleasepool {
    const enum pl_color_primaries prims[]={PL_COLOR_PRIM_BT_601_525,PL_COLOR_PRIM_BT_601_625,PL_COLOR_PRIM_BT_709,PL_COLOR_PRIM_DISPLAY_P3,PL_COLOR_PRIM_DCI_P3,PL_COLOR_PRIM_BT_2020};
    const int codes[]={6,5,1,12,11,9};
    for(int i=0;i<6;i++) assert(CVColorPrimariesGetIntegerCodePointForString(get_cv_color_primaries(prims[i]))==codes[i]);
    assert(!get_cv_ycbcr_matrix(PL_COLOR_SYSTEM_BT_2020_C));
    assert(!get_cv_ycbcr_matrix(PL_COLOR_SYSTEM_BT_2100_PQ));
    const OSType formats[]={kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange,kCVPixelFormatType_420YpCbCr8BiPlanarFullRange,kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange,kCVPixelFormatType_420YpCbCr10BiPlanarFullRange};
    for (int f=0;f<4;f++) {
        CVPixelBufferRef buffer=NULL;assert(CVPixelBufferCreate(NULL,16,8,formats[f],NULL,&buffer)==kCVReturnSuccess);
        assert(CVPixelBufferGetPixelFormatType(buffer)==formats[f]);
        struct pl_color_space color={.primaries=PL_COLOR_PRIM_BT_2020,.transfer=PL_COLOR_TRC_PQ,
            .hdr={.prim={.red={.708,.292},.green={.170,.797},.blue={.131,.046},.white={.3127,.3290}},.min_luma=.005,.max_luma=1000,.max_cll=1200,.max_fall=400}};
        avf_tag_color_metadata(buffer,&color,PL_COLOR_SYSTEM_BT_2020_NC,PL_CHROMA_TOP_LEFT);
        assert(CFEqual(CVBufferGetAttachment(buffer,kCVImageBufferChromaLocationTopFieldKey,NULL),kCVImageBufferChromaLocation_TopLeft));
        CFDataRef mdcv=CVBufferGetAttachment(buffer,kCVImageBufferMasteringDisplayColorVolumeKey,NULL);
        CFDataRef clli=CVBufferGetAttachment(buffer,kCVImageBufferContentLightLevelInfoKey,NULL);
        const uint8_t expected[24]={0x21,0x34,0x9b,0xaa,0x19,0x96,0x08,0xfc,0x8a,0x48,0x39,0x08,0x3d,0x13,0x40,0x42,0x00,0x98,0x96,0x80,0,0,0,50};
        const uint8_t expcll[4]={4,176,1,144};
        assert(mdcv && CFDataGetLength(mdcv)==24 && !memcmp(CFDataGetBytePtr(mdcv),expected,24));
        assert(clli && CFDataGetLength(clli)==4 && !memcmp(CFDataGetBytePtr(clli),expcll,4));
        avf_tag_geometry(buffer,4,3,2,1,14,7);
        NSDictionary *ap=(__bridge NSDictionary*)CVBufferGetAttachment(buffer,kCVImageBufferCleanApertureKey,NULL);
        assert([ap[(id)kCVImageBufferCleanApertureWidthKey] intValue]==12);
        assert([ap[(id)kCVImageBufferCleanApertureHeightKey] intValue]==6);
        assert(CVBufferGetAttachment(buffer,kCVImageBufferPixelAspectRatioKey,NULL));
        CMVideoFormatDescriptionRef first=NULL;assert(CMVideoFormatDescriptionCreateForImageBuffer(NULL,buffer,&first)==noErr);
        CFDictionaryRef snapshot=CFDictionaryCreateCopy(NULL,CVBufferGetAttachments(buffer,kCVAttachmentMode_ShouldPropagate));
        color.hdr.max_cll=1400;avf_tag_color_metadata(buffer,&color,PL_COLOR_SYSTEM_BT_2020_NC,PL_CHROMA_LEFT);
        assert(!CFEqual(snapshot,CVBufferGetAttachments(buffer,kCVAttachmentMode_ShouldPropagate)));
        CMVideoFormatDescriptionRef changed=NULL;assert(CMVideoFormatDescriptionCreateForImageBuffer(NULL,buffer,&changed)==noErr);
        assert(!CFEqual(CMFormatDescriptionGetExtensions(first),CMFormatDescriptionGetExtensions(changed)));
        CFRelease(first);CFRelease(changed);CFRelease(snapshot);
        CVPixelBufferRef copy=NULL;assert(CVPixelBufferCreate(NULL,16,8,formats[f],NULL,&copy)==kCVReturnSuccess);
        CVBufferSetAttachment(copy,CFSTR("OldDynamicPayload"),CFSTR("stale"),kCVAttachmentMode_ShouldPropagate);
        CVBufferSetAttachment(buffer,CFSTR("DecoderPrivateMetadata"),CFSTR("keep"),kCVAttachmentMode_ShouldNotPropagate);
        copy_pixel_buffer_metadata(buffer,copy,formats[f]);
        assert(!CVBufferGetAttachment(copy,CFSTR("OldDynamicPayload"),NULL));
        assert(CFEqual(CVBufferGetAttachment(copy,CFSTR("DecoderPrivateMetadata"),NULL),CFSTR("keep")));
        assert(CFEqual(CVBufferGetAttachment(copy,kCVImageBufferMasteringDisplayColorVolumeKey,NULL),
                       CVBufferGetAttachment(buffer,kCVImageBufferMasteringDisplayColorVolumeKey,NULL)));
        CVPixelBufferRelease(copy);
        CVPixelBufferRef rgbCopy=NULL;assert(CVPixelBufferCreate(NULL,32,16,kCVPixelFormatType_64RGBAHalf,NULL,&rgbCopy)==kCVReturnSuccess);
        copy_pixel_buffer_metadata(buffer,rgbCopy,kCVPixelFormatType_64RGBAHalf);
        assert(!CVBufferGetAttachment(rgbCopy,kCVImageBufferYCbCrMatrixKey,NULL));
        assert(!CVBufferGetAttachment(rgbCopy,kCVImageBufferChromaLocationTopFieldKey,NULL));
        assert(!CVBufferGetAttachment(rgbCopy,kCVImageBufferPixelAspectRatioKey,NULL));
        NSDictionary *rgbAperture=(__bridge NSDictionary*)CVBufferGetAttachment(rgbCopy,kCVImageBufferCleanApertureKey,NULL);
        assert([rgbAperture[(id)kCVImageBufferCleanApertureWidthKey] intValue]==32);
        CVPixelBufferRelease(rgbCopy);
        // Simulate a recycled HDR buffer becoming SDR, including old dynamic metadata.
        CVBufferSetAttachment(buffer,CFSTR("DolbyVisionRPUData"),CFSTR("stale"),kCVAttachmentMode_ShouldPropagate);
        color.transfer=PL_COLOR_TRC_BT_1886;color.primaries=PL_COLOR_PRIM_BT_709;
        avf_tag_color_metadata(buffer,&color,PL_COLOR_SYSTEM_BT_709,PL_CHROMA_UNKNOWN);avf_tag_geometry(buffer,1,1,0,0,16,8);
        assert(!CVBufferGetAttachment(buffer,kCVImageBufferMasteringDisplayColorVolumeKey,NULL));
        assert(!CVBufferGetAttachment(buffer,kCVImageBufferContentLightLevelInfoKey,NULL));
        assert(!CVBufferGetAttachment(buffer,CFSTR("DolbyVisionRPUData"),NULL));
        assert(!CVBufferGetAttachment(buffer,kCVImageBufferChromaLocationTopFieldKey,NULL));
        assert(!CVBufferGetAttachment(buffer,kCVImageBufferPixelAspectRatioKey,NULL));
        for (int loc=PL_CHROMA_LEFT;loc<PL_CHROMA_COUNT;loc++) assert(avf_chroma_location(loc));
        color.transfer=PL_COLOR_TRC_HLG;avf_tag_color_metadata(buffer,&color,PL_COLOR_SYSTEM_BT_709,PL_CHROMA_CENTER);
        assert(CVTransferFunctionGetIntegerCodePointForString(CVBufferGetAttachment(buffer,kCVImageBufferTransferFunctionKey,NULL))==18);
        CVPixelBufferRelease(buffer);
    }
    // Exercise the production CI texture through Apple's actual color manager.
    CVPixelBufferRef sub=NULL;assert(CVPixelBufferCreate(NULL,2,2,kCVPixelFormatType_32BGRA,NULL,&sub)==kCVReturnSuccess);
    CVPixelBufferLockBaseAddress(sub,0);
    uint8_t *base=CVPixelBufferGetBaseAddress(sub);size_t row=CVPixelBufferGetBytesPerRow(sub);
    for(int y=0;y<2;y++)for(int x=0;x<2;x++){uint8_t *p=base+y*row+4*x;p[0]=p[1]=p[2]=p[3]=128;}
    CVPixelBufferUnlockBaseAddress(sub,0);
    struct avf_overlay_color color={.transfer=AVF_PQ,.white_nits=203,.kr=.2627,.kb=.0593,.rgb_matrix={{1,0,0},{0,1,0},{0,0,1}}};
    CGColorSpaceRef pq=CGColorSpaceCreateWithName(kCGColorSpaceITUR_2100_PQ);
    CGColorSpaceRef linear=CGColorSpaceCreateWithName(kCGColorSpaceExtendedLinearITUR_2020);
    test_subtitle_cache(sub,pq,&color);
    struct avf_subtitle_image_cache subtitleCache={0};
    CIImage *overlay=avf_cached_subtitle_image(&subtitleCache,sub,pq,&color);assert(overlay);
    double background[3]={1000,1000,1000};avf_from_nits(AVF_PQ,background,.2627,.0593);
    CGFloat comps[4]={background[0],background[1],background[2],1};
    CGColorRef bg=CGColorCreate(pq,comps);
    CIImage *video=[[CIImage imageWithColor:[CIColor colorWithCGColor:bg]] imageByCroppingToRect:CGRectMake(0,0,2,2)];
    CIImage *composite=[overlay imageByCompositingOverImage:video];
    CIContext *ctx=[CIContext contextWithOptions:@{kCIContextWorkingColorSpace:(__bridge id)linear,kCIContextUseSoftwareRenderer:@YES}];
    float pixels[16]={0};[ctx render:composite toBitmap:pixels rowBytes:8*sizeof(float) bounds:CGRectMake(0,0,2,2) format:kCIFormatRGBAf colorSpace:pq];
    double rendered[3]={pixels[0],pixels[1],pixels[2]};avf_to_nits(AVF_PQ,rendered,.2627,.0593);
    double expected=1000*127.0/255+203*128.0/255;
    if(fabs(rendered[0]-expected)>3){fprintf(stderr,"CI alpha nits: %.4f expected %.4f\n",rendered[0],expected);assert(0);}
    // A white-level change must affect pixels on the next frame, not only the key.
    color.white_nits=100;
    overlay=avf_cached_subtitle_image(&subtitleCache,sub,pq,&color);
    composite=[overlay imageByCompositingOverImage:video];
    [ctx render:composite toBitmap:pixels rowBytes:8*sizeof(float) bounds:CGRectMake(0,0,2,2) format:kCIFormatRGBAf colorSpace:pq];
    for(int c=0;c<3;c++) rendered[c]=pixels[c];
    avf_to_nits(AVF_PQ,rendered,.2627,.0593);
    expected=1000*127.0/255+100*128.0/255;
    assert(fabs(rendered[0]-expected)<3);
    color.white_nits=203;
    // Match the prior CGContext/CGImage row convention with asymmetric alpha.
    avf_subtitle_image_cache_clear(&subtitleCache); // production invalidates before changing a cue
    CVPixelBufferLockBaseAddress(sub,0);
    const uint8_t alphaMarkers[4]={255,128,64,0};
    for(int y=0;y<2;y++)for(int x=0;x<2;x++){uint8_t *p=base+y*row+4*x;for(int k=0;k<4;k++)p[k]=alphaMarkers[y*2+x];}
    CGColorSpaceRef srgb=CGColorSpaceCreateWithName(kCGColorSpaceSRGB);
    CGContextRef cg=CGBitmapContextCreate(base,2,2,8,row,srgb,kCGImageAlphaPremultipliedFirst|kCGBitmapByteOrder32Little);
    CGImageRef oldImage=CGBitmapContextCreateImage(cg);CGContextRelease(cg);
    CVPixelBufferUnlockBaseAddress(sub,0);
    CIImage *old=[CIImage imageWithCGImage:oldImage];
    CIImage *converted=avf_cached_subtitle_image(&subtitleCache,sub,pq,&color);
    float oldPixels[16]={0}, newPixels[16]={0};
    [ctx render:old toBitmap:oldPixels rowBytes:8*sizeof(float) bounds:CGRectMake(0,0,2,2) format:kCIFormatRGBAf colorSpace:srgb];
    [ctx render:converted toBitmap:newPixels rowBytes:8*sizeof(float) bounds:CGRectMake(0,0,2,2) format:kCIFormatRGBAf colorSpace:pq];
    for(int i=0;i<4;i++) assert(fabs(oldPixels[4*i+3]-newPixels[4*i+3])<.001);
    for(int i=0;i<4;i++) if(newPixels[4*i+3]==0) for(int c=0;c<3;c++) assert(newPixels[4*i+c]==0);
    avf_subtitle_image_cache_clear(&subtitleCache);
    CGImageRelease(oldImage);CGColorSpaceRelease(srgb);
    CGColorRelease(bg);CGColorSpaceRelease(pq);CGColorSpaceRelease(linear);CVPixelBufferRelease(sub);
    puts("Native CoreVideo/CoreImage: metadata mappings/copies, stale HDR removal, format changes, subtitle cache reuse/invalidation, linear PQ alpha and overlay orientation passed");
}}
