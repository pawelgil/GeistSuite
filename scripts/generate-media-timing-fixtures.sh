#!/bin/bash
set -euo pipefail

fixture_dir="$(cd "$(dirname "$0")/.." && pwd)/GeistLens/Tests/GeistCameraTests/Fixtures"

# Each video frame carries its index in luma (32 + frame index); each audio
# sample carries its source time in amplitude (0.1 + 0.1 * seconds).
ffmpeg -hide_banner -loglevel error -y \
  -f lavfi -i "nullsrc=s=64x48:r=30:d=2,geq=lum='32+N':cb=128:cr=128" \
  -f lavfi -i "aevalsrc=0.1+0.1*t:s=48000:d=2" \
  -c:v libx264 -qp 1 -profile:v high -preset ultrafast -pix_fmt yuv420p \
  -c:a pcm_f32le -ac 1 "$fixture_dir/TimingMarkers.mov"

ffmpeg -hide_banner -loglevel error -y \
  -itsoffset 0.3 -i "$fixture_dir/TimingMarkers.mov" \
  -i "$fixture_dir/TimingMarkers.mov" \
  -map 0:v -map 1:a -c copy "$fixture_dir/OffsetTimingMarkers.mov"

ffmpeg -hide_banner -loglevel error -y \
  -i "$fixture_dir/TimingMarkers.mov" -map 0:v -c copy \
  "$fixture_dir/VideoOnlyTimingMarkers.mov"
