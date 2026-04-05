ARG CLAUDE_CODE_VERSION=latest

FROM hexpm/elixir:1.18.3-erlang-27.3-debian-bookworm-20250407 AS build

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

# --- Runtime ---
FROM hexpm/elixir:1.18.3-erlang-27.3-debian-bookworm-20250407

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

# Default mount points
RUN mkdir -p /workspace /config \
    && chown -R crowdctl:crowdctl /app /workspace /config

VOLUME ["/workspace", "/config"]

# Copy template config files
COPY config/templates /config/templates

ENV MIX_ENV=prod
ENV CLAUDE_CODE_SKIP_UPDATE_CHECK=1

HEALTHCHECK --interval=30s --timeout=5s --start-period=15s --retries=3 \
  CMD mix eval "if CrowdControl.healthy?(), do: System.halt(0), else: System.halt(1)"

USER crowdctl

ENTRYPOINT ["iex", "-S", "mix"]
