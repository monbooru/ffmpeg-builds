#!/bin/sh
# build.sh <target>
#
# Builds the trimmed ffmpeg + ffprobe pair for one target into dist/.
# Targets: linux64, linuxarm64 (cross), win64 (mingw cross).

set -eu

TARGET=${1:-linux64}
ROOT=$(cd "$(dirname "$0")" && pwd)
. "$ROOT/versions.sh"

WORK="$ROOT/work/$TARGET"
PREFIX="$WORK/prefix"
DIST="$ROOT/dist"
SOURCES="$ROOT/sources"
JOBS=$(nproc 2>/dev/null || echo 4)

case "$TARGET" in
  linux64)
    CROSS=""; HOST=""; FF_ARCH=x86_64; FF_OS=linux; EXE="" ;;
  linuxarm64)
    CROSS=aarch64-linux-gnu-; HOST=aarch64-linux-gnu
    FF_ARCH=aarch64; FF_OS=linux; EXE="" ;;
  win64)
    CROSS=x86_64-w64-mingw32-; HOST=x86_64-w64-mingw32
    FF_ARCH=x86_64; FF_OS=mingw32; EXE=.exe ;;
  *) echo "unknown target: $TARGET" >&2; exit 1 ;;
esac

fetch() {
  url=$1; file=$2; sha=$3
  [ -f "$SOURCES/$file" ] || curl -fsSL -o "$SOURCES/$file" "$url"
  echo "$sha  $SOURCES/$file" | sha256sum -c -
}

mkdir -p "$WORK" "$DIST" "$SOURCES"

fetch "https://ffmpeg.org/releases/ffmpeg-$FFMPEG_VERSION.tar.xz" \
      "ffmpeg-$FFMPEG_VERSION.tar.xz" "$FFMPEG_SHA256"
fetch "https://storage.googleapis.com/downloads.webmproject.org/releases/webp/libwebp-$LIBWEBP_VERSION.tar.gz" \
      "libwebp-$LIBWEBP_VERSION.tar.gz" "$LIBWEBP_SHA256"
fetch "https://downloads.videolan.org/pub/videolan/dav1d/$DAV1D_VERSION/dav1d-$DAV1D_VERSION.tar.xz" \
      "dav1d-$DAV1D_VERSION.tar.xz" "$DAV1D_SHA256"

rm -rf "$WORK/libwebp-$LIBWEBP_VERSION" "$WORK/dav1d-$DAV1D_VERSION" \
       "$WORK/ffmpeg-$FFMPEG_VERSION" "$PREFIX"
tar -xzf "$SOURCES/libwebp-$LIBWEBP_VERSION.tar.gz" -C "$WORK"
tar -xJf "$SOURCES/dav1d-$DAV1D_VERSION.tar.xz" -C "$WORK"
tar -xJf "$SOURCES/ffmpeg-$FFMPEG_VERSION.tar.xz" -C "$WORK"

ASM_OK=1
if [ "$FF_ARCH" = x86_64 ] && ! command -v nasm >/dev/null && ! command -v yasm >/dev/null; then
  ASM_OK=0
  if [ "${ALLOW_NOASM:-}" != 1 ]; then
    echo "nasm/yasm missing: the no-asm swscale C path corrupts scaled output." >&2
    echo "Install nasm, or set ALLOW_NOASM=1 to build anyway." >&2
    exit 1
  fi
  echo "WARNING: building without x86 asm - scaled output is known bad" >&2
fi

echo "=== libwebp ($TARGET)"
cd "$WORK/libwebp-$LIBWEBP_VERSION"
./configure --prefix="$PREFIX" ${HOST:+--host=$HOST} \
  --disable-shared --enable-static --enable-libwebpmux \
  --disable-gl --disable-sdl --disable-png --disable-jpeg \
  --disable-tiff --disable-gif --disable-wic \
  CC="${CROSS}gcc" >/dev/null
make -j"$JOBS" >/dev/null
make install >/dev/null

echo "=== dav1d ($TARGET)"
DAV1D_OPTS="--default-library=static --prefix=$PREFIX --libdir=lib \
  -Denable_tools=false -Denable_tests=false -Denable_examples=false"
[ "$ASM_OK" = 1 ] || DAV1D_OPTS="$DAV1D_OPTS -Denable_asm=false"
[ -z "$CROSS" ] || DAV1D_OPTS="$DAV1D_OPTS --cross-file=$ROOT/cross/$TARGET.meson"
# shellcheck disable=SC2086
meson setup "$WORK/dav1d-build" "$WORK/dav1d-$DAV1D_VERSION" $DAV1D_OPTS >/dev/null
ninja -C "$WORK/dav1d-build" >/dev/null
ninja -C "$WORK/dav1d-build" install >/dev/null

echo "=== ffmpeg ($TARGET)"
cd "$WORK/ffmpeg-$FFMPEG_VERSION"
FF_OPTS=""
[ "$ASM_OK" = 1 ] || FF_OPTS="--disable-x86asm"
[ -z "$CROSS" ] || FF_OPTS="$FF_OPTS --enable-cross-compile --cross-prefix=$CROSS"
# shellcheck disable=SC2086
env PKG_CONFIG_PATH="$PREFIX/lib/pkgconfig" ./configure \
  --arch="$FF_ARCH" --target-os="$FF_OS" $FF_OPTS \
  --pkg-config-flags=--static \
  --extra-cflags="-I$PREFIX/include" \
  --extra-ldflags="-L$PREFIX/lib -static" \
  --disable-everything \
  --disable-autodetect \
  --disable-network \
  --disable-doc \
  --disable-debug \
  --disable-avdevice \
  --disable-ffplay \
  --enable-ffmpeg --enable-ffprobe \
  --enable-protocol=file \
  --enable-demuxer=mov,matroska,gif,image2,image_jpeg_pipe \
  --enable-decoder=h264,hevc,vp8,vp9,mpeg4,mjpeg,gif,libdav1d \
  --enable-parser=h264,hevc,vp8,vp9,av1,mjpeg,gif \
  --enable-encoder=mjpeg,libwebp,libwebp_anim \
  --enable-muxer=image2,webp \
  --enable-filter=scale \
  --enable-libwebp --enable-libdav1d >/dev/null
make -j"$JOBS" >/dev/null

PKG="ffmpeg-$FFMPEG_VERSION-mb$MB_REV-$TARGET"
STAGE="$WORK/$PKG"
rm -rf "$STAGE"
mkdir -p "$STAGE/bin" "$STAGE/licenses"
cp "ffmpeg$EXE" "ffprobe$EXE" "$STAGE/bin/"
"${CROSS}strip" "$STAGE/bin/ffmpeg$EXE" "$STAGE/bin/ffprobe$EXE"
cp LICENSE.md COPYING.LGPLv2.1 "$STAGE/licenses/"
cp "$WORK/libwebp-$LIBWEBP_VERSION/COPYING" "$STAGE/licenses/COPYING.libwebp"
cp "$WORK/dav1d-$DAV1D_VERSION/COPYING" "$STAGE/licenses/COPYING.dav1d"

cd "$WORK"
if [ "$TARGET" = win64 ]; then
  rm -f "$DIST/$PKG.zip"
  zip -qr "$DIST/$PKG.zip" "$PKG"
  OUT="$PKG.zip"
else
  tar -cJf "$DIST/$PKG.tar.xz" "$PKG"
  OUT="$PKG.tar.xz"
fi
cd "$DIST"
sha256sum "$OUT" > "$OUT.sha256"
ls -la "$OUT"
cat "$OUT.sha256"
