#!/bin/bash
# Builds scripts/vendor/whisper.xcframework: whisper.cpp and its bundled ggml as one
# static library for macOS arm64, which SwiftPM links through the `whisper` binary target.
#
# Pinned to the same source pair as scripts/vendor/dylibs (whisper.cpp 1.8.3, ggml 0.9.5),
# built with the configuration of those dylibs: Release, Metal with the shader library
# embedded, Accelerate BLAS, backends registered statically, and GGML_NATIVE=OFF so the
# CPU code runs on every Apple silicon Mac (a native build could use instructions an M1
# lacks). The headers in Sources/CWhisper/include are refreshed from the same checkout.
#
# Usage: bash scripts/vendor/build-whisper-xcframework.sh [path-to-whisper.cpp-checkout]
# Without a path the script clones the pinned tag into a temporary directory. Needs cmake
# and Xcode. Afterwards commit the xcframework, the headers and whisper.xcframework.sha256.
set -euo pipefail

WHISPER_TAG="v1.8.3"
WHISPER_COMMIT="2eeeba56e9edd762b4b38467bab96c2517163158"
GGML_VERSION="0.9.5"
DEPLOYMENT_TARGET="14.0"

VENDOR_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_DIR="$(cd "$VENDOR_DIR/../.." && pwd)"
OUTPUT="$VENDOR_DIR/whisper.xcframework"
HEADERS_DIR="$REPO_DIR/Sources/CWhisper/include"

WORK_DIR="$(mktemp -d "${TMPDIR:-/tmp}/whisper-xcframework.XXXXXX")"
trap 'rm -rf "$WORK_DIR"' EXIT

SOURCE_DIR="${1:-}"
if [ -z "$SOURCE_DIR" ]; then
    SOURCE_DIR="$WORK_DIR/whisper.cpp"
    git clone --quiet --depth 1 --branch "$WHISPER_TAG" \
        https://github.com/ggml-org/whisper.cpp.git "$SOURCE_DIR"
fi
SOURCE_DIR="$(cd "$SOURCE_DIR" && pwd)"

ACTUAL_COMMIT="$(git -C "$SOURCE_DIR" rev-parse HEAD)"
if [ "$ACTUAL_COMMIT" != "$WHISPER_COMMIT" ]; then
    echo "FATAL: $SOURCE_DIR is at $ACTUAL_COMMIT, expected $WHISPER_TAG ($WHISPER_COMMIT)." >&2
    exit 1
fi
if [ -n "$(git -C "$SOURCE_DIR" status --porcelain)" ]; then
    echo "FATAL: $SOURCE_DIR has local changes." >&2
    exit 1
fi
ACTUAL_GGML="$(sed -nE 's/^set\(GGML_VERSION_(MAJOR|MINOR|PATCH) ([0-9]+)\)$/\2/p' \
    "$SOURCE_DIR/ggml/CMakeLists.txt" | paste -sd. -)"
if [ "$ACTUAL_GGML" != "$GGML_VERSION" ]; then
    echo "FATAL: bundled ggml is $ACTUAL_GGML, expected $GGML_VERSION." >&2
    exit 1
fi

BUILD_DIR="$WORK_DIR/build"
# Path maps keep the temporary checkout and build paths (from __FILE__ in asserts) out of
# the objects, so a rebuild from the same source produces the same bytes.
PREFIX_MAPS="-ffile-prefix-map=$SOURCE_DIR=whisper.cpp -ffile-prefix-map=$BUILD_DIR=build"
cmake -S "$SOURCE_DIR" -B "$BUILD_DIR" \
    -DCMAKE_C_FLAGS="$PREFIX_MAPS" \
    -DCMAKE_CXX_FLAGS="$PREFIX_MAPS" \
    -DCMAKE_OBJC_FLAGS="$PREFIX_MAPS" \
    -DCMAKE_BUILD_TYPE=Release \
    -DCMAKE_OSX_ARCHITECTURES=arm64 \
    -DCMAKE_OSX_DEPLOYMENT_TARGET="$DEPLOYMENT_TARGET" \
    -DBUILD_SHARED_LIBS=OFF \
    -DGGML_NATIVE=OFF \
    -DGGML_METAL=ON \
    -DGGML_METAL_EMBED_LIBRARY=ON \
    -DGGML_BLAS=ON \
    -DGGML_OPENMP=OFF \
    -DWHISPER_BUILD_EXAMPLES=OFF \
    -DWHISPER_BUILD_TESTS=OFF \
    -DWHISPER_BUILD_SERVER=OFF \
    -DWHISPER_SDL2=OFF
cmake --build "$BUILD_DIR" --config Release --parallel "$(sysctl -n hw.ncpu)"

# One archive holding whisper and every ggml library. ZERO_AR_DATE keeps libtool and
# strip from writing timestamps, so a rebuild from the same source produces the same bytes.
export ZERO_AR_DATE=1
LIBS=()
while IFS= read -r lib; do LIBS+=("$lib"); done < <(find "$BUILD_DIR" -name '*.a' | sort)
for required in libwhisper.a libggml.a libggml-base.a libggml-cpu.a libggml-metal.a libggml-blas.a; do
    printf '%s\n' "${LIBS[@]}" | grep -q "/$required$" \
        || { echo "FATAL: $required was not built." >&2; exit 1; }
done
COMBINED="$WORK_DIR/libwhisper.a"
libtool -static -no_warning_for_no_symbols -o "$COMBINED" "${LIBS[@]}"
strip -S "$COMBINED"

rm -rf "$OUTPUT"
xcodebuild -create-xcframework -library "$COMBINED" -output "$OUTPUT" >/dev/null

# Headers from the same checkout, so the module always matches the library.
for header in "$HEADERS_DIR"/*.h; do
    name="$(basename "$header")"
    source="$(find "$SOURCE_DIR/include" "$SOURCE_DIR/ggml/include" -name "$name" | head -1)"
    [ -n "$source" ] || { echo "FATAL: $name not found in the checkout." >&2; exit 1; }
    cp "$source" "$header"
done

(cd "$VENDOR_DIR" && shasum -a 256 whisper.xcframework/Info.plist \
    whisper.xcframework/*/libwhisper.a > whisper.xcframework.sha256)

echo "Built $OUTPUT from whisper.cpp $WHISPER_TAG with ggml $GGML_VERSION"
du -sh "$OUTPUT"
