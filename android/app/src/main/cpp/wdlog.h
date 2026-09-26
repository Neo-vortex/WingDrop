// A small in-memory log for the in-app "nerd log" screen, alongside logcat.
#pragma once

#include <string>

namespace wdlog {

// printf-style; also forwarded to logcat.
void log(char level, const char* tag, const char* fmt, ...) __attribute__((format(printf, 3, 4)));
std::string dump();
void clear();

}  // namespace wdlog
