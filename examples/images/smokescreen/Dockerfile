# Smokescreen egress proxy, compiled from a pinned upstream commit.
#
# An example, not a published image. Upstream's Dockerfile only packages a
# prebuilt binary, so this one builds it. From the repository root:
#
#     docker build -t crowd_control/smokescreen:dev examples/images/smokescreen
#
# The runtime is busybox rather than distroless: `nc` is the readiness probe and
# `sh` is the wrapper that redirects Smokescreen's stderr (where its
# CANONICAL-PROXY-DECISION lines go) to a file, e.g.
#
#     sh -c 'exec smokescreen --config-file /etc/smokescreen/config.yaml 2>>/var/log/proxy/decisions.jsonl'
ARG SMOKESCREEN_COMMIT=336cb34495041ce3a33b8d489a2edcbf5f300913

# Bases pinned by digest (multi-arch index), so a rebuild is reproducible;
# refresh with `docker buildx imagetools inspect <tag>`.
FROM golang:1.26@sha256:670bb5aa5349ae03b8516764718486f4f16399134bdc9acd0c46a23f043ab05c AS build

ARG SMOKESCREEN_COMMIT

WORKDIR /src

RUN git init -q . \
    && git remote add origin https://github.com/stripe/smokescreen.git \
    && git fetch -q --depth 1 origin "${SMOKESCREEN_COMMIT}" \
    && git checkout -q FETCH_HEAD \
    && test "$(git rev-parse HEAD)" = "${SMOKESCREEN_COMMIT}"

RUN CGO_ENABLED=0 go build -mod=vendor -trimpath -ldflags='-s -w' -o /out/smokescreen .

FROM busybox:1.37@sha256:a7dbc319b1438115a207e11930dc4bb3e643dcb3ec0bdd694bb36cd8fad289ec

COPY --from=build /etc/ssl/certs/ca-certificates.crt /etc/ssl/certs/ca-certificates.crt
COPY --from=build /out/smokescreen /usr/local/bin/smokescreen

# Same non-root uid as upstream's image. /var/log/proxy is writable by it so
# the stderr redirect works without a volume.
RUN mkdir -p /var/log/proxy /etc/smokescreen \
    && chown 65532:65532 /var/log/proxy

USER 65532:65532

EXPOSE 4750

ENTRYPOINT ["/usr/local/bin/smokescreen"]
CMD ["--listen-ip", "0.0.0.0", "--listen-port", "4750"]
