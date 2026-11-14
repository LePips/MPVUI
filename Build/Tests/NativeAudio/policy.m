#import <AVFoundation/AVFoundation.h>
#import <Foundation/Foundation.h>
#include <assert.h>
#include <math.h>
#include <stdatomic.h>
#include "audio/out/ao_avfoundation_iec.h"

#define MP_TIME_MS_TO_NS(x) ((int64_t)(x) * 1000000LL)
#define MP_TIME_S_TO_NS(x) ((int64_t)(x) * 1000000000LL)
#define MPMAX(a, b) ((a) > (b) ? (a) : (b))
#define MPCLAMP(x, low, high) ((x) < (low) ? (low) : (x) > (high) ? (high) : (x))
#define MP_WARN(...) ((void)0)
#define MP_VERBOSE(...) ((void)0)
#define MP_ERR(...) ((void)0)

// Only platform observations and AO event delivery are simulated. policy.h
// contains the current patched production functions, extracted by run.py.
@interface TestItem : NSObject
@property AVPlayerItemStatus status;
@property(retain) NSError *error;
@property CMTimebaseRef timebase;
@property CMTime observedTime;
@property int seeks;
- (CMTime)currentTime;
- (void)seekToTime:(CMTime)time completionHandler:(void (^)(BOOL))completion;
@end
@implementation TestItem
- (CMTime)currentTime {
    return self.observedTime;
}
- (void)seekToTime:(CMTime)time completionHandler:(void (^)(BOOL))completion {
    (void)time;
    (void)completion;
    self.seeks++;
}
- (void)dealloc {
    [_error release];
    [super dealloc];
}
@end

@interface TestPlayer : NSObject
@property float rate;
@property float volume;
@property BOOL muted;
@property(retain) NSError *error;
@property AVPlayerTimeControlStatus timeControlStatus;
@end
@implementation TestPlayer
- (void)dealloc {
    [_error release];
    [super dealloc];
}
@end

struct priv {
    TestItem *item;
    TestPlayer *player;
    bool spdif_reload_requested, timer_idle, avp_gain_warned, avp_muted;
    float avp_volume;
    bool avp_playing, avp_eof, avp_rate_applied, avp_start_seeked;
    int64_t es_pts, avp_start_deadline, avp_last_position, avp_last_progress;
    int64_t avp_primed_pts, avp_lead_ns;
    int spdif_rate, stash_len, es_len;
    bool avp_bounded_length, avp_eof_response;
    int64_t es_served_until, es_head;
    int64_t avp_eof_parked_since, avp_eof_parked_position, avp_eof_parked_end;
};
struct ao {
    struct priv *priv;
    _Atomic float gain;
    int fallback_requests, stopped_clocks;
};
static int64_t now;
static int64_t mp_time_ns(void) { return now; }
static void avp_timer_idle(struct priv *p) { p->timer_idle = true; }
static void ao_request_pcm_fallback(struct ao *ao) { ao->fallback_requests++; }
static void ao_update_streaming_clock(struct ao *ao, int64_t delay, double rate, bool playing) {
    assert(delay == 0 && rate == 0 && !playing);
    ao->stopped_clocks++;
}
#include "policy.h"

static struct priv state(void) {
    TestItem *item = [[[TestItem alloc] init] autorelease];
    item.observedTime = kCMTimeZero;
    item.status = AVPlayerItemStatusReadyToPlay;
    TestPlayer *player = [[[TestPlayer alloc] init] autorelease];
    player.timeControlStatus = AVPlayerTimeControlStatusPaused;
    return (struct priv){.item = item, .player = player, .avp_volume = 1, .spdif_rate = 48000, .avp_lead_ns = MP_TIME_S_TO_NS(5)};
}

static void test_iec(void) {
    uint8_t data[24576] = {0x72, 0xf8, 0x1f, 0x4e};
    for (int codec = 0; codec < 2; codec++) {
        int type = codec ? 0x15 : 1, period = codec ? 24576 : 6144;
        data[4] = type;
        int encoded = codec ? 100 : 800;
        data[6] = encoded & 255;
        data[7] = encoded >> 8;
        data[8] = 0x77;
        data[9] = 0x0b;
        int payload = -1;
        for (int size = 0; size < period; size++)
            assert(avfoundation_iec_payload(data, size, type, period, &payload) == 0);
        assert(avfoundation_iec_payload(data, period, type, period, &payload) == 1 && payload == 100);
        data[4] |= 0x80;
        assert(avfoundation_iec_payload(data, period, type, period, &payload) == -1);
        data[4] = type;
        data[8] = 0;
        assert(avfoundation_iec_payload(data, period, type, period, &payload) == -1);
        data[8] = 0x77;
        for (int length = 0; length <= 65535; length++) {
            data[6] = length & 255;
            data[7] = length >> 8;
            int decoded = codec ? length : length / 8;
            bool valid = (codec || length % 8 == 0) && decoded >= 8 && !(decoded & 1) && decoded <= period - 8;
            assert(avfoundation_iec_payload(data, period, type, period, &payload) == (valid ? 1 : -1));
        }
        assert(avfoundation_iec_payload(data, -1, type, period, &payload) == -1);
        assert(avfoundation_iec_payload(data, period, type, period - 1, &payload) == -1);
    }
}

static void test_ranges(void) {
    int64_t end = 0;
    assert(!avfoundation_request_end(-1, 0, false, &end));
    assert(!avfoundation_request_end(0, -1, false, &end));
    assert(!avfoundation_request_end(INT64_MAX, 1, false, &end));
    assert(avfoundation_request_end(INT64_MAX - 1, 1, false, &end) && end == INT64_MAX);
    assert(avfoundation_request_end(100, -1, true, &end) && end == INT64_MAX);
    assert(avfoundation_request_end(0, 0, false, &end) && end == 0);
}

static void test_clock(void) {
    struct priv p = state();
    struct ao a = {.priv = &p, .gain = 1};
    p.es_pts = MP_TIME_S_TO_NS(4200);
    p.item.observedTime = CMTimeMake(MP_TIME_S_TO_NS(4199), 1000000000);
    assert(avp_current_time_ns(&a) == MP_TIME_S_TO_NS(4199));
    p.item.observedTime = CMTimeMake(MP_TIME_S_TO_NS(4300), 1000000000);
    assert(avp_current_time_ns(&a) == p.es_pts);
    p.item.observedTime = CMTimeMake(-1, 1);
    assert(avp_current_time_ns(&a) == 0);
    p.item.observedTime = kCMTimeInvalid;
    assert(avp_current_time_ns(&a) == 0);
    p.item = nil;
    assert(avp_current_time_ns(&a) == 0);
}

static void test_startup(void) {
    struct priv p = state();
    struct ao a = {.priv = &p, .gain = 1};
    now = MP_TIME_S_TO_NS(1);
    avp_update_transport(&a);
    assert(!p.avp_rate_applied);
    p.avp_playing = true;
    avp_update_transport(&a);
    assert(!p.avp_rate_applied);
    p.es_pts = MP_TIME_S_TO_NS(10);
    avp_update_transport(&a);
    assert(p.avp_rate_applied && p.player.rate == 1);
    now += AVP_START_GRACE_NS + 1;
    avp_update_transport(&a);
    assert(p.item.seeks == 1 && !a.fallback_requests);
    now += AVP_START_GRACE_NS + 1;
    avp_update_transport(&a);
    assert(a.fallback_requests == 1 && a.stopped_clocks == 1 && p.timer_idle && p.player.rate == 0);
    avp_update_transport(&a);
    assert(a.fallback_requests == 1);
    struct priv slow = state();
    struct ao b = {.priv = &slow, .gain = 1};
    slow.avp_playing = true;
    slow.es_pts = AVP_START_MIN_NS;
    avp_update_transport(&b);
    now += AVP_START_GRACE_NS + 1;
    slow.es_pts += AVP_START_MIN_NS;
    avp_update_transport(&b);
    assert(!b.fallback_requests && slow.item.seeks == 0);
    slow.item.observedTime = CMTimeMake(1, 2);
    avp_update_transport(&b);
    assert(slow.avp_start_deadline < 0 && slow.avp_last_position == 500000000);
}

static void test_stalls(void) {
    for (int eof = 0; eof < 2; eof++) {
        struct priv p = state();
        struct ao a = {.priv = &p, .gain = 1};
        p.avp_playing = p.avp_rate_applied = true;
        p.avp_eof = eof;
        p.avp_start_deadline = -1;
        p.es_pts = MP_TIME_S_TO_NS(4200);
        p.item.observedTime = CMTimeMake(4190, 1);
        now = MP_TIME_S_TO_NS(5000);
        avp_update_transport(&a);
        now += MP_TIME_S_TO_NS(eof ? 2 : 10);
        avp_update_transport(&a);
        assert(!a.fallback_requests);
        now++;
        avp_update_transport(&a);
        assert(a.fallback_requests == 1);
    }
    struct priv p = state();
    struct ao a = {.priv = &p, .gain = 1};
    p.avp_playing = p.avp_rate_applied = true;
    p.avp_start_deadline = -1;
    p.es_pts = MP_TIME_S_TO_NS(1);
    p.item.observedTime = CMTimeMake(1, 1);
    now += MP_TIME_S_TO_NS(100);
    avp_update_transport(&a);
    assert(!a.fallback_requests); // Source underrun is not a decoder stall.
}

static void test_tail(void) {
    struct priv p = state();
    struct ao a = {.priv = &p, .gain = 1};
    p.avp_playing = p.avp_bounded_length = p.avp_eof = p.avp_eof_response = true;
    p.avp_start_deadline = -1;
    p.avp_last_position = MP_TIME_S_TO_NS(1);
    p.es_pts = MP_TIME_S_TO_NS(1) + MP_TIME_MS_TO_NS(98);
    p.es_len = 1000;
    p.es_served_until = 1000;
    int64_t position = MP_TIME_S_TO_NS(1);
    now = MP_TIME_S_TO_NS(1);
    assert(!avp_stream_tail_drained(&a, position, 0, true));
    now += AVP_EOF_SETTLE_NS - 1;
    assert(!avp_stream_tail_drained(&a, position, 0, true));
    now++;
    assert(avp_stream_tail_drained(&a, position, 0, true));
    assert(!avp_stream_tail_drained(&a, position, 1, true));
    assert(!p.avp_eof_parked_since);
    assert(!avp_stream_tail_drained(&a, position, 0, false));
    p.avp_eof = false;
    assert(!avp_stream_tail_drained(&a, position, 0, true));
    p.avp_eof = true;
    p.es_served_until--;
    assert(!avp_stream_tail_drained(&a, position, 0, true));
    p.es_served_until++;
    p.stash_len = 1;
    assert(!avp_stream_tail_drained(&a, position, 0, true));
    p.stash_len = 0;
    p.avp_playing = false;
    assert(!avp_stream_tail_drained(&a, position, 0, true));
    p.avp_playing = true;
    p.es_pts += MP_TIME_S_TO_NS(1);
    assert(!avp_stream_tail_drained(&a, position, 0, true));
    p.es_pts -= MP_TIME_S_TO_NS(1);
    p.item.status = AVPlayerItemStatusFailed;
    assert(!avp_stream_tail_drained(&a, position, 0, true));
    p.item.status = AVPlayerItemStatusReadyToPlay;
    assert(!avp_stream_tail_drained(&a, position, 0, true));
    now += AVP_EOF_SETTLE_NS;
    assert(!avp_stream_tail_drained(&a, position + 1, 0, true)); // Movement rearms settlement.
}

static void test_volume(void) {
    struct priv p = state(), q = state();
    struct ao a = {.priv = &p, .gain = 0.5}, b = {.priv = &q, .gain = 1};
    p.avp_volume = 0.5;
    avp_apply_volume(&a);
    avp_apply_volume(&b);
    assert(p.player.volume == 0.25 && q.player.volume == 1);
    atomic_store(&a.gain, 3);
    avp_apply_volume(&a);
    assert(p.player.volume == 1 && p.avp_gain_warned);
    float invalid[] = {NAN, INFINITY, -1, 0};
    for (unsigned i = 0; i < sizeof(invalid) / sizeof(*invalid); i++) {
        atomic_store(&a.gain, invalid[i]);
        avp_apply_volume(&a);
        assert(p.player.muted && p.player.volume == 0 && !q.player.muted);
    }
    atomic_store(&a.gain, 1);
    p.avp_muted = true;
    avp_apply_volume(&a);
    assert(p.player.muted && !q.player.muted);
}

int main(void) {
    @autoreleasepool {
        test_iec();
        test_ranges();
        test_clock();
        test_startup();
        test_stalls();
        test_tail();
        test_volume();
    }
    puts("Native audio: 7 production-policy checks passed with ASan/UBSan");
    return 0;
}
