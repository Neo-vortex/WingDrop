#include "media.h"
#include "wdlog.h"

#include <android/log.h>
#include <jni.h>
#include <sys/stat.h>
#include <unistd.h>

#include <algorithm>
#include <atomic>
#include <cmath>
#include <cstring>
#include <map>
#include <mutex>

extern "C" {
#include <libavcodec/avcodec.h>
#include <libavcodec/jni.h>
#include <libavformat/avformat.h>
#include <libavutil/audio_fifo.h>
#include <libavutil/channel_layout.h>
#include <libavutil/display.h>
#include <libavutil/opt.h>
#include <libswresample/swresample.h>
#include <libswscale/swscale.h>
}

#define LOG_TAG "wingdrop-media"
#define LOGI(...) wdlog::log('I', LOG_TAG, __VA_ARGS__)
#define LOGW(...) wdlog::log('W', LOG_TAG, __VA_ARGS__)

namespace media {

namespace {

// ---------------------------------------------------------------- job table

struct Job {
    std::atomic<double> progress{0};
    std::atomic<bool> cancel{false};
};

std::mutex gJobsMu;
std::map<int, Job> gJobs;

Job& job(int id) {
    std::lock_guard<std::mutex> l(gJobsMu);
    return gJobs[id];
}

// ---------------------------------------------------------------- fd AVIO

struct FdIo {
    int fd;
    int64_t pos = 0;
    int64_t size = -1;
};

int fdRead(void* opaque, uint8_t* buf, int n) {
    auto* io = static_cast<FdIo*>(opaque);
    ssize_t r = pread64(io->fd, buf, static_cast<size_t>(n), io->pos);
    if (r < 0) return AVERROR(errno);
    if (r == 0) return AVERROR_EOF;
    io->pos += r;
    return static_cast<int>(r);
}

int fdWrite(void* opaque, const uint8_t* buf, int n) {
    auto* io = static_cast<FdIo*>(opaque);
    int left = n;
    while (left > 0) {
        ssize_t r = pwrite64(io->fd, buf, static_cast<size_t>(left), io->pos);
        if (r < 0) {
            if (errno == EINTR) continue;
            return AVERROR(errno);
        }
        buf += r;
        left -= static_cast<int>(r);
        io->pos += r;
    }
    return n;
}

int64_t fdSeek(void* opaque, int64_t off, int whence) {
    auto* io = static_cast<FdIo*>(opaque);
    if (whence & AVSEEK_SIZE) {
        if (io->size < 0) {
            struct stat st{};
            io->size = fstat(io->fd, &st) == 0 ? st.st_size : -1;
        }
        return io->size;
    }
    switch (whence & ~AVSEEK_FORCE) {
        case SEEK_SET: io->pos = off; break;
        case SEEK_CUR: io->pos += off; break;
        case SEEK_END: {
            struct stat st{};
            if (fstat(io->fd, &st) != 0) return -1;
            io->pos = st.st_size + off;
            break;
        }
        default: return -1;
    }
    return io->pos;
}

AVIOContext* makeIo(FdIo* io, bool write) {
    constexpr int kBuf = 1 << 20;
    auto* buf = static_cast<uint8_t*>(av_malloc(kBuf));
    return avio_alloc_context(buf, kBuf, write ? 1 : 0, io, write ? nullptr : fdRead, write ? fdWrite : nullptr,
                              fdSeek);
}

void freeIo(AVIOContext** ctx) {
    if (!*ctx) return;
    av_freep(&(*ctx)->buffer);
    avio_context_free(ctx);
}

// ---------------------------------------------------------------- presets

struct VideoTarget {
    int maxLongSide;
    double bitsPerPixel;  // for HEVC; H.264 gets 1.35x
    double maxOfSource;   // never exceed this share of the source bitrate
    int audioKbps;
};

VideoTarget videoTarget(Preset p) {
    return p == kLight ? VideoTarget{1920, 0.075, 0.70, 160} : VideoTarget{1280, 0.045, 0.45, 96};
}

int musicKbps(Preset p) { return p == kLight ? 192 : 96; }

}  // namespace

VideoPlan videoPlan(Preset p) {
    const VideoTarget t = videoTarget(p);
    return VideoPlan{t.maxLongSide, t.bitsPerPixel, t.maxOfSource};
}

namespace {

// ---------------------------------------------------------------- audio encode chain

struct AudioChain {
    AVCodecContext* dec = nullptr;
    AVCodecContext* enc = nullptr;
    SwrContext* swr = nullptr;
    AVAudioFifo* fifo = nullptr;
    AVStream* out = nullptr;
    int inIndex = -1;
    int64_t nextPts = 0;
    AVFrame* frame = nullptr;

    ~AudioChain() {
        avcodec_free_context(&dec);
        avcodec_free_context(&enc);
        swr_free(&swr);
        if (fifo) av_audio_fifo_free(fifo);
        av_frame_free(&frame);
    }

    bool open(AVFormatContext* ic, int index, AVFormatContext* oc, int kbps) {
        inIndex = index;
        AVStream* st = ic->streams[index];
        const AVCodec* d = avcodec_find_decoder(st->codecpar->codec_id);
        const AVCodec* e = avcodec_find_encoder(AV_CODEC_ID_AAC);
        if (!d || !e) return false;
        dec = avcodec_alloc_context3(d);
        avcodec_parameters_to_context(dec, st->codecpar);
        dec->pkt_timebase = st->time_base;
        if (avcodec_open2(dec, d, nullptr) < 0) return false;

        enc = avcodec_alloc_context3(e);
        int channels = std::min(2, std::max(1, dec->ch_layout.nb_channels));
        av_channel_layout_default(&enc->ch_layout, channels);
        int rate = dec->sample_rate;
        if (rate <= 0 || rate > 48000) rate = 48000;
        enc->sample_rate = rate;
        enc->sample_fmt = AV_SAMPLE_FMT_FLTP;
        enc->bit_rate = static_cast<int64_t>(kbps) * 1000 * channels / 2;
        enc->time_base = AVRational{1, rate};
        if (oc->oformat->flags & AVFMT_GLOBALHEADER) enc->flags |= AV_CODEC_FLAG_GLOBAL_HEADER;
        if (avcodec_open2(enc, e, nullptr) < 0) return false;

        out = avformat_new_stream(oc, nullptr);
        avcodec_parameters_from_context(out->codecpar, enc);
        out->time_base = enc->time_base;
        av_dict_copy(&out->metadata, st->metadata, 0);

        if (swr_alloc_set_opts2(&swr, &enc->ch_layout, enc->sample_fmt, enc->sample_rate, &dec->ch_layout,
                                dec->sample_fmt, dec->sample_rate, 0, nullptr) < 0 ||
            swr_init(swr) < 0)
            return false;
        fifo = av_audio_fifo_alloc(enc->sample_fmt, channels, enc->frame_size * 4);
        frame = av_frame_alloc();
        return fifo && frame;
    }

    int drainEncoder(AVFormatContext* oc, AVPacket* pkt) {
        int r;
        while ((r = avcodec_receive_packet(enc, pkt)) == 0) {
            av_packet_rescale_ts(pkt, enc->time_base, out->time_base);
            pkt->stream_index = out->index;
            if ((r = av_interleaved_write_frame(oc, pkt)) < 0) return r;
        }
        return r == AVERROR(EAGAIN) || r == AVERROR_EOF ? 0 : r;
    }

    // Moves whole encoder frames out of the FIFO (all remaining when flushing).
    int pump(AVFormatContext* oc, AVPacket* pkt, bool flush) {
        const int fs = enc->frame_size > 0 ? enc->frame_size : 1024;
        while (av_audio_fifo_size(fifo) >= fs || (flush && av_audio_fifo_size(fifo) > 0)) {
            int n = std::min(fs, av_audio_fifo_size(fifo));
            AVFrame* f = av_frame_alloc();
            f->nb_samples = n;
            av_channel_layout_copy(&f->ch_layout, &enc->ch_layout);
            f->format = enc->sample_fmt;
            f->sample_rate = enc->sample_rate;
            if (av_frame_get_buffer(f, 0) < 0) {
                av_frame_free(&f);
                return -1;
            }
            av_audio_fifo_read(fifo, reinterpret_cast<void**>(f->data), n);
            f->pts = nextPts;
            nextPts += n;
            int r = avcodec_send_frame(enc, f);
            av_frame_free(&f);
            if (r < 0) return r;
            if ((r = drainEncoder(oc, pkt)) < 0) return r;
        }
        return 0;
    }

    int decoded(AVFormatContext* oc, AVPacket* pkt) {
        int r;
        while ((r = avcodec_receive_frame(dec, frame)) == 0) {
            int outMax = swr_get_out_samples(swr, frame->nb_samples);
            uint8_t** buf = nullptr;
            av_samples_alloc_array_and_samples(&buf, nullptr, enc->ch_layout.nb_channels, outMax, enc->sample_fmt, 0);
            int got = swr_convert(swr, buf, outMax, const_cast<const uint8_t**>(frame->extended_data), frame->nb_samples);
            if (got > 0) av_audio_fifo_write(fifo, reinterpret_cast<void**>(buf), got);
            av_freep(&buf[0]);
            av_freep(&buf);
            av_frame_unref(frame);
            if ((r = pump(oc, pkt, false)) < 0) return r;
        }
        return r == AVERROR(EAGAIN) || r == AVERROR_EOF ? 0 : r;
    }

    int feed(AVPacket* in, AVFormatContext* oc, AVPacket* pkt) {
        int r = avcodec_send_packet(dec, in);
        if (r < 0 && r != AVERROR(EAGAIN) && r != AVERROR_INVALIDDATA) return r;
        return decoded(oc, pkt);
    }

    int finish(AVFormatContext* oc, AVPacket* pkt) {
        avcodec_send_packet(dec, nullptr);
        int r = decoded(oc, pkt);
        if (r < 0) return r;
        // Flush the resampler's delay line.
        int outMax = swr_get_out_samples(swr, 0);
        if (outMax > 0) {
            uint8_t** buf = nullptr;
            av_samples_alloc_array_and_samples(&buf, nullptr, enc->ch_layout.nb_channels, outMax, enc->sample_fmt, 0);
            int got = swr_convert(swr, buf, outMax, nullptr, 0);
            if (got > 0) av_audio_fifo_write(fifo, reinterpret_cast<void**>(buf), got);
            av_freep(&buf[0]);
            av_freep(&buf);
        }
        if ((r = pump(oc, pkt, true)) < 0) return r;
        avcodec_send_frame(enc, nullptr);
        return drainEncoder(oc, pkt);
    }
};

// ---------------------------------------------------------------- video encode chain

struct VideoChain {
    AVCodecContext* dec = nullptr;
    AVCodecContext* enc = nullptr;
    SwsContext* sws = nullptr;
    AVFrame* frame = nullptr;
    AVFrame* scaled = nullptr;
    AVStream* out = nullptr;
    int inIndex = -1;
    AVRational inTb{};

    ~VideoChain() {
        avcodec_free_context(&dec);
        avcodec_free_context(&enc);
        sws_freeContext(sws);
        av_frame_free(&frame);
        av_frame_free(&scaled);
    }

    // Hardware decoder first (MediaCodec), software as fallback.
    bool openDecoder(AVStream* st) {
        const char* hw = nullptr;
        switch (st->codecpar->codec_id) {
            case AV_CODEC_ID_H264: hw = "h264_mediacodec"; break;
            case AV_CODEC_ID_HEVC: hw = "hevc_mediacodec"; break;
            case AV_CODEC_ID_VP9: hw = "vp9_mediacodec"; break;
            case AV_CODEC_ID_VP8: hw = "vp8_mediacodec"; break;
            case AV_CODEC_ID_AV1: hw = "av1_mediacodec"; break;
            case AV_CODEC_ID_MPEG4: hw = "mpeg4_mediacodec"; break;
            default: break;
        }
        const AVCodec* candidates[2] = {hw ? avcodec_find_decoder_by_name(hw) : nullptr,
                                        avcodec_find_decoder(st->codecpar->codec_id)};
        for (const AVCodec* c : candidates) {
            if (!c) continue;
            dec = avcodec_alloc_context3(c);
            avcodec_parameters_to_context(dec, st->codecpar);
            dec->pkt_timebase = st->time_base;
            dec->thread_count = 0;  // software: all cores
            if (avcodec_open2(dec, c, nullptr) == 0) {
                LOGI("video decoder: %s", c->name);
                return true;
            }
            avcodec_free_context(&dec);
        }
        return false;
    }

    bool open(AVFormatContext* ic, int index, AVFormatContext* oc, const VideoTarget& t) {
        inIndex = index;
        AVStream* st = ic->streams[index];
        inTb = st->time_base;
        if (!openDecoder(st)) return false;

        int w = st->codecpar->width, h = st->codecpar->height;
        if (w <= 0 || h <= 0) return false;
        double scale = std::min(1.0, static_cast<double>(t.maxLongSide) / std::max(w, h));
        // Multiples of 64: FFmpeg only pads the MediaCodec input to 16, but many
        // HEVC encoders (Qualcomm, Exynos) code 32-64 pixel blocks and fill the
        // gap with zeros, which shows up as a green stripe on the right or
        // bottom edge. The few extra pixels are trimmed (not stretched) below.
        int ow = std::max(64, static_cast<int>(std::lround(w * scale / 64.0)) * 64);
        int oh = std::max(64, static_cast<int>(std::lround(h * scale / 64.0)) * 64);

        AVRational fr = av_guess_frame_rate(ic, st, nullptr);
        double fps = fr.num > 0 && fr.den > 0 ? av_q2d(fr) : 30.0;
        fps = std::clamp(fps, 1.0, 60.0);

        bool hevc = true;
        const AVCodec* e = avcodec_find_encoder_by_name("hevc_mediacodec");
        if (!e) {
            e = avcodec_find_encoder_by_name("h264_mediacodec");
            hevc = false;
        }
        if (!e) return false;

        double bpp = t.bitsPerPixel * (hevc ? 1.0 : 1.35);
        double target = ow * static_cast<double>(oh) * fps * bpp;
        int64_t src = st->codecpar->bit_rate > 0 ? st->codecpar->bit_rate : ic->bit_rate;
        if (src > 0) target = std::min(target, src * t.maxOfSource);
        target = std::max(target, 400e3);

        for (int attempt = 0; attempt < 2; ++attempt) {
            enc = avcodec_alloc_context3(e);
            enc->width = ow;
            enc->height = oh;
            enc->pix_fmt = AV_PIX_FMT_NV12;
            enc->time_base = st->time_base;
            enc->framerate = AVRational{static_cast<int>(std::lround(fps * 1000)), 1000};
            enc->bit_rate = static_cast<int64_t>(target);
            enc->gop_size = static_cast<int>(fps * 2);
            enc->color_range = dec->color_range;
            enc->color_primaries = dec->color_primaries;
            enc->color_trc = dec->color_trc;
            enc->colorspace = dec->colorspace;
            if (oc->oformat->flags & AVFMT_GLOBALHEADER) enc->flags |= AV_CODEC_FLAG_GLOBAL_HEADER;
            if (avcodec_open2(enc, e, nullptr) == 0) break;
            avcodec_free_context(&enc);
            // Some chips refuse HEVC at this size; H.264 is universal.
            e = avcodec_find_encoder_by_name("h264_mediacodec");
            if (!e) return false;
            hevc = false;
            target *= 1.35;
        }
        if (!enc) return false;
        LOGI("video %dx%d -> %dx%d %s %.0f kbps", w, h, ow, oh, hevc ? "hevc" : "h264", target / 1000);

        out = avformat_new_stream(oc, nullptr);
        avcodec_parameters_from_context(out->codecpar, enc);
        out->time_base = enc->time_base;
        out->avg_frame_rate = enc->framerate;
        if (hevc) out->codecpar->codec_tag = MKTAG('h', 'v', 'c', '1');  // plays on Apple too
        // Keep rotation: players apply the display matrix.
        if (const AVPacketSideData* sd = av_packet_side_data_get(st->codecpar->coded_side_data,
                                                                  st->codecpar->nb_coded_side_data,
                                                                  AV_PKT_DATA_DISPLAYMATRIX)) {
            AVPacketSideData* dst = av_packet_side_data_new(&out->codecpar->coded_side_data,
                                                            &out->codecpar->nb_coded_side_data,
                                                            AV_PKT_DATA_DISPLAYMATRIX, sd->size, 0);
            if (dst) memcpy(dst->data, sd->data, sd->size);
        }
        av_dict_copy(&out->metadata, st->metadata, 0);

        frame = av_frame_alloc();
        scaled = av_frame_alloc();
        scaled->format = enc->pix_fmt;
        scaled->width = ow;
        scaled->height = oh;
        return frame && scaled && av_frame_get_buffer(scaled, 64) == 0;
    }

    int drainEncoder(AVFormatContext* oc, AVPacket* pkt) {
        int r;
        while ((r = avcodec_receive_packet(enc, pkt)) == 0) {
            av_packet_rescale_ts(pkt, enc->time_base, out->time_base);
            pkt->stream_index = out->index;
            if ((r = av_interleaved_write_frame(oc, pkt)) < 0) return r;
        }
        return r == AVERROR(EAGAIN) || r == AVERROR_EOF ? 0 : r;
    }

    int decoded(AVFormatContext* oc, AVPacket* pkt) {
        int r;
        while ((r = avcodec_receive_frame(dec, frame)) == 0) {
            // Match the 64-aligned output aspect by trimming a sliver off the
            // long side (never stretching). Cropping just moves data pointers.
            const double srcAspect = static_cast<double>(frame->width) / frame->height;
            const double dstAspect = static_cast<double>(enc->width) / enc->height;
            if (srcAspect > dstAspect * 1.001) {
                size_t keep = static_cast<size_t>(frame->height * dstAspect) & ~static_cast<size_t>(1);
                size_t cut = (static_cast<size_t>(frame->width) - keep) / 2 & ~static_cast<size_t>(1);
                frame->crop_left = cut;
                frame->crop_right = static_cast<size_t>(frame->width) - keep - cut;
            } else if (srcAspect < dstAspect / 1.001) {
                size_t keep = static_cast<size_t>(frame->width / dstAspect) & ~static_cast<size_t>(1);
                size_t cut = (static_cast<size_t>(frame->height) - keep) / 2 & ~static_cast<size_t>(1);
                frame->crop_top = cut;
                frame->crop_bottom = static_cast<size_t>(frame->height) - keep - cut;
            }
            av_frame_apply_cropping(frame, AV_FRAME_CROP_UNALIGNED);
            // The decoder can change format mid-stream (e.g. once MediaCodec starts).
            sws = sws_getCachedContext(sws, frame->width, frame->height, static_cast<AVPixelFormat>(frame->format),
                                       enc->width, enc->height, enc->pix_fmt, SWS_BILINEAR, nullptr, nullptr, nullptr);
            if (!sws || av_frame_make_writable(scaled) < 0) return -1;
            sws_scale(sws, frame->data, frame->linesize, 0, frame->height, scaled->data, scaled->linesize);
            scaled->pts = frame->best_effort_timestamp;
            av_frame_unref(frame);
            if ((r = avcodec_send_frame(enc, scaled)) < 0 && r != AVERROR(EAGAIN)) return r;
            if ((r = drainEncoder(oc, pkt)) < 0) return r;
        }
        return r == AVERROR(EAGAIN) || r == AVERROR_EOF ? 0 : r;
    }

    int feed(AVPacket* in, AVFormatContext* oc, AVPacket* pkt) {
        int r = avcodec_send_packet(dec, in);
        if (r < 0 && r != AVERROR(EAGAIN) && r != AVERROR_INVALIDDATA) return r;
        return decoded(oc, pkt);
    }

    int finish(AVFormatContext* oc, AVPacket* pkt) {
        avcodec_send_packet(dec, nullptr);
        int r = decoded(oc, pkt);
        if (r < 0) return r;
        avcodec_send_frame(enc, nullptr);
        return drainEncoder(oc, pkt);
    }
};

bool audioIsCopyable(const AVCodecParameters* p, int maxKbps) {
    return p->codec_id == AV_CODEC_ID_AAC && p->bit_rate > 0 && p->bit_rate <= maxKbps * 1000LL * 6 / 5;
}

}  // namespace

// ---------------------------------------------------------------- public API

std::vector<uint8_t> frame(int inFd, int maxSide, int* outW, int* outH) {
    FdIo io{inFd};
    AVFormatContext* ic = avformat_alloc_context();
    AVIOContext* pb = makeIo(&io, false);
    ic->pb = pb;
    ic->flags |= AVFMT_FLAG_CUSTOM_IO;
    AVCodecContext* dec = nullptr;
    AVPacket* pkt = av_packet_alloc();
    AVFrame* fr = av_frame_alloc();
    SwsContext* sws = nullptr;
    std::vector<uint8_t> rgba;
    auto done = [&] {
        sws_freeContext(sws);
        av_frame_free(&fr);
        av_packet_free(&pkt);
        avcodec_free_context(&dec);
        avformat_close_input(&ic);
        freeIo(&pb);
    };
    if (avformat_open_input(&ic, nullptr, nullptr, nullptr) < 0 || avformat_find_stream_info(ic, nullptr) < 0) {
        done();
        return rgba;
    }
    const AVCodec* codec = nullptr;
    int vi = av_find_best_stream(ic, AVMEDIA_TYPE_VIDEO, -1, -1, &codec, 0);
    if (vi < 0 || !codec) {
        done();
        return rgba;
    }
    AVStream* st = ic->streams[vi];
    dec = avcodec_alloc_context3(codec);
    avcodec_parameters_to_context(dec, st->codecpar);
    dec->thread_count = 2;
    if (avcodec_open2(dec, codec, nullptr) < 0) {
        done();
        return rgba;
    }
    // Album art / still images: the attached picture is the thumbnail.
    // Videos: a frame ~10% in is far more telling than the (often black) first one.
    if (!(st->disposition & AV_DISPOSITION_ATTACHED_PIC) && ic->duration > 0) {
        av_seek_frame(ic, -1, ic->duration / 10, AVSEEK_FLAG_BACKWARD);
    }
    bool got = false;
    for (int guard = 0; !got && guard < 400 && av_read_frame(ic, pkt) >= 0; ++guard) {
        if (pkt->stream_index == vi && avcodec_send_packet(dec, pkt) >= 0 && avcodec_receive_frame(dec, fr) == 0) got = true;
        av_packet_unref(pkt);
    }
    if (!got) {
        avcodec_send_packet(dec, nullptr);
        got = avcodec_receive_frame(dec, fr) == 0;
    }
    if (got && fr->width > 0 && fr->height > 0) {
        double scale = std::min(1.0, static_cast<double>(maxSide) / std::max(fr->width, fr->height));
        int w = std::max(1, static_cast<int>(fr->width * scale)), h = std::max(1, static_cast<int>(fr->height * scale));
        sws = sws_getContext(fr->width, fr->height, static_cast<AVPixelFormat>(fr->format), w, h, AV_PIX_FMT_RGBA,
                             SWS_BILINEAR, nullptr, nullptr, nullptr);
        if (sws) {
            rgba.resize(static_cast<size_t>(w) * h * 4);
            uint8_t* dst[4] = {rgba.data(), nullptr, nullptr, nullptr};
            int ls[4] = {w * 4, 0, 0, 0};
            sws_scale(sws, fr->data, fr->linesize, 0, fr->height, dst, ls);
            *outW = w;
            *outH = h;
        }
    }
    done();
    return rgba;
}

void init(_JavaVM* vm) {
    av_jni_set_java_vm(reinterpret_cast<JavaVM*>(vm), nullptr);
    av_log_set_level(AV_LOG_ERROR);
}

double progress(int id) { return job(id).progress.load(); }

void cancel(int id) { job(id).cancel = true; }

int transcode(int id, int inFd, int outFd, Kind kind, Preset preset) {
    Job& jb = job(id);
    jb.progress = 0;
    jb.cancel = false;

    FdIo inIo{inFd}, outIo{outFd};
    AVFormatContext* ic = avformat_alloc_context();
    AVIOContext* inPb = makeIo(&inIo, false);
    ic->pb = inPb;
    ic->flags |= AVFMT_FLAG_CUSTOM_IO;
    AVFormatContext* oc = nullptr;
    AVIOContext* outPb = nullptr;
    AVPacket* pkt = av_packet_alloc();
    AVPacket* opkt = av_packet_alloc();
    int result = -1;

    auto cleanup = [&] {
        if (oc) avformat_free_context(oc);
        freeIo(&outPb);
        avformat_close_input(&ic);
        freeIo(&inPb);
        av_packet_free(&pkt);
        av_packet_free(&opkt);
        std::lock_guard<std::mutex> l(gJobsMu);
        gJobs.erase(id);
    };

    if (avformat_open_input(&ic, nullptr, nullptr, nullptr) < 0 || avformat_find_stream_info(ic, nullptr) < 0) {
        cleanup();
        return -2;
    }
    const int64_t duration = ic->duration > 0 ? ic->duration : 0;  // AV_TIME_BASE units

    int vIdx = kind == kVideo ? av_find_best_stream(ic, AVMEDIA_TYPE_VIDEO, -1, -1, nullptr, 0) : -1;
    int aIdx = av_find_best_stream(ic, AVMEDIA_TYPE_AUDIO, -1, vIdx, nullptr, 0);
    if ((kind == kVideo && vIdx < 0) || (kind == kAudio && aIdx < 0)) {
        cleanup();
        return -3;
    }

    // Already small enough? Then shrinking only costs quality.
    if (kind == kAudio) {
        const AVCodecParameters* p = ic->streams[aIdx]->codecpar;
        int64_t br = p->bit_rate > 0 ? p->bit_rate : ic->bit_rate;
        bool lossless = p->codec_id == AV_CODEC_ID_FLAC || p->codec_id == AV_CODEC_ID_ALAC ||
                        (p->codec_id >= AV_CODEC_ID_PCM_S16LE && p->codec_id < AV_CODEC_ID_ADPCM_IMA_QT);
        if (!lossless && br > 0 && br <= musicKbps(preset) * 1000LL * 6 / 5) {
            cleanup();
            return 1;
        }
    }

    avformat_alloc_output_context2(&oc, nullptr, kind == kVideo ? "mp4" : "ipod", nullptr);
    if (!oc) {
        cleanup();
        return -4;
    }
    outPb = makeIo(&outIo, true);
    oc->pb = outPb;
    oc->flags |= AVFMT_FLAG_CUSTOM_IO;
    av_dict_copy(&oc->metadata, ic->metadata, 0);

    VideoChain video;
    AudioChain audio;
    AVStream* audioCopy = nullptr;
    AVStream* coverOut = nullptr;
    int coverIdx = -1;
    const VideoTarget vt = videoTarget(preset);
    const int aKbps = kind == kVideo ? vt.audioKbps : musicKbps(preset);

    if (kind == kVideo && !video.open(ic, vIdx, oc, vt)) {
        cleanup();
        return -5;
    }
    if (aIdx >= 0) {
        if (kind == kVideo && audioIsCopyable(ic->streams[aIdx]->codecpar, aKbps)) {
            audioCopy = avformat_new_stream(oc, nullptr);
            avcodec_parameters_copy(audioCopy->codecpar, ic->streams[aIdx]->codecpar);
            audioCopy->codecpar->codec_tag = 0;
            audioCopy->time_base = ic->streams[aIdx]->time_base;
        } else if (!audio.open(ic, aIdx, oc, aKbps)) {
            cleanup();
            return -6;
        }
    }
    // Album art travels along with music.
    if (kind == kAudio) {
        for (unsigned i = 0; i < ic->nb_streams; ++i) {
            AVStream* s = ic->streams[i];
            if ((s->disposition & AV_DISPOSITION_ATTACHED_PIC) &&
                (s->codecpar->codec_id == AV_CODEC_ID_MJPEG || s->codecpar->codec_id == AV_CODEC_ID_PNG)) {
                coverOut = avformat_new_stream(oc, nullptr);
                avcodec_parameters_copy(coverOut->codecpar, s->codecpar);
                coverOut->codecpar->codec_tag = 0;
                coverOut->disposition = AV_DISPOSITION_ATTACHED_PIC;
                coverIdx = static_cast<int>(i);
                break;
            }
        }
    }

    AVDictionary* muxOpts = nullptr;
    if (avformat_write_header(oc, &muxOpts) < 0) {
        av_dict_free(&muxOpts);
        cleanup();
        return -7;
    }
    av_dict_free(&muxOpts);
    if (coverOut) {
        AVPacket* cp = av_packet_clone(&ic->streams[coverIdx]->attached_pic);
        if (cp) {
            cp->stream_index = coverOut->index;
            av_interleaved_write_frame(oc, cp);
            av_packet_free(&cp);
        }
    }

    int r = 0;
    while (r >= 0 && !jb.cancel && av_read_frame(ic, pkt) >= 0) {
        const int si = pkt->stream_index;
        if (duration > 0 && pkt->pts != AV_NOPTS_VALUE && (si == vIdx || si == aIdx)) {
            int64_t t = av_rescale_q(pkt->pts - (ic->streams[si]->start_time != AV_NOPTS_VALUE ? ic->streams[si]->start_time : 0),
                                     ic->streams[si]->time_base, AV_TIME_BASE_Q);
            jb.progress = std::clamp(static_cast<double>(t) / static_cast<double>(duration), 0.0, 0.99);
        }
        if (si == vIdx) {
            r = video.feed(pkt, oc, opkt);
        } else if (si == aIdx && audioCopy) {
            av_packet_rescale_ts(pkt, ic->streams[aIdx]->time_base, audioCopy->time_base);
            pkt->stream_index = audioCopy->index;
            pkt->pos = -1;
            r = av_interleaved_write_frame(oc, pkt);
        } else if (si == aIdx) {
            r = audio.feed(pkt, oc, opkt);
        }
        av_packet_unref(pkt);
    }
    if (r >= 0 && !jb.cancel) {
        if (vIdx >= 0) r = video.finish(oc, opkt);
        if (r >= 0 && aIdx >= 0 && !audioCopy) r = audio.finish(oc, opkt);
    }
    if (r >= 0 && !jb.cancel && av_write_trailer(oc) == 0) {
        avio_flush(oc->pb);
        result = 0;
        // Not worth it unless we save at least 10%.
        struct stat a{}, b{};
        if (fstat(inFd, &a) == 0 && fstat(outFd, &b) == 0 && outIo.pos > a.st_size * 9 / 10) result = 1;
        if (result == 0) ftruncate64(outFd, outIo.pos);
    } else if (!jb.cancel) {
        char err[128];
        av_strerror(r, err, sizeof err);
        LOGW("transcode failed: %s", err);
        result = -8;
    }
    jb.progress = 1;
    cleanup();
    return result;
}

int mux(int id, int videoFd, int srcFd, int outFd, Preset preset) {
    Job& jb = job(id);
    jb.progress = 0;

    FdIo vIo{videoFd}, sIo{srcFd}, outIo{outFd};
    AVFormatContext* vc = avformat_alloc_context();
    AVFormatContext* ic = avformat_alloc_context();
    AVIOContext* vPb = makeIo(&vIo, false);
    AVIOContext* sPb = makeIo(&sIo, false);
    vc->pb = vPb;
    vc->flags |= AVFMT_FLAG_CUSTOM_IO;
    ic->pb = sPb;
    ic->flags |= AVFMT_FLAG_CUSTOM_IO;
    AVFormatContext* oc = nullptr;
    AVIOContext* outPb = nullptr;
    AVPacket* vp = av_packet_alloc();
    AVPacket* ap = av_packet_alloc();
    AVPacket* opkt = av_packet_alloc();
    int result = -1;

    auto cleanup = [&] {
        if (oc) avformat_free_context(oc);
        freeIo(&outPb);
        avformat_close_input(&vc);
        avformat_close_input(&ic);
        freeIo(&vPb);
        freeIo(&sPb);
        av_packet_free(&vp);
        av_packet_free(&ap);
        av_packet_free(&opkt);
        std::lock_guard<std::mutex> l(gJobsMu);
        gJobs.erase(id);
    };

    if (avformat_open_input(&vc, nullptr, nullptr, nullptr) < 0 || avformat_find_stream_info(vc, nullptr) < 0 ||
        avformat_open_input(&ic, nullptr, nullptr, nullptr) < 0 || avformat_find_stream_info(ic, nullptr) < 0) {
        cleanup();
        return -2;
    }
    const int vIdx = av_find_best_stream(vc, AVMEDIA_TYPE_VIDEO, -1, -1, nullptr, 0);
    const int srcV = av_find_best_stream(ic, AVMEDIA_TYPE_VIDEO, -1, -1, nullptr, 0);
    const int aIdx = av_find_best_stream(ic, AVMEDIA_TYPE_AUDIO, -1, srcV, nullptr, 0);
    if (vIdx < 0) {
        cleanup();
        return -3;
    }
    const int64_t duration = ic->duration > 0 ? ic->duration : 0;

    avformat_alloc_output_context2(&oc, nullptr, "mp4", nullptr);
    if (!oc) {
        cleanup();
        return -4;
    }
    outPb = makeIo(&outIo, true);
    oc->pb = outPb;
    oc->flags |= AVFMT_FLAG_CUSTOM_IO;
    // Date, place and the like come from the original.
    av_dict_copy(&oc->metadata, ic->metadata, 0);

    AVStream* vin = vc->streams[vIdx];
    AVStream* vout = avformat_new_stream(oc, nullptr);
    avcodec_parameters_copy(vout->codecpar, vin->codecpar);  // incl. the rotation matrix
    vout->codecpar->codec_tag = vin->codecpar->codec_id == AV_CODEC_ID_HEVC ? MKTAG('h', 'v', 'c', '1') : 0;
    vout->time_base = vin->time_base;
    vout->avg_frame_rate = vin->avg_frame_rate;
    if (srcV >= 0) av_dict_copy(&vout->metadata, ic->streams[srcV]->metadata, 0);

    AudioChain audio;
    AVStream* audioCopy = nullptr;
    const int aKbps = videoTarget(preset).audioKbps;
    if (aIdx >= 0) {
        if (audioIsCopyable(ic->streams[aIdx]->codecpar, aKbps)) {
            audioCopy = avformat_new_stream(oc, nullptr);
            avcodec_parameters_copy(audioCopy->codecpar, ic->streams[aIdx]->codecpar);
            audioCopy->codecpar->codec_tag = 0;
            audioCopy->time_base = ic->streams[aIdx]->time_base;
        } else if (!audio.open(ic, aIdx, oc, aKbps)) {
            cleanup();
            return -6;
        }
    }
    if (avformat_write_header(oc, nullptr) < 0) {
        cleanup();
        return -7;
    }

    // Two-way merge by time so the muxer never has to buffer a whole track.
    auto next = [](AVFormatContext* c, AVPacket* p, int want) {
        while (av_read_frame(c, p) >= 0) {
            if (p->stream_index == want) return true;
            av_packet_unref(p);
        }
        return false;
    };
    auto when = [](AVFormatContext* c, AVPacket* p) {
        int64_t t = p->dts != AV_NOPTS_VALUE ? p->dts : p->pts;
        return t == AV_NOPTS_VALUE ? 0 : av_rescale_q(t, c->streams[p->stream_index]->time_base, AV_TIME_BASE_Q);
    };
    bool haveV = next(vc, vp, vIdx);
    bool haveA = aIdx >= 0 && next(ic, ap, aIdx);
    int r = 0;
    while (r >= 0 && !jb.cancel && (haveV || haveA)) {
        if (haveV && (!haveA || when(vc, vp) <= when(ic, ap))) {
            if (duration > 0) jb.progress = std::clamp(static_cast<double>(when(vc, vp)) / duration, 0.0, 0.99);
            av_packet_rescale_ts(vp, vin->time_base, vout->time_base);
            vp->stream_index = vout->index;
            vp->pos = -1;
            r = av_interleaved_write_frame(oc, vp);
            haveV = next(vc, vp, vIdx);
        } else {
            if (audioCopy) {
                av_packet_rescale_ts(ap, ic->streams[aIdx]->time_base, audioCopy->time_base);
                ap->stream_index = audioCopy->index;
                ap->pos = -1;
                r = av_interleaved_write_frame(oc, ap);
            } else {
                r = audio.feed(ap, oc, opkt);
                av_packet_unref(ap);
            }
            haveA = next(ic, ap, aIdx);
        }
    }
    if (r >= 0 && !jb.cancel && aIdx >= 0 && !audioCopy) r = audio.finish(oc, opkt);
    if (r >= 0 && !jb.cancel && av_write_trailer(oc) == 0) {
        avio_flush(oc->pb);
        result = 0;
        struct stat a{};
        if (fstat(srcFd, &a) == 0 && outIo.pos > a.st_size * 9 / 10) result = 1;  // not worth it
        if (result == 0) ftruncate64(outFd, outIo.pos);
    } else if (!jb.cancel) {
        char err[128];
        av_strerror(r, err, sizeof err);
        LOGW("mux failed: %s", err);
        result = -8;
    }
    jb.progress = 1;
    cleanup();
    return result;
}

}  // namespace media
