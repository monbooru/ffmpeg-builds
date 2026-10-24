#!/bin/sh
# smoke.sh <bindir>
#
# Runs the trimmed pair in <bindir> through every invocation monbooru
# makes (argv copied verbatim from monbooru's internal/gallery/video.go
# and kept in sync by hand), then the negative checks that keep a fat
# build from shipping by accident.
#
# CORPUS_DIR   prebuilt corpus (default: ./corpus, generated on the fly
#              via gencorpus.sh when absent)
# RUNNER       prefix for every binary call (qemu-aarch64, wine)
# SIZE_BUDGET  per-binary cap in bytes (default 20 MB)
# GO           go binary for the stdlib decode check (default: go,
#              skipped with a warning when missing)
set -eu

BIN=${1:?usage: smoke.sh <bindir>}
BIN=$(cd "$BIN" && pwd)
HERE=$(cd "$(dirname "$0")" && pwd)
CORPUS=${CORPUS_DIR:-$HERE/../corpus}
RUNNER=${RUNNER:-}
SIZE_BUDGET=${SIZE_BUDGET:-20971520}
GO=${GO:-go}

EXE=""
[ -f "$BIN/ffmpeg.exe" ] && EXE=.exe
FF="$BIN/ffmpeg$EXE"
FP="$BIN/ffprobe$EXE"

[ -d "$CORPUS" ] || "$HERE/gencorpus.sh" "$CORPUS"

TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT
fail=0
bad() { echo "FAIL: $*" >&2; fail=1; }

is_jpeg() { [ "$(head -c2 "$1" | od -An -tx1 | tr -d ' ')" = "ffd8" ]; }
is_webp() { head -c 16 "$1" | grep -q WEBP; }
anim_frames() { grep -aoc ANMF "$1" || true; }

probe_duration() {
  $RUNNER "$FP" -v quiet -print_format csv=p=0 -show_entries format=duration -- "$1" | tr -d '\r'
}
# The JSON carries the rotation monbooru swaps a quarter-turned video's
# width and height on; probe_dims prints it, dims_of reads WxH out of it.
probe_dims() {
  $RUNNER "$FP" -v quiet -select_streams v:0 \
    -show_entries format=duration:stream=width,height:stream_side_data=rotation:stream_tags=rotate \
    -print_format json -- "$1" | tr -d '\r'
}
dims_of() {
  w=$(printf '%s\n' "$1" | sed -n 's/.*"width": *\([0-9]*\).*/\1/p' | head -n 1)
  h=$(printf '%s\n' "$1" | sed -n 's/.*"height": *\([0-9]*\).*/\1/p' | head -n 1)
  echo "${w}x${h}"
}
probe_audio() {
  $RUNNER "$FP" -v quiet -select_streams a:0 -show_entries stream=codec_type -print_format csv=p=0 -- "$1" | tr -d '\r'
}

fit() { echo "scale='min($1,iw)':'min($1,ih)':force_original_aspect_ratio=decrease"; }

dims_ok() {
  w=${1%%x*}; rest=${1#*x}; h=${rest%%x*}
  case "$w" in ''|0|*[!0-9]*) return 1;; esac
  case "$h" in ''|0|*[!0-9]*) return 1;; esac
}

for v in h264.mp4 hevc.mp4 mpeg4.mp4 av1.mp4 vp8.webm vp9.webm av1.webm rot.mp4; do
  src="$CORPUS/$v"
  [ -f "$src" ] || { echo "skip: $v not in corpus" >&2; continue; }
  echo "--- $v"

  d=$(probe_duration "$src")
  case "$d" in ''|0*[!.0-9]*) bad "$v: duration probe returned '$d'";; esac

  probe=$(probe_dims "$src")
  dims=$(dims_of "$probe")
  dims_ok "$dims" || bad "$v: dimension probe returned '$dims'"
  if [ "$v" = rot.mp4 ]; then
    printf '%s\n' "$probe" | grep -Eq '"rotation": *-?90([^0-9]|$)' || bad "rot.mp4: the probe carries no quarter-turn rotation"
  fi

  # An exit 0 with no stream is the answer for a silent clip.
  probe_audio "$src" >/dev/null || bad "$v: audio probe"

  # generateVideoThumb
  $RUNNER "$FF" -y -loglevel error -ss 0.1 -i "$src" -update 1 -frames:v 1 -vf "$(fit 300)" -q:v 2 -- "$TMP/$v.thumb.jpg" \
    || bad "$v: thumbnail extraction"
  is_jpeg "$TMP/$v.thumb.jpg" || bad "$v: thumbnail is not a JPEG"

  # generateVideoHover
  $RUNNER "$FF" -y -loglevel error -ss 0.1 -t 4 -i "$src" -vf "$(fit 300)" -an -loop 0 -- "$TMP/$v.hover.webp" \
    || bad "$v: hover generation"
  is_webp "$TMP/$v.hover.webp" || bad "$v: hover is not WebP"
  [ "$(anim_frames "$TMP/$v.hover.webp")" -ge 2 ] || bad "$v: hover is not animated"

  # A broken scaler still emits a valid JPEG, so compare the scaled
  # thumb against an unscaled frame from the same offset.
  if command -v "$GO" >/dev/null; then
    $RUNNER "$FF" -y -loglevel error -ss 0.1 -i "$src" -frames:v 1 -q:v 2 -- "$TMP/$v.ref.jpg" 2>/dev/null || true
    if [ -f "$TMP/$v.ref.jpg" ]; then
      "$GO" run "$HERE/decodecheck.go" -similar "$TMP/$v.thumb.jpg" "$TMP/$v.ref.jpg" \
        || bad "$v: scaled thumbnail does not resemble the source frame"
    fi
  fi

  # ExtractVideoFrames (the tagger's five sample positions, fractions of
  # the duration: on the 1 s corpus they are these seconds)
  n=0
  for off in 0.1 0.3 0.5 0.7 0.9; do
    if $RUNNER "$FF" -y -loglevel error -ss "$off" -i "$src" -update 1 -frames:v 1 -q:v 2 -- "$TMP/$v.frame$n.jpg" 2>/dev/null \
       && is_jpeg "$TMP/$v.frame$n.jpg"; then
      n=$((n + 1))
    fi
  done
  [ "$n" -ge 1 ] || bad "$v: no frames extracted"
done

echo "--- sound.mp4"
if [ -f "$CORPUS/sound.mp4" ]; then
  [ "$(probe_audio "$CORPUS/sound.mp4")" = audio ] || bad "sound.mp4: the audio probe does not report the audio stream"
else
  echo "skip: sound.mp4 not in corpus" >&2
fi

echo "--- anim.gif"
src="$CORPUS/anim.gif"
$RUNNER "$FF" -y -loglevel error -t 4 -i "$src" -vf "$(fit 300)" -loop 0 -- "$TMP/gif.hover.webp" \
  || bad "gif: hover generation"
is_webp "$TMP/gif.hover.webp" || bad "gif: hover is not WebP"
[ "$(anim_frames "$TMP/gif.hover.webp")" -ge 2 ] || bad "gif: hover is not animated"

# renderStill: a .webp destination is the lossless still Go decodes (the
# still route, AVIF and JPEG XL tagging), anything else a JPEG.
render_still() {
  r_src=$1 r_dst=$2 r_vf=""
  [ "$3" -gt 0 ] && r_vf=$(fit "$3")
  case "$r_dst" in
    *.webp) set -- -c:v libwebp -lossless 1 ;;
    *) set -- -q:v 2 ;;
  esac
  if [ -n "$r_vf" ]; then
    $RUNNER "$FF" -y -xerror -loglevel error -i "$r_src" -update 1 -frames:v 1 -vf "$r_vf" "$@" -- "$r_dst"
  else
    $RUNNER "$FF" -y -xerror -loglevel error -i "$r_src" -update 1 -frames:v 1 "$@" -- "$r_dst"
  fi
}

for s in still.avif alpha.avif rot.avif still.jxl container.jxl recompressed.jxl; do
  src="$CORPUS/$s"
  [ -f "$src" ] || { echo "skip: $s not in corpus" >&2; continue; }
  echo "--- $s"

  dims=$(dims_of "$(probe_dims "$src")")
  dims_ok "$dims" || bad "$s: dimension probe returned '$dims'"

  for max in 300 4000 0; do
    render_still "$src" "$TMP/$s.$max.jpg" "$max" || bad "$s: render at $max"
    is_jpeg "$TMP/$s.$max.jpg" || bad "$s: render at $max is not a JPEG"
  done

  for max in 4000 0; do
    render_still "$src" "$TMP/$s.$max.webp" "$max" || bad "$s: lossless WebP render at $max"
    is_webp "$TMP/$s.$max.webp" && grep -aq VP8L "$TMP/$s.$max.webp" \
      || bad "$s: render at $max is not a lossless WebP"
  done

  if command -v "$GO" >/dev/null; then
    "$GO" run "$HERE/decodecheck.go" -similar "$TMP/$s.300.jpg" "$TMP/$s.0.jpg" \
      || bad "$s: thumbnail does not resemble the full image"
  fi
done

# The 640x360 source comes out portrait once irot is applied.
if command -v "$GO" >/dev/null && [ -f "$TMP/rot.avif.0.jpg" ]; then
  "$GO" run "$HERE/decodecheck.go" "$TMP/rot.avif.0.jpg" | grep -q '^jpeg 360x640$' \
    || bad "rot.avif: irot not applied"
fi

echo "--- normalize"
if command -v "$GO" >/dev/null; then
  if [ -f "$CORPUS/weird.jpg" ]; then
    if "$GO" run "$HERE/decodecheck.go" "$CORPUS/weird.jpg" >/dev/null 2>&1; then
      bad "weird.jpg decodes with the stdlib before normalize - corpus is not a refused shape"
    fi
    cp "$CORPUS/weird.jpg" "$TMP/norm.jpg"
    $RUNNER "$FF" -y -loglevel error -i "$TMP/norm.jpg" -update 1 -frames:v 1 -q:v 2 -- "$TMP/norm.out.jpg" \
      || bad "normalize re-encode"
    "$GO" run "$HERE/decodecheck.go" "$TMP/norm.out.jpg" || bad "normalized output does not decode with the stdlib"
  fi
  cp "$CORPUS/plain.jpg" "$TMP/plain.jpg"
  $RUNNER "$FF" -y -loglevel error -i "$TMP/plain.jpg" -update 1 -frames:v 1 -q:v 2 -- "$TMP/plain.out.jpg" \
    || bad "normalize on a plain JPEG"
  "$GO" run "$HERE/decodecheck.go" "$TMP/plain.out.jpg" || bad "plain normalize output does not decode"
else
  echo "skip: go missing, stdlib decode contract unchecked" >&2
fi

echo "--- negative checks"
protos=$($RUNNER "$FF" -hide_banner -protocols 2>/dev/null)
echo "$protos" | grep -qw file || bad "file protocol missing"
for p in http https tcp tls udp; do
  echo "$protos" | grep -qw "$p" && bad "network protocol '$p' compiled in"
done

ndec=$($RUNNER "$FF" -hide_banner -decoders 2>/dev/null | grep -c '^ [AVS][A-Z.]\{5\} [^=]') || true
[ "$ndec" -le 10 ] || bad "decoder count $ndec exceeds budget (accidental fat build?)"

npdec=$($RUNNER "$FP" -hide_banner -decoders 2>/dev/null | grep -c '^ [AVS][A-Z.]\{5\} [^=]') || true
[ "$npdec" -eq 0 ] || bad "ffprobe carries $npdec decoders, it only reads containers"

for b in "$FF" "$FP"; do
  sz=$(wc -c < "$b")
  [ "$sz" -le "$SIZE_BUDGET" ] || bad "$(basename "$b") is $sz bytes, budget $SIZE_BUDGET"
done

if [ -z "$RUNNER" ] && [ -z "$EXE" ] && command -v ldd >/dev/null; then
  ldd "$FF" 2>&1 | grep -q 'not a dynamic executable\|statically linked' || bad "ffmpeg is dynamically linked"
fi

[ "$fail" = 0 ] && echo "smoke: OK" || { echo "smoke: FAILED" >&2; exit 1; }
