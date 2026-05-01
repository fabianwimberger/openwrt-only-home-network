FROM alpine:latest

ARG OPENWRT_VERSION
ARG OPENWRT_TARGET

RUN apk add --no-cache bash coreutils make gcc g++ musl-dev \
    ncurses-dev zlib-dev gawk git gettext openssl-dev libxslt \
    rsync wget unzip python3 file perl findutils grep tar zstd \
    patch diffutils bzip2 gzip envsubst

RUN adduser -D builder
USER builder
WORKDIR /builder

RUN TARGET_PATH=$(echo "${OPENWRT_TARGET}" | tr '/' '-') && \
    URL="https://downloads.openwrt.org/releases/${OPENWRT_VERSION}/targets/${OPENWRT_TARGET}/openwrt-imagebuilder-${OPENWRT_VERSION}-${TARGET_PATH}.Linux-x86_64.tar.zst" && \
    wget -q "$URL" -O imagebuilder.tar.zst && \
    tar --zstd -xf imagebuilder.tar.zst --strip-components=1 && \
    rm imagebuilder.tar.zst

ENTRYPOINT ["/bin/bash", "-c"]
