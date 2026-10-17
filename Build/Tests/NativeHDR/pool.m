/* Exercise bounded allocation and notification-driven buffer reuse. */
#import <Foundation/Foundation.h>
#import <CoreVideo/CoreVideo.h>
#include <assert.h>
#include <stdbool.h>
#include <stdio.h>
#include <time.h>

#define MPMIN(a, b) ((a) < (b) ? (a) : (b))
#define MPMAX(a, b) ((a) > (b) ? (a) : (b))
#define MP_TIME_MS_TO_NS(ms) ((int64_t)(ms) * 1000000)

struct options {
    int queue_lead_ms;
};
struct priv {
    bool playback_paused, presentation_host;
    int64_t next_present_host_ns, pool_frame_duration_ns;
    struct options *opts;
};
struct vo {
    struct priv *priv;
};

static int64_t mp_time_ns(void) {
    struct timespec now;
    assert(clock_gettime(CLOCK_MONOTONIC, &now) == 0);
    return now.tv_sec * INT64_C(1000000000) + now.tv_nsec;
}

#include "pool_functions.h"

int main(void) {
    @autoreleasepool {
        CVPixelBufferPoolRef pool = NULL;
        CVPixelBufferPoolRef reserve_pool = NULL;
        NSDictionary *attributes = @{
            (id)kCVPixelBufferPixelFormatTypeKey : @(kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange),
            (id)kCVPixelBufferWidthKey : @64,
            (id)kCVPixelBufferHeightKey : @36,
            (id)kCVPixelBufferIOSurfacePropertiesKey : @{},
        };
        assert(CVPixelBufferPoolCreate(NULL, NULL, (__bridge CFDictionaryRef)attributes, &pool) == kCVReturnSuccess);
        struct options opts = {.queue_lead_ms = 128};
        struct priv p = {.opts = &opts};
        struct vo vo = {.priv = &p};
        CVPixelBufferRef held[8] = {0};
        for (int i = 0; i < 7; i++)
            assert(avf_pool_get_buffer_for_frame(&vo, pool, &reserve_pool, &held[i]) == kCVReturnSuccess);

        CVPixelBufferRef extra = NULL;
        assert(avf_pool_get_buffer_for_frame(&vo, pool, &reserve_pool, &extra) == kCVReturnWouldExceedAllocationThreshold);
        assert(extra == NULL);

        // A stopped renderer may hold every queued buffer even after flush,
        // releasing them only once it receives a replacement image. Reserve
        // the eighth buffer so that replacement does not depend on clock progress.
        p.playback_paused = true;
        assert(avf_pool_get_buffer_for_frame(&vo, pool, &reserve_pool, &held[7]) == kCVReturnSuccess);
        assert(reserve_pool);
        assert(avf_pool_get_buffer_with_limit(pool, 7, &extra) == kCVReturnWouldExceedAllocationThreshold);
        assert(avf_pool_get_buffer_with_limit(reserve_pool, 1, &extra) == kCVReturnWouldExceedAllocationThreshold);
        assert(extra == NULL);
        p.playback_paused = false;

        // Releasing a saturated pool buffer on another thread must wake the
        // scoped observer and recycle a buffer while the eight-buffer cap holds.
        dispatch_group_t released = dispatch_group_create();
        CVPixelBufferRef retired = held[0];
        dispatch_group_enter(released);
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, MP_TIME_MS_TO_NS(10)), dispatch_get_global_queue(QOS_CLASS_DEFAULT, 0), ^{
          CVPixelBufferRelease(retired);
          dispatch_group_leave(released);
        });
        p.next_present_host_ns = mp_time_ns() + MP_TIME_MS_TO_NS(100);
        assert(avf_pool_get_buffer_for_frame(&vo, pool, &reserve_pool, &held[0]) == kCVReturnSuccess);
        assert(held[0]);
        dispatch_group_wait(released, DISPATCH_TIME_FOREVER);
        assert(avf_pool_get_buffer_with_limit(pool, 7, &extra) == kCVReturnWouldExceedAllocationThreshold);
        assert(extra == NULL);

        // A past deadline returns immediately. A paused redraw only has a
        // bounded wait even when a caller supplies a distant future deadline.
        p.next_present_host_ns = mp_time_ns();
        assert(avf_pool_get_buffer_for_frame(&vo, pool, &reserve_pool, &extra) == kCVReturnWouldExceedAllocationThreshold);
        p.playback_paused = true;
        p.next_present_host_ns = mp_time_ns() + MP_TIME_MS_TO_NS(1000);
        assert(avf_pool_get_buffer_for_frame(&vo, pool, &reserve_pool, &extra) == kCVReturnWouldExceedAllocationThreshold);
        assert(extra == NULL);

        // Release after timeout to exercise observer removal and block/semaphore
        // ownership under ASan. A later request must still recycle normally.
        CVPixelBufferRelease(held[1]);
        assert(avf_pool_get_buffer_for_frame(&vo, pool, &reserve_pool, &held[1]) == kCVReturnSuccess);

        // The renderer retires old regular images after displaying the spare.
        // Repeated resume must never consume that spare, even while it is free:
        // CoreVideo's allocation threshold alone would allow an eighth recycled
        // allocation in a single shared pool.
        for (int cycle = 0; cycle < 3; cycle++) {
            for (int i = 0; i < 8; i++) {
                CVPixelBufferRelease(held[i]);
                held[i] = NULL;
            }
            p.playback_paused = false;
            p.next_present_host_ns = mp_time_ns();
            for (int i = 0; i < 7; i++)
                assert(avf_pool_get_buffer_for_frame(&vo, pool, &reserve_pool, &held[i]) == kCVReturnSuccess);
            assert(avf_pool_get_buffer_for_frame(&vo, pool, &reserve_pool, &extra) == kCVReturnWouldExceedAllocationThreshold);
            assert(extra == NULL);
            p.playback_paused = true;
            assert(avf_pool_get_buffer_for_frame(&vo, pool, &reserve_pool, &held[7]) == kCVReturnSuccess);
            assert(avf_pool_get_buffer_with_limit(reserve_pool, 1, &extra) == kCVReturnWouldExceedAllocationThreshold);
        }
        for (int i = 0; i < 8; i++)
            CVPixelBufferRelease(held[i]);
        assert(avf_pool_get_buffer(pool, &extra) == kCVReturnSuccess);
        CVPixelBufferRelease(extra);

        // At 120 fps the default lead can queue sixteen samples. Keep room for
        // those samples, renderer retention and the next upload, without using
        // the paused replacement reserve or allowing unbounded allocation.
        p.playback_paused = false;
        p.pool_frame_duration_ns = MP_TIME_MS_TO_NS(1000) / 120;
        p.next_present_host_ns = mp_time_ns();
        CVPixelBufferRef high_rate[AVF_POOL_MAX_BUFFERS] = {0};
        int regular = avf_presentation_pool_limit(opts.queue_lead_ms, p.pool_frame_duration_ns, false);
        assert(regular >= 16 + 3 && regular < AVF_POOL_MAX_BUFFERS);
        for (int i = 0; i < regular; i++)
            assert(avf_pool_get_buffer_for_frame(&vo, pool, &reserve_pool, &high_rate[i]) == kCVReturnSuccess);
        assert(avf_pool_get_buffer_for_frame(&vo, pool, &reserve_pool, &extra) == kCVReturnWouldExceedAllocationThreshold);
        p.playback_paused = true;
        assert(avf_pool_get_buffer_for_frame(&vo, pool, &reserve_pool, &high_rate[regular]) == kCVReturnSuccess);
        assert(avf_pool_get_buffer_for_frame(&vo, pool, &reserve_pool, &extra) == kCVReturnWouldExceedAllocationThreshold);
        for (int i = 0; i <= regular; i++)
            CVPixelBufferRelease(high_rate[i]);
        assert(avf_presentation_pool_limit(1000, 1, false) == AVF_POOL_MAX_BUFFERS - 1);
        assert(avf_presentation_pool_limit(1000, 1, true) == AVF_POOL_MAX_BUFFERS);
        assert(avf_presentation_pool_limit(0, p.pool_frame_duration_ns, false) == 7);
        dispatch_release(released);
        CVPixelBufferPoolRelease(reserve_pool);
        CVPixelBufferPoolRelease(pool);
        puts("Pixel-buffer pool: high-rate capacity, bounded retry, pause reserve, deadlines and teardown passed");
    }
    return 0;
}
