# Build stage
# Keep these pins aligned with `.tool-versions` and the CI workflow.
ARG ELIXIR_VERSION=1.20.2
ARG OTP_VERSION=29.0.4
ARG DEBIAN_VERSION=bookworm-20260713-slim
ARG NODE_VERSION=26.5.1
ARG NODE_SHA256=cc7b3484ade63bd203a9d304f21ec37a3b622b988d7bdecf1dc4d68fc44a91b7
ARG NPM_VERSION=12.0.2
ARG GIT_SHA=unknown

ARG BUILDER_IMAGE="hexpm/elixir:${ELIXIR_VERSION}-erlang-${OTP_VERSION}-debian-${DEBIAN_VERSION}"
ARG RUNNER_IMAGE="debian:${DEBIAN_VERSION}"

FROM ${BUILDER_IMAGE} AS builder

ARG NODE_VERSION
ARG NODE_SHA256
ARG NPM_VERSION

# Install build dependencies including Node.js and libvips headers (vix
# compiles a NIF against libvips during `mix deps.compile`).
RUN apt-get update -y && apt-get install -y --no-install-recommends \
    build-essential ca-certificates curl git libvips-dev pkg-config xz-utils \
    && curl -fsSLO "https://nodejs.org/dist/v${NODE_VERSION}/node-v${NODE_VERSION}-linux-x64.tar.xz" \
    && echo "${NODE_SHA256}  node-v${NODE_VERSION}-linux-x64.tar.xz" | sha256sum -c - \
    && tar -xJf "node-v${NODE_VERSION}-linux-x64.tar.xz" -C /usr/local --strip-components=1 \
    && rm "node-v${NODE_VERSION}-linux-x64.tar.xz" \
    && npm install --global "npm@${NPM_VERSION}" --no-audit --no-fund \
    && apt-get clean && rm -rf /var/lib/apt/lists/*

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
COPY assets/patches assets/patches
RUN cd assets && npm ci --omit=dev --no-audit --no-fund

# Copy application files
COPY priv priv
COPY lib lib
COPY assets assets

# Compile the application first (generates phoenix-colocated hooks)
RUN mix compile

# Setup and compile assets (after app compilation for colocated hooks)
RUN mix assets.setup
RUN mix assets.deploy

# Build release
COPY config/runtime.exs config/
COPY rel rel
RUN mix release

# Start a new build stage for the final image
FROM ${RUNNER_IMAGE}

ARG GIT_SHA=unknown

RUN apt-get update -y && \
    apt-get install -y --no-install-recommends libstdc++6 openssl libncurses5 locales ca-certificates curl \
    libvips42 \
    ffmpeg \
    && apt-get clean && rm -rf /var/lib/apt/lists/*

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
ENV STREAMIX_REVISION="${GIT_SHA}"

# Copy the release from builder
COPY --from=builder --chown=nobody:root /app/_build/${MIX_ENV}/rel/streamix ./

USER nobody

# Health check
HEALTHCHECK --interval=30s --timeout=10s --start-period=10s --retries=3 \
    CMD curl -f http://localhost:${PORT:-4000}/api/health || exit 1

CMD ["/app/bin/server"]
