#!/usr/bin/env bash
set -euo pipefail

OUT_ROOT="${1:-$PWD/out/macos-arm64-runtime}"
SRC_ROOT="$OUT_ROOT/src"
BUILD_ROOT="$OUT_ROOT/build"
PREFIX="$OUT_ROOT/prefix"
ARTIFACT_ROOT="$OUT_ROOT/artifact"
JOBS="${JOBS:-$(sysctl -n hw.ncpu 2>/dev/null || echo 3)}"

FFMPEG_VERSION="8.1.2"
X265_VERSION="4.2"
ZIMG_VERSION="3.0.6"
DEPLOYMENT_TARGET="12.0"

FFMPEG_URL="https://ffmpeg.org/releases/ffmpeg-${FFMPEG_VERSION}.tar.xz"
X265_URL="https://download.videolan.org/pub/videolan/x265/x265_${X265_VERSION}.tar.gz"
ZIMG_URL="https://github.com/sekrit-twc/zimg/archive/refs/tags/release-${ZIMG_VERSION}.tar.gz"

FFMPEG_SHA256="464beb5e7bf0c311e68b45ae2f04e9cc2af88851abb4082231742a74d97b524c"
X265_SHA256="40b1ea0453e0309f0eba934e0ddf533f8f6295966679e8894e8f1c1c8d5e1210"
ZIMG_SHA256="be89390f13a5c9b2388ce0f44a5e89364a20c1c57ce46d382b1fcc3967057577"

rm -rf "$OUT_ROOT"
mkdir -p "$SRC_ROOT" "$BUILD_ROOT" "$PREFIX" "$ARTIFACT_ROOT"

export MACOSX_DEPLOYMENT_TARGET="$DEPLOYMENT_TARGET"
export PATH="$PREFIX/bin:$PATH"
export PKG_CONFIG_PATH="$PREFIX/lib/pkgconfig"
export CFLAGS="-O3 -mmacosx-version-min=$DEPLOYMENT_TARGET"
export CXXFLAGS="-O3 -mmacosx-version-min=$DEPLOYMENT_TARGET"
export LDFLAGS="-mmacosx-version-min=$DEPLOYMENT_TARGET -L$PREFIX/lib"
export CPPFLAGS="-I$PREFIX/include"

download_verified() {
  local url="$1" destination="$2" expected="$3"
  curl --fail --location --retry 3 --retry-delay 2 "$url" -o "$destination"
  local actual
  actual="$(shasum -a 256 "$destination" | awk '{print $1}')"
  if [[ "$actual" != "$expected" ]]; then
    echo "SHA-256 mismatch for $url: expected $expected, got $actual" >&2
    exit 1
  fi
}

download_verified "$FFMPEG_URL" "$SRC_ROOT/ffmpeg.tar.xz" "$FFMPEG_SHA256"
download_verified "$X265_URL" "$SRC_ROOT/x265.tar.gz" "$X265_SHA256"
download_verified "$ZIMG_URL" "$SRC_ROOT/zimg.tar.gz" "$ZIMG_SHA256"

mkdir -p "$SRC_ROOT/ffmpeg" "$SRC_ROOT/x265" "$SRC_ROOT/zimg"
tar -xf "$SRC_ROOT/ffmpeg.tar.xz" --strip-components=1 -C "$SRC_ROOT/ffmpeg"
tar -xf "$SRC_ROOT/x265.tar.gz" --strip-components=1 -C "$SRC_ROOT/x265"
tar -xf "$SRC_ROOT/zimg.tar.gz" --strip-components=1 -C "$SRC_ROOT/zimg"

X265_BUILD="$BUILD_ROOT/x265"
mkdir -p "$X265_BUILD"
pushd "$X265_BUILD" >/dev/null

cmake "$SRC_ROOT/x265/source"   -DCMAKE_BUILD_TYPE=Release   -DCMAKE_OSX_ARCHITECTURES=arm64   -DCMAKE_OSX_DEPLOYMENT_TARGET="$DEPLOYMENT_TARGET"   -DHIGH_BIT_DEPTH=ON -DMAIN12=ON -DEXPORT_C_API=OFF   -DENABLE_CLI=OFF -DENABLE_SHARED=OFF
cmake --build . --parallel "$JOBS"
mv libx265.a libx265_main12.a
rm -rf CMakeCache.txt CMakeFiles

cmake "$SRC_ROOT/x265/source"   -DCMAKE_BUILD_TYPE=Release   -DCMAKE_OSX_ARCHITECTURES=arm64   -DCMAKE_OSX_DEPLOYMENT_TARGET="$DEPLOYMENT_TARGET"   -DHIGH_BIT_DEPTH=ON -DMAIN10=ON -DEXPORT_C_API=OFF   -DENABLE_CLI=OFF -DENABLE_SHARED=OFF
cmake --build . --parallel "$JOBS"
mv libx265.a libx265_main10.a
rm -rf CMakeCache.txt CMakeFiles

cmake "$SRC_ROOT/x265/source"   -DCMAKE_BUILD_TYPE=Release   -DCMAKE_INSTALL_PREFIX="$PREFIX"   -DCMAKE_OSX_ARCHITECTURES=arm64   -DCMAKE_OSX_DEPLOYMENT_TARGET="$DEPLOYMENT_TARGET"   -DEXTRA_LIB="x265_main10.a;x265_main12.a"   -DEXTRA_LINK_FLAGS="-L."   -DLINKED_10BIT=ON -DLINKED_12BIT=ON   -DENABLE_CLI=OFF -DENABLE_SHARED=OFF
cmake --build . --parallel "$JOBS"
mv libx265.a libx265_main.a
libtool -static -o libx265.a libx265_main.a libx265_main10.a libx265_main12.a
cmake --install .
mkdir -p "$PREFIX/lib/pkgconfig"
cat > "$PREFIX/lib/pkgconfig/x265.pc" <<EOF
prefix=$PREFIX
exec_prefix=\${prefix}
libdir=\${prefix}/lib
includedir=\${prefix}/include

Name: x265
Description: H.265/HEVC encoder library
Version: $X265_VERSION
Libs: -L\${libdir} -lx265
Libs.private: -lc++ -lm
Cflags: -I\${includedir}
EOF
pkg-config --modversion x265
pkg-config --libs --static x265
popd >/dev/null

pushd "$SRC_ROOT/zimg" >/dev/null
if command -v glibtoolize >/dev/null 2>&1; then
  export LIBTOOLIZE=glibtoolize
fi
./autogen.sh
./configure --prefix="$PREFIX" --disable-shared --enable-static
make -j"$JOBS"
make install
popd >/dev/null

pushd "$SRC_ROOT/ffmpeg" >/dev/null
./configure   --prefix="$PREFIX"   --arch=arm64   --target-os=darwin   --cc=clang   --cxx=clang++   --disable-shared   --enable-static   --disable-debug   --disable-doc   --disable-ffplay   --disable-autodetect   --enable-gpl   --enable-libx265   --enable-libzimg   --enable-videotoolbox   --enable-audiotoolbox   --pkg-config-flags="--static"   --extra-cflags="-I$PREFIX/include -mmacosx-version-min=$DEPLOYMENT_TARGET"   --extra-cxxflags="-I$PREFIX/include -mmacosx-version-min=$DEPLOYMENT_TARGET"   --extra-ldflags="-L$PREFIX/lib -mmacosx-version-min=$DEPLOYMENT_TARGET"   --extra-libs="-lc++"
make -j"$JOBS"
make install
popd >/dev/null

FFMPEG="$PREFIX/bin/ffmpeg"
FFPROBE="$PREFIX/bin/ffprobe"
test -x "$FFMPEG"
test -x "$FFPROBE"

FFMPEG_LINE="$("$FFMPEG" -version | head -n 1)"
[[ "$FFMPEG_LINE" == ffmpeg\ version\ "$FFMPEG_VERSION"* ]]
X265_OUTPUT="$("$FFMPEG" -hide_banner -loglevel info -f lavfi -i "color=c=black:s=64x64:r=1"   -frames:v 1 -an -c:v libx265 -preset ultrafast -x265-params "log-level=info" -f null - 2>&1)"
grep -Eq "HEVC encoder version[[:space:]]+$X265_VERSION([+[:space:]]|$)" <<<"$X265_OUTPUT"
"$FFMPEG" -hide_banner -filters | grep -Eq '[[:space:]]zscale[[:space:]]'

for binary in "$FFMPEG" "$FFPROBE"; do
  file "$binary" | grep -q 'arm64'
  if otool -L "$binary" | tail -n +2 | grep -Ev '^[[:space:]]+(/usr/lib/|/System/Library/)' | grep -q .; then
    echo "Non-system dynamic dependency in $binary:" >&2
    otool -L "$binary" >&2
    exit 1
  fi
done

cp "$FFMPEG" "$ARTIFACT_ROOT/ffmpeg"
cp "$FFPROBE" "$ARTIFACT_ROOT/ffprobe"
chmod 0755 "$ARTIFACT_ROOT/ffmpeg" "$ARTIFACT_ROOT/ffprobe"

{
  echo "ffmpeg_version=$FFMPEG_VERSION"
  echo "x265_version=$X265_VERSION"
  echo "zimg_version=$ZIMG_VERSION"
  echo "architecture=arm64"
  echo "deployment_target=$DEPLOYMENT_TARGET"
  echo "ffmpeg_sha256=$(shasum -a 256 "$ARTIFACT_ROOT/ffmpeg" | awk '{print $1}')"
  echo "ffprobe_sha256=$(shasum -a 256 "$ARTIFACT_ROOT/ffprobe" | awk '{print $1}')"
  echo "$FFMPEG_LINE"
  grep -m1 'HEVC encoder version' <<<"$X265_OUTPUT"
} > "$ARTIFACT_ROOT/runtime-build.txt"

cat "$ARTIFACT_ROOT/runtime-build.txt"
