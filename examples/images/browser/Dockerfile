# Browser sidecar: one headless Chromium served two ways.
#
#   ws://browser:3000/<PW_WS_TOKEN>  Playwright launchServer, for playwright-cli,
#                                    @playwright/test and chromium.connect()
#   http://browser:8931/mcp          `playwright mcp`, bound to the same browser
#
# An example, not a published image. PLAYWRIGHT_VERSION has no default on
# purpose: the pin lives in the repository's root Dockerfile, and a client of a
# different minor gets 428 from the server. From the repository root:
#
#     docker build \
#       --build-arg PLAYWRIGHT_VERSION=$(awk -F= '/^ARG PLAYWRIGHT_VERSION=/{print $2}' Dockerfile) \
#       -t crowd_control/browser:dev examples/images/browser
#
# Runtime needs: /dev/shm of 1 GiB or more (ShmSize, or an emptyDir with
# medium: Memory on Kubernetes), a writable /tmp, and egress only to the proxy.
# Environment: PW_WS_TOKEN (required), PW_PROXY_SERVER, PW_PROXY_BYPASS.
ARG PLAYWRIGHT_VERSION

FROM mcr.microsoft.com/playwright:v${PLAYWRIGHT_VERSION}-noble

ARG PLAYWRIGHT_VERSION

# The base image runs as root and has no init. tini reaps Chromium's orphans
# (Kubernetes has no --init). The fixed uid is for runAsUser.
RUN apt-get update && apt-get install -y --no-install-recommends tini \
    && rm -rf /var/lib/apt/lists/* \
    && useradd -u 10001 -U -m -d /home/browser -s /usr/sbin/nologin browser

WORKDIR /opt/cc-browser

# Preinstalled because the sidecar sits on internal networks with no npm. The
# base image already carries this version's browsers in /ms-playwright.
ENV PLAYWRIGHT_SKIP_BROWSER_DOWNLOAD=1
RUN npm install --omit=dev --no-fund --no-audit playwright@${PLAYWRIGHT_VERSION} \
    && npm cache clean --force

COPY browser-sidecar.mjs ./

USER 10001
WORKDIR /home/browser

EXPOSE 3000 8931

ENTRYPOINT ["/usr/bin/tini", "-s", "--", "node", "/opt/cc-browser/browser-sidecar.mjs"]
