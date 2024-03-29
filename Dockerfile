# syntax = docker/dockerfile-upstream:1.1.4-experimental

## TODO: update to go 1.18, but doing so breaks the mods when the go install happens below.
##       we'll troubleshoot that later. 
FROM golang:1.17 AS build
ENV CGO_ENABLED 0
WORKDIR /tmp
RUN go install sigs.k8s.io/controller-tools/cmd/controller-gen@v0.9.2
WORKDIR /src
COPY ./go.mod ./
COPY ./go.sum ./
RUN go mod download
RUN go mod verify
COPY ./ ./
RUN go list -mod=readonly all >/dev/null

FROM build AS manifests-build
ARG NAME
RUN controller-gen rbac:roleName=${NAME}-role crd paths="./..." output:rbac:artifacts:config=config/rbac output:crd:artifacts:config=config/crd/bases
FROM scratch AS manifests
COPY --from=manifests-build /src/config/crd /config/crd
COPY --from=manifests-build /src/config/rbac /config/rbac

FROM build AS generate-build
RUN controller-gen object:headerFile=./hack/boilerplate.go.txt paths="./..."
FROM scratch AS generate
COPY --from=generate-build /src/api /api

FROM ubuntu:22.04 AS release-build
RUN apt update -y \
  && apt install -y curl \
  && curl -LO https://github.com/kubernetes-sigs/kustomize/releases/download/kustomize%2Fv4.5.7/kustomize_v4.5.7_linux_amd64.tar.gz \
  && tar -xf kustomize_v4.5.7_linux_amd64.tar.gz -C /usr/local/bin \
  && rm kustomize_v4.5.7_linux_amd64.tar.gz
RUN curl -LO "https://dl.k8s.io/release/v1.24.3/bin/linux/amd64/kubectl" \
  && chmod +x kubectl \
  && mv kubectl /usr/local/bin/kubectl
COPY ./config ./config
ARG REGISTRY_AND_USERNAME
ARG NAME
ARG TAG
RUN cd config/manager \
  && kustomize edit set image controller=${REGISTRY_AND_USERNAME}/${NAME}:${TAG} \
  && cd - \
  && kubectl kustomize config >/release.yaml
FROM scratch AS release
COPY --from=release-build /release.yaml /release.yaml

FROM build AS binary
RUN --mount=type=cache,target=/root/.cache/go-build GOOS=linux go build -ldflags "-s -w" -o /manager
RUN chmod +x /manager

FROM scratch AS container
COPY --from=ghcr.io/siderolabs/ca-certificates:v1.2.0 / /
COPY --from=ghcr.io/siderolabs/fhs:v1.2.0 / /
COPY --from=binary /manager /manager
ENTRYPOINT [ "/manager" ]
