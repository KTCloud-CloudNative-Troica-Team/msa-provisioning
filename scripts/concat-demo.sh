#!/usr/bin/env bash
# Concatenate two demo recordings into a single MP4.
#
# Default usage (no args) — combines the standard cluster-up + platform-sync
# outputs from $HOME/recordings:
#   bash concat-demo.sh
#
# Custom usage (3 args):
#   bash concat-demo.sh <input1.mp4> <input2.mp4> <output.mp4>
#
# Handles different source resolutions by padding both to a common
# 1280x640 canvas (force_original_aspect_ratio=decrease + pad). Re-encodes
# with libx264 because the source MP4s usually differ in dimensions so the
# faster -c copy concat won't work.
set -euo pipefail

REC="$HOME/recordings"
IN1="${1:-$REC/cluster_up_provisioning.mp4}"
IN2="${2:-$REC/platform_sync.mp4}"
OUT="${3:-$REC/cluster_up_full_demo.mp4}"

# Output canvas size — pick something that fits both source aspect ratios
# with minimal black padding. 1280x640 covers our typical asciinema output.
CANVAS_W=1280
CANVAS_H=640

# 사전 검증
if ! command -v ffmpeg >/dev/null 2>&1; then
  echo "error: ffmpeg not found in PATH" >&2
  exit 1
fi
if ! command -v ffprobe >/dev/null 2>&1; then
  echo "error: ffprobe not found in PATH" >&2
  exit 1
fi

for f in "$IN1" "$IN2"; do
  if [ ! -f "$f" ]; then
    echo "error: missing input $f" >&2
    exit 1
  fi
done

mkdir -p "$(dirname "$OUT")"

echo ">>> inputs"
printf "  %-40s %s\n" "$(basename "$IN1"):" "$(ffprobe -v error -show_entries stream=width,height -of csv=p=0:s=x "$IN1")"
printf "  %-40s %s\n" "$(basename "$IN2"):" "$(ffprobe -v error -show_entries stream=width,height -of csv=p=0:s=x "$IN2")"
echo ">>> output canvas: ${CANVAS_W}x${CANVAS_H}"
echo ">>> output file:   $OUT"
echo ""

echo ">>> concat via filter_complex (pad both inputs to canvas, then concat)"
ffmpeg -y \
  -i "$IN1" \
  -i "$IN2" \
  -filter_complex "[0:v]scale=${CANVAS_W}:${CANVAS_H}:force_original_aspect_ratio=decrease,pad=${CANVAS_W}:${CANVAS_H}:(ow-iw)/2:(oh-ih)/2:black,setsar=1[v0];[1:v]scale=${CANVAS_W}:${CANVAS_H}:force_original_aspect_ratio=decrease,pad=${CANVAS_W}:${CANVAS_H}:(ow-iw)/2:(oh-ih)/2:black,setsar=1[v1];[v0][v1]concat=n=2:v=1[outv]" \
  -map "[outv]" \
  -c:v libx264 -pix_fmt yuv420p -movflags faststart \
  -b:v 1200k -maxrate 1500k -bufsize 3000k \
  -r 15 \
  "$OUT"

echo ""
echo ">>> done"
ls -lh "$OUT"
ffmpeg -i "$OUT" 2>&1 | grep -E "Duration|Stream #0"
