# ffmpeg-builds

Trimmed static builds of ffmpeg and ffprobe for the
[monbooru](https://github.com/monbooru/monbooru) bundles.

## What is inside

- Demuxers: mov (mp4), matroska (webm), gif, image2, jpeg pipe
- Decoders: h264, hevc, vp8, vp9, mpeg4, mjpeg, gif, and AV1 via
  [dav1d](https://code.videolan.org/videolan/dav1d)
- Encoders: mjpeg and animated WebP via
  [libwebp](https://chromium.googlesource.com/webm/libwebp)
- Muxers: image2, webp
- Filters: scale (plus what the ffmpeg tool itself requires)
- Protocols: file, nothing else

Everything else is disabled. In particular these binaries cannot
encode video, cannot touch the network, and will refuse codecs outside
the list above.

## Targets and artifacts

| Target | Toolchain | Archive |
|---|---|---|
| linux64 | native gcc, static | `ffmpeg-<version>-mb<rev>-linux64.tar.xz` |
| linuxarm64 | aarch64-linux-gnu cross, static | `ffmpeg-<version>-mb<rev>-linuxarm64.tar.xz` |
| win64 | mingw-w64 cross, static | `ffmpeg-<version>-mb<rev>-win64.zip` |

Each archive holds `bin/ffmpeg`, `bin/ffprobe` and the licence texts.
A `.sha256` file sits beside each archive on the release.

Release tags are `v<ffmpeg version>-mb<rev>`, where the `mb` revision
bumps for a rebuild of the same ffmpeg (a library bump, a flag fix).

## Reproducing

```sh
./build.sh linux64
```

## Licensing

The build scripts in this repository are MIT. The binaries they
produce are LGPL-2.1-or-later ffmpeg builds (no `--enable-gpl`
components) statically linked with libwebp (BSD-3-Clause) and dav1d
(BSD-2-Clause); each archive ships the corresponding licence texts
under `licenses/`. The exact source versions and checksums are pinned
in `versions.sh`.
