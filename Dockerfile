# The build environment: Ubuntu with autotools, CMake and NASM, and llvm-mingw, which cross-compiles for x64 and ARM64
# Windows from one toolchain. build.ps1 builds this image and runs build.sh in it.
FROM ubuntu:24.04

ARG LLVM_MINGW_VERSION=20261006
ARG LLVM_MINGW_SHA256=5f9c6ed95b2d4bdb2869a488c5fd5857fbdabcf288a0aa3eb1da43f6a08d8ab4

RUN apt-get update \
    && apt-get install -y --no-install-recommends \
        autoconf automake ca-certificates cmake curl file libtool make nasm ninja-build pkg-config python3 xz-utils zip \
    && rm -rf /var/lib/apt/lists/*

RUN curl -fsSL -o /tmp/llvm-mingw.tar.xz \
        "https://github.com/mstorsjo/llvm-mingw/releases/download/${LLVM_MINGW_VERSION}/llvm-mingw-${LLVM_MINGW_VERSION}-ucrt-ubuntu-22.04-x86_64.tar.xz" \
    && echo "${LLVM_MINGW_SHA256}  /tmp/llvm-mingw.tar.xz" | sha256sum -c - \
    && tar -xJf /tmp/llvm-mingw.tar.xz -C /opt \
    && mv /opt/llvm-mingw-* /opt/llvm-mingw \
    && rm /tmp/llvm-mingw.tar.xz

ENV PATH=/opt/llvm-mingw/bin:$PATH
WORKDIR /work
