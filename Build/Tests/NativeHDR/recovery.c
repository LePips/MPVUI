#include <assert.h>
#include <limits.h>
#include <stdint.h>
#include <stdio.h>

#include "hwdec_recovery.h"

static void default_thresholds(void) {
    // Startup and non-native codecs keep the original three-error fallback.
    for (int eligible = 0; eligible <= 1; eligible++) {
        struct mp_hwdec_recovery state = {0};
        assert(!mp_hwdec_recovery_error(&state, -1, eligible, 0));
        assert(!mp_hwdec_recovery_error(&state, -1, eligible, 1));
        assert(mp_hwdec_recovery_error(&state, -1, eligible, 2));
    }
    struct mp_hwdec_recovery state = {0};
    mp_hwdec_recovery_frame(&state);
    assert(!mp_hwdec_recovery_error(&state, -1, false, 0));
    assert(!mp_hwdec_recovery_error(&state, -1, false, 1));
    assert(mp_hwdec_recovery_error(&state, -1, false, 2));
}

static void explicit_thresholds(void) {
    for (int threshold = 1; threshold <= 8; threshold++) {
        struct mp_hwdec_recovery state = {0};
        mp_hwdec_recovery_frame(&state);
        for (int error = 1; error <= threshold; error++) {
            int64_t now = (int64_t)error * MP_HWDEC_RECOVERY_MAX_NS;
            assert(mp_hwdec_recovery_error(&state, threshold, true, now) == (error == threshold));
            assert(!mp_hwdec_recovery_expired(&state, threshold, true, now));
        }
    }
    struct mp_hwdec_recovery state = {.had_frame = true, .errors = INT_MAX - 1};
    for (int error = 0; error < 10; error++) {
        assert(!mp_hwdec_recovery_error(&state, INT_MAX, true, INT64_MAX));
        assert(state.errors == INT_MAX);
        assert(!mp_hwdec_recovery_expired(&state, INT_MAX, true, INT64_MAX));
    }
}

static void elapsed_bound(void) {
    struct mp_hwdec_recovery state = {0};
    mp_hwdec_recovery_frame(&state);
    // Zero is a valid first timestamp. The counter establishes timer presence.
    for (int error = 0; error < 3; error++)
        assert(!mp_hwdec_recovery_error(&state, -1, true, error));
    assert(state.first_error_ns == 0);
    assert(!mp_hwdec_recovery_expired(&state, -1, true, MP_HWDEC_RECOVERY_MAX_NS - 1));
    assert(mp_hwdec_recovery_expired(&state, -1, true, MP_HWDEC_RECOVERY_MAX_NS));
    // A decode attempt with no additional error still spends the allowance.
    assert(state.errors == 3);
    assert(!mp_hwdec_recovery_expired(&state, -1, false, INT64_MAX));
    assert(!mp_hwdec_recovery_expired(&state, -1, true, -1));
    assert(mp_hwdec_recovery_error(&state, -1, true, MP_HWDEC_RECOVERY_MAX_NS));

    mp_hwdec_recovery_frame(&state);
    assert(!mp_hwdec_recovery_expired(&state, -1, true, INT64_MAX));
    assert(state.first_error_ns == 0 && state.errors == 0 && state.had_frame);
    // Sparse errors retain the minimum error threshold before using the timer.
    assert(!mp_hwdec_recovery_error(&state, -1, true, 100));
    assert(!mp_hwdec_recovery_error(&state, -1, true, 100 + MP_HWDEC_RECOVERY_MAX_NS));
    assert(!mp_hwdec_recovery_expired(&state, -1, true, INT64_MAX));
    assert(mp_hwdec_recovery_error(&state, -1, true, 101 + MP_HWDEC_RECOVERY_MAX_NS));

    mp_hwdec_recovery_reset(&state);
    assert(state.first_error_ns == 0 && state.errors == 0 && !state.had_frame);
    assert(!mp_hwdec_recovery_expired(&state, -1, true, INT64_MAX));
    assert(!mp_hwdec_recovery_error(&state, -1, true, 0));
    assert(!mp_hwdec_recovery_error(&state, -1, true, 1));
    assert(mp_hwdec_recovery_error(&state, -1, true, 2));
}

static void attempt_bounds(void) {
    struct mp_hwdec_recovery state = {0};
    mp_hwdec_recovery_frame(&state);
    // Keyframes before any failure do not consume recovery attempts.
    mp_hwdec_recovery_packet(&state, true);
    assert(state.keyframes == 0);
    assert(!mp_hwdec_recovery_error(&state, -1, true, 0));
    mp_hwdec_recovery_packet(&state, false);
    assert(state.keyframes == 0);
    mp_hwdec_recovery_packet(&state, true);
    assert(!mp_hwdec_recovery_error(&state, -1, true, 1));
    mp_hwdec_recovery_packet(&state, true);
    assert(mp_hwdec_recovery_error(&state, -1, true, 2));
    mp_hwdec_recovery_packet(&state, true);
    assert(state.keyframes == MP_HWDEC_RECOVERY_KEYFRAMES);

    mp_hwdec_recovery_frame(&state);
    assert(state.keyframes == 0);
    for (int error = 1; error <= MP_HWDEC_RECOVERY_MAX_ERRORS; error++) {
        assert(mp_hwdec_recovery_error(&state, -1, true, error) == (error == MP_HWDEC_RECOVERY_MAX_ERRORS));
    }
}

int main(void) {
    default_thresholds();
    explicit_thresholds();
    elapsed_bound();
    attempt_bounds();
    puts("Native HEVC recovery: thresholds, elapsed bound, keyframes, reset and explicit overrides passed");
    return 0;
}
