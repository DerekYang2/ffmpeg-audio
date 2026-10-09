#!/usr/bin/env bash
# Builds an audio-only, LGPL ffmpeg.exe for Windows on x64 or ARM64, with LAME, Opus and Vorbis linked in statically.
# Run it in the Docker image from the Dockerfile, through build.ps1 on Windows:  ./build.sh x64|arm64
set -euo pipefail

ARCH=${1:?"usage: build.sh x64|arm64"}
case "$ARCH" in
    x64) TRIPLE=x86_64-w64-mingw32; FFARCH=x86_64 ;;
    arm64) TRIPLE=aarch64-w64-mingw32; FFARCH=aarch64 ;;
    *) echo "unknown architecture: $ARCH" >&2; exit 2 ;;
esac

ROOT=$(cd "$(dirname "$0")" && pwd)
# shellcheck source=versions.sh
source "$ROOT/versions.sh"
# Downloads and results go next to the scripts. The build itself can go elsewhere, such as the container's own disk,
# which is much faster than a folder shared with Windows.
SOURCES=${SOURCES_DIR:-$ROOT/.cache/sources}
BUILD=${BUILD_DIR:-$ROOT/.cache/build}/$ARCH
PREFIX=$BUILD/prefix
NAME=ffmpeg-$FFMPEG_VERSION-audio-win-$ARCH
DIST=${DIST_DIR:-$ROOT/dist}/$NAME
JOBS=$(nproc)

export PKG_CONFIG_LIBDIR=$PREFIX/lib/pkgconfig
export PKG_CONFIG_PATH=$PREFIX/lib/pkgconfig
export CC=$TRIPLE-clang CXX=$TRIPLE-clang++ AR=llvm-ar RANLIB=llvm-ranlib NM=llvm-nm STRIP=llvm-strip

CMAKE_ARGS=(
    -G Ninja
    -DCMAKE_SYSTEM_NAME=Windows
    -DCMAKE_SYSTEM_PROCESSOR="$FFARCH"
    -DCMAKE_C_COMPILER="$TRIPLE-clang"
    -DCMAKE_RC_COMPILER="$TRIPLE-windres"
    -DCMAKE_FIND_ROOT_PATH="$PREFIX"
    -DCMAKE_INSTALL_PREFIX="$PREFIX"
    -DCMAKE_BUILD_TYPE=Release
    -DBUILD_SHARED_LIBS=OFF
)

fetch() {
    local url=$1 sha=$2 file
    file=$SOURCES/$(basename "$url")
    mkdir -p "$SOURCES"
    if [ ! -f "$file" ]; then
        echo "Downloading $url" >&2
        curl -fsSL --retry 3 -o "$file.part" "$url"
        mv "$file.part" "$file"
    fi
    echo "$sha  $file" | sha256sum -c --quiet - >&2
    echo "$file"
}

# Extracts a fresh copy of a source tarball into the build folder and prints its path.
unpack() {
    local file=$1 dir
    dir=$BUILD/src/$(basename "$file" | sed -E 's/\.tar\.(gz|xz)$//')
    rm -rf "$dir"
    mkdir -p "$BUILD/src"
    tar -xf "$file" -C "$BUILD/src"
    echo "$dir"
}

build_zlib() {
    local dir
    dir=$(unpack "$(fetch "$ZLIB_URL" "$ZLIB_SHA256")")
    make -C "$dir" -f win32/Makefile.gcc -j"$JOBS" CC="$CC" AR="$AR" RC="$TRIPLE-windres" STRIP="$STRIP" libz.a
    install -D -m644 "$dir/libz.a" "$PREFIX/lib/libz.a"
    install -D -m644 "$dir/zlib.h" "$PREFIX/include/zlib.h"
    install -D -m644 "$dir/zconf.h" "$PREFIX/include/zconf.h"
}

build_ogg() {
    local dir
    dir=$(unpack "$(fetch "$OGG_URL" "$OGG_SHA256")")
    cmake -S "$dir" -B "$dir/build" "${CMAKE_ARGS[@]}" -DINSTALL_DOCS=OFF -DBUILD_TESTING=OFF
    cmake --build "$dir/build" --target install
}

build_vorbis() {
    local dir
    dir=$(unpack "$(fetch "$VORBIS_URL" "$VORBIS_SHA256")")
    cmake -S "$dir" -B "$dir/build" "${CMAKE_ARGS[@]}" -DCMAKE_POLICY_VERSION_MINIMUM=3.5 -DOGG_ROOT="$PREFIX"
    cmake --build "$dir/build" --target install
}

build_opus() {
    local dir arch_args=()
    dir=$(unpack "$(fetch "$OPUS_URL" "$OPUS_SHA256")")
    # Opus can't detect CPU features at run time on Windows on Arm. Every ARM64 CPU has NEON, so it doesn't need to.
    # Opus's CMake build presumes NEON without the MAY_HAVE definitions its headers declare the NEON functions under,
    # which its autotools build sets.
    [ "$ARCH" = arm64 ] && arch_args=(-DOPUS_MAY_HAVE_NEON=OFF -DOPUS_PRESUME_NEON=ON
        "-DCMAKE_C_FLAGS=-DOPUS_ARM_MAY_HAVE_NEON -DOPUS_ARM_MAY_HAVE_NEON_INTR")
    # FORTIFY_SOURCE and the stack protector would need libssp, which a static mingw build doesn't link.
    cmake -S "$dir" -B "$dir/build" "${CMAKE_ARGS[@]}" "${arch_args[@]}" \
        -DOPUS_BUILD_PROGRAMS=OFF -DOPUS_BUILD_TESTING=OFF -DOPUS_FORTIFY_SOURCE=OFF -DOPUS_STACK_PROTECTOR=OFF
    cmake --build "$dir/build" --target install
}

build_fdk_aac() {
    local dir
    dir=$(unpack "$(fetch "$FDK_AAC_URL" "$FDK_AAC_SHA256")")
    cmake -S "$dir" -B "$dir/build" "${CMAKE_ARGS[@]}" -DBUILD_PROGRAMS=OFF
    cmake --build "$dir/build" --target install
}

build_lame() {
    local dir
    dir=$(unpack "$(fetch "$LAME_URL" "$LAME_SHA256")")
    # LAME 3.100's config.sub predates aarch64-w64-mingw32.
    cp /usr/share/misc/config.sub /usr/share/misc/config.guess "$dir/" 2>/dev/null \
        || cp /usr/share/automake-*/config.sub /usr/share/automake-*/config.guess "$dir/"
    # The export list names lame_init_old, which 3.100 no longer has. It only matters for DLLs.
    sed -i '/lame_init_old/d' "$dir/include/libmp3lame.sym"
    (cd "$dir" && ./configure --host="$TRIPLE" --prefix="$PREFIX" --disable-shared --enable-static \
        --disable-frontend --disable-decoder --disable-gtktest --enable-nasm=no)
    make -C "$dir" -j"$JOBS" install
}

# Every component FluentDL and FluentSpek use, and nothing else. Grouped by what needs them.
FFMPEG_COMPONENTS=(
    # ffmpeg's command line and filter graphs always need these. configure always builds the buffer sources and sinks.
    --enable-protocol=file,pipe
    --enable-filter=aformat,format,aresample,anull,null,acopy,copy,atrim,trim,asetpts,setpts,scale

    # Reading: the formats FluentDL's Local Explorer lists that FFmpeg can decode, plus cover art in them.
    --enable-demuxer=aa,aac,ac3,aiff,ape,asf,caf,dsf,dts,dtshd,eac3,flac,iff,loas,matroska,mlp,mov,mp3,mpc,mpc8,ogg,tak,truehd,tta,vqf,w64,wav,wv,xwma
    --enable-decoder=aac,aac_latm,ac3,alac,ape,dca,dsd_lsbf,dsd_lsbf_planar,dsd_msbf,dsd_msbf_planar,eac3,flac,mlp,truehd
    --enable-decoder=mp1,mp1float,mp2,mp2float,mp3,mp3float,mpc7,mpc8,opus,vorbis,tak,tta,twinvq,wavpack
    --enable-decoder=wmalossless,wmapro,wmav1,wmav2,wmavoice,sipr,adpcm_ima_wav,adpcm_ms,'pcm_*'
    --enable-decoder=mjpeg,png,bmp
    --enable-parser=aac,aac_latm,ac3,dca,flac,mlp,mpegaudio,opus,vorbis,tak,mjpeg,png
    --enable-bsf=aac_adtstoasc,null

    # Writing: FluentDL's conversions to FLAC, MP3, AAC, ALAC, Vorbis and Opus, its remuxes from MP4 to M4A and from
    # WebM to Opus, cover art copied or re-encoded as PNG, and the 32-bit float WAV that ReplayGain reads. AAC has two
    # encoders: Fraunhofer's libfdk_aac, the better one, and FFmpeg's own aac.
    --enable-encoder=flac,alac,aac,libfdk_aac,libmp3lame,libvorbis,libopus,pcm_s16le,pcm_s24le,pcm_s32le,pcm_f32le,png
    --enable-muxer=flac,mp3,ipod,mp4,mov,ogg,opus,wav,w64,matroska,matroska_audio,webm,adts,null

    # FluentSpek decodes one channel to raw floats. FluentDL's current spectrogram dialog draws a PNG with
    # showspectrumpic.
    --enable-filter=pan,showspectrumpic
    --enable-muxer=pcm_f32le,image2,image2pipe

    # The test suites of both projects generate audio with these.
    --enable-indev=lavfi
    --enable-filter=aevalsrc,sine,anoisesrc,anullsrc,amerge,amix,volume
)

# configure only warns when no name in a comma-separated list matches, so a misspelt name next to a valid one would be
# dropped quietly. This checks each name against configure's own lists. Names may use * as a wildcard.
check_components() {
    local option thing names name list unknown=()
    for option in "${FFMPEG_COMPONENTS[@]}"; do
        thing=${option#--enable-}
        names=${thing#*=}
        thing=${thing%%=*}
        list=" $(cd "$FFMPEG_DIR" && ./configure --list-"${thing}"s | tr -s ' \t\n' ' ') "
        IFS=, read -ra names <<< "$names"
        for name in "${names[@]}"; do
            name=${name//\'/}
            if [[ "$name" == *"*"* ]]; then
                # shellcheck disable=SC2053
                [[ $list =~ \ ${name//\*/[^ ]*}\  ]] || unknown+=("$thing $name")
            else
                [[ $list == *" $name "* ]] || unknown+=("$thing $name")
            fi
        done
    done
    if [ ${#unknown[@]} -gt 0 ]; then
        echo "Not components of FFmpeg $FFMPEG_VERSION:" >&2
        printf '  %s\n' "${unknown[@]}" >&2
        exit 1
    fi
}

build_ffmpeg() {
    local log
    FFMPEG_DIR=$(unpack "$(fetch "$FFMPEG_URL" "$FFMPEG_SHA256")")
    check_components
    log=$BUILD/ffmpeg-configure.log
    (cd "$FFMPEG_DIR" && ./configure \
        --prefix="$PREFIX" \
        --arch="$FFARCH" --target-os=mingw32 --enable-cross-compile \
        --cc="$CC" --cxx="$CXX" --ar="$AR" --ranlib="$RANLIB" --nm="$NM" --strip="$STRIP" \
        --windres="$TRIPLE-windres" \
        --pkg-config=pkg-config --pkg-config-flags=--static \
        --extra-cflags="-I$PREFIX/include" --extra-ldflags="-L$PREFIX/lib -static" \
        --extra-version=audio \
        --disable-everything --disable-autodetect --disable-network --disable-doc --disable-debug \
        --disable-ffplay --disable-ffprobe --disable-shared --enable-static --enable-w32threads \
        --enable-zlib --enable-libmp3lame --enable-libopus --enable-libvorbis --enable-libfdk-aac \
        "${FFMPEG_COMPONENTS[@]}") | tee "$log"
    if grep -q "did not match anything" "$log"; then
        echo "configure didn't recognise some components:" >&2
        grep "did not match anything" "$log" >&2
        exit 1
    fi
    make -C "$FFMPEG_DIR" -j"$JOBS"
    make -C "$FFMPEG_DIR" install
}

package() {
    rm -rf "$DIST" "$DIST.zip"
    mkdir -p "$DIST/licenses"
    cp "$PREFIX/bin/ffmpeg.exe" "$DIST/"
    "$STRIP" "$DIST/ffmpeg.exe"
    cp "$FFMPEG_DIR/COPYING.LGPLv2.1" "$DIST/licenses/FFmpeg-LGPL-2.1.txt"
    cp "$BUILD/src/lame-$LAME_VERSION/COPYING" "$DIST/licenses/LAME-LGPL.txt"
    cp "$BUILD/src/opus-$OPUS_VERSION/COPYING" "$DIST/licenses/Opus.txt"
    cp "$BUILD/src/libogg-$OGG_VERSION/COPYING" "$DIST/licenses/Ogg.txt"
    cp "$BUILD/src/libvorbis-$VORBIS_VERSION/COPYING" "$DIST/licenses/Vorbis.txt"
    cp "$BUILD/src/zlib-$ZLIB_VERSION/LICENSE" "$DIST/licenses/zlib.txt"
    cp "$BUILD/src/fdk-aac-$FDK_AAC_VERSION/NOTICE" "$DIST/licenses/FDK-AAC.txt"
    {
        echo "FFmpeg $FFMPEG_VERSION, audio-only LGPL build for Windows $ARCH"
        echo
        echo "Libraries: Fraunhofer FDK AAC $FDK_AAC_VERSION, LAME $LAME_VERSION, Opus $OPUS_VERSION, libogg $OGG_VERSION, libvorbis $VORBIS_VERSION, zlib $ZLIB_VERSION"
        echo "FFmpeg source: $FFMPEG_URL"
        echo "FDK AAC source: $FDK_AAC_URL"
        echo "Build scripts: https://github.com/DerekYang2/ffmpeg-audio"
        echo
        echo "Configuration:"
        sed -n 's/^#define FFMPEG_CONFIGURATION "\(.*\)"$/\1/p' "$FFMPEG_DIR/config.h" | tr ' ' '\n' | grep -v '^$'
    } > "$DIST/BUILD.txt"
    (cd "$(dirname "$DIST")" && zip -qr "$NAME.zip" "$NAME")
    file "$DIST/ffmpeg.exe"
    ls -l "$DIST/ffmpeg.exe" "$DIST.zip"
}

if [ "${CHECK_ONLY:-}" = 1 ]; then
    FFMPEG_DIR=$(unpack "$(fetch "$FFMPEG_URL" "$FFMPEG_SHA256")")
    check_components
    echo "All components exist in FFmpeg $FFMPEG_VERSION."
    exit 0
fi

build_zlib
build_ogg
build_vorbis
build_opus
build_fdk_aac
build_lame
build_ffmpeg
package
