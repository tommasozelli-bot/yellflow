#!/usr/bin/env bash
#
# Rebuilds vendor/transcribe/ — the speech engine behind the Parakeet option —
# from handy-computer/transcribe.cpp (MIT, the engine used by Handy), pinned
# to one commit. Run it only to update the engine; build.sh uses the committed
# result and never compiles C++.
#
# Output: one universal libtranscribe.dylib (arm64 with Metal, x86_64 CPU only)
# with ggml linked INSIDE it and only the transcribe_* symbols exported, so it
# can't collide with the ggml that lives inside whisper.framework.
#
set -euo pipefail

REPO="https://github.com/handy-computer/transcribe.cpp"
COMMIT="5700f127e38dd53c4735ea23ef743b4b538eacd4" # 27/10/2026, transcribe.cpp 0.4.x

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
OUT="$HERE/transcribe"
WORK="${TRANSCRIBE_WORK:-/tmp/yellflow-transcribe}"
SRC="$WORK/src"
mkdir -p "$WORK"

echo "▸ 1/4  Source at ${COMMIT}…"
if [[ ! -d "$SRC/.git" ]]; then
    git clone --quiet "$REPO" "$SRC"
fi
git -C "$SRC" fetch --quiet --depth 1 origin "$COMMIT" 2>/dev/null || true
git -C "$SRC" checkout --quiet "$COMMIT"

echo "▸ 2/4  cmake…"
# The Command Line Tools have no cmake. The pip wheel ships a universal binary;
# it is called through `arch` because the system Python is x86_64 and a cmake
# started from it would configure an Intel build without Metal (31/10/2026).
CMAKE="$(command -v cmake || true)"
if [[ -z "$CMAKE" ]]; then
    if [[ ! -x "$WORK/venv/bin/python3" ]]; then
        python3 -m venv "$WORK/venv"
        "$WORK/venv/bin/pip" install --quiet cmake
    fi
    CMAKE="$(ls "$WORK"/venv/lib/python3*/site-packages/cmake/data/bin/cmake)"
fi

build_slice() { # arch, extra cmake flags…
    local arch="$1"; shift
    local dir="$WORK/build-$arch"
    echo "▸ 3/4  Compiling ${arch}…"
    arch "-$arch" "$CMAKE" -S "$SRC" -B "$dir" -DCMAKE_BUILD_TYPE=Release \
        -DCMAKE_OSX_ARCHITECTURES="$arch" -DCMAKE_OSX_DEPLOYMENT_TARGET=13.3 \
        -DTRANSCRIBE_BUILD_TESTS=OFF -DTRANSCRIBE_BUILD_EXAMPLES=OFF \
        -DGGML_NATIVE=OFF "$@" > "$WORK/cmake-$arch.log"
    nice -n 10 arch "-$arch" "$CMAKE" --build "$dir" -j "${JOBS:-2}" --target transcribe >> "$WORK/cmake-$arch.log"
    local libs=("$dir/src/libtranscribe.a" "$dir"/ggml/src/libggml*.a)
    local frameworks=(-framework Accelerate -framework Foundation)
    if [[ -f "$dir/ggml/src/ggml-metal/libggml-metal.a" ]]; then
        libs+=("$dir/ggml/src/ggml-metal/libggml-metal.a")
        frameworks+=(-framework Metal -framework MetalKit)
    fi
    clang++ -arch "$arch" -dynamiclib -mmacosx-version-min=13.3 \
        -install_name @rpath/libtranscribe.dylib \
        -Wl,-all_load "${libs[@]}" -Wl,-dead_strip \
        -Wl,-exported_symbol,'_transcribe_*' \
        "${frameworks[@]}" -lc++ -lm \
        -o "$WORK/libtranscribe-$arch.dylib"
}

build_slice arm64 -DTRANSCRIBE_METAL=ON -DGGML_METAL_EMBED_LIBRARY=ON
# Conservative baseline plus AVX2/FMA: every Mac Intel since 2013 (Haswell) has them.
build_slice x86_64 -DTRANSCRIBE_METAL=OFF -DTRANSCRIBE_X86_CONSERVATIVE=ON \
    -DGGML_AVX=ON -DGGML_AVX2=ON -DGGML_FMA=ON -DGGML_F16C=ON

echo "▸ 4/4  Universal library…"
mkdir -p "$OUT/lib" "$OUT/include"
lipo -create "$WORK/libtranscribe-arm64.dylib" "$WORK/libtranscribe-x86_64.dylib" -output "$OUT/lib/libtranscribe.dylib"
cp "$SRC/include/transcribe.h" "$OUT/include/transcribe.h"
cp "$SRC/LICENSE" "$OUT/LICENSE"
echo "$COMMIT" > "$OUT/COMMIT"
lipo -info "$OUT/lib/libtranscribe.dylib"
if nm -gU "$OUT/lib/libtranscribe.dylib" | grep -q " _ggml_"; then
    echo "❌ ggml symbols are exported: they would collide with whisper.framework" >&2
    exit 1
fi
echo "✅ $OUT/lib/libtranscribe.dylib ($(du -h "$OUT/lib/libtranscribe.dylib" | cut -f1))"
