# syntax=docker/dockerfile:1.11
ARG BUILDER=base

FROM --platform=$BUILDPLATFORM docker.io/library/node:23.11.0-bookworm AS node

WORKDIR /app

COPY ui .

RUN --mount=type=cache,target=/app/npm/cache npm install

RUN --mount=type=cache,target=/app/npm/cache npm run build

FROM docker.io/library/rust:1.95.0-trixie AS musl-builder

ARG TARGETARCH

RUN --mount=type=cache,target=/var/cache/apt,sharing=locked \
    --mount=type=cache,target=/var/lib/apt,sharing=locked \
    rm -f /etc/apt/apt.conf.d/docker-clean && \
    echo 'Binary::apt::APT::Keep-Downloaded-Packages "true";' > /etc/apt/apt.conf.d/keep-cache && \
    apt-get update && apt-get install -y --no-install-recommends \
    make musl-tools

RUN <<EOF
mkdir /build
if [ "$TARGETARCH" = "arm64" ]; then
  rustup target add aarch64-unknown-linux-musl;
  echo aarch64-unknown-linux-musl > /build/target
else
  rustup target add x86_64-unknown-linux-musl;
  echo x86_64-unknown-linux-musl > /build/target
fi
EOF

FROM --platform=$BUILDPLATFORM docker.io/library/rust:1.95.0-trixie AS base-builder

ARG TARGETARCH
ARG BUILDARCH

RUN --mount=type=cache,target=/var/cache/apt,sharing=locked \
    --mount=type=cache,target=/var/lib/apt,sharing=locked \
    rm -f /etc/apt/apt.conf.d/docker-clean && \
    echo 'Binary::apt::APT::Keep-Downloaded-Packages "true";' > /etc/apt/apt.conf.d/keep-cache && \
    apt-get update && apt-get install -y --no-install-recommends make

RUN <<EOF
set -e
mkdir /build
if [ "$TARGETARCH" = "arm64" ]; then
  TARGET=aarch64-unknown-linux-gnu
else
  TARGET=x86_64-unknown-linux-gnu
fi
echo "$TARGET" > /build/target
echo "Building $TARGET on $BUILDARCH"

# Cross-compile setup when BUILDARCH != TARGETARCH.
if [ "$BUILDARCH" != "$TARGETARCH" ]; then
  rustup target add "$TARGET"
  if [ "$TARGETARCH" = "arm64" ]; then
    dpkg --add-architecture arm64
    apt-get update
    apt-get install -y --no-install-recommends crossbuild-essential-arm64
    mkdir -p /root/.cargo
    cat > /root/.cargo/config.toml <<CFG
[target.aarch64-unknown-linux-gnu]
linker = "aarch64-linux-gnu-gcc"
CFG
  else
    dpkg --add-architecture amd64
    apt-get update
    apt-get install -y --no-install-recommends crossbuild-essential-amd64
    mkdir -p /root/.cargo
    cat > /root/.cargo/config.toml <<CFG
[target.x86_64-unknown-linux-gnu]
linker = "x86_64-linux-gnu-gcc"
CFG
  fi
fi
EOF

FROM ${BUILDER}-builder AS builder
ARG TARGETARCH
ARG BUILDARCH
ARG PROFILE=release
ARG VERSION
ARG GIT_REVISION
ARG CARGO_FEATURES=agentgateway/ui
ARG CARGO_NO_DEFAULT_FEATURES=false

WORKDIR /app

COPY Makefile Cargo.toml Cargo.lock ./
COPY .cargo ./.cargo
COPY crates ./crates
COPY tools ./tools
COPY --from=node /app/out ./ui/out

RUN \
    --mount=type=cache,id=cargo,target=/usr/local/cargo/registry \
    --mount=type=cache,id=cargo-git,target=/usr/local/cargo/git \
    cargo fetch --locked
RUN --mount=type=cache,target=/app/target \
    --mount=type=cache,id=cargo,target=/usr/local/cargo/registry  \
    --mount=type=cache,id=cargo-git,target=/usr/local/cargo/git \
    <<EOF
export VERSION="${VERSION}"
export GIT_REVISION="${GIT_REVISION}"

# When cross-compiling, point cargo + cc-rs at the GNU cross toolchain.
# These env vars override any project-level .cargo/config.toml.
if [ "${BUILDARCH}" != "${TARGETARCH}" ]; then
  if [ "${TARGETARCH}" = "arm64" ]; then
    export CARGO_TARGET_AARCH64_UNKNOWN_LINUX_GNU_LINKER=aarch64-linux-gnu-gcc
    export CC_aarch64_unknown_linux_gnu=aarch64-linux-gnu-gcc
    export CXX_aarch64_unknown_linux_gnu=aarch64-linux-gnu-g++
    export AR_aarch64_unknown_linux_gnu=aarch64-linux-gnu-ar
    export PKG_CONFIG_ALLOW_CROSS=1
  else
    export CARGO_TARGET_X86_64_UNKNOWN_LINUX_GNU_LINKER=x86_64-linux-gnu-gcc
    export CC_x86_64_unknown_linux_gnu=x86_64-linux-gnu-gcc
    export CXX_x86_64_unknown_linux_gnu=x86_64-linux-gnu-g++
    export AR_x86_64_unknown_linux_gnu=x86_64-linux-gnu-ar
    export PKG_CONFIG_ALLOW_CROSS=1
  fi
fi

if [ "${CARGO_NO_DEFAULT_FEATURES}" = "true" ]; then
  cargo build --no-default-features --features "${CARGO_FEATURES}" --target "$(cat /build/target)" --profile ${PROFILE} || exit 1
else
  cargo build --features "${CARGO_FEATURES}" --target "$(cat /build/target)" --profile ${PROFILE} || exit 1
fi
mkdir /out
mv /app/target/$(cat /build/target)/${PROFILE}/agentgateway /out
# Skip --version check when cross-compiled (binary is for a different arch).
if [ "${BUILDARCH}" = "${TARGETARCH}" ]; then
  /out/agentgateway --version
  if /out/agentgateway --version | grep -q '"unknown"'; then
    exit 1
  fi
fi
EOF

FROM cgr.dev/chainguard/glibc-dynamic AS runner

ARG TARGETARCH

WORKDIR /

COPY --from=builder /out/agentgateway /app/agentgateway

LABEL org.opencontainers.image.source=https://github.com/agentgateway/agentgateway
LABEL org.opencontainers.image.description="Agentgateway is an open source project that is built on AI-native protocols to connect, secure, and observe agent-to-agent and agent-to-tool communication across any agent framework and environment."

ENTRYPOINT ["/app/agentgateway"]
