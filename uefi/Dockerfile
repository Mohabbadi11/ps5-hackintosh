# Build environment for the PS5 UEFI layer (EDK2 UefiPayloadPkg, cross-built for X64 with clang/lld)
FROM ubuntu:24.04
ENV DEBIAN_FRONTEND=noninteractive
RUN apt-get update && apt-get install -y --no-install-recommends \
        build-essential clang lld llvm nasm acpica-tools python3 python3-pip uuid-dev git ca-certificates \
        xz-utils \
    && rm -rf /var/lib/apt/lists/*
WORKDIR /work
