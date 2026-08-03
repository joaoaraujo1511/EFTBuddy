# Production image for EFT Buddy.
#
# Multi-stage: a builder that needs a full Elixir toolchain, and a runtime that
# needs none of it. Only the compiled OTP release crosses between them, so the
# shipped image carries no source, no Mix, no Hex credentials and no build cache.
#
# ARCHITECTURE. The base images below are multi-arch manifests, so this file
# builds unmodified on both x86_64 and arm64 — which matters because Oracle's
# Always Free tier is Ampere (arm64) while most CI runners are x86_64. An image
# built on one will NOT run on the other. Either build on the target host, or
# build with `docker buildx --platform linux/arm64`. The CI job that builds this
# only proves it COMPILES; it does not produce a deployable arm64 artefact.
#
# Versions are pinned to the same toolchain CI runs (.github/workflows/ci.yml).
# The Erlang line is the one exception worth knowing about: CI pins the full
# patch 27.3.4.3, and the hexpm image line publishes 27.3.4. If you bump one,
# bump the other and re-read that file's comment on why the pin is exact.
#
# DEBIAN_VERSION is a DATE, and it is not a free choice: it selects the builder
# tag, and hexpm does not publish every date for every architecture. The previous
# pin, bookworm-20250610, is published for arm64 ONLY — so an amd64 host could not
# build this image at all and died with "no match for platform in manifest".
# bookworm-20260610 publishes amd64 AND arm64 for both the hexpm builder and the
# debian runner, so both deploy targets build from an unmodified file. Verify
# before bumping this again:
#
#   docker manifest inspect hexpm/elixir:1.18.4-erlang-27.3.4-debian-<date>-slim \
#     | grep architecture
#
# Only the Debian base date changes here. Elixir and OTP are untouched, and the
# builder's base does not appear in the final image.
ARG ELIXIR_VERSION=1.18.4
ARG OTP_VERSION=27.3.4
ARG DEBIAN_VERSION=bookworm-20260610

ARG BUILDER_IMAGE="hexpm/elixir:${ELIXIR_VERSION}-erlang-${OTP_VERSION}-debian-${DEBIAN_VERSION}-slim"
ARG RUNNER_IMAGE="debian:${DEBIAN_VERSION}-slim"

# ── Build stage ───────────────────────────────────────────────────────────────
FROM ${BUILDER_IMAGE} AS builder

# `build-essential` and `git` are needed by dependencies that compile NIFs —
# lazy_html pulls in cc_precompiler/elixir_make. On arm64 there may be no
# precompiled artefact, so this is not optional padding.
RUN apt-get update -y \
  && apt-get install -y --no-install-recommends build-essential git ca-certificates \
  && apt-get clean \
  && rm -rf /var/lib/apt/lists/*

WORKDIR /app

RUN mix local.hex --force && mix local.rebar --force

ENV MIX_ENV="prod"

# Dependencies first, as their own layer: mix.exs/mix.lock change far less often
# than lib/, so edits to application code reuse the compiled deps cache.
COPY mix.exs mix.lock ./
RUN mix deps.get --only $MIX_ENV
RUN mkdir config

# config/config.exs and config/prod.exs are read at COMPILE time, so they must
# land before `deps.compile`. config/runtime.exs deliberately does not — it is
# evaluated at boot, which is what lets one image run against any environment.
COPY config/config.exs config/${MIX_ENV}.exs config/
RUN mix deps.compile

COPY priv priv
COPY lib lib
COPY assets assets

# Compile BEFORE assets. LiveView's compiler emits colocated hooks into
# `_build/${MIX_ENV}/phoenix-colocated/eft_buddy`, and assets/js/app.js imports
# that path — esbuild cannot resolve it until a compile has run. The
# `assets.deploy` alias now compiles first too, so this is explicit ordering
# rather than the only thing standing between you and a broken build.
RUN mix compile

# `assets.deploy` runs tailwind + esbuild and then `phx.digest`, which writes the
# cache_static_manifest that config/prod.exs points at.
RUN mix assets.deploy

COPY config/runtime.exs config/

# rel/overlays/bin/{server,migrate} are copied verbatim into the release by
# `mix release`. `bin/server` is what CMD runs; `bin/migrate` is the one-shot
# migration entrypoint. Both must be executable in git — see the note in
# rel/overlays/bin/migrate.
COPY rel rel

RUN mix release

# ── Runtime stage ─────────────────────────────────────────────────────────────
FROM ${RUNNER_IMAGE} AS runner

# `ca-certificates` is load-bearing, not hygiene: config/runtime.exs calls
# :public_key.cacerts_get/0 to verify the database's TLS certificate and RAISES
# at boot without a trust store. It stays required even when DB_CACERTFILE pins a
# private CA for the database — outbound HTTPS (the wiki dump fetch) still
# resolves against the OS store. `libstdc++6`/`libncurses6` are ERTS runtime
# needs; `openssl` backs :crypto and :ssl; `locales` supports the UTF-8 setup
# below, which Elixir needs for correct string handling.
RUN apt-get update -y \
  && apt-get install -y --no-install-recommends \
     libstdc++6 openssl libncurses6 locales ca-certificates \
  && apt-get clean \
  && rm -rf /var/lib/apt/lists/*

RUN sed -i '/en_US.UTF-8/s/^# //g' /etc/locale.gen && locale-gen
ENV LANG=en_US.UTF-8 LANGUAGE=en_US:en LC_ALL=en_US.UTF-8

WORKDIR /app

# NON-ROOT. A compromised web process should not be able to modify the release
# it is running from, so the app is owned by root and merely readable/executable
# by the unprivileged user that runs it.
RUN groupadd --system --gid 1001 eftbuddy \
  && useradd --system --uid 1001 --gid eftbuddy --home /app eftbuddy

ENV MIX_ENV="prod"

COPY --from=builder --chown=root:root /app/_build/${MIX_ENV}/rel/eft_buddy ./

# Database trust anchors, at a STABLE path. These do ship inside the release too
# (priv/ is part of it), but only under `/app/lib/eft_buddy-<version>/priv/`, and
# baking a version number into DB_CACERTFILE means the next `version:` bump in
# mix.exs silently breaks database TLS. `/app/certs/` does not move.
#
# Public certificates, no private key material: a CA certificate is the half that
# is meant to be distributed, so committing one leaks nothing. They are copied
# rather than mounted so that deploying is a `git pull` and a rebuild, with no
# out-of-band file for someone to forget.
COPY --from=builder --chown=root:root /app/priv/certs /app/certs

USER eftbuddy

# Build provenance, reported by /health so verifying a deploy is one curl rather
# than comparing four timestamps by eye — see `EftBuddy.BuildInfo`.
#
# It has to be passed IN: `.dockerignore` excludes `.git`, so the builder cannot
# resolve the revision itself. docker-compose.yml declares the argument and
# documents the invocation. Omitted, the image reports "unknown" and the build
# still succeeds — build metadata must never be able to fail a deploy.
#
# Declared here, at the end, on purpose: it changes on every commit, so an
# earlier position would invalidate the whole runtime layer cache each time.
# Not a secret — this repository is public and the commit is already published.
ARG GIT_SHA=""
ENV GIT_SHA=${GIT_SHA}

# Bandit binds this; config/runtime.exs reads PORT and defaults to 4000.
EXPOSE 4000

# PHX_SERVER is what actually starts the endpoint under a release — without it
# the release boots the supervision tree and serves nothing. See the note at the
# top of config/runtime.exs.
ENV PHX_SERVER=true

# NO SECRETS IN THIS FILE, deliberately. SECRET_KEY_BASE, DATABASE_URL,
# DB_PASSWORD and PHX_HOST are supplied at `docker run` time. Anything baked in
# with ENV is readable by anyone who can pull the image, and this repository is
# public — a value committed here is a published value.

CMD ["/app/bin/server"]
