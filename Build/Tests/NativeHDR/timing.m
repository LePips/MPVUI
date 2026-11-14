/* Production frame timing with a real CoreMedia timebase and synthetic frames. */
#import <Foundation/Foundation.h>
#import <CoreMedia/CoreMedia.h>
#include <assert.h>
#include <math.h>
#include <stdbool.h>
#include <stdio.h>

#define MP_TIME_US_TO_NS(t) ((int64_t)((t) * 1000LL))
#define MP_TIME_MS_TO_NS(t) ((int64_t)((t) * 1000000LL))
#define MP_TIME_S_TO_NS(t) ((int64_t)((t) * 1000000000LL))
#define MPCLAMP(x, lo, hi) fmin(fmax(x, lo), hi)
#define MP_NOPTS_VALUE (-1e20)
#define MP_VERBOSE(...) ((void)0)
#define MP_WARN(...) assert(!"CoreMedia timebase operation failed")

#include "timing_core.h"

struct mp_image {
    double pts;
};
struct vo_frame {
    struct mp_image *current;
    bool repeat, redraw;
    int64_t pts;
    double playback_rate;
    bool display_synced;
    double ideal_frame_duration, duration;
};
struct priv {
    struct mp_image *next_image;
    double next_pts;
    CMTimebaseRef timebase;
    int64_t next_present_host_ns, next_media_pts_ns, last_media_pts_ns;
    bool next_media_pts_valid, last_media_pts_valid;
    double next_timebase_rate;
    bool next_timebase_rate_valid;
    bool timebase_anchor_valid, timebase_paused, playback_paused;
    double timebase_rate, timebase_applied_rate, servo_integral;
    int64_t last_rate_update_ns, last_servo_eval_ns, diag_drift_peak_ns;
    int diag_rate_update_count, diag_anchor_count;
    int64_t pool_frame_duration_ns;
};
struct vo {
    struct priv *priv;
};

static int64_t mp_time_ns(void) {
    return CMTimeConvertScale(CMClockGetTime(CMClockGetHostTimeClock()), NSEC_PER_SEC, kCMTimeRoundingMethod_Default).value;
}

// Image ownership is unrelated to timing. The test retains all synthetic frames.
static void mp_image_unrefp(struct mp_image **image) { *image = NULL; }
static struct mp_image *mp_image_new_ref(struct mp_image *image) { return image; }

#include "timing_functions.h"

static void present(struct vo *vo, double pts, double rate, bool redraw) {
    struct mp_image image = {.pts = pts};
    struct vo_frame frame = {
        .current = &image,
        .pts = mp_time_ns(),
        .playback_rate = rate,
        .redraw = redraw,
    };
    assert(draw_frame(vo, &frame));
    update_media_timebase_for_frame(vo);
    assert(vo->priv->timebase_rate == rate);
    assert(CMTimebaseGetRate(vo->priv->timebase) == (vo->priv->playback_paused ? 0 : rate));
    CMTime scheduled = CMSyncConvertTime(CMTimeMake(frame.pts, NSEC_PER_SEC), CMClockGetHostTimeClock(), vo->priv->timebase);
    assert(fabs(CMTimeGetSeconds(scheduled) - pts) < 0.02);
    mp_image_unrefp(&vo->priv->next_image);
}

int main(void) {
    struct priv p = {0};
    struct vo vo = {.priv = &p};
    assert(CMTimebaseCreateWithSourceClock(NULL, CMClockGetHostTimeClock(), &p.timebase) == noErr);
    reset_media_timing(&p);

    // Every changed rate must apply on its first frame, including small changes
    // and rates outside the removed estimator's 0.05...8 range.
    double rates[] = {1.5, 0.5, 2, 1.005, 1, 0.01, 100};
    for (size_t i = 0; i < sizeof(rates) / sizeof(rates[0]); i++) {
        int anchors = p.diag_anchor_count;
        present(&vo, 2 + i * 0.037, rates[i], false);
        assert(p.diag_anchor_count == anchors + 1);
    }

    // A paused redraw stores the new nominal rate while keeping the clock stopped.
    p.playback_paused = true;
    present(&vo, 4, 0.75, true);
    p.playback_paused = false;
    present(&vo, 4.041, 0.75, false);

    // Seek resets must not delay the first frame's new rate or infer speed from
    // the timestamp discontinuity. The same applies to irregular frame cadence.
    reset_media_timing(&p);
    present(&vo, 20, 1.25, false);
    present(&vo, 3, 1.25, false);
    present(&vo, 3.2, 1.25, false);

    CFRelease(p.timebase);
    puts("Presentation timing: first-frame speed changes, paused redraw, seek and irregular cadence passed");
    return 0;
}
