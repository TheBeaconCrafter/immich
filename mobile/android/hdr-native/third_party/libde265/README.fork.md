# libde265 (vendored)

Unmodified source of the `libde265/` library directory from
[libde265 v1.1.3](https://github.com/strukturag/libde265/releases/tag/v1.1.3)
(`libde265-1.1.3.tar.gz`, SHA-256 `554228bd17788c99a7e63b37ab5634722190e6e2bf60c1dcb01cef328e133905`),
plus a hand-written `de265-version.h` in place of the CMake-generated one.

It is licensed under the GNU LGPL v3 (see `COPYING` and `libde265/COPYING`) and is built into its own shared
library (`libhdr_native.so`), which only decodes the monochrome HEVC gain map tiles of iPhone HEIC photos.
Android's own HEVC decoders do not support the Range Extensions profile those tiles use.

To update, replace the files in `libde265/` from a newer release and adjust `de265-version.h`.
