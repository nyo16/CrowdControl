ARG CLAUDE_CODE_VERSION=latest

# The single Playwright pin. The sandbox-browser stage below and the example
# browser sidecar image (examples/images/browser) must run the same version:
# a run-server rejects a client of a different minor with 428.
ARG PLAYWRIGHT_VERSION=1.64.1

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
# A real sandbox image additionally needs the agent CLI; the runtime stage
# below is that image.
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
#
# The default build output. It is named so that sandbox-browser can extend it,
# and re-selected by the final stage at the end of this file, which keeps a
# plain `docker build .` producing exactly this image.
FROM ${ELIXIR_IMAGE} AS runtime

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

# --- Sandbox with the Playwright client side ---
#
#     docker build --target sandbox-browser -t crowd_control/sandbox-browser:dev .
#
# The runtime image plus playwright and @playwright/test at the single pin, a
# `playwright-cli` shim and the playwright-cli skill for `crowdctl`. No
# browsers: they live in the browser sidecar (examples/images/browser), which
# the agent reaches over ws://browser:3000/<token> or http://browser:8931/mcp.
# A separate stage so the default image does not carry the npm packages.
FROM runtime AS sandbox-browser

ARG PLAYWRIGHT_VERSION

ENV PLAYWRIGHT_SKIP_BROWSER_DOWNLOAD=1

USER root

# The shim lets the skill's literal `playwright-cli …` commands run on the
# pinned core rather than the alpha-cored @playwright/cli package.
RUN npm install -g playwright@${PLAYWRIGHT_VERSION} @playwright/test@${PLAYWRIGHT_VERSION} \
    && npm cache clean --force \
    && printf '#!/bin/sh\nexec playwright cli "$@"\n' > /usr/local/bin/playwright-cli \
    && chmod 0755 /usr/local/bin/playwright-cli

USER crowdctl

# Installs to ~/.claude/skills/playwright-cli/, where Claude Code loads
# personal skills from.
RUN cd /home/crowdctl && playwright-cli install --skills -g \
    && test -f /home/crowdctl/.claude/skills/playwright-cli/SKILL.md

# --- Default target ---
#
# `docker build` without --target builds the last stage. This one adds nothing
# to runtime, so the default output stays the runtime image.
FROM runtime
