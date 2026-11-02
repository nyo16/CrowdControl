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
# The base image is pinned by digest, so bumping PLAYWRIGHT_VERSION means
# replacing the digest below with the new tag's
# (`docker buildx imagetools inspect mcr.microsoft.com/playwright:v<version>-noble`);
# the build fails if the two disagree.
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
# base image already carries this version's browsers in /ms-playwright; the
# check fails the build when the digest-pinned base is another version's.
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
