// JNI bridge between NativeEngine.kt and the C++ transfer engine.
#include <jni.h>

#include <array>
#include <cstring>
#include <string>
#include <vector>

#include "bench.h"
#include "engine.h"
#include "media.h"
#include "wdlog.h"

namespace {

JavaVM* gVm = nullptr;
jclass gEngineClass = nullptr;
jmethodID gOpenOutputs = nullptr;
jmethodID gResumeBitmap = nullptr;
jmethodID gFileDone = nullptr;
jmethodID gSessionDone = nullptr;
jmethodID gApprove = nullptr;

// Attaches the calling native thread for the duration of a callback.
class ScopedEnv {
public:
    ScopedEnv() {
        if (gVm->GetEnv(reinterpret_cast<void**>(&env_), JNI_VERSION_1_6) == JNI_EDETACHED) {
            gVm->AttachCurrentThread(&env_, nullptr);
            attached_ = true;
        }
    }
    ~ScopedEnv() {
        if (attached_) gVm->DetachCurrentThread();
    }
    JNIEnv* operator->() { return env_; }
    JNIEnv* get() { return env_; }

private:
    JNIEnv* env_ = nullptr;
    bool attached_ = false;
};

std::string toString(JNIEnv* env, jstring s) {
    if (!s) return {};
    const char* c = env->GetStringUTFChars(s, nullptr);
    std::string out(c);
    env->ReleaseStringUTFChars(s, c);
    return out;
}

jobjectArray toJavaStrings(JNIEnv* env, const std::vector<std::string>& v) {
    jclass str = env->FindClass("java/lang/String");
    jobjectArray arr = env->NewObjectArray(static_cast<jsize>(v.size()), str, nullptr);
    for (size_t i = 0; i < v.size(); ++i) {
        jstring s = env->NewStringUTF(v[i].c_str());
        env->SetObjectArrayElement(arr, static_cast<jsize>(i), s);
        env->DeleteLocalRef(s);
    }
    env->DeleteLocalRef(str);
    return arr;
}

jbyteArray toJavaBytes(JNIEnv* env, const uint8_t* p, size_t n) {
    jbyteArray a = env->NewByteArray(static_cast<jsize>(n));
    if (n) env->SetByteArrayRegion(a, 0, static_cast<jsize>(n), reinterpret_cast<const jbyte*>(p));
    return a;
}

bool clearException(JNIEnv* env) {
    if (!env->ExceptionCheck()) return false;
    env->ExceptionDescribe();
    env->ExceptionClear();
    return true;
}

wd::ReceiverSink makeSink() {
    wd::ReceiverSink sink;
    sink.openOutputs = [](uint64_t batch, const std::string& tid, uint32_t chunk, const std::vector<wd::FileEntry>& files,
                          std::vector<int>& fds, std::vector<uint8_t>& bitmap) {
        ScopedEnv env;
        std::vector<std::string> names, rels;
        std::vector<jlong> sizes;
        std::vector<jint> cats;
        for (auto& f : files) {
            names.push_back(f.name);
            rels.push_back(f.rel);
            sizes.push_back(static_cast<jlong>(f.size));
            cats.push_back(f.category);
        }
        jstring jt = env->NewStringUTF(tid.c_str());
        jobjectArray jn = toJavaStrings(env.get(), names);
        jobjectArray jr = toJavaStrings(env.get(), rels);
        jlongArray js = env->NewLongArray(static_cast<jsize>(sizes.size()));
        env->SetLongArrayRegion(js, 0, static_cast<jsize>(sizes.size()), sizes.data());
        jintArray jc = env->NewIntArray(static_cast<jsize>(cats.size()));
        env->SetIntArrayRegion(jc, 0, static_cast<jsize>(cats.size()), cats.data());

        auto res = static_cast<jintArray>(env->CallStaticObjectMethod(gEngineClass, gOpenOutputs, static_cast<jlong>(batch),
                                                                      jt, static_cast<jint>(chunk), jn, jr, js, jc));
        if (!clearException(env.get()) && res) {
            jsize n = env->GetArrayLength(res);
            fds.resize(static_cast<size_t>(n));
            env->GetIntArrayRegion(res, 0, n, fds.data());
            auto bm = static_cast<jbyteArray>(env->CallStaticObjectMethod(gEngineClass, gResumeBitmap, static_cast<jlong>(batch)));
            if (!clearException(env.get()) && bm) {
                jsize m = env->GetArrayLength(bm);
                bitmap.resize(static_cast<size_t>(m));
                env->GetByteArrayRegion(bm, 0, m, reinterpret_cast<jbyte*>(bitmap.data()));
                env->DeleteLocalRef(bm);
            }
        }
        env->DeleteLocalRef(jt);
        env->DeleteLocalRef(jn);
        env->DeleteLocalRef(jr);
        env->DeleteLocalRef(js);
        env->DeleteLocalRef(jc);
        if (res) env->DeleteLocalRef(res);
        return !fds.empty() || files.empty();
    };
    sink.fileDone = [](uint64_t batch, int index) {
        ScopedEnv env;
        env->CallStaticVoidMethod(gEngineClass, gFileDone, static_cast<jlong>(batch), static_cast<jint>(index));
        clearException(env.get());
    };
    sink.sessionDone = [](uint64_t batch, bool ok, const std::vector<uint8_t>& bitmap, const wd::Peer& peer,
                          const uint8_t* bond) {
        ScopedEnv env;
        jbyteArray jb = toJavaBytes(env.get(), bitmap.data(), bitmap.size());
        jstring jp = env->NewStringUTF(peer.deviceId.c_str());
        jstring jn = env->NewStringUTF(peer.nick.c_str());
        jbyteArray jk = bond ? toJavaBytes(env.get(), bond, 32) : nullptr;
        env->CallStaticVoidMethod(gEngineClass, gSessionDone, static_cast<jlong>(batch), static_cast<jboolean>(ok), jb, jp,
                                  static_cast<jint>(peer.buddy), jn, jk);
        clearException(env.get());
        env->DeleteLocalRef(jb);
        env->DeleteLocalRef(jp);
        env->DeleteLocalRef(jn);
        if (jk) env->DeleteLocalRef(jk);
    };
    sink.approve = [](const wd::Peer& peer, size_t files, uint64_t bytes) {
        ScopedEnv env;
        jstring jn = env->NewStringUTF(peer.nick.c_str());
        jstring jp = env->NewStringUTF(peer.deviceId.c_str());
        jint r = env->CallStaticIntMethod(gEngineClass, gApprove, static_cast<jint>(peer.buddy), jn, jp,
                                          static_cast<jint>(files), static_cast<jlong>(bytes));
        if (clearException(env.get())) r = 0;
        env->DeleteLocalRef(jn);
        env->DeleteLocalRef(jp);
        return static_cast<int>(r);
    };
    return sink;
}

}  // namespace

extern "C" JNIEXPORT jint JNI_OnLoad(JavaVM* vm, void*) {
    gVm = vm;
    media::init(vm);
    JNIEnv* env;
    if (vm->GetEnv(reinterpret_cast<void**>(&env), JNI_VERSION_1_6) != JNI_OK) return JNI_ERR;
    jclass c = env->FindClass("ir/neovortex/wingdrop/NativeEngine");
    if (!c) return JNI_ERR;
    gEngineClass = static_cast<jclass>(env->NewGlobalRef(c));
    gOpenOutputs = env->GetStaticMethodID(c, "openOutputs",
                                          "(JLjava/lang/String;I[Ljava/lang/String;[Ljava/lang/String;[J[I)[I");
    gResumeBitmap = env->GetStaticMethodID(c, "resumeBitmap", "(J)[B");
    gFileDone = env->GetStaticMethodID(c, "onFileDone", "(JI)V");
    gSessionDone = env->GetStaticMethodID(c, "onSessionDone", "(JZ[BLjava/lang/String;ILjava/lang/String;[B)V");
    gApprove = env->GetStaticMethodID(c, "approve", "(ILjava/lang/String;Ljava/lang/String;IJ)I");
    if (!gOpenOutputs || !gResumeBitmap || !gFileDone || !gSessionDone || !gApprove) return JNI_ERR;
    return JNI_VERSION_1_6;
}

#define JNI_FN(name) Java_ir_neovortex_wingdrop_NativeEngine_##name

extern "C" JNIEXPORT jint JNICALL JNI_FN(nativeListen)(JNIEnv* env, jclass, jint port, jbyteArray key,
                                                       jbyteArray radarKey) {
    uint8_t k[32]{}, rk[32]{};
    if (env->GetArrayLength(key) != 32) return -1;
    env->GetByteArrayRegion(key, 0, 32, reinterpret_cast<jbyte*>(k));
    const bool radar = radarKey && env->GetArrayLength(radarKey) == 32;
    if (radar) env->GetByteArrayRegion(radarKey, 0, 32, reinterpret_cast<jbyte*>(rk));
    return wd::Engine::get().listen(port, k, radar ? rk : nullptr, makeSink());
}

extern "C" JNIEXPORT void JNICALL JNI_FN(nativeStopListening)(JNIEnv*, jclass) {
    wd::Engine::get().stopListening();
}

// opts: [flags, streams, chunkSize, sockBuf, tos, depth, buddy]
extern "C" JNIEXPORT jlong JNICALL JNI_FN(nativeSend)(JNIEnv* env, jclass, jobjectArray hosts, jint port,
                                                       jlong netHandle, jbyteArray key, jobjectArray names,
                                                       jobjectArray rels, jintArray cats, jintArray fds, jintArray opts,
                                                       jstring nick, jstring peerId, jobjectArray thumbs) {
    std::vector<std::string> hostList;
    for (jsize i = 0; i < env->GetArrayLength(hosts); ++i) {
        auto s = static_cast<jstring>(env->GetObjectArrayElement(hosts, i));
        hostList.push_back(toString(env, s));
        env->DeleteLocalRef(s);
    }
    uint8_t k[32]{};
    if (env->GetArrayLength(key) != 32) return 0;
    env->GetByteArrayRegion(key, 0, 32, reinterpret_cast<jbyte*>(k));

    jsize n = env->GetArrayLength(fds);
    std::vector<jint> fdv(static_cast<size_t>(n)), catv(static_cast<size_t>(n));
    env->GetIntArrayRegion(fds, 0, n, fdv.data());
    env->GetIntArrayRegion(cats, 0, n, catv.data());
    std::vector<wd::FileEntry> files(static_cast<size_t>(n));
    for (jsize i = 0; i < n; ++i) {
        auto jn = static_cast<jstring>(env->GetObjectArrayElement(names, i));
        auto jr = static_cast<jstring>(env->GetObjectArrayElement(rels, i));
        files[i].name = toString(env, jn);
        files[i].rel = toString(env, jr);
        files[i].category = static_cast<uint8_t>(catv[i]);
        files[i].fd = fdv[i];
        env->DeleteLocalRef(jn);
        env->DeleteLocalRef(jr);
    }

    jint o[7]{};
    env->GetIntArrayRegion(opts, 0, std::min<jsize>(7, env->GetArrayLength(opts)), o);
    wd::Options options;
    options.flags = static_cast<uint32_t>(o[0]);
    options.streams = static_cast<uint32_t>(o[1]);
    options.chunkSize = static_cast<uint32_t>(o[2]);
    options.sockBuf = static_cast<uint32_t>(o[3]);
    options.tos = static_cast<uint32_t>(o[4]);
    options.depth = static_cast<uint32_t>(o[5] > 0 ? o[5] : 4);
    options.buddy = static_cast<uint32_t>(o[6]);
    options.nick = toString(env, nick);
    options.peerDeviceId = toString(env, peerId);
    std::vector<std::vector<uint8_t>> previews;
    if (thumbs) {
        jsize m = env->GetArrayLength(thumbs);
        previews.resize(static_cast<size_t>(m));
        for (jsize i = 0; i < m; ++i) {
            auto b = static_cast<jbyteArray>(env->GetObjectArrayElement(thumbs, i));
            if (!b) continue;
            jsize len = env->GetArrayLength(b);
            previews[static_cast<size_t>(i)].resize(static_cast<size_t>(len));
            env->GetByteArrayRegion(b, 0, len, reinterpret_cast<jbyte*>(previews[static_cast<size_t>(i)].data()));
            env->DeleteLocalRef(b);
        }
    }
    return static_cast<jlong>(
        wd::Engine::get().send(hostList, port, netHandle, k, std::move(files), options, std::move(previews)));
}

extern "C" JNIEXPORT void JNICALL JNI_FN(nativeCancel)(JNIEnv*, jclass, jlong id) {
    wd::Engine::get().cancel(static_cast<uint64_t>(id));
}

extern "C" JNIEXPORT jstring JNICALL JNI_FN(nativeStatus)(JNIEnv* env, jclass) {
    return env->NewStringUTF(wd::Engine::get().status().c_str());
}

extern "C" JNIEXPORT void JNICALL JNI_FN(nativeSetIdentity)(JNIEnv* env, jclass, jstring id) {
    wd::Engine::get().setIdentity(toString(env, id));
}

extern "C" JNIEXPORT void JNICALL JNI_FN(nativeSetBonds)(JNIEnv* env, jclass, jobjectArray keys) {
    std::vector<std::array<uint8_t, 32>> bonds;
    for (jsize i = 0; i < env->GetArrayLength(keys); ++i) {
        auto k = static_cast<jbyteArray>(env->GetObjectArrayElement(keys, i));
        if (k && env->GetArrayLength(k) == 32) {
            std::array<uint8_t, 32> b{};
            env->GetByteArrayRegion(k, 0, 32, reinterpret_cast<jbyte*>(b.data()));
            bonds.push_back(b);
        }
        if (k) env->DeleteLocalRef(k);
    }
    wd::Engine::get().setBonds(bonds);
}

extern "C" JNIEXPORT jstring JNICALL JNI_FN(nativeLastError)(JNIEnv* env, jclass) {
    return env->NewStringUTF(wd::Engine::get().lastError().c_str());
}

extern "C" JNIEXPORT jdoubleArray JNICALL JNI_FN(nativeBenchmark)(JNIEnv* env, jclass) {
    auto r = bench::run();
    jdoubleArray out = env->NewDoubleArray(static_cast<jsize>(r.size()));
    env->SetDoubleArrayRegion(out, 0, static_cast<jsize>(r.size()), r.data());
    return out;
}

// kind: 0 video, 1 audio; preset: 0 light, 1 small. Returns 0 ok, 1 keep original, <0 error.
extern "C" JNIEXPORT jint JNICALL JNI_FN(nativeTranscode)(JNIEnv*, jclass, jint job, jint inFd, jint outFd, jint kind,
                                                          jint preset) {
    return media::transcode(job, inFd, outFd, static_cast<media::Kind>(kind), static_cast<media::Preset>(preset));
}

extern "C" JNIEXPORT jdouble JNICALL JNI_FN(nativeTranscodeProgress)(JNIEnv*, jclass, jint job) {
    return media::progress(job);
}

extern "C" JNIEXPORT void JNICALL JNI_FN(nativeTranscodeCancel)(JNIEnv*, jclass, jint job) { media::cancel(job); }

extern "C" JNIEXPORT jstring JNICALL JNI_FN(nativeFiles)(JNIEnv* env, jclass, jint limit) {
    return env->NewStringUTF(wd::Engine::get().files(static_cast<size_t>(limit)).c_str());
}

extern "C" JNIEXPORT jbyteArray JNICALL JNI_FN(nativePreview)(JNIEnv* env, jclass, jlong session, jint file) {
    auto v = wd::Engine::get().preview(static_cast<uint64_t>(session), static_cast<uint32_t>(file));
    if (v.empty()) return nullptr;
    return toJavaBytes(env, v.data(), v.size());
}

// RGBA frame with an 8-byte header (width, height as little-endian int32), or null.
extern "C" JNIEXPORT jbyteArray JNICALL JNI_FN(nativeFrame)(JNIEnv* env, jclass, jint fd, jint maxSide) {
    int w = 0, h = 0;
    auto rgba = media::frame(fd, maxSide, &w, &h);
    if (rgba.empty()) return nullptr;
    std::vector<uint8_t> out(8 + rgba.size());
    memcpy(out.data(), &w, 4);
    memcpy(out.data() + 4, &h, 4);
    memcpy(out.data() + 8, rgba.data(), rgba.size());
    return toJavaBytes(env, out.data(), out.size());
}

extern "C" JNIEXPORT jint JNICALL JNI_FN(nativeChat)(JNIEnv* env, jclass, jlong session, jstring text) {
    return wd::Engine::get().chat(static_cast<uint64_t>(session), toString(env, text));
}

extern "C" JNIEXPORT jstring JNICALL JNI_FN(nativeChatLog)(JNIEnv* env, jclass, jlong since) {
    return env->NewStringUTF(wd::Engine::get().chatLog(static_cast<uint64_t>(since)).c_str());
}

extern "C" JNIEXPORT jstring JNICALL JNI_FN(nativeLog)(JNIEnv* env, jclass) {
    return env->NewStringUTF(wdlog::dump().c_str());
}

extern "C" JNIEXPORT void JNICALL JNI_FN(nativeLogClear)(JNIEnv*, jclass) { wdlog::clear(); }
