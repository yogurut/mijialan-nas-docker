# syntax=docker/dockerfile:1
# MijiaLAN-rs -> single Docker product for UGREEN DX4600 (x86_64, UGOS Pro)
#
# Why this shape:
# - Upstream `main` (Swift) is macOS 15 only and cannot run in a Linux
#   container at all. This image builds the Rust branch `MijiaLAN-rs`
#   instead (pinned commit below).
# - Upstream `scripts/docker/Dockerfile` is a *build* container only: it
#   has no CMD/ENTRYPOINT and produces DEB/tar.gz. This Dockerfile reuses
#   that idea as stage 1, then ships a small runtime image that only runs
#   the headless CLI bridge (`mijia-rust bridge`). No desktop/GPUI is
#   included: a NAS has no X11/Wayland/tray for it.
# - All state lives in /data (mounted from the NAS):
#     /data/config/MijiaLAN Rust/devices.json   device list (no tokens)
#     /data/config/MijiaLAN Rust/credentials.enc  ChaCha20-Poly1305 ciphertext
#     /data/local/share/keyrings/               gnome-keyring (master key)
#   The master key itself lives in Secret Service (gnome-keyring), unlocked
#   at container start by entrypoint.sh with MIJIALAN_KEYRING_PASSWORD.
#   The app never falls back to plaintext storage, so without a working,
#   unlocked keyring it will refuse to save credentials. That is by design.

ARG MIJIALAN_REF=048d2911ffff8a3223e41f4b8036b6e8554dad96
ARG RUST_VERSION=1.98-bookworm

# ---------------------------------------------------------------- stage 1
FROM rust:${RUST_VERSION} AS builder
ARG MIJIALAN_REF

RUN apt-get update && apt-get install -y --no-install-recommends \
      git build-essential pkg-config clang libclang-dev cmake \
      libssl-dev libdbus-1-dev \
    && rm -rf /var/lib/apt/lists/*

WORKDIR /src
RUN git clone --depth 1 -b MijiaLAN-rs https://github.com/iPocket-APP/MijiaLAN.git . \
 && git checkout "${MIJIALAN_REF}" \
 && git rev-parse HEAD

# CLI only: core (miIO/MIoT) + homekit bridge. The desktop/GPUI target is
# deliberately NOT built here; it needs a display server a NAS does not have.
RUN cargo build --locked --release -p mijialan-cli \
 && cp target/release/mijia-rust /usr/local/bin/mijia-rust \
 && /usr/local/bin/mijia-rust --help

# ---------------------------------------------------------------- stage 2
FROM debian:12-slim AS runtime

RUN apt-get update && apt-get install -y --no-install-recommends \
      ca-certificates \
      libdbus-1-3 libssl3 \
      dbus dbus-bin \
      gnome-keyring libsecret-1-0 libsecret-tools \
      iproute2 iputils-ping procps \
    && rm -rf /var/lib/apt/lists/* \
 && mkdir -p /data/config /data/local/share

COPY --from=builder /usr/local/bin/mijia-rust /usr/local/bin/mijia-rust
COPY entrypoint.sh /usr/local/bin/entrypoint.sh
RUN chmod +x /usr/local/bin/entrypoint.sh \
 && mijia-rust --help

# Data dir. ProjectDirs on Linux resolves config_dir() from XDG_CONFIG_HOME,
# so /data/config is where "MijiaLAN Rust/devices.json" ends up.
ENV HOME=/data \
    XDG_CONFIG_HOME=/data/config \
    XDG_DATA_HOME=/data/local/share \
    TZ=Asia/Shanghai

VOLUME ["/data"]
WORKDIR /data

ENTRYPOINT ["/usr/local/bin/entrypoint.sh"]
# Default: run the HomeKit bridge forever. Override per-run for one-offs,
# e.g. `docker compose run --rm mijialan login --region cn`.
CMD ["bridge"]

# No HTTP port to probe (HomeKit picks a persisted TCP port, mDNS announces
# it; miIO is UDP 54321 broadcast). Liveness = bridge process alive.
HEALTHCHECK --interval=60s --timeout=10s --start-period=30s --retries=3 \
  CMD pgrep -f "mijia-rust bridge" >/dev/null || exit 1
