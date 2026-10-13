#!/bin/bash
set -e

# Versions
VPX_VERSION=1.13.0
MBEDTLS_VERSION=3.4.1
FFMPEG_VERSION=6.0
DAVS2_VERSION=1.7

# Directories
BASE_DIR=$(cd "$(dirname "$0")" && pwd)
BUILD_DIR=$BASE_DIR/build
OUTPUT_DIR=$BASE_DIR/output
SOURCES_DIR=$BASE_DIR/sources
PATCH_DIR=$BASE_DIR/patches
FFMPEG_DIR=$SOURCES_DIR/ffmpeg-$FFMPEG_VERSION
VPX_DIR=$SOURCES_DIR/libvpx-$VPX_VERSION
MBEDTLS_DIR=$SOURCES_DIR/mbedtls-$MBEDTLS_VERSION
DAVS2_DIR=$SOURCES_DIR/davs2-$DAVS2_VERSION
UAVS3D_DIR=$SOURCES_DIR/uavs3d

# Configuration
ANDROID_ABIS="x86 x86_64 armeabi-v7a arm64-v8a"
ANDROID_PLATFORM=21
# NOTE: 这里必须是真实存在的 ffmpeg 解码器名。
# "avs3" 在 ffmpeg 6.0 里【没有对应解码器】（只有 avs3 demuxer/parser），
# configure 的 --enable-decoder=avs3 会被静默吞掉不报错 —— 这正是旧 AAR
# "编了但实际没有 AVS3 解码器"的原因。AVS3 解码请用 libuavs3d wrapper。
ENABLED_DECODERS="vorbis opus flac alac pcm_mulaw pcm_alaw mp3 amrnb amrwb aac ac3 eac3 dca mlp truehd h264 hevc mpeg2video mpegvideo libvpx_vp8 libvpx_vp9 cavs libuavs3d libdavs2"
JOBS=$(nproc 2>/dev/null || sysctl -n hw.ncpu 2>/dev/null || sysctl -n hw.physicalcpu 2>/dev/null || echo 4)

# Set up host platform variables
HOST_PLATFORM="linux-x86_64"
case "$OSTYPE" in
darwin*) HOST_PLATFORM="darwin-x86_64" ;;
linux*) HOST_PLATFORM="linux-x86_64" ;;
msys)
  case "$(uname -m)" in
  x86_64) HOST_PLATFORM="windows-x86_64" ;;
  i686) HOST_PLATFORM="windows" ;;
  esac
  ;;
esac

# Build tools
TOOLCHAIN_PREFIX="${ANDROID_NDK_HOME}/toolchains/llvm/prebuilt/${HOST_PLATFORM}"
CMAKE_EXECUTABLE="${ANDROID_SDK_HOME}/cmake/${ANDROID_CMAKE_VERSION}/bin/cmake"

# Check if sdkmanager is in PATH
if command -v sdkmanager &> /dev/null; then
  # Use sdkmanager from PATH
  echo "Using sdkmanager from PATH"
  echo y | sdkmanager --sdk_root="${ANDROID_SDK_HOME}" "cmake;${ANDROID_CMAKE_VERSION}"
else
  # Use sdkmanager from Android SDK
  SDKMANAGER_EXECUTABLE="${ANDROID_SDK_HOME}/cmdline-tools/latest/bin/sdkmanager"
  if [[ -x "$SDKMANAGER_EXECUTABLE" ]]; then
    echo "Using sdkmanager from Android SDK"
    echo y | "$SDKMANAGER_EXECUTABLE" --sdk_root="${ANDROID_SDK_HOME}" "cmake;${ANDROID_CMAKE_VERSION}"
  else
    echo "Error: sdkmanager not found in PATH or Android SDK"
    exit 1
  fi
fi

mkdir -p $SOURCES_DIR

function downloadLibVpx() {
  pushd $SOURCES_DIR
  echo "Downloading Vpx source code of version $VPX_VERSION..."
  VPX_FILE=libvpx-$VPX_VERSION.tar.gz
  curl -L "https://github.com/webmproject/libvpx/archive/refs/tags/v${VPX_VERSION}.tar.gz" -o $VPX_FILE
  [ -e $VPX_FILE ] || { echo "$VPX_FILE does not exist. Exiting..."; exit 1; }
  tar -zxf $VPX_FILE
  rm $VPX_FILE
  popd
}

function downloadMbedTLS() {
  pushd $SOURCES_DIR
  echo "Downloading mbedtls source code of version $MBEDTLS_VERSION..."
  MBEDTLS_FILE=mbedtls-$MBEDTLS_VERSION.tar.gz
  curl -L "https://github.com/Mbed-TLS/mbedtls/archive/refs/tags/v${MBEDTLS_VERSION}.tar.gz" -o $MBEDTLS_FILE
  [ -e $MBEDTLS_FILE ] || { echo "$MBEDTLS_FILE does not exist. Exiting..."; exit 1; }
  tar -zxf $MBEDTLS_FILE
  rm $MBEDTLS_FILE
  popd
}

function downloadFfmpeg() {
  pushd $SOURCES_DIR
  echo "Downloading Ffmpeg source code of version $FFMPEG_VERSION..."
  FFMPEG_FILE=ffmpeg-$FFMPEG_VERSION.tar.gz
  curl -L "https://ffmpeg.org/releases/ffmpeg-${FFMPEG_VERSION}.tar.gz" -o $FFMPEG_FILE
  [ -e $FFMPEG_FILE ] || { echo "$FFMPEG_FILE does not exist. Exiting..."; exit 1; }
  tar -zxf $FFMPEG_FILE
  rm $FFMPEG_FILE
  popd
}

function downloadDavs2() {
  pushd $SOURCES_DIR
  echo "Downloading davs2 source code of version $DAVS2_VERSION..."
  if [[ ! -d "davs2-$DAVS2_VERSION" ]]; then
    git clone --branch $DAVS2_VERSION https://github.com/pkuvcl/davs2.git davs2-$DAVS2_VERSION
  fi
  popd
}

function buildLibVpx() {
  pushd $VPX_DIR

  VPX_AS=${TOOLCHAIN_PREFIX}/bin/llvm-as
  for ABI in $ANDROID_ABIS; do
    # Set up environment variables
    case $ABI in
    armeabi-v7a)
      EXTRA_BUILD_FLAGS="--force-target=armv7-android-gcc --disable-neon --enable-pic"
      TOOLCHAIN=armv7a-linux-androideabi21-
      ;;
    arm64-v8a)
      EXTRA_BUILD_FLAGS="--force-target=armv8-android-gcc --enable-pic"
      TOOLCHAIN=aarch64-linux-android21-
      ;;
    x86)
      EXTRA_BUILD_FLAGS="--force-target=x86-android-gcc --disable-sse2 --disable-sse3 --disable-ssse3 --disable-sse4_1 --disable-avx --disable-avx2 --enable-pic"
      VPX_AS=${TOOLCHAIN_PREFIX}/bin/yasm
      TOOLCHAIN=i686-linux-android21-
      ;;
    x86_64)
      EXTRA_BUILD_FLAGS="--force-target=x86_64-android-gcc --disable-sse2 --disable-sse3 --disable-ssse3 --disable-sse4_1 --disable-avx --disable-avx2 --enable-pic --disable-neon --disable-neon-asm"
      VPX_AS=${TOOLCHAIN_PREFIX}/bin/yasm
      TOOLCHAIN=x86_64-linux-android21-
      ;;
    *)
      echo "Unsupported architecture: $ABI"
      exit 1
      ;;
    esac

    CC=${TOOLCHAIN_PREFIX}/bin/${TOOLCHAIN}clang \
      CXX=${CC}++ \
      LD=${CC} \
      AR=${TOOLCHAIN_PREFIX}/bin/llvm-ar \
      AS=${VPX_AS} \
      STRIP=${TOOLCHAIN_PREFIX}/bin/llvm-strip \
      NM=${TOOLCHAIN_PREFIX}/bin/llvm-nm \
      LDFLAGS="-Wl,-z,max-page-size=16384" \
      ./configure \
      --prefix=$BUILD_DIR/external/$ABI \
      --libc="${TOOLCHAIN_PREFIX}/sysroot" \
      --enable-vp8 \
      --enable-vp9 \
      --enable-static \
      --disable-shared \
      --disable-examples \
      --disable-docs \
      --enable-realtime-only \
      --enable-install-libs \
      --enable-multithread \
      --disable-webm-io \
      --disable-libyuv \
      --enable-better-hw-compatibility \
      --disable-runtime-cpu-detect \
      ${EXTRA_BUILD_FLAGS}

    make clean
    make -j$JOBS
    make install
  done
  popd
}

function buildMbedTLS() {
    pushd $MBEDTLS_DIR

    for ABI in $ANDROID_ABIS; do

      CMAKE_BUILD_DIR=$MBEDTLS_DIR/mbedtls_build_${ABI}
      rm -rf ${CMAKE_BUILD_DIR}
      mkdir -p ${CMAKE_BUILD_DIR}
      cd ${CMAKE_BUILD_DIR}

      ${CMAKE_EXECUTABLE} .. \
       -DANDROID_PLATFORM=${ANDROID_PLATFORM} \
       -DANDROID_ABI=$ABI \
       -DCMAKE_TOOLCHAIN_FILE=${ANDROID_NDK_HOME}/build/cmake/android.toolchain.cmake \
       -DCMAKE_INSTALL_PREFIX=$BUILD_DIR/external/$ABI \
       -DCMAKE_SHARED_LINKER_FLAGS="-Wl,-z,max-page-size=16384" \
       -DENABLE_TESTING=0

      make -j$JOBS
      make install

    done
    popd
}

function applyPatch() {
  # applyPatch <patchfile> [required|optional]
  # 用 git apply --check 验证；失败时检查"是否已应用"（reverse --check）；
  # 两者都不成立：required 直接 exit 1（绝不让 CI 产出一个缺东西的库），
  # optional 只告警（调用方另有兜底机制）。
  local patch_file="$1"
  local mode="${2:-required}"
  local name
  name=$(basename "$patch_file")

  if git apply --check "$patch_file" 2>/dev/null; then
    git apply "$patch_file"
    echo "[OK] $name applied"
  elif git apply --reverse --check "$patch_file" 2>/dev/null; then
    echo "[SKIP] $name already applied"
  elif [ "$mode" = "optional" ]; then
    echo "::warning::$name 无法干净应用 —— 上游源码结构变了？仅依赖调用方的兜底机制"
  else
    echo "::error::$name 无法应用 —— 上游源码结构变了？请核对补丁与上游版本"
    git apply --check "$patch_file" || true
    exit 1
  fi
}

function buildDavs2() {
  pushd $DAVS2_DIR

  # 10bit + flush 崩溃修复（补丁详见 ffmpeg/patches/README.md，
  # 对 davs2 1.7 实测可干净应用；davs2 1.7 已自带 seek 死锁修复，无需该补丁）
  applyPatch "$PATCH_DIR/davs2-10bit.patch"
  applyPatch "$PATCH_DIR/davs2-flush-crash.patch"

  for ABI in $ANDROID_ABIS; do
    # Set up environment variables
    case $ABI in
    armeabi-v7a)
      TOOLCHAIN=armv7a-linux-androideabi21-
      HOST_TRIPLE=armv7a-linux-android
      ;;
    arm64-v8a)
      TOOLCHAIN=aarch64-linux-android21-
      HOST_TRIPLE=aarch64-linux-android
      ;;
    x86)
      TOOLCHAIN=i686-linux-android21-
      HOST_TRIPLE=i686-linux-android
      ;;
    x86_64)
      TOOLCHAIN=x86_64-linux-android21-
      HOST_TRIPLE=x86_64-linux-android
      ;;
    *)
      echo "Unsupported architecture: $ABI"
      exit 1
      ;;
    esac

    # davs2 configure script is in build/linux/
    cd build/linux

    CC=${TOOLCHAIN_PREFIX}/bin/${TOOLCHAIN}clang \
    CXX=${CC}++ \
    LD=${CC} \
    AR=${TOOLCHAIN_PREFIX}/bin/llvm-ar \
    STRIP=${TOOLCHAIN_PREFIX}/bin/llvm-strip \
    NM=${TOOLCHAIN_PREFIX}/bin/llvm-nm \
    PKG_CONFIG_PATH=$BUILD_DIR/external/$ABI/lib/pkgconfig \
    ./configure \
      --prefix=$BUILD_DIR/external/$ABI \
      --host=$HOST_TRIPLE \
      --disable-asm \
      --bit-depth=10 \
      --extra-cflags="-fPIC -I$BUILD_DIR/external/$ABI/include" \
      --extra-ldflags="-L$BUILD_DIR/external/$ABI/lib"

    make clean
    # davs2 Makefile targets: lib-static, install-lib-static (NOT 'lib')
    # 'make' without target also builds test executable which fails on Android
    make -j$JOBS lib-static
    make install-lib-static

    # Fix davs2.pc Version field (version.sh may fail with git clone --branch)
    PC_FILE="$BUILD_DIR/external/$ABI/lib/pkgconfig/davs2.pc"
    if [ -f "$PC_FILE" ]; then
      echo "=== davs2.pc before fix ==="
      cat "$PC_FILE"
      if ! grep -q "^Version: 1" "$PC_FILE"; then
        if grep -q "^Version:" "$PC_FILE"; then
          sed -i "s/^Version:.*/Version: 1.7.0/" "$PC_FILE"
        else
          sed -i "/^Name:/a Version: 1.7.0" "$PC_FILE"
        fi
        echo "=== davs2.pc after fix ==="
        cat "$PC_FILE"
      fi
    fi

    # Go back to davs2 root for next ABI
    cd ../..
  done
  popd
}

function downloadUavs3d() {
  if [[ ! -d "$UAVS3D_DIR" ]]; then
    echo "Cloning uavs3d (AVS3-P2/IEEE1857.10 video decoder, master) ..."
    # 与 mpv-android-avs CI 保持一致：master + depth 1。
    # uavs3d 没有稳定的分支/tag 可 pin（上游 master 即发布线），
    # 版本号由 version.sh 生成 1.2.x（shallow clone 时恒为 1.2.1，
    # 满足 ffmpeg configure 的 "uavs3d >= 1.1.41" 要求）。
    git clone --depth 1 https://github.com/uavs3/uavs3d.git "$UAVS3D_DIR"
  fi
}

function buildUavs3d() {
  # AVS3 视频解码器（uavs3d）。ffmpeg 通过 --enable-libuavs3d 使用其
  # libavcodec/libuavs3d.c wrapper（解码器注册名 "libuavs3d"，
  # wrapper 原生支持 8bit/10bit 输出 pix_fmt 选择）。
  #
  # 编译配方与 Android 适配改法与 sggc/mpv-android-avs CI 对齐（已验证）：
  #   - 静态库（默认 BUILD_SHARED_LIBS=OFF）→ 由 AAR 侧 --whole-archive 链入
  #   - COMPILE_10BIT=1（现网 AVS3 10bit 流需要）
  #   - Bionic 的 pthread 在 libc 里，没有 -lpthread
  #   - armv7 手写汇编含非 PIC 重定位，Android lld 拒绝 → 走 generic 纯 C
  pushd "$UAVS3D_DIR"

  # 10bit 补丁（默认 COMPILE_10BIT 0→1）。头文件有 #ifndef 保护，
  # cmake 的 -DCOMPILE_10BIT=1 也能生效，故此处 optional。
  applyPatch "$PATCH_DIR/uavs3d-10bit.patch" optional

  # --- Android/Bionic 适配（来自 mpv-android-avs CI 验证过的 sed 配方）---
  # 注：老配方里还有一条 sed add_subdirectory(test) —— 当前 uavs3d master 的
  # test/ 已不是 CMake 子工程（无 add_subdirectory 引用，源码只收 decoder+decore），
  # 留着就是 silent no-op，故不保留。
  sed -i 's/find_package(Threads REQUIRED)/#find_package(Threads REQUIRED)/' source/CMakeLists.txt
  sed -i 's/target_link_libraries(\${LIBNAME} pthread)/#target_link_libraries(\${LIBNAME} pthread)/' source/CMakeLists.txt
  sed -i 's/-lpthread//' source/CMakeLists.txt
  sed -i 's/-mfloat-abi=hard/-mfloat-abi=softfp/g' source/CMakeLists.txt
  # Force generic CPU: hand-written ARMv7 ASM uses non-PIC relocations
  sed -i 's/set(UAVS3D_TARGET_CPU "armv7")/set(UAVS3D_TARGET_CPU "generic")/' source/CMakeLists.txt

  for ABI in $ANDROID_ABIS; do
    echo "=== Building uavs3d for $ABI ==="
    CMAKE_BUILD_DIR=$UAVS3D_DIR/uavs3d_build_${ABI}
    rm -rf ${CMAKE_BUILD_DIR}
    mkdir -p ${CMAKE_BUILD_DIR}
    cd ${CMAKE_BUILD_DIR}

    # 与 buildMbedTLS 同一套 cmake 调用风格（SDK cmake + NDK toolchain + make）
    ${CMAKE_EXECUTABLE} "$UAVS3D_DIR" \
      -DANDROID_PLATFORM=${ANDROID_PLATFORM} \
      -DANDROID_ABI=$ABI \
      -DCMAKE_TOOLCHAIN_FILE=${ANDROID_NDK_HOME}/build/cmake/android.toolchain.cmake \
      -DCMAKE_INSTALL_PREFIX=$BUILD_DIR/external/$ABI \
      -DCMAKE_BUILD_TYPE=Release \
      -DCOMPILE_10BIT=1 \
      -DCMAKE_POSITION_INDEPENDENT_CODE=ON

    make -j$JOBS
    make install
    cd "$UAVS3D_DIR"

    # --- 安装产物自检（缺一样就让 CI 失败，别等到 ffmpeg configure 报天书）---
    PC_FILE="$BUILD_DIR/external/$ABI/lib/pkgconfig/uavs3d.pc"
    [ -f "$BUILD_DIR/external/$ABI/lib/libuavs3d.a" ] || { echo "::error::libuavs3d.a missing for $ABI"; exit 1; }
    [ -f "$BUILD_DIR/external/$ABI/include/uavs3d.h" ] || { echo "::error::uavs3d.h missing for $ABI"; exit 1; }
    [ -f "$PC_FILE" ] || { echo "::error::uavs3d.pc missing for $ABI"; exit 1; }

    # ffmpeg 6.0 要求 pkg-config 版本 >= 1.1.41；version.sh 产出 1.2.x 恒满足，
    # 这里显式校验，防上游改动把版本号改成不满足的形式。
    PC_VERSION=$(grep -E '^Version:' "$PC_FILE" | head -1 | awk '{print $2}')
    if [ -z "$PC_VERSION" ]; then
      echo "::error::uavs3d.pc has no Version field ($ABI)"; exit 1
    fi
    if [ "$(printf '%s\n' "1.1.41" "$PC_VERSION" | sort -V | head -1)" != "1.1.41" ]; then
      echo "::error::uavs3d.pc Version=$PC_VERSION < 1.1.41 ($ABI)"; exit 1
    fi
    echo "[OK] uavs3d $ABI: lib+header+pc(Version=$PC_VERSION) installed"
  done
  popd
}

function buildFfmpeg() {
  pushd $FFMPEG_DIR
  EXTRA_BUILD_CONFIGURATION_FLAGS=""
  COMMON_OPTIONS=""

  # Add enabled decoders to FFmpeg build configuration
  for decoder in $ENABLED_DECODERS; do
    COMMON_OPTIONS="${COMMON_OPTIONS} --enable-decoder=${decoder}"
  done

  # Build FFmpeg for each architecture and platform
  for ABI in $ANDROID_ABIS; do

    # Set up environment variables
    case $ABI in
    armeabi-v7a)
      TOOLCHAIN=armv7a-linux-androideabi21-
      CPU=armv7-a
      ARCH=arm
      ;;
    arm64-v8a)
      TOOLCHAIN=aarch64-linux-android21-
      CPU=armv8-a
      ARCH=aarch64
      ;;
    x86)
      TOOLCHAIN=i686-linux-android21-
      CPU=i686
      ARCH=i686
      EXTRA_BUILD_CONFIGURATION_FLAGS=--disable-asm
      ;;
    x86_64)
      TOOLCHAIN=x86_64-linux-android21-
      CPU=x86_64
      ARCH=x86_64
      ;;
    *)
      echo "Unsupported architecture: $ABI"
      exit 1
      ;;
    esac

    # Referencing dependencies without pkgconfig
    DEP_CFLAGS="-I$BUILD_DIR/external/$ABI/include"
    DEP_LD_FLAGS="-L$BUILD_DIR/external/$ABI/lib"

    # Set PKG_CONFIG_PATH so FFmpeg configure can find davs2.pc
    export PKG_CONFIG_PATH="$BUILD_DIR/external/$ABI/lib/pkgconfig"

    # Configure FFmpeg build
    ./configure \
      --prefix=$BUILD_DIR/$ABI \
      --enable-cross-compile \
      --arch=$ARCH \
      --cpu=$CPU \
      --cross-prefix="${TOOLCHAIN_PREFIX}/bin/$TOOLCHAIN" \
      --nm="${TOOLCHAIN_PREFIX}/bin/llvm-nm" \
      --ar="${TOOLCHAIN_PREFIX}/bin/llvm-ar" \
      --ranlib="${TOOLCHAIN_PREFIX}/bin/llvm-ranlib" \
      --strip="${TOOLCHAIN_PREFIX}/bin/llvm-strip" \
      --extra-cflags="-O3 -fPIC $DEP_CFLAGS" \
      --extra-ldflags="$DEP_LD_FLAGS -Wl,-z,max-page-size=16384" \
      --pkg-config="$(which pkg-config)" \
      --pkg-config-flags="--static" \
      --target-os=android \
      --enable-static \
      --disable-shared \
      --disable-doc \
      --disable-programs \
      --disable-everything \
      --disable-vulkan \
      --disable-avdevice \
      --disable-postproc \
      --disable-avfilter \
      --disable-symver \
      --enable-parsers \
      --enable-demuxers \
      --enable-swresample \
      --enable-avformat \
      --enable-avcodec \
      --enable-libvpx \
      --enable-libuavs3d \
      --enable-libdavs2 \
      --enable-protocol=file,http,https,mmsh,mmst,pipe,rtmp,rtmps,rtmpt,rtmpts,rtp,tls \
      --enable-version3 \
      --enable-gpl \
      --enable-mbedtls \
      --extra-ldexeflags=-pie \
      --disable-debug \
      ${EXTRA_BUILD_CONFIGURATION_FLAGS} \
      ${COMMON_OPTIONS}

    # Build FFmpeg
    echo "Building FFmpeg for $ARCH..."
    make clean
    make -j$JOBS
    make install

    OUTPUT_LIB=${OUTPUT_DIR}/lib/${ABI}
    mkdir -p "${OUTPUT_LIB}"
    # Copy FFmpeg static libraries (.a) — static linking ensures all FFmpeg symbols
    # (including swr_free from libswresample) are embedded into libmedia3ext.so
    cp "${BUILD_DIR}"/"${ABI}"/lib/*.a "${OUTPUT_LIB}" 2>/dev/null || true
    # Copy external dependency static libraries (needed for static linking)
    cp "${BUILD_DIR}"/external/"${ABI}"/lib/*.a "${OUTPUT_LIB}" 2>/dev/null || true
    # Also copy any .so files (for reference/debugging, not used in static linking)
    cp "${BUILD_DIR}"/"${ABI}"/lib/*.so "${OUTPUT_LIB}" 2>/dev/null || true

    # No merged archive needed — CMakeLists.txt links individual .a files directly.

    OUTPUT_HEADERS=${OUTPUT_DIR}/include/${ABI}
    mkdir -p "${OUTPUT_HEADERS}"
    cp -r "${BUILD_DIR}"/"${ABI}"/include/* "${OUTPUT_HEADERS}"

  done
  popd
}

if [[ ! -d "$OUTPUT_DIR" ]]; then
  # Download MbedTLS source code if it doesn't exist
  if [[ ! -d "$MBEDTLS_DIR" ]]; then
    downloadMbedTLS
  fi

  # Download Vpx source code if it doesn't exist
  if [[ ! -d "$VPX_DIR" ]]; then
    downloadLibVpx
  fi

  # Download Ffmpeg source code if it doesn't exist
  if [[ ! -d "$FFMPEG_DIR" ]]; then
    downloadFfmpeg
  fi

  # Download davs2 source code if it doesn't exist
  if [[ ! -d "$DAVS2_DIR" ]]; then
    downloadDavs2
  fi

  # Download uavs3d source code if it doesn't exist
  if [[ ! -d "$UAVS3D_DIR" ]]; then
    downloadUavs3d
  fi

  # Building libraries
  buildMbedTLS
  buildLibVpx
  buildDavs2
  buildUavs3d
  buildFfmpeg

  echo "=== FFmpeg build complete ==="
  echo "=== Output libraries ==="
  find "$OUTPUT_DIR" -name "*.a" | sort
  find "$OUTPUT_DIR" -name "*.so" 2>/dev/null | sort || true
fi
