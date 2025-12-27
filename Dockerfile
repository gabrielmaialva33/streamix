# Build stage
ARG ELIXIR_VERSION=1.18.2
ARG OTP_VERSION=27.2.1
ARG DEBIAN_VERSION=bookworm-20250113-slim

ARG BUILDER_IMAGE="hexpm/elixir:${ELIXIR_VERSION}-erlang-${OTP_VERSION}-debian-${DEBIAN_VERSION}"
ARG RUNNER_IMAGE="debian:${DEBIAN_VERSION}"

FROM ${BUILDER_IMAGE} AS builder

# Install build dependencies including Node.js
RUN apt-get update -y && apt-get install -y build-essential git curl \
    && curl -fsSL https://deb.nodesource.com/setup_20.x | bash - \
    && apt-get install -y nodejs \
    && apt-get clean && rm -f /var/lib/apt/lists/*_*

# Prepare build dir
WORKDIR /app

# Install hex + rebar
RUN mix local.hex --force && \
    mix local.rebar --force

# Set build ENV
ENV MIX_ENV="prod"

# Install mix dependencies
COPY mix.exs mix.lock ./
RUN mix deps.get --only $MIX_ENV
RUN mkdir config

# Copy compile-time config files
COPY config/config.exs config/${MIX_ENV}.exs config/
RUN mix deps.compile

# Install npm dependencies
COPY assets/package.json assets/package-lock.json assets/
RUN cd assets && npm ci

# Copy application files
COPY priv priv
COPY lib lib
COPY assets assets

# Compile assets
RUN mix assets.setup
RUN mix assets.deploy

# Compile the release
RUN mix compile

# Build release
COPY config/runtime.exs config/
COPY rel rel
RUN mix release

# Start a new build stage for the final image
FROM ${RUNNER_IMAGE}

RUN apt-get update -y && \
    apt-get install -y libstdc++6 openssl libncurses5 locales ca-certificates curl \
    && apt-get clean && rm -f /var/lib/apt/lists/*_*

# Set the locale
RUN sed -i '/en_US.UTF-8/s/^# //g' /etc/locale.gen && locale-gen

ENV LANG=en_US.UTF-8
ENV LANGUAGE=en_US:en
ENV LC_ALL=en_US.UTF-8

WORKDIR /app
RUN chown nobody /app

# Set runner ENV
ENV MIX_ENV="prod"
ENV PHX_SERVER="true"

# Copy the release from builder
COPY --from=builder --chown=nobody:root /app/_build/${MIX_ENV}/rel/streamix ./

USER nobody

# Health check
HEALTHCHECK --interval=30s --timeout=10s --start-period=10s --retries=3 \
    CMD curl -f http://localhost:${PORT:-4000}/api/health || exit 1

CMD ["/app/bin/server"]
