#include "wdlog.h"

#include <android/log.h>
#include <sys/time.h>

#include <cstdarg>
#include <cstdio>
#include <ctime>
#include <deque>
#include <mutex>

namespace wdlog {

namespace {
std::mutex gMu;
std::deque<std::string> gLines;
constexpr size_t kMax = 600;
}  // namespace

void log(char level, const char* tag, const char* fmt, ...) {
    char msg[768];
    va_list ap;
    va_start(ap, fmt);
    vsnprintf(msg, sizeof msg, fmt, ap);
    va_end(ap);
    __android_log_print(level == 'W' ? ANDROID_LOG_WARN : level == 'E' ? ANDROID_LOG_ERROR : ANDROID_LOG_INFO, tag,
                        "%s", msg);
    // Same "HH:MM:SS.mmm L tag: msg" shape as the Kotlin log, so they merge by time.
    timeval tv{};
    gettimeofday(&tv, nullptr);
    tm t{};
    localtime_r(&tv.tv_sec, &t);
    char line[900];
    snprintf(line, sizeof line, "%02d:%02d:%02d.%03d %c %s: %s", t.tm_hour, t.tm_min, t.tm_sec,
             static_cast<int>(tv.tv_usec / 1000), level, tag, msg);
    std::lock_guard<std::mutex> l(gMu);
    gLines.emplace_back(line);
    while (gLines.size() > kMax) gLines.pop_front();
}

std::string dump() {
    std::lock_guard<std::mutex> l(gMu);
    std::string out;
    for (auto& s : gLines) {
        out += s;
        out += '\n';
    }
    return out;
}

void clear() {
    std::lock_guard<std::mutex> l(gMu);
    gLines.clear();
}

}  // namespace wdlog
