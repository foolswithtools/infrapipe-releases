# syntax=docker/dockerfile:1
#
# infrapipe container images. Build context must contain
#   bin/infrapipe-linux-amd64 and bin/infrapipe-linux-arm64
# (the released, checksum-verified binaries; see .github/workflows/image.yml).
#
# Targets:
#   core    (default)  infrapipe + OpenTofu + git        (Alpine)
#   aws                core + AWS CLI v2                 (Alpine package)
#   pulumi             core + Pulumi CLI
#   azure              infrapipe + OpenTofu + git + Azure CLI (Debian slim; az is Python)
#
# Terraform (BUSL-1.1) is deliberately NOT bundled; OpenTofu (MPL-2.0) is.
# Not included: gcloud (never required; HTTP fallback exists), incus (needs a host daemon).

ARG ALPINE_VERSION=3.23
ARG PYTHON_IMAGE=python:3.12-slim-bookworm

# ---- fetch stages -------------------------------------------------------------
FROM alpine:${ALPINE_VERSION} AS tofu
ARG TARGETARCH
ARG TOFU_VERSION=1.13.1
ARG TOFU_SHA256_AMD64=8ccbc6f8ee21d2827715f3c6e08a9b3e0209b1e62057c05067ef117e047c1a80
ARG TOFU_SHA256_ARM64=b9614df40575cc3fc10a8a25025b7245d961da279f715ea3efff4ddae8e6938a
RUN apk add --no-cache curl unzip ca-certificates
RUN set -eu; \
    case "$TARGETARCH" in amd64) sha="$TOFU_SHA256_AMD64";; arm64) sha="$TOFU_SHA256_ARM64";; *) echo "unsupported arch $TARGETARCH" >&2; exit 1;; esac; \
    curl -fsSL -o /tmp/tofu.zip "https://github.com/opentofu/opentofu/releases/download/v${TOFU_VERSION}/tofu_${TOFU_VERSION}_linux_${TARGETARCH}.zip"; \
    echo "${sha}  /tmp/tofu.zip" | sha256sum -c -; \
    mkdir /out; unzip -q /tmp/tofu.zip tofu -d /out; chmod 0755 /out/tofu

FROM alpine:${ALPINE_VERSION} AS pulumi
ARG TARGETARCH
ARG PULUMI_VERSION=3.268.0
ARG PULUMI_SHA256_AMD64=903cafeaa9f6327e4bf53a8b7b99ae660f26198acfa804a2f982bf5de3f1de0b
ARG PULUMI_SHA256_ARM64=47c1b9283b7997337b0a373d240f771a6aeb42ee5dd2e213c14604247c7ff15a
RUN apk add --no-cache curl ca-certificates
RUN set -eu; \
    case "$TARGETARCH" in amd64) arch=x64; sha="$PULUMI_SHA256_AMD64";; arm64) arch=arm64; sha="$PULUMI_SHA256_ARM64";; *) echo "unsupported arch $TARGETARCH" >&2; exit 1;; esac; \
    curl -fsSL -o /tmp/pulumi.tgz "https://github.com/pulumi/pulumi/releases/download/v${PULUMI_VERSION}/pulumi-v${PULUMI_VERSION}-linux-${arch}.tar.gz"; \
    echo "${sha}  /tmp/pulumi.tgz" | sha256sum -c -; \
    mkdir -p /out && tar -xzf /tmp/pulumi.tgz -C /out

# ---- core ---------------------------------------------------------------------
FROM alpine:${ALPINE_VERSION} AS core
ARG TARGETARCH
RUN apk add --no-cache ca-certificates git tini \
 && git config --system --add safe.directory '*' \
 && addgroup -g 10001 infrapipe \
 && adduser -D -u 10001 -G infrapipe -h /home/infrapipe infrapipe \
 && mkdir -p /workspace && chown infrapipe:infrapipe /workspace
COPY --from=tofu /out/tofu /usr/local/bin/tofu
COPY --chmod=0755 bin/infrapipe-linux-${TARGETARCH} /usr/local/bin/infrapipe
LABEL org.opencontainers.image.title="infrapipe" \
      org.opencontainers.image.description="infrapipe CLI with OpenTofu and git" \
      org.opencontainers.image.source="https://github.com/foolswithtools/infrapipe-releases" \
      org.opencontainers.image.licenses="MIT"
ENV HOME=/home/infrapipe TF_IN_AUTOMATION=1 CHECKPOINT_DISABLE=1
USER 10001:10001
WORKDIR /workspace
ENTRYPOINT ["/sbin/tini", "--", "infrapipe"]
CMD ["--help"]

# ---- aws ----------------------------------------------------------------------
FROM core AS aws
USER root
RUN apk add --no-cache aws-cli
USER 10001:10001

# ---- pulumi -------------------------------------------------------------------
FROM core AS pulumi-cli
USER root
COPY --from=pulumi /out/pulumi/ /usr/local/bin/
USER 10001:10001

# ---- azure (Debian slim: the Azure CLI is a Python application) ---------------
FROM ${PYTHON_IMAGE} AS azure
ARG TARGETARCH
ARG AZURE_CLI_VERSION=2.91.0
RUN apt-get update \
 && apt-get install -y --no-install-recommends ca-certificates git tini \
 && rm -rf /var/lib/apt/lists/* \
 && git config --system --add safe.directory '*' \
 && python -m venv /opt/az \
 && /opt/az/bin/pip install --no-cache-dir "azure-cli==${AZURE_CLI_VERSION}" \
 && ln -s /opt/az/bin/az /usr/local/bin/az \
 && groupadd -g 10001 infrapipe \
 && useradd -m -u 10001 -g infrapipe -d /home/infrapipe infrapipe \
 && mkdir -p /workspace && chown infrapipe:infrapipe /workspace
COPY --from=tofu /out/tofu /usr/local/bin/tofu
COPY --chmod=0755 bin/infrapipe-linux-${TARGETARCH} /usr/local/bin/infrapipe
LABEL org.opencontainers.image.title="infrapipe (azure)" \
      org.opencontainers.image.description="infrapipe CLI with OpenTofu, git and Azure CLI" \
      org.opencontainers.image.source="https://github.com/foolswithtools/infrapipe-releases" \
      org.opencontainers.image.licenses="MIT"
ENV HOME=/home/infrapipe TF_IN_AUTOMATION=1 CHECKPOINT_DISABLE=1
USER 10001:10001
WORKDIR /workspace
ENTRYPOINT ["/usr/bin/tini", "--", "infrapipe"]
CMD ["--help"]

# ---- default ------------------------------------------------------------------
# `docker build .` without --target builds this stage, which is core.
FROM core AS default
