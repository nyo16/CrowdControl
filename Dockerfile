ARG CLAUDE_CODE_VERSION=latest

# One place, three stages. Bumped from 1.18.3/erlang-27.3 because mix.exs now
# requires ~> 1.19 (:gcp_compute declares it). Debian bookworm is deliberate and
# load-bearing for the sandboxd release: an OTP release must be built on the
# target's glibc, and bookworm is what the sandbox image and the published
# linux tarball both use.
ARG ELIXIR_IMAGE=hexpm/elixir:1.19.6-erlang-28.5.0.5-debian-bookworm-20260824

FROM ${ELIXIR_IMAGE} AS build

ARG CLAUDE_CODE_VERSION

RUN apt-get update && apt-get install -y --no-install-recommends \
    build-essential git curl ca-certificates \
    && rm -rf /var/lib/apt/lists/*

# Install Claude Code CLI (requires Node.js)
RUN curl -fsSL https://deb.nodesource.com/setup_22.x | bash - \
    && apt-get install -y nodejs \
    && npm install -g @anthropic-ai/claude-code@${CLAUDE_CODE_VERSION} \
    && rm -rf /var/lib/apt/lists/*

WORKDIR /app

COPY mix.exs mix.lock ./
RUN mix local.hex --force && mix local.rebar --force
RUN mix deps.get && mix deps.compile

COPY lib lib/
COPY .formatter.exs ./

RUN mix compile

# --- sandboxd release ---
#
# The in-sandbox agent, built as a self-contained OTP release. Separate stage,
# separate dependency set: sandboxd depends on bandit + plug + net_runner +
# jason and nothing else, and it must not inherit crowd_control's deps — this
# artifact is downloaded into sandboxes, sometimes over the network by a GCE
# startup script, so every transitive package is attack surface.
#
# build-essential is required, not incidental: net_runner ships a NIF and a
# shepherd binary compiled through elixir_make.
FROM ${ELIXIR_IMAGE} AS sandboxd-build

RUN apt-get update && apt-get install -y --no-install-recommends \
    build-essential ca-certificates \
    && rm -rf /var/lib/apt/lists/*

WORKDIR /src

RUN mix local.hex --force && mix local.rebar --force

COPY sandboxd/mix.exs sandboxd/mix.lock ./
RUN MIX_ENV=prod mix deps.get && MIX_ENV=prod mix deps.compile

COPY sandboxd/lib lib/
# rel/env.sh.eex is baked into the release and sets ELIXIR_ERL_OPTIONS=+fnu and
# RELEASE_DISTRIBUTION=none. Without this COPY the release builds fine and
# silently loses both, which is how the latin1-locale warning got here in the
# first place.
COPY sandboxd/rel rel/

RUN MIX_ENV=prod mix release --path /opt/sandboxd

# --- Release artifact, for export only ---
#
#     docker buildx build --target sandboxd-artifact \
#       --output type=local,dest=./out --platform linux/arm64 .
#
# FROM scratch so a `type=local` export contains the release and nothing else.
# Exporting the build stage directly would write out that whole Elixir image —
# gigabytes — to obtain one directory.
FROM scratch AS sandboxd-artifact

COPY --from=sandboxd-build /opt/sandboxd /sandboxd

# --- Minimal sandbox image, for exercising the transport ---
#
#     docker build --target sandbox-dev -t crowd_control/sandbox:dev .
#
# No Elixir and no agent CLI: the release carries its own ERTS
# (include_erts: true), so this proves the artifact is genuinely
# self-contained — which is the property the GCE provider depends on, since it
# fetches this tarball onto a bare Debian VM. It is also what the :sandboxd
# integration test runs against, so that test exercises the transport rather
# than a node install.
#
# A real sandbox image additionally needs the agent CLI; the default runtime
# stage below is that image.
FROM debian:bookworm-slim AS sandbox-dev

# libssl3 is REQUIRED, not optional: the release embeds ERTS, but ERTS's crypto
# NIF links against the system OpenSSL, so without it the VM dies at boot with
# "Failed to load NIF library .../crypto: libcrypto.so.3: cannot open shared
# object file". debian:bookworm-slim does not ship it. Naming it explicitly
# rather than inheriting it through ca-certificates, which happens to depend on
# openssl today and is not a contract.
RUN apt-get update && apt-get install -y --no-install-recommends \
    ca-certificates libssl3 libncurses6 \
    && rm -rf /var/lib/apt/lists/*

RUN groupadd -r crowdctl && useradd -r -g crowdctl -m -d /home/crowdctl crowdctl \
    && mkdir -p /var/log/cc \
    && chown -R crowdctl:crowdctl /var/log/cc

COPY --from=sandboxd-build /opt/sandboxd /opt/sandboxd

USER crowdctl

ENTRYPOINT ["/opt/sandboxd/bin/sandboxd"]
CMD ["start"]

# --- Runtime ---
FROM ${ELIXIR_IMAGE}

ARG CLAUDE_CODE_VERSION

RUN apt-get update && apt-get install -y --no-install-recommends \
    ca-certificates git curl \
    && curl -fsSL https://deb.nodesource.com/setup_22.x | bash - \
    && apt-get install -y nodejs \
    && npm install -g @anthropic-ai/claude-code@${CLAUDE_CODE_VERSION} \
    && apt-get purge -y --auto-remove curl \
    && rm -rf /var/lib/apt/lists/*

RUN mix local.hex --force && mix local.rebar --force

# Non-root user
RUN groupadd -r crowdctl && useradd -r -g crowdctl -m -d /home/crowdctl crowdctl

WORKDIR /app

COPY --from=build /app/_build _build/
COPY --from=build /app/deps deps/
COPY --from=build /app/mix.exs /app/mix.lock ./
COPY --from=build /app/lib lib/

# The sandboxd agent, so this one image serves both sandbox transports:
# Backend.Docker's FIFO/tee path (which needs only sh and tail, both present)
# and Backend.Sandboxd's HTTP path (which needs this release).
COPY --from=sandboxd-build /opt/sandboxd /opt/sandboxd

# Default mount points. /var/log/cc is the agent's capture directory and must
# exist and be writable by the runtime user: sandboxd creates it if it can, and
# as a non-root user under /var/log it cannot.
RUN mkdir -p /workspace /config /var/log/cc \
    && chown -R crowdctl:crowdctl /app /workspace /config /var/log/cc

VOLUME ["/workspace", "/config"]

# Copy template config files
COPY config/templates /config/templates

ENV MIX_ENV=prod
ENV CLAUDE_CODE_SKIP_UPDATE_CHECK=1

HEALTHCHECK --interval=30s --timeout=5s --start-period=15s --retries=3 \
  CMD mix eval "if CrowdControl.healthy?(), do: System.halt(0), else: System.halt(1)"

USER crowdctl

# Self-hosting CrowdControl itself. Unchanged.
#
# To run this image as a *sandbox* driven by CrowdControl.Backend.Sandboxd,
# override the entrypoint and let the provider inject the agent's environment:
#
#     docker run --rm \
#       -e CC_SANDBOXD_TOKEN=... -e CC_SANDBOXD_BIND=0.0.0.0 \
#       -p 127.0.0.1::8080 \
#       --entrypoint /opt/sandboxd/bin/sandboxd \
#       crowd_control:latest start
#
# CrowdControl.Provider.Docker does exactly that, so nothing but the image name
# is normally needed.
ENTRYPOINT ["iex", "-S", "mix"]
