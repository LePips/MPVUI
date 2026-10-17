#ifndef MPVCORE_BRIDGE_H
#define MPVCORE_BRIDGE_H

#include <stddef.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

#define MPVCORE_ABI_VERSION 1

/* UTF-8 bytes; length excludes any terminator. Inputs are borrowed for the call. */
typedef struct {
    const uint8_t *data;
    size_t length;
} MPVCoreString;

/* Every returned buffer has one matching mpvcore_buffer_release call. */
typedef struct {
    uint8_t *data;
    size_t length;
} MPVCoreBuffer;

typedef struct {
    uint32_t version;
    uint32_t size;
    int32_t video_output;      /* 0: GPU, 1: direct MediaCodec surface, 2: automatic */
    int32_t hardware_decoding; /* 0: automatic, 1: MediaCodec, 2: software */
    int32_t auto_play;
    int32_t loop;
    int32_t low_power;
    int32_t profile7_compatibility;
    double volume;
    double playback_rate;
    double initial_buffer_seconds;
    double network_cache_seconds;
    /* Native platform setup only; the pointer never crosses into Java. */
    void *platform_context;
    int32_t (*prepare_handle)(void *platform_context, void *mpv_handle);
    /* Optional ABI v1 configuration record, copied before create returns. */
    MPVCoreString settings;
} MPVCoreConfiguration;

/* Opaque retained Swift session. No Swift layouts or borrowed mpv nodes escape. */
typedef void *MPVCoreSession;

/* Stable command discriminants. Unused fields must be zero. Strings are UTF-8
 * and may not contain NUL. Every input is copied before send returns. */
typedef enum {
    MPVCORE_LOAD = 1,
    MPVCORE_PLAY,
    MPVCORE_PAUSE,
    MPVCORE_TOGGLE,
    MPVCORE_STOP,
    MPVCORE_SEEK,
    MPVCORE_SEEK_RELATIVE,
    MPVCORE_FRAME_STEP,
    MPVCORE_VOLUME,
    MPVCORE_MUTE,
    MPVCORE_RATE,
    MPVCORE_SELECT_TRACK,
    MPVCORE_SELECT_SUBTITLE,
    MPVCORE_DISABLE_TRACK,
    MPVCORE_INTERCEPT_SUBTITLES,
    MPVCORE_DIAGNOSTICS,
    MPVCORE_PROPERTY,
    MPVCORE_NATIVE_COMMAND,
    MPVCORE_EXTERNAL_TRACK,
    MPVCORE_CLEAR_ERROR,
    MPVCORE_TOGGLE_MUTE
} MPVCoreCommandKind;

typedef struct {
    uint32_t version, size;
    int32_t kind;
    int32_t flags;      /* load: autoplay -1(default), 0, 1; other commands: boolean */
    int32_t track_type; /* 0 video, 1 audio, 2 subtitles */
    int32_t role;       /* 0 primary, 1 secondary, -1 no selection */
    int64_t track_id;   /* -1 disables a subtitle slot */
    double value;       /* finite seconds/value; load start omitted when has_value=0 */
    int32_t has_value;
    const MPVCoreString *strings;
    size_t string_count;
} MPVCoreCommand;

typedef struct {
    uint64_t id, generation;
} MPVCoreOperation;

/* Callbacks run on the session queue and must only copy/signal, never call the
 * session synchronously. buffer ownership transfers to the callback. kind is
 * 1 snapshot, 2 log, 3 subtitle query, 4 cancelled query, 5 failed query,
 * 6 replaceable continuous snapshot. Logs may be delivered through a bounded channel.
 * Records begin with MPVC + uint32 version and use the typed v1 field schema.
 * Unknown fields may be skipped; unknown schema versions must be rejected. */
typedef void (*MPVCoreDelivery)(void *context, int32_t kind, uint64_t generation, MPVCoreBuffer buffer);
typedef void (*MPVCoreContextRelease)(void *context);
typedef void *MPVCoreSubscription;
typedef void *MPVCoreQuery;

uint32_t mpvcore_abi_version(void);
MPVCoreSession mpvcore_session_create(const MPVCoreConfiguration *configuration);
int32_t mpvcore_session_initialize(MPVCoreSession session);
void mpvcore_session_close(MPVCoreSession session);
void mpvcore_session_retain(MPVCoreSession session);
void mpvcore_session_release(MPVCoreSession session);
void mpvcore_buffer_release(MPVCoreBuffer buffer);
int32_t mpvcore_session_send(MPVCoreSession session, const MPVCoreCommand *command, MPVCoreOperation *operation);
MPVCoreBuffer mpvcore_session_snapshot(MPVCoreSession session);
/* Bit positions follow nativeSubtitles, bakedOverlays, zoomAndPan, inlineOverlays, PiP subtitles. */
MPVCoreBuffer mpvcore_session_request_features(MPVCoreSession session, uint32_t mask);
MPVCoreSubscription mpvcore_session_subscribe(MPVCoreSession session, void *context, MPVCoreDelivery delivery);
/* Cancels and fences all callbacks before returning; consumes subscription. */
void mpvcore_subscription_release(MPVCoreSubscription subscription);
MPVCoreQuery mpvcore_query_subtitles(MPVCoreSession session, int32_t track_type, int64_t track_id, void *context, MPVCoreDelivery delivery,
                                     MPVCoreContextRelease release_context);
/* Cancels and consumes the query. release_context runs after the last callback. */
void mpvcore_query_release(MPVCoreQuery query);

/* Surface ownership transfers only on success. The core releases the context
 * after native renderer/decoder retirement. Address is an opaque platform token
 * (a JNI global Surface reference on Android), never a borrowed reference. */
int32_t mpvcore_session_surface(MPVCoreSession session, int64_t address, void *context, MPVCoreContextRelease release_context,
                                MPVCoreString display);
void mpvcore_session_resize(MPVCoreSession session, int64_t address, int32_t width, int32_t height);

#ifdef __cplusplus
}
#endif
#endif
