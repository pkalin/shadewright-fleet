# faultbox: a static binary on distroless, non-root. Build from this directory:
#   docker build -t faultbox tools/faultbox
# Run it with a read-only root filesystem; the disk fault writes only into --disk-dir (an emptyDir in a pod).
# The builder and the base are pinned by digest (the same as the operator's images); bump the tag and digest together.
FROM --platform=$BUILDPLATFORM golang:1.27.4@sha256:5e8afd493a7124a8586e134d9b532731161d4b9becf9dee5a5956b107426f93d AS builder
ARG TARGETOS
ARG TARGETARCH

WORKDIR /src
COPY go.mod ./
RUN go mod download
COPY *.go ./
RUN CGO_ENABLED=0 GOOS=${TARGETOS:-linux} GOARCH=${TARGETARCH} go build -trimpath -ldflags="-s -w" -o /out/faultbox .

FROM gcr.io/distroless/static:nonroot@sha256:8ce6dd87e9823c5b48dcfb2c8604714ccb351ce59607327bcc4957448da279b5
COPY --from=builder /out/faultbox /faultbox
USER 65532:65532
EXPOSE 8080
ENTRYPOINT ["/faultbox"]
