#!/usr/bin/env bash
set -euo pipefail

# auto-speedup-silence.sh
#
# Usage:
#   ./auto-speedup-silence.sh input.mkv
#   ./auto-speedup-silence.sh *.mkv
#
# Output:
#   input.edited.mp4
#
# Requirements:
#   sudo apt install ffmpeg
#
# Defaults can be overridden:
#   SILENCE_DB="-35dB" SILENCE_DURATION="2" SILENCE_SPEED="5" ./auto-speedup-silence.sh input.mkv
#
# Notes:
#   SILENCE_SPEED=5 means silent parts are played at 5x speed,
#   i.e. compressed to 20% of their original duration.

SILENCE_DB="${SILENCE_DB:--35dB}"
SILENCE_DURATION="${SILENCE_DURATION:-2}"
SILENCE_SPEED="${SILENCE_SPEED:-5}"

# Output resolution.
# For YouTube-style 16:9, 1920x1080 is a safe default.
OUT_W="${OUT_W:-1920}"
OUT_H="${OUT_H:-1080}"

# Output frame rate (constant). Set to "source" to preserve source framerate (may produce VFR).
OUTPUT_FPS="${OUTPUT_FPS:-60}"

# H.264/AAC settings.
CRF="${CRF:-20}"
PRESET="${PRESET:-medium}"
AUDIO_BITRATE="${AUDIO_BITRATE:-192k}"

if ! command -v ffmpeg >/dev/null 2>&1; then
  echo "Error: ffmpeg is not installed. Run: sudo apt install ffmpeg" >&2
  exit 1
fi

if ! command -v ffprobe >/dev/null 2>&1; then
  echo "Error: ffprobe is not installed. Run: sudo apt install ffmpeg" >&2
  exit 1
fi

if [[ "$#" -lt 1 ]]; then
  echo "Usage: $0 input1.mkv [input2.mkv ...]" >&2
  exit 1
fi

float_lt() {
  awk -v a="$1" -v b="$2" 'BEGIN { exit !(a < b) }'
}

float_gt() {
  awk -v a="$1" -v b="$2" 'BEGIN { exit !(a > b) }'
}

float_sub() {
  awk -v a="$1" -v b="$2" 'BEGIN { printf "%.6f", a - b }'
}

process_file() {
  local input="$1"

  if [[ ! -f "$input" ]]; then
    echo "Skipping missing file: $input" >&2
    return
  fi

  local base="${input%.*}"
  local output="${base}.edited.mp4"

  echo "Processing: $input"
  echo "Output:     $output"
  echo "Silence:    ${SILENCE_DB}, minimum ${SILENCE_DURATION}s"
  echo "Speedup:    ${SILENCE_SPEED}x during silence"
  local fps_label="${OUTPUT_FPS}fps"
  if [[ "$OUTPUT_FPS" == "source" ]]; then fps_label="source (may be VFR)"; fi
  echo "Frame rate: ${fps_label}"
  echo

  local duration
  duration="$(
    ffprobe -v error \
      -show_entries format=duration \
      -of default=noprint_wrappers=1:nokey=1 \
      "$input"
  )"

  if [[ -z "$duration" ]]; then
    echo "Could not determine duration for $input" >&2
    return
  fi

  local tmpdir
  tmpdir="$(mktemp -d)"
  local silence_log="$tmpdir/silence.log"
  local ranges_file="$tmpdir/ranges.tsv"
  local filter_file="$tmpdir/filter_complex.txt"

  # Detect silence.
  ffmpeg -hide_banner -nostats -i "$input" \
    -af "silencedetect=noise=${SILENCE_DB}:d=${SILENCE_DURATION}" \
    -f null - 2> "$silence_log" || true

  # Parse silence ranges from ffmpeg log.
  awk -v total_duration="$duration" '
    /silence_start:/ {
      s=$NF
    }
    /silence_end:/ {
      for (i=1; i<=NF; i++) {
        if ($i == "silence_end:") {
          e=$(i+1)
          gsub(/\|/, "", e)
          if (s != "" && e > s) {
            print s "\t" e
          }
          s=""
        }
      }
    }
    END {
      # If the file ends while still silent, close the final silence at EOF.
      if (s != "" && total_duration > s) {
        print s "\t" total_duration
      }
    }
  ' "$silence_log" > "$ranges_file"

  local segment_count=0
  local cursor="0"
  local filter=""

  while IFS=$'\t' read -r s e; do
    [[ -z "${s:-}" || -z "${e:-}" ]] && continue

    # Normal section before silence.
    if float_gt "$s" "$cursor"; then
      filter+="[0:v]trim=start=${cursor}:end=${s},setpts=PTS-STARTPTS[v${segment_count}];"
      filter+="[0:a]atrim=start=${cursor}:end=${s},asetpts=PTS-STARTPTS[a${segment_count}];"
      segment_count=$((segment_count + 1))
    fi

    # Silent section, sped up.
    if float_gt "$e" "$s"; then
      filter+="[0:v]trim=start=${s}:end=${e},setpts=(PTS-STARTPTS)/${SILENCE_SPEED}[v${segment_count}];"
      filter+="[0:a]atrim=start=${s}:end=${e},asetpts=PTS-STARTPTS,atempo=${SILENCE_SPEED}[a${segment_count}];"
      segment_count=$((segment_count + 1))
    fi

    cursor="$e"
  done < "$ranges_file"

  # Tail after last silence.
  if float_gt "$duration" "$cursor"; then
    filter+="[0:v]trim=start=${cursor}:end=${duration},setpts=PTS-STARTPTS[v${segment_count}];"
    filter+="[0:a]atrim=start=${cursor}:end=${duration},asetpts=PTS-STARTPTS[a${segment_count}];"
    segment_count=$((segment_count + 1))
  fi

  if [[ "$segment_count" -eq 0 ]]; then
    echo "No usable segments found; skipping $input" >&2
    rm -rf "$tmpdir"
    return
  fi

  local concat_inputs=""
  for ((i=0; i<segment_count; i++)); do
    concat_inputs+="[v${i}][a${i}]"
  done

  # Concat all sections, then make output 16:9 without distortion:
  # - crop to 16:9 centered
  # - scale to OUT_W x OUT_H
  # - setsar=1 for square pixels
  # - format=yuv420p for broad MP4/H.264 compatibility
  filter+="${concat_inputs}concat=n=${segment_count}:v=1:a=1[vcat][acat];"
  filter+="[vcat]crop='if(gt(iw/ih,16/9),ih*16/9,iw)':'if(gt(iw/ih,16/9),ih,iw*9/16)',scale=${OUT_W}:${OUT_H},setsar=1,format=yuv420p[vout];"
  filter+="[acat]aresample=48000[aout]"

  printf "%s" "$filter" > "$filter_file"

  local fps_opts=()
if [[ "$OUTPUT_FPS" != "source" ]]; then
  fps_opts=(-r "$OUTPUT_FPS" -vsync cfr)
fi

ffmpeg -hide_banner -y \
    -i "$input" \
    -filter_complex_script "$filter_file" \
    "${fps_opts[@]}" \
    -map "[vout]" \
    -map "[aout]" \
    -c:v libx264 \
    -preset "$PRESET" \
    -crf "$CRF" \
    -profile:v high \
    -pix_fmt yuv420p \
    -c:a aac \
    -b:a "$AUDIO_BITRATE" \
    -movflags +faststart \
    -metadata:s:v:0 rotate=0 \
    "$output"

  rm -rf "$tmpdir"

  echo
  echo "Done: $output"
  echo
}

for file in "$@"; do
  process_file "$file"
done