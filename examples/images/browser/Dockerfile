# Browser sidecar: one headless Chromium served two ways.
#
#   ws://browser:3000/<PW_WS_TOKEN>  Playwright launchServer, for playwright-cli,
#                                    @playwright/test and chromium.connect()
#   http://browser:8931/mcp          `playwright mcp`, bound to the same browser
#
# An example, not a published image. PLAYWRIGHT_VERSION has no default on
# purpose: the pin is the repository's PLAYWRIGHT_VERSION file, which the
# sandbox-browser stage of the root Dockerfile reads too, and a client of a
# different minor gets 428 from the server. From the repository root:
#
#     docker build --build-arg PLAYWRIGHT_VERSION=$(cat PLAYWRIGHT_VERSION) \
#       -t crowd_control/browser:dev examples/images/browser
#
# The base image is pinned by digest, and once a digest is present it alone
# decides the image: the build does not check the tag in front of it.
# .github/workflows/image-pins.yml does, and flags a digest that no longer
# matches its tag. Bumping PLAYWRIGHT_VERSION therefore means replacing the
# digest below with the new tag's top-level (index) digest, from
# `docker buildx imagetools inspect mcr.microsoft.com/playwright:v<version>-noble`.
# The --build-arg must equal the repository's PLAYWRIGHT_VERSION file; this
# build context is examples/images/browser, so nothing here can read that file
# and compare. The npm check further down is weaker than a version match: it
# fails only when the base image lacks the Chromium revision that
# playwright@<build-arg> expects, so two patch releases sharing a revision
# both build against either digest.
#
# Runtime needs: /dev/shm of 1 GiB or more (ShmSize, or an emptyDir with
# medium: Memory on Kubernetes), a writable /tmp, and egress only to the proxy.
# Environment: PW_WS_TOKEN (required), PW_PROXY_SERVER, PW_PROXY_BYPASS,
# MCP_ALLOWED_HOSTS (see browser-sidecar.mjs).
ARG PLAYWRIGHT_VERSION

FROM mcr.microsoft.com/playwright:v${PLAYWRIGHT_VERSION}-noble@sha256:2f05f8a734509a7b3f26a912639488ee08f58a7b292d14d62271bcff9038768f

ARG PLAYWRIGHT_VERSION

# The digest above resolves the base image even when the build arg is missing,
# so say so here rather than fail later on `playwright@`.
RUN test -n "${PLAYWRIGHT_VERSION}" \
    || (echo 'pass --build-arg PLAYWRIGHT_VERSION=$(cat PLAYWRIGHT_VERSION) (from the repository root)' >&2 && exit 1)

# The base image runs as root and has no init. tini reaps Chromium's orphans
# (Kubernetes has no --init). The fixed uid is for runAsUser.
RUN apt-get update && apt-get install -y --no-install-recommends tini \
    && rm -rf /var/lib/apt/lists/* \
    && useradd -u 10001 -U -m -d /home/browser -s /usr/sbin/nologin browser

WORKDIR /opt/cc-browser

# Preinstalled because the sidecar sits on internal networks with no npm. The
# base image already carries its version's browsers in /ms-playwright; the
# check fails the build when that is not the Chromium revision this playwright
# expects (a revision check, not a version check: see the note at the top).
ENV PLAYWRIGHT_SKIP_BROWSER_DOWNLOAD=1
RUN npm install --omit=dev --no-fund --no-audit playwright@${PLAYWRIGHT_VERSION} \
    && npm cache clean --force \
    && node -e "const p = require('playwright').chromium.executablePath(); \
        if (!require('node:fs').existsSync(p)) { \
          console.error('the base image has no Chromium for playwright@${PLAYWRIGHT_VERSION} (' + p + '): update its digest'); \
          process.exit(1); }"

COPY browser-sidecar.mjs ./

USER 10001
WORKDIR /home/browser

EXPOSE 3000 8931

ENTRYPOINT ["/usr/bin/tini", "-s", "--", "node", "/opt/cc-browser/browser-sidecar.mjs"]
