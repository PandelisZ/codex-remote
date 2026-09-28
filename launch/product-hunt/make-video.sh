#!/usr/bin/env bash
# A captioned, silent 29-second walkthrough for autoplay and YouTube.
# The five plates are made from real app captures; motion is limited to slow
# camera movement and dissolves, so no interaction is implied that did not occur.
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
for number in 1 2 3 4 5; do
  [ -s "$HERE/gallery/$(printf '%02d' "$number").png" ] || {
    echo "Missing gallery card $number; run render.sh first" >&2
    exit 1
  }
done

inputs=()
for number in 1 2 3 4 5; do
  inputs+=(-loop 1 -framerate 30 -t 6.5 -i "$HERE/gallery/$(printf '%02d' "$number").png")
done

filter=""
for number in 0 1 2 3 4; do
  filter+="[$number:v]scale=2200:-2:flags=lanczos,zoompan=z='min(zoom+0.00014,1.026)':x='iw/2-(iw/zoom/2)':y='ih/2-(ih/zoom/2)':d=1:s=1920x1080:fps=30,trim=duration=6.5,setpts=PTS-STARTPTS,format=yuv420p[v$number];"
done
filter+='[v0][v1]xfade=transition=fade:duration=0.8:offset=5.7[x1];'
filter+='[x1][v2]xfade=transition=fade:duration=0.8:offset=11.4[x2];'
filter+='[x2][v3]xfade=transition=fade:duration=0.8:offset=17.1[x3];'
filter+='[x3][v4]xfade=transition=fade:duration=0.8:offset=22.8[out]'

ffmpeg -hide_banner -loglevel error -y \
  "${inputs[@]}" -filter_complex "$filter" -map '[out]' \
  -an -c:v libx264 -preset medium -crf 18 -pix_fmt yuv420p \
  -movflags +faststart "$HERE/codex-remote-launch.mp4"

ffprobe -v error -show_entries format=duration,size \
  -show_entries stream=width,height,codec_name \
  -of default=noprint_wrappers=1 "$HERE/codex-remote-launch.mp4"
