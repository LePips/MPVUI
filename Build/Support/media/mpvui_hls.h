#ifndef MPVUI_HLS_H
#define MPVUI_HLS_H

#include "client.h"

/* HLS packaging through an opaque session that keeps FFmpeg types private.
 * Create, configure, probe, prepare, run, and destroy the session serially.
 * Cancellation, pause, and playback position updates may run concurrently.
 * Wait for probe, prepare, or run to return before destroying the session. */
typedef struct mpvui_hls mpvui_hls;

typedef struct mpvui_hls_plan {
    int video_copied;
    int audio_copied;
    int has_video;
    int has_audio;
    int requires_foreground;
} mpvui_hls_plan;

typedef struct mpvui_hls_info {
    int video_copied;
    int audio_copied;
    int has_video;
    int has_audio;
    int requires_foreground;
    int video_range; /* 0 = SDR, 1 = PQ, 2 = HLG. */
    int dolby_vision_profile;
    int dolby_vision_level;
    char video_codec[128];
    char audio_codec[32];
    int audio_channels;
    int audio_joc;
    double frame_rate;
    double start_time;
} mpvui_hls_info;

/* Select tracks by FFmpeg stream index. Use -1 for automatic selection or -2 to disable a track type.
 * A NULL playlist permits probing without creating output. */
MPV_EXPORT mpvui_hls *mpvui_hls_create(const char *source, const char *playlist, double start_time, int video, int audio);
/* Set a demuxer or protocol option before preparing the source. */
MPV_EXPORT int mpvui_hls_set_option(mpvui_hls *session, const char *key, const char *value);
/* Inspect selected tracks without opening encoders or creating HLS output. May decode the first keyframe.
 * Returns zero on success. The same session can subsequently be prepared if it has a playlist path. */
MPV_EXPORT int mpvui_hls_probe(mpvui_hls *session, mpvui_hls_plan *plan);
/* Probe the source, choose copying or encoding for each track, and open HLS output. Returns zero on success. */
MPV_EXPORT int mpvui_hls_prepare(mpvui_hls *session, mpvui_hls_info *info);
/* Package media until completion, cancellation, or failure. Wait when packaging runs too far ahead of playback. */
MPV_EXPORT int mpvui_hls_run(mpvui_hls *session);
MPV_EXPORT void mpvui_hls_set_playback_position(mpvui_hls *session, double seconds);
/* Pause after current media processing finishes so iOS can safely suspend GPU work. */
MPV_EXPORT void mpvui_hls_set_paused(mpvui_hls *session, int paused);
MPV_EXPORT void mpvui_hls_cancel(mpvui_hls *session);
/* Read the error after probe, prepare, or run returns. The text remains valid until the session is destroyed. */
MPV_EXPORT const char *mpvui_hls_error(mpvui_hls *session);
MPV_EXPORT void mpvui_hls_destroy(mpvui_hls *session);

#endif
