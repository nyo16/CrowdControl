FROM hexpm/elixir:1.18.3-erlang-27.3-debian-bookworm-20250407 AS build

RUN apt-get update && apt-get install -y --no-install-recommends \
    build-essential git curl ca-certificates \
    && rm -rf /var/lib/apt/lists/*

# Install Claude Code CLI (requires Node.js)
RUN curl -fsSL https://deb.nodesource.com/setup_22.x | bash - \
    && apt-get install -y nodejs \
    && npm install -g @anthropic-ai/claude-code \
    && rm -rf /var/lib/apt/lists/*

WORKDIR /app

COPY mix.exs mix.lock ./
RUN mix local.hex --force && mix local.rebar --force
RUN mix deps.get && mix deps.compile

COPY lib lib/
COPY test test/
COPY .formatter.exs ./

RUN mix compile

# --- Runtime ---
FROM hexpm/elixir:1.18.3-erlang-27.3-debian-bookworm-20250407

RUN apt-get update && apt-get install -y --no-install-recommends \
    build-essential curl ca-certificates git \
    && curl -fsSL https://deb.nodesource.com/setup_22.x | bash - \
    && apt-get install -y nodejs \
    && npm install -g @anthropic-ai/claude-code \
    && rm -rf /var/lib/apt/lists/*

RUN mix local.hex --force && mix local.rebar --force

WORKDIR /app

COPY --from=build /app/_build _build/
COPY --from=build /app/deps deps/
COPY --from=build /app/mix.exs /app/mix.lock ./
COPY --from=build /app/lib lib/

# Default project mount point
RUN mkdir -p /workspace
VOLUME ["/workspace"]

ENV MIX_ENV=prod
ENV CLAUDE_CODE_SKIP_UPDATE_CHECK=1

ENTRYPOINT ["iex", "-S", "mix"]
