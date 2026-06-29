# auto-edit

Automated video editing tools.

## `auto-speedup-silence.sh`

A Bash script that automatically speeds up silent sections in OBS screen recordings (or any video with an audio track).

### Usage

```bash
./auto-speedup-silence.sh input.mkv
./auto-speedup-silence.sh *.mkv
```

Output is `<input>.edited.mp4`.

### How it works

1. Uses `ffmpeg`’s `silencedetect` filter to find silent ranges.
2. Splits the video into speaking (normal speed) and silent (5× speed) segments.
3. Reassembles everything with `concat`, crops to 16:9, and encodes as H.264 + AAC.

### Requirements

```bash
sudo apt install ffmpeg
```

### Configuration (environment variables)

| Variable | Default | Description |
|---|---|---|
| `SILENCE_DB` | `-35dB` | Noise threshold for silence detection |
| `SILENCE_DURATION` | `2` | Minimum silence duration in seconds |
| `SILENCE_SPEED` | `5` | Speed multiplier during silence |
| `OUT_W` | `1920` | Output width |
| `OUT_H` | `1080` | Output height |
| `CRF` | `20` | H.264 quality (lower = better) |
| `PRESET` | `medium` | x264 encoding preset |
| `AUDIO_BITRATE` | `192k` | AAC audio bitrate |
| `OUTPUT_FPS` | `60` | Output frame rate (`60` for 60fps, `30` for 30fps, or `source` to preserve source — may produce VFR) |

### Examples

```bash
# Default settings
./auto-speedup-silence.sh my-recording.mkv

# Less sensitive silence detection
SILENCE_DB="-45dB" SILENCE_DURATION="2" ./auto-speedup-silence.sh input.mkv

# Faster silence speedup (10x)
SILENCE_SPEED="10" ./auto-speedup-silence.sh input.mkv

# 30 FPS output instead of 60
OUTPUT_FPS="30" ./auto-speedup-silence.sh input.mkv

# Preserve source frame rate (may produce VFR)
OUTPUT_FPS="source" ./auto-speedup-silence.sh input.mkv
```
