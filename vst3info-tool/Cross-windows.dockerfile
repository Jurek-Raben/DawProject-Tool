FROM ghcr.io/cross-rs/x86_64-pc-windows-gnu:main

RUN dpkg --add-architecture amd64 && \
    apt-get update && \
    apt-get install --assume-yes \
    build-essential \
    cmake \
    pkg-config \
    mingw-w64 \
    g++-mingw-w64-x86-64 \
    libc6-dev-i386

ENV CC_x86_64_pc_windows_gnu=x86_64-w64-mingw32-gcc
ENV CXX_x86_64_pc_windows_gnu=x86_64-w64-mingw32-g++

# libclang does not find its own headers (e.g. mm_malloc.h) when generating the vst3 bindings
ENV CPLUS_INCLUDE_PATH=/usr/lib/llvm-18/lib/clang/18/include
