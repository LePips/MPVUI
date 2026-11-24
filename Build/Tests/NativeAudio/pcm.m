#import <AVFoundation/AVFoundation.h>
#import <Foundation/Foundation.h>
#include <assert.h>
#include <math.h>

#define MP_TIME_MS_TO_NS(x) ((int64_t)(x) * 1000000LL)
#define MPMAX(a, b) ((a) > (b) ? (a) : (b))
#define MPMIN(a, b) ((a) < (b) ? (a) : (b))
#define MPCLAMP(x, low, high) MPMIN(MPMAX(x, low), high)
#define MP_VERBOSE(...) ((void)0)
#define MP_FATAL(...) ((void)0)

// Exercise the production mobile and desktop branches on the host. Only the
// platform clock, renderer readiness, timer delivery, and source are simulated.
#undef TARGET_OS_IPHONE
#define TARGET_OS_IPHONE TEST_MOBILE
#undef TARGET_OS_TV
#define TARGET_OS_TV TEST_TV
#undef TARGET_OS_OSX
#define TARGET_OS_OSX (!TEST_MOBILE)
static char avfoundation_queue_key;
static int64_t now;
static int64_t mp_time_ns(void) { return now; }

@interface TestPCMSession : NSObject
@property double outputLatency;
@property(copy) NSString *portType;
+ (instancetype)sharedInstance;
- (instancetype)currentRoute;
- (NSArray<TestPCMSession *> *)outputs;
@end
@implementation TestPCMSession
+ (instancetype)sharedInstance {
    static TestPCMSession *session;
    if (!session)
        session = [TestPCMSession new];
    return session;
}
- (instancetype)currentRoute {
    return self;
}
- (NSArray<TestPCMSession *> *)outputs {
    return self.portType ? @[ self ] : @[];
}
@end
#define AVAudioSession TestPCMSession
#define AVAudioSessionPortDescription TestPCMSession
#undef AVAudioSessionPortHDMI
#define AVAudioSessionPortHDMI @"HDMIOutput"

@interface TestPCMSynchronizer : NSObject
@property CMTime observedTime;
@property(nonatomic) float rate;
- (CMTime)currentTime;
@end
@implementation TestPCMSynchronizer
- (CMTime)currentTime {
    assert(dispatch_get_specific(&avfoundation_queue_key));
    return self.observedTime;
}
- (void)setRate:(float)rate {
    assert(dispatch_get_specific(&avfoundation_queue_key));
    _rate = rate;
}
@end

@interface TestPCMRenderer : NSObject
@property(copy) dispatch_block_t callback;
@property int requests;
@property int flushes;
@property int64_t samples;
@property CMTime lastEnd;
- (void)requestMediaDataWhenReadyOnQueue:(dispatch_queue_t)queue usingBlock:(dispatch_block_t)callback;
- (void)stopRequestingMediaData;
- (void)enqueueSampleBuffer:(CMSampleBufferRef)sample;
- (void)flush;
@end
@implementation TestPCMRenderer
- (void)requestMediaDataWhenReadyOnQueue:(dispatch_queue_t)queue usingBlock:(dispatch_block_t)callback {
    (void)queue;
    assert(dispatch_get_specific(&avfoundation_queue_key));
    self.requests++;
    self.callback = callback;
}
- (void)stopRequestingMediaData {
    assert(dispatch_get_specific(&avfoundation_queue_key));
    self.callback = nil;
}
- (void)enqueueSampleBuffer:(CMSampleBufferRef)sample {
    assert(dispatch_get_specific(&avfoundation_queue_key));
    CMTime pts = CMSampleBufferGetPresentationTimeStamp(sample);
    if (CMTIME_IS_NUMERIC(self.lastEnd))
        assert(CMTimeCompare(pts, self.lastEnd) >= 0);
    self.lastEnd = CMTimeAdd(pts, CMSampleBufferGetDuration(sample));
    self.samples += CMSampleBufferGetNumSamples(sample);
}
- (void)flush {
    assert(dispatch_get_specific(&avfoundation_queue_key));
    self.lastEnd = kCMTimeInvalid;
    self.flushes++;
}
- (void)dealloc {
    [_callback release];
    [super dealloc];
}
@end

struct TestTimer {
    dispatch_block_t handler;
    int64_t delay;
    bool resumed, canceled;
};
static bool fail_timer_creation;
static int live_timers;
static struct TestTimer *timer_state(dispatch_source_t source) { return (void *)source; }
static dispatch_source_t test_timer_create(dispatch_source_type_t type, uintptr_t handle, unsigned long mask, dispatch_queue_t queue) {
    (void)handle;
    (void)mask;
    (void)queue;
    assert(type == DISPATCH_SOURCE_TYPE_TIMER);
    if (fail_timer_creation)
        return NULL;
    struct TestTimer *timer = calloc(1, sizeof(*timer));
    live_timers++;
    return (dispatch_source_t)timer;
}
static void test_timer_handler(dispatch_source_t source, dispatch_block_t handler) { timer_state(source)->handler = [handler copy]; }
static void test_timer_schedule(dispatch_source_t source, dispatch_time_t start, uint64_t interval, uint64_t leeway) {
    (void)leeway;
    assert(interval == DISPATCH_TIME_FOREVER);
    timer_state(source)->delay = start == DISPATCH_TIME_FOREVER ? -1 : (int64_t)start;
}
static dispatch_time_t test_timer_time(dispatch_time_t start, int64_t delta) {
    assert(start == DISPATCH_TIME_NOW && delta > 0);
    return delta;
}
static void test_timer_resume(dispatch_source_t source) { timer_state(source)->resumed = true; }
static void test_timer_cancel(dispatch_source_t source) {
    struct TestTimer *timer = timer_state(source);
    timer->canceled = true;
    // A pending callback must remain harmless once feeding is disabled.
    timer->handler();
}
static void test_timer_release(dispatch_source_t source) {
    struct TestTimer *timer = timer_state(source);
    assert(timer->resumed && timer->canceled);
    [timer->handler release];
    free(timer);
    live_timers--;
}

struct priv {
    TestPCMRenderer *renderer;
    TestPCMSynchronizer *synchronizer;
    dispatch_queue_t queue;
    CMAudioFormatDescriptionRef format_description;
    int64_t end_time_av, pcm_lookahead_ns, pcm_credit_ns, pcm_credit_time_ns;
    dispatch_source_t feed_timer;
    bool feed_enabled;
    double opt_max_lookahead;
};
struct ao {
    struct priv *priv;
    int samplerate, sstride;
    double def_buffer;
    int reads, stops, reloads;
    int available;
    bool eof;
    int64_t read_samples, deadline;
};
static int ao_read_data(struct ao *ao, void **data, int count, int64_t deadline, bool *eof, bool pad, bool blocking) {
    assert(!pad && blocking && count > 0);
    int actual = MPMIN(count, ao->available);
    memset(data[0], 0, actual * ao->sstride);
    ao->available -= actual;
    *eof = ao->eof && !ao->available;
    ao->reads++;
    ao->read_samples += actual;
    ao->deadline = deadline;
    return actual;
}
static void ao_stop_streaming(struct ao *ao) { ao->stops++; }
static void ao_request_reload(struct ao *ao) { ao->reloads++; }

#define dispatch_source_create test_timer_create
#define dispatch_source_set_event_handler test_timer_handler
#define dispatch_source_set_timer test_timer_schedule
#define dispatch_source_cancel test_timer_cancel
#define dispatch_time test_timer_time
#undef dispatch_resume
#define dispatch_resume test_timer_resume
#undef dispatch_release
#define dispatch_release test_timer_release
#include "pcm.h"
#undef dispatch_release
#undef dispatch_resume
#undef dispatch_time

static void setup(struct ao *ao, struct priv *p, double lookahead, double latency, int samplerate) {
    now = MP_TIME_MS_TO_NS(10000);
    *p = (struct priv){.opt_max_lookahead = lookahead};
    *ao = (struct ao){.priv = p, .samplerate = samplerate, .sstride = 8, .def_buffer = 0.2, .available = INT_MAX};
    TestPCMSession.sharedInstance.outputLatency = latency;
    p->queue = dispatch_queue_create("pcm-regression", DISPATCH_QUEUE_SERIAL);
    dispatch_queue_set_specific(p->queue, &avfoundation_queue_key, p, NULL);
    p->renderer = [TestPCMRenderer new];
    p->synchronizer = [TestPCMSynchronizer new];
    p->synchronizer.observedTime = kCMTimeZero;
    AudioStreamBasicDescription asbd = {
        .mSampleRate = samplerate,
        .mFormatID = kAudioFormatLinearPCM,
        .mFormatFlags = kAudioFormatFlagIsFloat | kAudioFormatFlagIsPacked,
        .mBytesPerPacket = 8,
        .mFramesPerPacket = 1,
        .mBytesPerFrame = 8,
        .mChannelsPerFrame = 2,
        .mBitsPerChannel = 32,
    };
    assert(CMAudioFormatDescriptionCreate(NULL, &asbd, 0, NULL, 0, NULL, NULL, &p->format_description) == noErr);
    assert(pcm_init_feeding(ao));
}

static void teardown(struct ao *ao) {
    struct priv *p = ao->priv;
    dispatch_sync(p->queue, ^{
      pcm_stop(ao);
    });
    int requests = p->renderer.requests;
    pcm_uninit_feeding(ao);
    assert(!p->feed_timer && !p->feed_enabled && p->renderer.requests == requests);
    [p->renderer release];
    [p->synchronizer release];
    CFRelease(p->format_description);
    dispatch_release(p->queue);
    assert(!live_timers);
}

// Deliver callbacks as aggressively as an always-ready renderer can request.
static void pump(struct ao *ao) {
    struct priv *p = ao->priv;
    dispatch_sync(p->queue, ^{
      int calls = 0;
      while (p->renderer.callback) {
          assert(++calls < 1000);
          dispatch_block_t callback = [p->renderer.callback copy];
          callback();
          [callback release];
      }
    });
}

static void tick(struct ao *ao, int64_t elapsed, CMTime mediaTime) {
    struct priv *p = ao->priv;
    now += elapsed;
    p->synchronizer.observedTime = mediaTime;
    dispatch_sync(p->queue, ^{
      struct TestTimer *timer = timer_state(p->feed_timer);
      assert(timer->delay >= 0 && !timer->canceled);
      timer->handler();
    });
    pump(ao);
}

static void test_route_budget(void) {
    __block struct ao a;
    struct priv p;
    setup(&a, &p, PCM_DEFAULT_LOOKAHEAD, 2, 44100);
    assert(p.pcm_lookahead_ns == (TEST_MOBILE ? MP_TIME_MS_TO_NS(4000) : 0));
    teardown(&a);
    setup(&a, &p, 2, 0, 48000);
    assert(p.pcm_lookahead_ns == MP_TIME_MS_TO_NS(2000));
    teardown(&a);
    setup(&a, &p, 2, NAN, 48000);
    assert(p.pcm_lookahead_ns == MP_TIME_MS_TO_NS(2000));
    teardown(&a);
    setup(&a, &p, 0, 2, 48000);
    assert(!p.pcm_lookahead_ns);
    teardown(&a);
    setup(&a, &p, 2, 2, 48000);
    pcm_uninit_feeding(&a);
    fail_timer_creation = true;
    assert(!pcm_init_feeding(&a) && !p.feed_timer);
    fail_timer_creation = false;
    assert(pcm_init_feeding(&a));
    teardown(&a);
}

static void test_frozen_clock(void) {
    for (int rate = 44100; rate <= 48000; rate += 3900) {
        __block struct ao a;
        struct priv p;
        setup(&a, &p, 2, 2, rate);
        pcm_start(&a);
        pump(&a);
        int64_t expected = p.pcm_lookahead_ns * rate / 1000000000;
        assert(a.read_samples == expected && p.end_time_av == p.pcm_lookahead_ns);
        assert(timer_state(p.feed_timer)->delay == PCM_FULL_RETRY_NS);
        for (int i = 0; i < 100; i++)
            tick(&a, PCM_FULL_RETRY_NS, kCMTimeZero);
        assert(a.read_samples == expected && !a.stops && !a.reloads);
        teardown(&a);
    }
}

static void test_runaway_clock(void) {
    __block struct ao a;
    struct priv p;
    setup(&a, &p, 2, 2, 48000);
    pcm_start(&a);
    pump(&a);
    int64_t initial = a.read_samples;
    // The renderer clock races ahead by 100 s for every 50 ms of host time.
    for (int i = 1; i <= 200; i++) {
        tick(&a, PCM_FULL_RETRY_NS, CMTimeMake(i * 100, 1));
        assert(a.read_samples <= initial + (int64_t)i * 2424);
    }
    assert(a.read_samples == initial + 101 * a.samplerate / 10);
    teardown(&a);
}

static void test_steady_playback(void) {
    for (int clock_rate = 995; clock_rate <= 1005; clock_rate += 5) {
        __block struct ao a;
        struct priv p;
        setup(&a, &p, 2, 2, 44100);
        pcm_start(&a);
        pump(&a);
        int64_t initial = a.read_samples;
        // The independent audio clock can drift relative to the host clock.
        for (int i = 1; i <= 12000; i++) {
            CMTime media_time = CMTimeMake((int64_t)i * clock_rate, 20000);
            tick(&a, PCM_FULL_RETRY_NS, media_time);
            int64_t expected = initial + (int64_t)i * a.samplerate * clock_rate / 20000;
            assert(llabs(a.read_samples - expected) <= 1);
            assert(p.end_time_av <= p.pcm_lookahead_ns + CMTimeGetNanoseconds(media_time));
        }
        assert(!a.stops && !a.reloads);
        teardown(&a);
    }
}

static void test_short_reads_and_eof(void) {
    for (int bounded = 0; bounded <= 1; bounded++) {
        __block struct ao a;
        struct priv p;
        setup(&a, &p, bounded ? 2 : 0, 2, 48000);
        a.available = 1200;
        pcm_start(&a);
        pump(&a);
        assert(a.reads == 1 && a.read_samples == 1200 && !a.stops);
        assert(timer_state(p.feed_timer)->delay == PCM_RETRY_NS);
        tick(&a, PCM_RETRY_NS, kCMTimeZero);
        assert(a.reads == 2 && a.read_samples == 1200);
        a.available = 2400;
        a.eof = true;
        tick(&a, PCM_RETRY_NS, kCMTimeZero);
        assert(a.read_samples == 3600 && p.renderer.samples == 3600);
        assert(a.stops == 1 && !p.feed_enabled && timer_state(p.feed_timer)->delay == -1);
        // A callback queued before EOF cannot pull again.
        dispatch_sync(p.queue, ^{
          feed(&a);
        });
        assert(a.reads == 3);
        teardown(&a);
    }
}

static void test_pause_seek_and_teardown(void) {
    __block struct ao a;
    struct priv p;
    setup(&a, &p, 2, 2, 48000);
    pcm_start(&a);
    pump(&a);
    int64_t samples = a.read_samples, end = p.end_time_av;
    pcm_set_pause(&a, true);
    assert(!p.feed_enabled && !p.synchronizer.rate && timer_state(p.feed_timer)->delay == -1);
    now += MP_TIME_MS_TO_NS(60000);
    // Even if the platform clock jumps while paused, a late callback and a
    // subsequent resume cannot spend the paused minute as fresh feed credit.
    p.synchronizer.observedTime = CMTimeMake(end, 1000000000);
    dispatch_sync(p.queue, ^{
      feed(&a);
    });
    assert(a.read_samples == samples);
    pcm_set_pause(&a, false);
    pump(&a);
    assert(a.read_samples == samples && p.end_time_av == end && p.renderer.flushes == 0);
    // A seek flushes the old epoch, then gives the new one a bounded preroll.
    dispatch_sync(p.queue, ^{
      pcm_stop(&a);
    });
    p.synchronizer.observedTime = CMTimeMake(60, 1);
    pcm_start(&a);
    pump(&a);
    assert(a.read_samples == 2 * samples && p.renderer.flushes == 1);
    assert(p.end_time_av == MP_TIME_MS_TO_NS(60000) + p.pcm_lookahead_ns);
    teardown(&a);
}

static void test_invalid_clock_and_remaining_capacity(void) {
    __block struct ao a;
    struct priv p;
    setup(&a, &p, 2, 2, 48000);
    p.synchronizer.observedTime = kCMTimeInvalid;
    pcm_start(&a);
    pump(&a);
    assert(!a.reads && timer_state(p.feed_timer)->delay == PCM_RETRY_NS);
    tick(&a, PCM_RETRY_NS, kCMTimeZero);
    int64_t initial = a.read_samples;
    // Only 25 ms fits. A full 100 ms read would exceed the queue bound.
    tick(&a, MP_TIME_MS_TO_NS(100), CMTimeMake(1, 40));
    assert(a.read_samples == initial + 1200);
    teardown(&a);
}

static void test_hdmi_latency_deadline(void) {
    __block struct ao a;
    struct priv p;
    setup(&a, &p, 0, 0.29, 48000);
    TestPCMSession.sharedInstance.portType = @"HDMIOutput";

    a.available = 4800 * 5; // 500ms total across 5 pulls -> final pull end_time=400ms, delta=100ms
    a.eof = true;
    pcm_start(&a);
    pump(&a);
    assert(a.deadline == now + (TEST_TV ? MP_TIME_MS_TO_NS(210) : MP_TIME_MS_TO_NS(500)));

    // Wireless routes do not subtract HDMI latency.
    TestPCMSession.sharedInstance.portType = @"AirPlay";
    assert(avfoundation_hdmi_latency_ns() == 0);
    TestPCMSession.sharedInstance.portType = nil;
    teardown(&a);
}

int main(void) {
    @autoreleasepool {
        test_route_budget();
        test_frozen_clock();
        test_runaway_clock();
        test_steady_playback();
        test_short_reads_and_eof();
        test_pause_seek_and_teardown();
        test_invalid_clock_and_remaining_capacity();
        test_hdmi_latency_deadline();
    }
    printf("PCM feeder: 8 production checks passed (%s)\n", TEST_TV ? "tvOS" : TEST_MOBILE ? "iOS" : "macOS");
    return 0;
}
