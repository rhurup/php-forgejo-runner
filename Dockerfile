# syntax=docker/dockerfile:1.7
#
# Self-hosted Forgejo Actions runner with the PHP/Laravel CI toolchain.
#
#   docker build --build-arg PHP_VERSION=8.4 -t php-forgejo-runner:8.4 .
#
# This is NOT the GitHub runner image with a different name. Forgejo's runner
# is a single Go binary with its own lifecycle: the daemon self-registers from
# a config file and persists its identity, so there is no actions-runner
# tarball, no PAT-to-registration-token exchange and no config.sh/run.sh.
#
# Jobs run in HOST mode — as processes inside this container, sharing its
# filesystem, its ports and its toolchain. That is why the whole PHP, Composer,
# Node and Playwright stack lives here rather than in a per-job container, and
# it is also why there is no Docker socket and no unprivileged job user: in
# host mode the runner process IS the job environment. Capacity is expected to
# be 1 per container (see docker-compose.example.yml) because jobs would
# otherwise collide on port 8000 and on the shared caches.

ARG NODE_VERSION=24
ARG COMPOSER_VERSION=2

FROM composer:${COMPOSER_VERSION} AS composer
FROM node:${NODE_VERSION}-bookworm-slim AS node

FROM ubuntu:24.04

ARG RUNNER_VERSION=13.2.0
ARG PHP_VERSION=8.4
# Extensions without the "php<version>-" prefix. Packages that don't exist for
# the chosen PHP version (e.g. opcache, which is built in from 8.5) are skipped.
ARG PHP_EXTENSIONS="bcmath cli curl dev gd imagick intl mbstring mcrypt mongodb mysql opcache pcov pgsql readline redis soap sqlite3 uuid xml xsl yaml zip"
ARG TARGETARCH
ARG DEBIAN_FRONTEND=noninteractive

ENV PHP_VERSION=${PHP_VERSION} \
    FORGEJO_RUNNER_VERSION=${RUNNER_VERSION} \
    LANG=C.UTF-8

SHELL ["/bin/bash", "-o", "pipefail", "-c"]

# CI passes the date here so the apt layer is rebuilt (and picks up security
# updates) at least daily instead of being served from the build cache.
ARG APT_CACHE_BUST=""
# CI passes the lowest PHP patch release with all known security fixes; the
# build fails rather than publishing an image with an older, vulnerable PHP.
ARG PHP_MIN_VERSION=""

# Retry flaky mirrors, and fail instead of silently skipping the PHP packages
# when the PPA index can't be fetched.
RUN echo 'Acquire::Retries "5";' > /etc/apt/apt.conf.d/80-retries \
 && apt-get update --error-on=any \
 && apt-get install -y --no-install-recommends ca-certificates curl gnupg software-properties-common \
 && add-apt-repository -y -n ppa:ondrej/php \
 && apt-get update --error-on=any \
 && apt-get upgrade -y \
 && pkgs=() \
 && for ext in ${PHP_EXTENSIONS}; do \
      if apt-cache show "php${PHP_VERSION}-${ext}" >/dev/null 2>&1; then pkgs+=("php${PHP_VERSION}-${ext}"); \
      else echo "WARNING: php${PHP_VERSION}-${ext} not available, skipping"; fi; \
    done \
 && apt-get install -y --no-install-recommends \
      git openssh-client jq rsync unzip zip xz-utils \
      build-essential libssl-dev libffi-dev python3 python3-venv python3-dev python3-pip \
      "${pkgs[@]}" \
 && apt-get purge -y software-properties-common \
 && apt-get autoremove -y \
 && rm -rf /var/lib/apt/lists/*

RUN command -v php >/dev/null || { echo "ERROR: PHP was not installed"; exit 1; } \
 && echo "PHP $(php -r 'echo PHP_VERSION;')" \
 && if [ -n "${PHP_MIN_VERSION}" ] && ! php -r 'exit(version_compare(PHP_VERSION, getenv("PHP_MIN_VERSION"), ">=") ? 0 : 1);'; then \
      echo "ERROR: PHP $(php -r 'echo PHP_VERSION;') is older than ${PHP_MIN_VERSION} (missing security fixes)"; exit 1; \
    fi

COPY --from=composer /usr/bin/composer /usr/local/bin/composer
COPY --from=node /usr/local/bin/node /usr/local/bin/node
COPY --from=node /usr/local/lib/node_modules /usr/local/lib/node_modules
RUN ln -s ../lib/node_modules/npm/bin/npm-cli.js /usr/local/bin/npm \
 && ln -s ../lib/node_modules/npm/bin/npx-cli.js /usr/local/bin/npx \
 && ln -s ../lib/node_modules/corepack/dist/corepack.js /usr/local/bin/corepack \
 && node --version && npm --version

# The runner binary, verified against the checksum Forgejo publishes beside it.
# A silently corrupted or substituted download would otherwise end up running
# every CI job on this host.
RUN case "${TARGETARCH}" in \
      amd64) arch=amd64 ;; \
      arm64) arch=arm64 ;; \
      *) echo "Unsupported architecture: ${TARGETARCH}"; exit 1 ;; \
    esac \
 && base="https://code.forgejo.org/forgejo/runner/releases/download/v${RUNNER_VERSION}" \
 && asset="forgejo-runner-${RUNNER_VERSION}-linux-${arch}" \
 && curl -fsSL -o /tmp/forgejo-runner "${base}/${asset}" \
 && curl -fsSL -o /tmp/forgejo-runner.sha256 "${base}/${asset}.sha256" \
 && expected="$(awk '{print $1}' /tmp/forgejo-runner.sha256)" \
 && actual="$(sha256sum /tmp/forgejo-runner | awk '{print $1}')" \
 && if [ "$expected" != "$actual" ]; then \
      echo "ERROR: checksum mismatch for ${asset}"; echo "  expected $expected"; echo "  actual   $actual"; exit 1; \
    fi \
 && install -m 0755 /tmp/forgejo-runner /usr/local/bin/forgejo-runner \
 && rm -f /tmp/forgejo-runner /tmp/forgejo-runner.sha256 \
 && forgejo-runner --version

# System libraries for Playwright's Chromium. Browsers themselves are version
# specific, so jobs install them (npx playwright install chromium) into the
# shared cache below.
RUN npx -y playwright@latest install-deps chromium \
 && rm -rf /var/lib/apt/lists/* /root/.npm

# Caches live on a volume shared between runners so Composer, npm and
# Playwright don't re-download per job. Exported from profile.d, which means a
# job only sees them when its shell is a LOGIN shell — workflows must set
# `defaults.run.shell: bash -l {0}`, as ours do.
RUN printf '%s\n' \
      'export COMPOSER_CACHE_DIR=/cache/composer' \
      'export npm_config_cache=/cache/npm' \
      'export PLAYWRIGHT_BROWSERS_PATH=/cache/playwright' \
      > /etc/profile.d/99-ci-cache.sh \
 && chmod 0644 /etc/profile.d/99-ci-cache.sh

# Registration and workdirs are expected on a per-runner volume; the config
# mounted at /etc/runner-config.yaml points `runner.file` and
# `host.workdir_parent` into it.
VOLUME ["/data", "/cache"]
WORKDIR /data

# The binary itself, so the command stays the runner's own CLI:
#   forgejo-runner daemon --config /etc/runner-config.yaml
ENTRYPOINT ["forgejo-runner"]
CMD ["daemon", "--config", "/etc/runner-config.yaml"]

# Last, so correcting a label does not invalidate the expensive apt, Node and
# Playwright layers above it on a daily rebuild.
LABEL org.opencontainers.image.title="php-forgejo-runner" \
      org.opencontainers.image.description="Self-hosted Forgejo Actions runner with PHP, Composer, Node and Playwright system deps, for host-mode Laravel CI" \
      org.opencontainers.image.authors="rasmus@huruphansen.dk" \
      org.opencontainers.image.licenses="MIT" \
      org.opencontainers.image.source="https://github.com/rhurup/php-forgejo-runner"
