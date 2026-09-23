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
fetch "https://github.com/libjxl/libjxl/archive/refs/tags/v$LIBJXL_VERSION.tar.gz" \
      "libjxl-$LIBJXL_VERSION.tar.gz" "$LIBJXL_SHA256"
fetch "https://github.com/google/highway/archive/refs/tags/$HWY_VERSION.tar.gz" \
      "highway-$HWY_VERSION.tar.gz" "$HWY_SHA256"
fetch "https://github.com/google/brotli/archive/refs/tags/v$BROTLI_VERSION.tar.gz" \
      "brotli-$BROTLI_VERSION.tar.gz" "$BROTLI_SHA256"
fetch "https://github.com/google/skcms/archive/$SKCMS_COMMIT.tar.gz" \
      "skcms-$SKCMS_COMMIT.tar.gz" "$SKCMS_SHA256"

rm -rf "$WORK/libwebp-$LIBWEBP_VERSION" "$WORK/dav1d-$DAV1D_VERSION" \
       "$WORK/libjxl-$LIBJXL_VERSION" "$WORK/highway-$HWY_VERSION" \
       "$WORK/brotli-$BROTLI_VERSION" "$WORK/skcms-$SKCMS_COMMIT" \
       "$WORK/ffmpeg-$FFMPEG_VERSION" "$PREFIX"
tar -xzf "$SOURCES/libwebp-$LIBWEBP_VERSION.tar.gz" -C "$WORK"
tar -xJf "$SOURCES/dav1d-$DAV1D_VERSION.tar.xz" -C "$WORK"
tar -xzf "$SOURCES/libjxl-$LIBJXL_VERSION.tar.gz" -C "$WORK"
tar -xzf "$SOURCES/highway-$HWY_VERSION.tar.gz" -C "$WORK"
tar -xzf "$SOURCES/brotli-$BROTLI_VERSION.tar.gz" -C "$WORK"
tar -xzf "$SOURCES/skcms-$SKCMS_COMMIT.tar.gz" -C "$WORK"
tar -xJf "$SOURCES/ffmpeg-$FFMPEG_VERSION.tar.xz" -C "$WORK"

rmdir "$WORK/libjxl-$LIBJXL_VERSION/third_party/skcms"
mv "$WORK/skcms-$SKCMS_COMMIT" "$WORK/libjxl-$LIBJXL_VERSION/third_party/skcms"

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
  CC="${CROSS}gcc" > "$WORK/libwebp-configure.log" 2>&1 \
  || { tail -40 "$WORK/libwebp-configure.log" >&2; exit 1; }
make -j"$JOBS" >/dev/null
make install >/dev/null

echo "=== dav1d ($TARGET)"
DAV1D_OPTS="--default-library=static --prefix=$PREFIX --libdir=lib \
  -Denable_tools=false -Denable_tests=false -Denable_examples=false"
[ "$ASM_OK" = 1 ] || DAV1D_OPTS="$DAV1D_OPTS -Denable_asm=false"
[ -z "$CROSS" ] || DAV1D_OPTS="$DAV1D_OPTS --cross-file=$ROOT/cross/$TARGET.meson"
# shellcheck disable=SC2086
meson setup "$WORK/dav1d-build" "$WORK/dav1d-$DAV1D_VERSION" $DAV1D_OPTS > "$WORK/dav1d-configure.log" 2>&1 \
  || { tail -40 "$WORK/dav1d-configure.log" >&2; exit 1; }
ninja -C "$WORK/dav1d-build" >/dev/null
ninja -C "$WORK/dav1d-build" install >/dev/null

cmake_build() {
  name=$1; src=$2; shift 2
  echo "=== $name ($TARGET)"
  env PKG_CONFIG_PATH="$PREFIX/lib/pkgconfig" cmake -S "$src" -B "$WORK/$name-build" \
    -DCMAKE_BUILD_TYPE=Release -DCMAKE_INSTALL_PREFIX="$PREFIX" -DCMAKE_INSTALL_LIBDIR=lib \
    -DCMAKE_PREFIX_PATH="$PREFIX" -DBUILD_SHARED_LIBS=OFF -DBUILD_TESTING=OFF \
    ${CROSS:+"-DCMAKE_TOOLCHAIN_FILE=$ROOT/cross/$TARGET.cmake"} "$@" > "$WORK/$name-configure.log" 2>&1 \
    || { tail -40 "$WORK/$name-configure.log" >&2; exit 1; }
  cmake --build "$WORK/$name-build" -j "$JOBS" >/dev/null
  cmake --install "$WORK/$name-build" >/dev/null
}

cmake_build brotli "$WORK/brotli-$BROTLI_VERSION" -DBROTLI_BUILD_TOOLS=OFF
cmake_build highway "$WORK/highway-$HWY_VERSION" \
  -DHWY_ENABLE_CONTRIB=OFF -DHWY_ENABLE_EXAMPLES=OFF -DHWY_ENABLE_TESTS=OFF
cmake_build libjxl "$WORK/libjxl-$LIBJXL_VERSION" \
  -DJPEGXL_FORCE_SYSTEM_BROTLI=ON -DJPEGXL_FORCE_SYSTEM_HWY=ON -DJPEGXL_ENABLE_SKCMS=ON \
  -DJPEGXL_ENABLE_TOOLS=OFF -DJPEGXL_ENABLE_DOXYGEN=OFF -DJPEGXL_ENABLE_MANPAGES=OFF \
  -DJPEGXL_ENABLE_BENCHMARK=OFF -DJPEGXL_ENABLE_EXAMPLES=OFF -DJPEGXL_ENABLE_JNI=OFF \
  -DJPEGXL_ENABLE_SJPEG=OFF -DJPEGXL_ENABLE_OPENEXR=OFF -DJPEGXL_ENABLE_TCMALLOC=OFF \
  -DJPEGXL_BUNDLE_LIBPNG=OFF

echo "=== ffmpeg ($TARGET)"
cd "$WORK/ffmpeg-$FFMPEG_VERSION"
FF_OPTS=""
[ "$ASM_OK" = 1 ] || FF_OPTS="--disable-x86asm"
[ -z "$CROSS" ] || FF_OPTS="$FF_OPTS --enable-cross-compile --cross-prefix=$CROSS"
# shellcheck disable=SC2086
# --cross-prefix would otherwise make configure demand a <prefix>pkg-config.
env PKG_CONFIG_PATH="$PREFIX/lib/pkgconfig" ./configure \
  --arch="$FF_ARCH" --target-os="$FF_OS" $FF_OPTS \
  --pkg-config=pkg-config \
  --pkg-config-flags=--static \
  --extra-cflags="-I$PREFIX/include" \
  --extra-ldflags="-L$PREFIX/lib -static" \
  --extra-libs="-lstdc++ -lm" \
  --disable-everything \
  --disable-autodetect \
  --disable-network \
  --disable-doc \
  --disable-debug \
  --disable-avdevice \
  --disable-ffplay \
  --enable-ffmpeg --enable-ffprobe \
  --enable-protocol=file \
  --enable-demuxer=mov,matroska,gif,image2,image_jpeg_pipe,image_jpegxl_pipe \
  --enable-decoder=h264,hevc,vp8,vp9,mpeg4,mjpeg,gif,libdav1d,libjxl \
  --enable-parser=h264,hevc,vp8,vp9,av1,mjpeg,gif,jpegxl \
  --enable-encoder=mjpeg,libwebp,libwebp_anim \
  --enable-muxer=image2,webp \
  --enable-filter=scale \
  --enable-libwebp --enable-libdav1d --enable-libjxl > "$WORK/ffmpeg-configure.log" 2>&1 \
  || { tail -40 "$WORK/ffmpeg-configure.log" >&2; exit 1; }
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
cp "$WORK/libjxl-$LIBJXL_VERSION/LICENSE" "$STAGE/licenses/COPYING.libjxl"
cp "$WORK/libjxl-$LIBJXL_VERSION/third_party/skcms/LICENSE" "$STAGE/licenses/COPYING.skcms"
cp "$WORK/highway-$HWY_VERSION/LICENSE-BSD3" "$STAGE/licenses/COPYING.highway"
cp "$WORK/brotli-$BROTLI_VERSION/LICENSE" "$STAGE/licenses/COPYING.brotli"

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
