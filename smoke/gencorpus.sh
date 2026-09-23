#!/bin/sh
# gencorpus.sh <outdir>
#
# Generates the smoke corpus with a full-featured ffmpeg (FULL_FFMPEG,
# default the one on PATH), cjpeg from libjpeg-turbo, avifenc from
# libavif and cjxl from libjxl. The trimmed build cannot encode, so
# generation always rides other tools; the corpus is generated fresh
# rather than committed.
set -eu

OUT=${1:?usage: gencorpus.sh <outdir>}
FULL=${FULL_FFMPEG:-ffmpeg}
mkdir -p "$OUT"

SRC="testsrc2=size=64x36:rate=10:duration=1"

gen() {
  file=$1; shift
  "$FULL" -y -loglevel error -f lavfi -i "$SRC" "$@" "$OUT/$file"
}

gen h264.mp4  -c:v libx264 -pix_fmt yuv420p
gen hevc.mp4  -c:v libx265 -pix_fmt yuv420p -loglevel quiet
gen mpeg4.mp4 -c:v mpeg4
gen av1.mp4   -c:v libaom-av1 -cpu-used 8 -usage realtime -pix_fmt yuv420p
gen vp8.webm  -c:v libvpx -pix_fmt yuv420p
gen vp9.webm  -c:v libvpx-vp9 -pix_fmt yuv420p
gen av1.webm  -c:v libaom-av1 -cpu-used 8 -usage realtime -pix_fmt yuv420p
gen anim.gif
gen plain.jpg -frames:v 1 -update 1

"$FULL" -y -loglevel error -f lavfi -i "$SRC" -frames:v 1 -update 1 "$OUT/tmp.ppm"
cjpeg -quality 90 -sample 3x1 -outfile "$OUT/weird.jpg" "$OUT/tmp.ppm"
rm -f "$OUT/tmp.ppm"

"$FULL" -y -loglevel error -display_rotation 90 -i "$OUT/h264.mp4" -c copy "$OUT/rot.mp4"

STILL="testsrc2=size=640x360"
"$FULL" -y -loglevel error -f lavfi -i "$STILL" -frames:v 1 -update 1 "$OUT/tmp.png"
"$FULL" -y -loglevel error -f lavfi -i "$STILL,format=rgba,colorchannelmixer=aa=0.5" \
  -frames:v 1 -update 1 "$OUT/tmp-alpha.png"
avifenc "$OUT/tmp.png" "$OUT/still.avif" >/dev/null
avifenc "$OUT/tmp-alpha.png" "$OUT/alpha.avif" >/dev/null
avifenc --irot 1 "$OUT/tmp.png" "$OUT/rot.avif" >/dev/null
cjxl "$OUT/tmp.png" "$OUT/still.jxl" 2>/dev/null
cjxl --container=1 "$OUT/tmp-alpha.png" "$OUT/container.jxl" 2>/dev/null
cjxl "$OUT/plain.jpg" "$OUT/recompressed.jxl" 2>/dev/null
rm -f "$OUT/tmp.png" "$OUT/tmp-alpha.png"

ls -la "$OUT"
