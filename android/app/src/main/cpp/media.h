// Media shrinking with the bundled FFmpeg: any container/codec FFmpeg can
// read in, MP4 (HEVC/H.264 via the phone's hardware encoder + AAC) or M4A out.
#pragma once

#include <cstdint>
#include <vector>

struct _JavaVM;

namespace media {

enum Kind { kVideo = 0, kAudio = 1 };
enum Preset { kLight = 0, kSmall = 1 };

void init(_JavaVM* vm);

// Reads inFd, writes the result to outFd (both owned by the caller).
// Returns 0 on success, 1 when shrinking would not help (send the original),
// negative on failure. `job` identifies the progress slot.
int transcode(int job, int inFd, int outFd, Kind kind, Preset preset);

// Decodes a representative video frame (or embedded cover art) as RGBA,
// scaled to fit maxSide. Empty on failure.
std::vector<uint8_t> frame(int inFd, int maxSide, int* outW, int* outH);

// 0..1 for a running job.
double progress(int job);
void cancel(int job);

}  // namespace media
