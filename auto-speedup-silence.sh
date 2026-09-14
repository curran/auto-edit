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
#
#   The work is done in chunks (CHUNK_SECONDS) so that the ffmpeg filter
#   graph never has to hold hundreds of trim/atempo branches at once.
#   Chunk boundaries are nudged so they never fall inside a detected
#   silence range. Chunks are encoded identically and then concatenated
#   losslessly with the concat demuxer.

SILENCE_DB="${SILENCE_DB:--35dB}"
SILENCE_DURATION="${SILENCE_DURATION:-2}"
SILENCE_SPEED="${SILENCE_SPEED:-5}"

# Output resolution.
# For YouTube-style 16:9, 1920x1080 is a safe default.
OUT_W="${OUT_W:-1920}"
OUT_H="${OUT_H:-1080}"

# Output frame rate (constant). Set to "source" to preserve source framerate (may produce VFR).
OUTPUT_FPS="${OUTPUT_FPS:-60}"

# Maximum seconds of source video handled in one ffmpeg pass.
# Smaller values = smaller filter graphs / less memory, but more passes.
CHUNK_SECONDS="${CHUNK_SECONDS:-180}"

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

# Build the filtergraph for one chunk.
#
#   $1 chunk start (source seconds)
#   $2 chunk end   (source seconds)
#   $3 silence ranges file (global source timestamps, tab separated)
#   $4 output filter file
build_chunk_filter() {
  local cs="$1"
  local ce="$2"
  local ranges_file="$3"
  local filter_file="$4"

  local chunk_dur
  chunk_dur="$(float_sub "$ce" "$cs")"

  local segment_count=0
  local cursor="0"
  local filter=""

  while IFS=$'\t' read -r s e; do
    [[ -z "${s:-}" || -z "${e:-}" ]] && continue

    # Convert the global silence range into chunk-local timestamps and clip.
    local ls le
    ls="$(float_sub "$s" "$cs")"
    le="$(float_sub "$e" "$cs")"
    if float_lt "$ls" "0"; then ls="0"; fi
    if float_gt "$le" "$chunk_dur"; then le="$chunk_dur"; fi
    if ! float_gt "$le" "$ls"; then continue; fi

    # Normal section before silence.
    if float_gt "$ls" "$cursor"; then
      filter+="[0:v]trim=start=${cursor}:end=${ls},setpts=PTS-STARTPTS[v${segment_count}];"
      filter+="[0:a]atrim=start=${cursor}:end=${ls},asetpts=PTS-STARTPTS[a${segment_count}];"
      segment_count=$((segment_count + 1))
    fi

    # Silent section, sped up.
    filter+="[0:v]trim=start=${ls}:end=${le},setpts=(PTS-STARTPTS)/${SILENCE_SPEED}[v${segment_count}];"
    filter+="[0:a]atrim=start=${ls}:end=${le},asetpts=PTS-STARTPTS,atempo=${SILENCE_SPEED}[a${segment_count}];"
    segment_count=$((segment_count + 1))

    cursor="$le"
  done < "$ranges_file"

  # Tail after last silence.
  if float_gt "$chunk_dur" "$cursor"; then
    filter+="[0:v]trim=start=${cursor}:end=${chunk_dur},setpts=PTS-STARTPTS[v${segment_count}];"
    filter+="[0:a]atrim=start=${cursor}:end=${chunk_dur},asetpts=PTS-STARTPTS[a${segment_count}];"
    segment_count=$((segment_count + 1))
  fi

  if [[ "$segment_count" -eq 0 ]]; then
    return 1
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
  return 0
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
  echo "Chunk size: ${CHUNK_SECONDS}s"
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
  local bounds_file="$tmpdir/bounds.tsv"
  local list_file="$tmpdir/concat.txt"

  # Detect silence.
  ffmpeg -hide_banner -nostdin -nostats -i "$input" \
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

  # Compute fixed chunk boundaries. Splitting a silence range across a
  # chunk boundary is fine: each half is sped up independently and the
  # two halves together occupy exactly the same output duration as the
  # original range sped up as a whole. A tiny trailing remainder is
  # merged into the previous chunk so we never emit a near-empty chunk.
  awk -v total="$duration" -v chunk="$CHUNK_SECONDS" -v minchunk="1.0" '
    BEGIN {
      last = 0
      while (last < total - 0.001) {
        b = last + chunk
        if (b > total) b = total
        # Absorb a tiny tail into this chunk.
        if ((total - b) > 0 && (total - b) < minchunk) b = total
        printf "%.6f\t%.6f\n", last, b
        last = b
      }
    }
  ' > "$bounds_file"

  local fps_opts=()
  if [[ "$OUTPUT_FPS" != "source" ]]; then
    fps_opts=(-r "$OUTPUT_FPS" -fps_mode cfr)
  fi

  local chunk_index=0
  local chunk_files=()

  while IFS=$'\t' read -r cs ce; do
    [[ -z "${cs:-}" || -z "${ce:-}" ]] && continue

    local chunk_filter="$tmpdir/filter_${chunk_index}.txt"
    local chunk_out
    chunk_out="$(printf '%s/chunk_%03d.mp4' "$tmpdir" "$chunk_index")"
    local chunk_dur
    chunk_dur="$(float_sub "$ce" "$cs")"

    if ! build_chunk_filter "$cs" "$ce" "$ranges_file" "$chunk_filter"; then
      echo "Chunk ${chunk_index}: no usable segments; skipping" >&2
      chunk_index=$((chunk_index + 1))
      continue
    fi

    echo "Encoding chunk $((chunk_index + 1)): ${cs}s .. ${ce}s (${chunk_dur}s)"

    ffmpeg -hide_banner -nostdin -nostats -y \
      -ss "$cs" -t "$chunk_dur" \
      -i "$input" \
      -filter_complex "$(cat "$chunk_filter")" \
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
      "$chunk_out"

    chunk_files+=("$chunk_out")
    chunk_index=$((chunk_index + 1))
  done < "$bounds_file"

  if [[ "${#chunk_files[@]}" -eq 0 ]]; then
    echo "No usable segments found; skipping $input" >&2
    rm -rf "$tmpdir"
    return
  fi

  # Concatenate chunks losslessly (they all use identical codec settings).
  : > "$list_file"
  local f
  for f in "${chunk_files[@]}"; do
    printf "file '%s'\n" "$f" >> "$list_file"
  done

  echo
  echo "Concatenating ${#chunk_files[@]} chunk(s)..."

  ffmpeg -hide_banner -nostdin -nostats -y \
    -f concat -safe 0 \
    -i "$list_file" \
    -c copy \
    -movflags +faststart \
    "$output"

  rm -rf "$tmpdir"

  echo
  echo "Done: $output"
  echo
}

for file in "$@"; do
  process_file "$file"
done
