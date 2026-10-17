// SPDX-License-Identifier: MIT
#include <jni.h>
#include <android/asset_manager.h>
#include <android/asset_manager_jni.h>
#include <MPVCoreBridge.h>
#include <mpv/client.h>
#include <mpv/stream_cb.h>
extern "C" {
#include <libavcodec/jni.h>
}
#include <cstdint>
#include <mutex>
#include <condition_variable>
#include <algorithm>
#include <iterator>
#include <deque>
#include <map>
#include <memory>
#include <string>
#include <vector>
#include <atomic>
#include <unistd.h>
#include <fcntl.h>
#include <poll.h>
#include <sys/stat.h>

namespace {
std::once_flag vm_once;
JavaVM *java_vm = nullptr;
jobject app_context = nullptr;
AAssetManager *asset_manager = nullptr;
jclass java_string_class = nullptr;
jobject utf8_charset = nullptr;
jmethodID string_bytes = nullptr;
jmethodID string_constructor = nullptr;
jclass event_class = nullptr;
jmethodID event_constructor = nullptr;
void error(JNIEnv *env, const char *message) { env->ThrowNew(env->FindClass("java/lang/IllegalStateException"), message); }
std::string utf8(JNIEnv *env, jstring text) {
    if (!text) {
        error(env, "Null core string");
        return {};
    }
    auto bytes = static_cast<jbyteArray>(env->CallObjectMethod(text, string_bytes, utf8_charset));
    if (!bytes || env->ExceptionCheck())
        return {};
    std::string value(env->GetArrayLength(bytes), '\0');
    env->GetByteArrayRegion(bytes, 0, value.size(), reinterpret_cast<jbyte *>(value.data()));
    env->DeleteLocalRef(bytes);
    return value;
}
jstring string(JNIEnv *env, const std::string &value) {
    jbyteArray bytes = env->NewByteArray(value.size());
    env->SetByteArrayRegion(bytes, 0, value.size(), reinterpret_cast<const jbyte *>(value.data()));
    auto result = static_cast<jstring>(env->NewObject(java_string_class, string_constructor, bytes, utf8_charset));
    env->DeleteLocalRef(bytes);
    return result;
}
std::vector<uint8_t> bytes(JNIEnv *env, jbyteArray value) {
    if (!value)
        return {};
    std::vector<uint8_t> result(env->GetArrayLength(value));
    env->GetByteArrayRegion(value, 0, result.size(), reinterpret_cast<jbyte *>(result.data()));
    return result;
}
MPVCoreString borrowed(const std::vector<uint8_t> &value) { return {value.data(), value.size()}; }
jbyteArray array(JNIEnv *env, const std::vector<uint8_t> &value) {
    auto result = env->NewByteArray(value.size());
    if (result)
        env->SetByteArrayRegion(result, 0, value.size(), reinterpret_cast<const jbyte *>(value.data()));
    return result;
}
struct Event {
    int32_t kind;
    uint64_t generation, query;
    std::vector<uint8_t> record;
};
struct DeliveryQueue {
    std::mutex mutex;
    std::condition_variable condition;
    std::deque<Event> records;
    bool stopped = false;
    void push(int32_t kind, uint64_t generation, uint64_t query, MPVCoreBuffer buffer) {
        // Swift has already copied and interpreted the event. JNI only owns delivery.
        std::vector<uint8_t> record;
        if (buffer.data)
            record.assign(buffer.data, buffer.data + buffer.length);
        mpvcore_buffer_release(buffer);
        std::lock_guard<std::mutex> lock(mutex);
        if (stopped)
            return;
        if (kind == 6) {
            // Only snapshots certified by Swift as continuous may replace one
            // another. Lifecycle, metadata, errors and subtitles form barriers.
            for (auto item = records.rbegin(); item != records.rend(); ++item) {
                if (item->kind == 2)
                    continue;
                if (item->kind == 6 && item->generation == generation) {
                    records.erase(std::next(item).base());
                }
                break;
            }
        }
        if (kind == 2) {
            size_t logs = 0;
            for (const auto &item : records)
                if (item.kind == 2)
                    ++logs;
            if (logs >= 100) {
                auto oldest = std::find_if(records.begin(), records.end(), [](const Event &item) { return item.kind == 2; });
                records.erase(oldest);
            }
        }
        records.push_back({kind, generation, query, std::move(record)});
        condition.notify_one();
    }
};
struct Player {
    MPVCoreSession session = nullptr;
    MPVCoreSubscription subscription = nullptr;
    std::shared_ptr<DeliveryQueue> queue = std::make_shared<DeliveryQueue>();
    std::map<uint64_t, MPVCoreQuery> queries;
    int64_t surface_address = 0;
};
Player *player(jlong value) { return reinterpret_cast<Player *>(value); }
void deliver(void *context, int32_t kind, uint64_t generation, MPVCoreBuffer buffer) {
    static_cast<DeliveryQueue *>(context)->push(kind, generation, 0, buffer);
}
struct QueryContext {
    std::shared_ptr<DeliveryQueue> queue;
    uint64_t id;
};
void deliver_query(void *context, int32_t kind, uint64_t generation, MPVCoreBuffer buffer) {
    auto query = static_cast<QueryContext *>(context);
    query->queue->push(kind, generation, query->id, buffer);
}
void release_query(void *context) { delete static_cast<QueryContext *>(context); }
void release_surface(void *context) {
    JNIEnv *env = nullptr;
    bool attached = java_vm->GetEnv(reinterpret_cast<void **>(&env), JNI_VERSION_1_6) != JNI_OK;
    if (attached && java_vm->AttachCurrentThread(&env, nullptr) != JNI_OK)
        return;
    env->DeleteGlobalRef(static_cast<jobject>(context));
    if (attached)
        java_vm->DetachCurrentThread();
}
struct ContentStream {
    int fd;
    std::atomic<bool> cancelled{false};
};
int open_content(void *, char *uri, mpv_stream_cb_info *info) {
    JNIEnv *env = nullptr;
    bool attached = java_vm->GetEnv(reinterpret_cast<void **>(&env), JNI_VERSION_1_6) != JNI_OK;
    if (attached && java_vm->AttachCurrentThread(&env, nullptr) != JNI_OK)
        return MPV_ERROR_LOADING_FAILED;
    env->PushLocalFrame(24);
    auto ctx = env->GetObjectClass(app_context);
    auto getResolver = env->GetMethodID(ctx, "getContentResolver", "()Landroid/content/ContentResolver;");
    auto resolver = env->CallObjectMethod(app_context, getResolver);
    auto uriClass = env->FindClass("android/net/Uri");
    auto parse = env->GetStaticMethodID(uriClass, "parse", "(Ljava/lang/String;)Landroid/net/Uri;");
    const std::string source = "content" + std::string(uri).substr(std::string("mpvui-content").size());
    auto parsed = env->CallStaticObjectMethod(uriClass, parse, string(env, source));
    auto resolverClass = env->GetObjectClass(resolver);
    auto open =
        env->GetMethodID(resolverClass, "openFileDescriptor", "(Landroid/net/Uri;Ljava/lang/String;)Landroid/os/ParcelFileDescriptor;");
    auto descriptor = env->CallObjectMethod(resolver, open, parsed, env->NewStringUTF("r"));
    int fd = -1;
    if (!env->ExceptionCheck() && descriptor) {
        auto cls = env->GetObjectClass(descriptor);
        auto detach = env->GetMethodID(cls, "detachFd", "()I");
        fd = env->CallIntMethod(descriptor, detach);
    }
    if (env->ExceptionCheck())
        env->ExceptionClear();
    env->PopLocalFrame(nullptr);
    if (attached)
        java_vm->DetachCurrentThread();
    if (fd < 0)
        return MPV_ERROR_LOADING_FAILED;
    fcntl(fd, F_SETFL, fcntl(fd, F_GETFL) | O_NONBLOCK);
    auto stream = new ContentStream{fd};
    info->cookie = stream;
    info->read_fn = [](void *cookie, char *buffer, uint64_t size) -> int64_t {
        auto s = static_cast<ContentStream *>(cookie);
        while (!s->cancelled) {
            pollfd p{s->fd, POLLIN, 0};
            int ready = poll(&p, 1, 50);
            if (ready < 0 && errno != EINTR)
                return -1;
            if (ready <= 0)
                continue;
            auto result = read(s->fd, buffer, size);
            if (result < 0 && (errno == EAGAIN || errno == EINTR))
                continue;
            return result;
        }
        return -1;
    };
    info->seek_fn = [](void *cookie, int64_t offset) -> int64_t {
        auto s = static_cast<ContentStream *>(cookie);
        return s->cancelled ? -1 : lseek(s->fd, offset, SEEK_SET);
    };
    if (lseek(fd, 0, SEEK_CUR) < 0)
        info->seek_fn = nullptr;
    info->size_fn = [](void *cookie) -> int64_t {
        struct stat st{};
        return fstat(static_cast<ContentStream *>(cookie)->fd, &st) == 0 && S_ISREG(st.st_mode) ? st.st_size : -1;
    };
    info->cancel_fn = [](void *cookie) { static_cast<ContentStream *>(cookie)->cancelled = true; };
    info->close_fn = [](void *cookie) {
        auto s = static_cast<ContentStream *>(cookie);
        close(s->fd);
        delete s;
    };
    return 0;
}
struct AssetStream {
    AAsset *asset;
    std::atomic<bool> cancelled{false};
};
int open_asset(void *, char *uri, mpv_stream_cb_info *info) {
    std::string path(uri);
    const auto slash = path.find("://");
    if (slash == std::string::npos || !asset_manager)
        return MPV_ERROR_LOADING_FAILED;
    path.erase(0, slash + 3);
    while (!path.empty() && path.front() == '/')
        path.erase(0, 1);
    // Decode URI escapes using Android's Uri implementation, preserving UTF-8.
    JNIEnv *env = nullptr;
    const bool attached = java_vm->GetEnv(reinterpret_cast<void **>(&env), JNI_VERSION_1_6) != JNI_OK;
    if (attached && java_vm->AttachCurrentThread(&env, nullptr) != JNI_OK)
        return MPV_ERROR_LOADING_FAILED;
    env->PushLocalFrame(8);
    auto uri_class = env->FindClass("android/net/Uri");
    auto decode = env->GetStaticMethodID(uri_class, "decode", "(Ljava/lang/String;)Ljava/lang/String;");
    auto decoded = static_cast<jstring>(env->CallStaticObjectMethod(uri_class, decode, string(env, path)));
    path = utf8(env, decoded);
    const bool failed = env->ExceptionCheck();
    if (failed)
        env->ExceptionClear();
    env->PopLocalFrame(nullptr);
    if (attached)
        java_vm->DetachCurrentThread();
    if (failed)
        return MPV_ERROR_LOADING_FAILED;
    auto asset = AAssetManager_open(asset_manager, path.c_str(), AASSET_MODE_RANDOM);
    if (!asset)
        return MPV_ERROR_LOADING_FAILED;
    auto stream = new AssetStream{asset};
    info->cookie = stream;
    info->read_fn = [](void *cookie, char *buffer, uint64_t size) -> int64_t {
        auto stream = static_cast<AssetStream *>(cookie);
        return stream->cancelled ? -1 : AAsset_read(stream->asset, buffer, std::min(size, uint64_t(INT32_MAX)));
    };
    info->seek_fn = [](void *cookie, int64_t offset) -> int64_t {
        auto stream = static_cast<AssetStream *>(cookie);
        return stream->cancelled ? -1 : AAsset_seek64(stream->asset, offset, SEEK_SET);
    };
    info->size_fn = [](void *cookie) -> int64_t { return AAsset_getLength64(static_cast<AssetStream *>(cookie)->asset); };
    info->cancel_fn = [](void *cookie) { static_cast<AssetStream *>(cookie)->cancelled = true; };
    info->close_fn = [](void *cookie) {
        auto stream = static_cast<AssetStream *>(cookie);
        AAsset_close(stream->asset);
        delete stream;
    };
    return 0;
}
int32_t prepare_handle(void *, void *handle) {
    auto mpv = static_cast<mpv_handle *>(handle);
    int result = mpv_stream_cb_add_ro(mpv, "mpvui-content", nullptr, open_content);
    return result < 0 ? result : mpv_stream_cb_add_ro(mpv, "mpvui-asset", nullptr, open_asset);
}
} // namespace

#define JNI_METHOD(type, name) extern "C" JNIEXPORT type JNICALL Java_mpvui_internal_NativeBridge_##name

JNI_METHOD(jlong, create)(JNIEnv *env, jobject, jobject context, jbyteArray settings, jint output, jint decoder, jboolean low_power,
                          jboolean compatibility) {
    std::call_once(vm_once, [&] {
        env->GetJavaVM(&java_vm);
        av_jni_set_java_vm(java_vm, nullptr);
        // FFmpeg borrows the application context for process lifetime.
        app_context = env->NewGlobalRef(context);
        av_jni_set_android_app_ctx(app_context, nullptr);
        auto context_class = env->GetObjectClass(context);
        auto get_assets = env->GetMethodID(context_class, "getAssets", "()Landroid/content/res/AssetManager;");
        auto assets = env->CallObjectMethod(context, get_assets);
        asset_manager = AAssetManager_fromJava(env, assets);
        env->DeleteLocalRef(assets);
        env->DeleteLocalRef(context_class);
        // Bootstrap classes/Charset live for the process. Resolve once, not for
        // every observed property, and preserve real UTF-8 (including emoji).
        auto string_class = env->FindClass("java/lang/String");
        java_string_class = static_cast<jclass>(env->NewGlobalRef(string_class));
        string_bytes = env->GetMethodID(java_string_class, "getBytes", "(Ljava/nio/charset/Charset;)[B");
        string_constructor = env->GetMethodID(java_string_class, "<init>", "([BLjava/nio/charset/Charset;)V");
        auto charsets = env->FindClass("java/nio/charset/StandardCharsets");
        auto field = env->GetStaticFieldID(charsets, "UTF_8", "Ljava/nio/charset/Charset;");
        auto charset = env->GetStaticObjectField(charsets, field);
        utf8_charset = env->NewGlobalRef(charset);
        env->DeleteLocalRef(charset);
        env->DeleteLocalRef(charsets);
        env->DeleteLocalRef(string_class);
        auto global_class = [&](const char *name) {
            jclass local = env->FindClass(name);
            auto global = static_cast<jclass>(env->NewGlobalRef(local));
            env->DeleteLocalRef(local);
            return global;
        };
        event_class = global_class("mpvui/internal/CoreEvent");
        event_constructor = env->GetMethodID(event_class, "<init>", "(IJJ[B)V");
    });
    if (env->ExceptionCheck())
        return 0;
    auto record = bytes(env, settings);
    MPVCoreConfiguration configuration{};
    configuration.version = MPVCORE_ABI_VERSION;
    configuration.size = sizeof(configuration);
    configuration.video_output = output;
    configuration.hardware_decoding = decoder;
    configuration.low_power = low_power;
    configuration.profile7_compatibility = compatibility;
    configuration.auto_play = 1;
    configuration.volume = 100;
    configuration.playback_rate = 1;
    configuration.initial_buffer_seconds = 1;
    configuration.network_cache_seconds = 10;
    configuration.settings = borrowed(record);
    configuration.prepare_handle = prepare_handle;
    auto p = std::make_unique<Player>();
    p->session = mpvcore_session_create(&configuration);
    if (!p->session) {
        error(env, "Invalid shared core configuration");
        return 0;
    }
    p->subscription = mpvcore_session_subscribe(p->session, p->queue.get(), deliver);
    // Initialization failures are carried by the shared snapshot error model.
    mpvcore_session_initialize(p->session);
    return reinterpret_cast<jlong>(p.release());
}
JNI_METHOD(jlongArray, send)(JNIEnv *env, jobject, jlong handle, jint kind, jint flags, jint track_type, jint role, jlong track_id,
                             jdouble value, jboolean has_value, jobjectArray args) {
    auto p = player(handle);
    std::vector<std::string> strings;
    for (int i = 0; i < env->GetArrayLength(args); ++i) {
        auto argument = static_cast<jstring>(env->GetObjectArrayElement(args, i));
        strings.push_back(utf8(env, argument));
        env->DeleteLocalRef(argument);
        if (env->ExceptionCheck())
            return nullptr;
    }
    std::vector<MPVCoreString> values;
    for (const auto &text : strings)
        values.push_back({reinterpret_cast<const uint8_t *>(text.data()), text.size()});
    MPVCoreCommand command{};
    command.version = MPVCORE_ABI_VERSION;
    command.size = sizeof(command);
    command.kind = kind;
    command.flags = flags;
    command.track_type = track_type;
    command.role = role;
    command.track_id = track_id;
    command.value = value;
    command.has_value = has_value;
    command.strings = values.data();
    command.string_count = values.size();
    MPVCoreOperation result{};
    int status = mpvcore_session_send(p->session, &command, &result);
    if (status < 0) {
        error(env, "Shared core rejected command");
        return nullptr;
    }
    jlong identity[] = {static_cast<jlong>(result.id), static_cast<jlong>(result.generation)};
    auto array = env->NewLongArray(2);
    env->SetLongArrayRegion(array, 0, 2, identity);
    return array;
}
JNI_METHOD(jboolean, waitForEvents)(JNIEnv *, jobject, jlong h) {
    auto queue = player(h)->queue;
    std::unique_lock<std::mutex> lock(queue->mutex);
    queue->condition.wait(lock, [&] { return !queue->records.empty() || queue->stopped; });
    return !queue->stopped;
}
JNI_METHOD(jobject, event)(JNIEnv *env, jobject, jlong h) {
    auto queue = player(h)->queue;
    Event event;
    {
        std::lock_guard<std::mutex> lock(queue->mutex);
        if (queue->records.empty())
            return nullptr;
        event = std::move(queue->records.front());
        queue->records.pop_front();
    }
    auto record = array(env, event.record);
    auto result = env->NewObject(event_class, event_constructor, event.kind == 6 ? 1 : event.kind, static_cast<jlong>(event.generation),
                                 static_cast<jlong>(event.query), record);
    env->DeleteLocalRef(record);
    return result;
}
JNI_METHOD(void, stopEvents)(JNIEnv *, jobject, jlong h) {
    auto queue = player(h)->queue;
    std::lock_guard<std::mutex> lock(queue->mutex);
    queue->stopped = true;
    queue->records.clear();
    queue->condition.notify_all();
}
JNI_METHOD(void, querySubtitles)(JNIEnv *env, jobject, jlong h, jint type, jlong track, jlong id) {
    auto p = player(h);
    auto context = new QueryContext{p->queue, static_cast<uint64_t>(id)};
    auto query = mpvcore_query_subtitles(p->session, type, track, context, deliver_query, release_query);
    if (!query) {
        delete context;
        error(env, "Invalid subtitle query");
        return;
    }
    p->queries.emplace(id, query);
}
JNI_METHOD(void, releaseQuery)(JNIEnv *, jobject, jlong h, jlong id) {
    auto p = player(h);
    auto query = p->queries.find(id);
    if (query != p->queries.end()) {
        mpvcore_query_release(query->second);
        p->queries.erase(query);
    }
}
JNI_METHOD(void, surface)(JNIEnv *env, jobject, jlong h, jobject surface, jbyteArray display) {
    auto p = player(h);
    auto record = bytes(env, display);
    auto retained = surface ? env->NewGlobalRef(surface) : nullptr;
    int64_t address = reinterpret_cast<intptr_t>(retained);
    int status = mpvcore_session_surface(p->session, address, retained, release_surface, borrowed(record));
    if (status < 0) {
        if (retained)
            env->DeleteGlobalRef(retained);
        error(env, "Shared core rejected surface");
        return;
    }
    p->surface_address = address;
}
JNI_METHOD(void, resize)(JNIEnv *, jobject, jlong h, jint width, jint height) {
    auto p = player(h);
    mpvcore_session_resize(p->session, p->surface_address, width, height);
}
JNI_METHOD(void, destroy)(JNIEnv *, jobject, jlong h) {
    auto p = player(h);
    mpvcore_subscription_release(p->subscription);
    for (const auto &query : p->queries)
        mpvcore_query_release(query.second);
    mpvcore_session_close(p->session);
    mpvcore_session_release(p->session);
    delete p;
}

JNI_METHOD(jlong, retainSessionAddress)(JNIEnv *, jobject, jlong h) {
    auto session = player(h)->session;
    mpvcore_session_retain(session);
    return reinterpret_cast<jlong>(session);
}

JNI_METHOD(jbyteArray, snapshot)(JNIEnv *env, jobject, jlong h) {
    auto record = mpvcore_session_snapshot(player(h)->session);
    auto result = env->NewByteArray(static_cast<jsize>(record.length));
    if (result)
        env->SetByteArrayRegion(result, 0, static_cast<jsize>(record.length), reinterpret_cast<const jbyte *>(record.data));
    mpvcore_buffer_release(record);
    return result;
}

JNI_METHOD(jbyteArray, requestFeatures)(JNIEnv *env, jobject, jlong h, jint mask) {
    auto record = mpvcore_session_request_features(player(h)->session, static_cast<uint32_t>(mask));
    if (!record.data) {
        error(env, "Invalid feature request");
        return nullptr;
    }
    auto output = env->NewByteArray(static_cast<jsize>(record.length));
    if (output)
        env->SetByteArrayRegion(output, 0, static_cast<jsize>(record.length), reinterpret_cast<const jbyte *>(record.data));
    mpvcore_buffer_release(record);
    return output;
}
