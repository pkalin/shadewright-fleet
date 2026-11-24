# faultbox: a static binary on distroless, non-root. Build from this directory:
#   docker build -t faultbox tools/faultbox
# Run it with a read-only root filesystem; the disk fault writes only into --disk-dir (an emptyDir in a pod).
# The builder and the base are pinned by digest (the same as the operator's images); bump the tag and digest together.
FROM --platform=$BUILDPLATFORM golang:1.27.4@sha256:205c7636d74e0ffbe3d007162df7d74f859f5a8c8322dfb9f907977686c126cf AS builder
ARG TARGETOS
ARG TARGETARCH

WORKDIR /src
COPY go.mod ./
RUN go mod download
COPY *.go ./
RUN CGO_ENABLED=0 GOOS=${TARGETOS:-linux} GOARCH=${TARGETARCH} go build -trimpath -ldflags="-s -w" -o /out/faultbox .

FROM gcr.io/distroless/static:nonroot@sha256:aafe993665bf6200db38a02c11a9351e782a84b6a45e7f33b6695638c88e3931
COPY --from=builder /out/faultbox /faultbox
USER 65532:65532
EXPOSE 8080
ENTRYPOINT ["/faultbox"]
