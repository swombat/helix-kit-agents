# helix-kit-agents — runtime image for one HelixKit-hosted agent.
#
# Build:   docker build -t helix-kit-agents:latest .
# Run:     bin/deploy (or see docker-compose.yml.template)
#
# This repo USES chaos as a runtime dependency. It does not carry chaos source.
# The builder stage pulls and compiles a pinned tag of seuros/chaos; only the
# resulting binary crosses into the runtime stage.
#
# Multi-stage layout:
#   - Stage 1 (builder): rust:1.95-bookworm + chaos source @ pinned tag → /usr/local/bin/chaos
#   - Stage 2 (runtime): debian:bookworm-slim + Python + Flask + cryptography + chaos binary

# =============================================================================
# Stage 1 — pull and build chaos. Source tree is discarded after the binary copies.
# =============================================================================
FROM rust:1.95-bookworm AS builder

ENV DEBIAN_FRONTEND=noninteractive
RUN apt-get update && apt-get install -y --no-install-recommends \
        protobuf-compiler \
        clang \
        pkg-config \
        libdbus-1-dev \
        ca-certificates \
        git \
    && rm -rf /var/lib/apt/lists/*

# Pin to a specific chaos commit SHA for reproducibility.
#
# Note on chaos versioning (2026-05-04): chaos's GitHub repo carries 30 tags
# in the form `rust-v0.7x.y`, but those are remnants of an earlier incarnation
# (chaos was forked from OpenAI's codex repo and renamed). The current chaos
# workspace on master has no version tags and no published binary releases.
# We pin to a SHA on master. Update CHAOS_REF when bumping to a newer tip.
#
# Last bumped: 2026-05-04 — d3bb3e9 "Use per-server runtime DB ops for MCP registry"
ARG CHAOS_REPO=https://github.com/seuros/chaos.git
ARG CHAOS_REF=d3bb3e9418cef11c64b83326f8bb9559daf9ec2b

WORKDIR /build
# Clone the default branch shallowly, then check out the specific SHA.
# `git clone --depth 1 --branch <SHA>` works for tags but not for arbitrary
# SHAs — so we do it in two steps.
RUN git clone --filter=blob:none ${CHAOS_REPO} chaos \
    && cd chaos \
    && git checkout ${CHAOS_REF}

WORKDIR /build/chaos
RUN cargo build --release --bin chaos \
    && cp target/release/chaos /usr/local/bin/chaos \
    && /usr/local/bin/chaos --version

# =============================================================================
# Stage 2 — runtime
# =============================================================================
FROM debian:bookworm-slim AS runtime

ENV DEBIAN_FRONTEND=noninteractive
RUN apt-get update && apt-get install -y --no-install-recommends \
        ca-certificates \
        python3 \
        python3-pip \
        python3-flask \
        python3-cryptography \
        python3-yaml \
        git \
        curl \
        tini \
        gosu \
        libdbus-1-3 \
    && rm -rf /var/lib/apt/lists/*
# libdbus-1-3 — runtime shared library that chaos links against.
# python3-cryptography + python3-yaml — pre-installed for symmetry with the
#   host-side bin/generate-env.
# gosu — lightweight su-exec replacement; entrypoint.sh uses it to drop
#   privileges from root to the agent user after fixing volume permissions.

# Non-root agent user. uid 1000 matches typical host bind-mount uids.
RUN useradd --create-home --shell /bin/bash --uid 1000 agent

# chaos binary built in stage 1
COPY --from=builder /usr/local/bin/chaos /usr/local/bin/chaos

# Trigger shim — the HTTP service that translates HelixKit's HTTP triggers into chaos exec calls
COPY --chown=agent:agent trigger_shim.py /home/agent/trigger_shim.py

# Entrypoint wrapper — runs as root, chowns the chaos-home volume to uid 1000,
# then drops privs and execs the shim. See entrypoint.sh for rationale.
COPY entrypoint.sh /usr/local/bin/entrypoint.sh
RUN chmod 0755 /usr/local/bin/entrypoint.sh

# Identity volume — bind-mounted at runtime from the deploy host.
# Contains soul.md, self-narrative.md, journals/, memory/.
VOLUME ["/home/agent/identity"]

# chaos session/config volume — bind-mounted from a docker-managed volume on
# the host (chaos-home). Persists across container restarts.

# Note: USER is NOT set here. The container starts as root, runs entrypoint.sh,
# which chowns volumes and then drops privs to the `agent` user via gosu.

WORKDIR /home/agent

# Sane defaults — overridden by bin/generate-env-produced .env
ENV SHIM_PORT=4000

EXPOSE 4000

# tini handles PID 1 signal forwarding; entrypoint.sh handles privilege drop.
# The CMD is what entrypoint.sh ultimately exec's as the agent user.
ENTRYPOINT ["tini", "--", "/usr/local/bin/entrypoint.sh"]
CMD ["python3", "/home/agent/trigger_shim.py"]
