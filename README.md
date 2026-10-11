# Infrapipe

> Opinionated CLI for provisioning secure cloud infrastructure.
> One workflow across Terraform, OpenTofu, Pulumi, CloudFormation, Bicep, and ARM templates.
> One command set across AWS, Azure, GCP, Cloudflare, DigitalOcean, OCI, Incus, LXD, and Kubernetes.

> **Binaries only.** This repository publishes the compiled `infrapipe` binaries and
> their documentation. **The source code is not published.** Infrapipe is released
> under the MIT license (see [LICENSE](LICENSE)).
> Download releases from the [releases page](https://github.com/foolswithtools/infrapipe-releases/releases).

## Why Infrapipe

Provisioning cloud infrastructure securely requires coordinating multiple tools -- IaC engines, cloud providers, state backends, secret managers, and CI/CD systems -- each with its own configuration surface. Infrapipe eliminates that complexity by providing a single, opinionated workflow that enforces security-first defaults. Fewer choices means fewer mistakes, faster onboarding, and consistent infrastructure across teams.

## Quick Start

### Install

Every release ships checksummed binaries for **linux/amd64, linux/arm64, darwin/amd64, darwin/arm64, and windows/amd64** as [GitHub Release assets](https://github.com/foolswithtools/infrapipe-releases/releases).

**Linux and macOS (recommended)** -- the installer detects your platform, verifies the SHA256 checksum, and installs:

```bash
# Latest release
curl -fsSL https://raw.githubusercontent.com/foolswithtools/infrapipe-releases/main/install.sh | bash

# Pin a specific version / choose the install directory
curl -fsSL https://raw.githubusercontent.com/foolswithtools/infrapipe-releases/main/install.sh | bash -s -- --version 0.0.133 --install-dir "$HOME/.local/bin"
```

**Manual install with checksum verification (Linux/macOS)**

```bash
ASSET="infrapipe-$(uname -s | tr '[:upper:]' '[:lower:]')-$(uname -m | sed 's/x86_64/amd64/; s/aarch64/arm64/')"
curl -fsSLO "https://github.com/foolswithtools/infrapipe-releases/releases/latest/download/${ASSET}"
curl -fsSLO "https://github.com/foolswithtools/infrapipe-releases/releases/latest/download/${ASSET}.sha256"
sha256sum --check "${ASSET}.sha256"          # macOS: shasum -a 256 -c "${ASSET}.sha256"
sudo install -m 0755 "${ASSET}" /usr/local/bin/infrapipe
infrapipe version
# For a specific version, replace latest/download with download/X.Y.Z
```

**Windows** -- download `infrapipe-windows-amd64.exe` and its `.sha256` from the [releases page](https://github.com/foolswithtools/infrapipe-releases/releases/latest), then verify:

```powershell
Get-FileHash infrapipe-windows-amd64.exe -Algorithm SHA256   # compare with the .sha256 file
```

**Docker** -- a signed, multi-arch (amd64, arm64) image with infrapipe, OpenTofu and git, running as a non-root user:

```bash
docker pull ghcr.io/foolswithtools/infrapipe:latest
docker run --rm ghcr.io/foolswithtools/infrapipe:latest version

# run against the current directory (mount your project and pass credentials as env vars)
docker run --rm -v "$PWD:/workspace" -e AWS_ACCESS_KEY_ID -e AWS_SECRET_ACCESS_KEY \
  ghcr.io/foolswithtools/infrapipe:latest validate system
```

| Tag | Contents | Compressed pull size (amd64 / arm64) |
|---|---|---|
| `:latest`, `:X.Y.Z` | infrapipe, OpenTofu, git | about 53 MB / 49 MB |
| `:aws`, `:X.Y.Z-aws` | core + AWS CLI v2 | about 94 MB / 89 MB |
| `:pulumi`, `:X.Y.Z-pulumi` | core + Pulumi CLI | about 174 MB / 158 MB |
| `:azure`, `:X.Y.Z-azure` | infrapipe, OpenTofu, git + Azure CLI (Debian slim) | about 234 MB / 228 MB |

Sizes are for release 0.0.136 and will drift. All images run as a non-root user (uid 10001) in `/workspace`, and are signed and carry an SBOM attestation.

Terraform is not bundled (OpenTofu is). OpenTofu does not support the `oci` state backend, which needs Terraform 1.12 or later; if you use that backend, build your own image from this one with Terraform added. `gcloud` is not included because infrapipe does not require it, and `incus` is not included because it needs a daemon on the host.

To run infrapipe in server mode in a container, publish port 8080 and pass the authentication and TLS options described in [Server Mode](docs/server-mode.md):

```bash
docker run --rm -p 8080:8080 -v "$PWD:/workspace" ghcr.io/foolswithtools/infrapipe:latest serve --addr :8080
```

The server answers `GET /api/v1/health` with `{"status":"ok"}` without authentication, which you can use for container health checks.

What is inside each image, with licences and source pointers, is listed in [IMAGE_NOTICES.md](IMAGE_NOTICES.md). Images and signatures for a release appear shortly after the release itself.

### Verifying a download

Every release asset has a SHA256 checksum file (`<asset>.sha256`); see the manual install steps above.

Binaries, checksum files and SBOMs are signed with [cosign](https://docs.sigstore.dev/) (keyless, GitHub OIDC); each asset has a matching `<asset>.sigstore.json` bundle and the SBOM is `<binary>.spdx.json`:

```bash
cosign verify-blob \
  --bundle infrapipe-linux-amd64.sigstore.json \
  --certificate-identity "https://github.com/foolswithtools/infrapipe-releases/.github/workflows/sign-release.yml@refs/heads/main" \
  --certificate-oidc-issuer https://token.actions.githubusercontent.com \
  infrapipe-linux-amd64
```

Container images are signed the same way:

```bash
cosign verify ghcr.io/foolswithtools/infrapipe:latest \
  --certificate-identity "https://github.com/foolswithtools/infrapipe-releases/.github/workflows/image.yml@refs/heads/main" \
  --certificate-oidc-issuer https://token.actions.githubusercontent.com
```

Release tags are bare numbers (`0.0.133`, no leading `v`) and are never moved or re-cut once published.

### Behind a corporate proxy or an artifact repository

Release downloads from `github.com` redirect to `release-assets.githubusercontent.com`; allow-list that host (and `github.com`) or fetch through your artifact repository's remote/proxy repository pointed at this repo's releases. Asset names are stable and a published tag is never moved or re-cut, so version-pinned downloads are safe to cache. Container images (`ghcr.io/foolswithtools/infrapipe`) can be proxied the same way.

> The source is not published, so there is no `go install` and no build-from-source path.

## Prerequisites

Infrapipe requires these tools depending on your configuration:

| Tool | Required When | Install |
|------|--------------|---------|
| Git | Always | [git-scm.com](https://git-scm.com) |
| Terraform | `IaC.type: terraform` | [developer.hashicorp.com/terraform/install](https://developer.hashicorp.com/terraform/install) |
| OpenTofu | `IaC.type: tofu` | [opentofu.org/docs/intro/install](https://opentofu.org/docs/intro/install) |
| AWS CLI | `IaC.type: cloudformation`; on `cloudProvider.type: aws`, `cloudProvider.aws.exec_role_arn` (any engine) or Pulumi with `{ENV}_AWS_ASSUME_ROLE_ARN` (STS via the CLI); recommended only for an `s3` state backend | [aws.amazon.com/cli](https://aws.amazon.com/cli/) |
| Azure CLI | `IaC.type: bicep` or `IaC.type: arm`; the Azure family with `credential_source: ambient` and an effective `ambient_method: azure_cli` (any engine); recommended only for an `azurerm` state backend | [learn.microsoft.com](https://learn.microsoft.com/en-us/cli/azure/install-azure-cli) |
| Pulumi CLI | `IaC.type: pulumi` | [pulumi.com/docs/install](https://www.pulumi.com/docs/install/) |
| Google Cloud SDK | Recommended only: `cloudProvider.type: gcp` or a `gcs` state backend (`IaC.<terraform\|tofu>.backend: gcs`) on any cloud | [cloud.google.com/sdk](https://cloud.google.com/sdk/docs/install) |
| Incus daemon | `cloudProvider.type: incus` with `credential_source: ambient` (recommended only with `env`) | [linuxcontainers.org](https://linuxcontainers.org/incus/docs/main/installing/) |

**Note:** Google Cloud SDK (`gcloud`) is never required: `validate system` reports it as a recommendation for a GCP cloud or a `gcs` state backend and does not fail when it is missing. Only `validate backend` runs it, for a `gcs` backend. When `gcloud` is not installed, `validate backend` falls back to the GCS JSON API. With `credential_source: ambient` (the GCP default) that fallback needs no `GOOGLE_APPLICATION_CREDENTIALS`: it asks the metadata server for the ambient identity, or type-checks the ADC file when one is set. With `credential_source: env` it still needs `GOOGLE_APPLICATION_CREDENTIALS`.

**Note:** With the default `credential_source: ambient`, Incus and LXD use the local daemon's unix socket, so the daemon must run on the same host. With `credential_source: env` and `{ENV}_INCUS_ADDR` set, infrapipe writes the remote into the generated `remote {}` block. The lxc/incus provider (0.x and v1) documents that this works with no local Incus installation. `validate system` therefore requires the local `incus` binary only in `ambient` mode; with `env` it reports a missing binary as a recommendation and does not fail.

**Note:** `validate system` requires the AWS CLI and Azure CLI only on the paths an executor runs them; for an `s3` or `azurerm` state backend, which only `validate backend` checks with them, a missing CLI is reported as a recommendation and does not fail. The STS paths do not apply with `auth_mode: environment`. On AWS and the Azure family it resolves the deployment like `validate secrets`, so the credential-source migration guard fails it too.

Run `infrapipe validate system` to check if your system meets all requirements.

### Configure

Generate a config interactively, or create one manually:

```bash
# Interactive wizard (recommended for first-time setup)
infrapipe init config
```

Or create a `.infrapipe.yaml` manually in your project root:

```yaml
# Required -- choose your IaC engine
IaC:
  type: terraform            # terraform | tofu | cloudformation | bicep | arm | pulumi
  terraform:
    version: "1.7.0"
    backend: s3
    key: "my-project/terraform.tfstate"
    region: "us-east-1"

# Required -- target cloud platform
cloudProvider:
  type: aws                  # aws | azurerm | azuread | azapi | azureCombo | gcp | cloudflare | digitalocean | oci | incus | lxd | kubernetes
  aws:
    region: "us-east-1"

# CI/CD execution context
cicd:
  type: local
  local:
    enabled: true

# Secret management
secrets:
  type: envars
  envars:
    enabled: true

# Source control
scm:
  gitcli:
    version: "2.40"
  remote: origin

# Deployment mappings (branch -> environment)
applications:
  deployment:
    dev:
      branch: develop
      infraenv: dev
      appenv: development
      postfix: "-dev"
      domain: dev.example.com
```

### Run

```bash
infrapipe validate system     # Check system tool requirements
infrapipe validate config     # Check config file is valid
infrapipe validate secrets    # Check credentials are set
infrapipe validate backend    # Check state backend is accessible
infrapipe iac init            # Generate provider/backend config
infrapipe iac plan            # Preview infrastructure changes
infrapipe iac apply           # Apply infrastructure changes
```

### LLM Integration (Optional)

Configure an LLM provider for AI-powered features. Three providers supported:

```yaml
# In .infrapipe.yaml — choose one:
llm:
  enabled: true
  provider: "anthropic"         # or "openai" or "ollama"
  model: "claude-sonnet-4-20250514"  # or "gpt-4o" or "llama3.1:8b"
  apiKeyEnv: "ANTHROPIC_API_KEY"     # or "OPENAI_API_KEY" (not needed for ollama)
```

```bash
# Anthropic (cloud)
export ANTHROPIC_API_KEY=sk-ant-your-key-here

# OR OpenAI (cloud)
export OPENAI_API_KEY=sk-your-key-here

# OR Ollama (local — no API key, data stays on your machine)
# Just install Ollama and pull a model: ollama pull llama3.1:8b

infrapipe validate system --fix   # AI generates platform-specific install scripts
infrapipe iac plan                # AI explains the plan in natural language
infrapipe iac apply               # AI reviews .tf files before applying
```

When enabled, `iac plan` displays an "AI Explanation" of what the plan will change, and `iac apply` shows an "AI Config Review" with security findings before applying. LLM features are optional — if disabled or the key is missing, infrapipe works normally without them. LLM failures never block IaC operations.

In server mode, the server handles all LLM calls. The client displays the results without needing an API key.

### Credentials

Infrapipe uses the current **git branch** to determine which environment to deploy to. Your `.infrapipe.yaml` maps branches to environments, and the `infraenv` field becomes the prefix for per-environment variables (`DEV_…`, `PROD_…`). If the branch isn't found in the config, infrapipe falls back to the `default` deployment entry.

Where the cloud credentials come from is set per cloud by `credential_source: ambient | env` (for example `cloudProvider.aws.credential_source`):

- **`ambient`** uses the host's workload identity: an EC2 instance profile (through IMDSv2), an ECS task role, EKS IRSA or Pod Identity, and the equivalents on other clouds. No static keys are required or exported.
- **`env`** uses the `{INFRAENV}_*` static credential variables, for example `DEV_AWS_ACCESS_KEY`/`DEV_AWS_SECRET_KEY` or `DEV_AZ_CLIENT_ID`.

**AWS defaults to `ambient`.** With no `credential_source`, infrapipe runs AWS operations as the host's workload identity. Per-environment identifiers still come from the environment: `{INFRAENV}_AWS_TFSTATE_S3_BUCKET` for the S3 backend and, optionally (in both modes), `{INFRAENV}_AWS_ASSUME_ROLE_ARN` for the role to assume. Each state backend's variables are required whatever the cloud (see `docs/configuration-reference.md`, State backend variables). The **Azure family** (`azurerm`, `azuread`, `azapi`, `azureCombo`), **GCP**, **OCI**, **Kubernetes**, **Incus** and **LXD** also default to `ambient` (see below). DigitalOcean and Cloudflare are `env`-only.

```yaml
cloudProvider:
  type: aws
  aws:
    region: us-east-1
    # credential_source: ambient   # the default for aws: instance profile (IMDSv2), task role, IRSA, Pod Identity
    credential_source: env         # opt out: keep using DEV_AWS_ACCESS_KEY / DEV_AWS_SECRET_KEY
```

**Migration guard (active for AWS from this release).** If `credential_source` is unset but the static keys are present, infrapipe never silently picks either identity. It stops before any IaC tool runs:

```text
credential_source not set for aws but static credential variables are present (DEV_AWS_ACCESS_KEY) — set cloudProvider.aws.credential_source: env (keep using these variables) or ambient (use the workload identity)
```

Add `credential_source: env` to keep using the keys, or remove them and set `ambient`.

Two more things change for AWS users with no `credential_source`:

- **`AWS_ACCESS_KEY_ID`/`AWS_SECRET_ACCESS_KEY` in infrapipe's own environment now fail** (for example the default output of `aws-actions/configure-aws-credentials` in GitHub Actions). In `ambient` mode the SDK chain would use those keys instead of the workload identity, so infrapipe refuses to run and names the variable. Either use web identity (`AWS_WEB_IDENTITY_TOKEN_FILE` + `AWS_ROLE_ARN`, which ambient mode accepts), or set `credential_source: env` and pass the keys as `{INFRAENV}_AWS_ACCESS_KEY`/`_SECRET_KEY`/`_SESSION_TOKEN`.
- **Pulumi writes `Pulumi.<stack>.yaml`.** pulumi-aws disables the instance metadata service by default, so in `ambient` mode infrapipe sets `aws:skipMetadataApiCheck false` on the stack when it is unset. That writes `Pulumi.<stack>.yaml` in your code directory (in server mode, the server's checkout): commit it, or set the key yourself. An explicit value is never changed. Running on EC2 inside a container needs an IMDSv2 hop limit of 2; see [Operating with workload identity](docs/configuration-reference.md#operating-with-workload-identity) for that and the other operational gotchas, and the [configuration reference](docs/configuration-reference.md#credential-source) for the full rules.

**Kubernetes defaults to `ambient`.** With no `credential_source`, infrapipe runs Kubernetes operations as the pod's in-cluster service account: no kubeconfig is required or exported, and the generated block is `provider "kubernetes" {}`. The migration guard is active for Kubernetes too: `DEV_KUBECONFIG` or `DEV_KUBE_TOKEN` set with no `credential_source` stops infrapipe with the same message (naming the Kubernetes variables). **To keep using `DEV_KUBECONFIG`, set `credential_source: env`:**

```yaml
cloudProvider:
  type: kubernetes
  kubernetes:
    credential_source: env   # keep using DEV_KUBECONFIG (and DEV_KUBE_CONTEXT/HOST/TOKEN/CA_CERT)
```

Outside a pod, ambient Kubernetes auth has no identity to use: `validate secrets` warns, and you need `credential_source: env` (an exec-plugin kubeconfig such as `aws eks get-token` still uses the host's cloud identity). The service account needs RBAC for what your code manages; see [cloudProvider.kubernetes](docs/configuration-reference.md#cloudproviderkubernetes) for an example.

**Incus and LXD default to `ambient`: the local daemon's unix socket.** **If you set `DEV_INCUS_ADDR` or `DEV_LXD_ADDR` (or `_TOKEN`, `_CONF` (Incus only), `_TLS_CLIENT_CERT/KEY`) without `credential_source`, infrapipe now stops** with the migration-guard message naming those variables, locally, via `--remote` and as HTTP 400; before this release it ran against your remote daemon. **To keep targeting the remote, set `credential_source: env`:**

```yaml
cloudProvider:
  type: incus                # or lxd (then the block is lxd:)
  incus:
    credential_source: env   # keep using DEV_INCUS_ADDR (and _REMOTE/_TOKEN/_CONF)
```

With no variables nothing changes: that config already used the local socket. Access is whatever the socket's group grants (Incus: `incus-admin`, or `incus` for the restricted per-user socket; LXD: `lxd` or the snap's `daemon.group`); see [Incus and LXD credential source](docs/configuration-reference.md#incus-and-lxd-credential-source).

**Azure defaults to `ambient`.** With no `credential_source`, infrapipe runs `azurerm`, `azuread`, `azapi` and `azureCombo` operations as the host's Azure identity, picked per run (`cloudProvider.azurerm.ambient_method`, default `auto`):

- **VM, VMSS, ACI, AKS node (managed identity, `msi`).** With no `{INFRAENV}_AZ_CLIENT_ID` the system-assigned identity is used; set `{INFRAENV}_AZ_CLIENT_ID` to the client id of a user-assigned identity to pick that one. On a shared host, a different user-assigned identity per environment keeps `DEV` and `PROD` apart.
- **AKS Workload Identity (`workload_identity`).** Picked automatically when the webhook has injected `AZURE_FEDERATED_TOKEN_FILE`, `AZURE_CLIENT_ID` and `AZURE_TENANT_ID`; nothing else to set.
- **Container Apps and App Service (`azure_cli`).** Picked automatically when `IDENTITY_ENDPOINT` and `IDENTITY_HEADER` are set: the azurerm provider's MSI client cannot use that endpoint (terraform-provider-azurerm#25726), so infrapipe logs `az` in as the identity in a private config directory and Terraform uses the CLI session. Needs az ≥ 2.73.0.

Ambient Azure requires only `{INFRAENV}_AZ_SUBSCRIPTION_ID`, plus `{INFRAENV}_AZ_TFSTATE_STORAGE_ACCOUNT` for an `azurerm` state backend; no client secret. The state backend authenticates with Entra ID (`use_azuread_auth`), so the identity needs **Storage Blob Data Contributor** on the state container (no storage-key permission), plus whatever roles your code deploys. An inherited `ARM_CLIENT_SECRET`, `AZURE_CLIENT_SECRET` (or another static Azure credential) in infrapipe's own environment fails the run, because the SDK chain would use it instead of the identity.

**The migration guard is active for Azure from this release.** If `DEV_AZ_CLIENT_SECRET` is set and `credential_source` is not, infrapipe stops before any tool runs (locally, via `--remote` and as HTTP 400):

```text
credential_source not set for azurerm but static credential variables are present (DEV_AZ_CLIENT_SECRET) — set cloudProvider.azurerm.credential_source: env (keep using these variables) or ambient (use the workload identity)
```

Before this release that configuration ran as the service principal. **To keep using the client secret, set `credential_source: env`** (in the `azurerm` block, which `azuread`, `azapi` and `azureCombo` also read):

```yaml
cloudProvider:
  type: azurerm              # or azuread, azapi, azureCombo
  azurerm:
    credential_source: env   # keep using DEV_AZ_CLIENT_ID / _CLIENT_SECRET / _TENANT_ID / _SUBSCRIPTION_ID
```

`DEV_AZ_CLIENT_ID`, `DEV_AZ_TENANT_ID` and `DEV_AZ_SUBSCRIPTION_ID` alone are identifiers, not credentials, and do not trip the guard. See [cloudProvider.azurerm](docs/configuration-reference.md#cloudproviderazurerm) for the variables per mode and the tool-version notes.

**GCP defaults to `ambient`.** With no `credential_source`, infrapipe runs GCP operations as Google Application Default Credentials find them, and exports no key file:

- **GCE, Cloud Run, GKE Workload Identity:** the metadata server's service account. Nothing to set.
- **Workload identity federation** (GitHub Actions, AWS, Azure, OIDC): an `external_account` ADC file in `GOOGLE_APPLICATION_CREDENTIALS`.
- **A workstation:** `gcloud auth application-default login`.

Ambient GCP requires only `{INFRAENV}_GCP_PROJECT` and `{INFRAENV}_GCP_REGION`, plus `{INFRAENV}_GCP_TFSTATE_BUCKET` for a `gcs` state backend. An inherited `service_account` key (in `GOOGLE_APPLICATION_CREDENTIALS`, `GOOGLE_CREDENTIALS` and the like) fails the run in `ambient` mode, because ADC would use it instead of the identity.

**One identity per environment: `{INFRAENV}_GCP_IMPERSONATE_SERVICE_ACCOUNT`.** A host has one ambient identity. In server mode one server deploys every environment as that identity. To keep `DEV` and `PROD` apart, give each environment its own deploying service account, for example `DEV_GCP_IMPERSONATE_SERVICE_ACCOUNT=deploy@dev-project.iam.gserviceaccount.com`. The generated provider and `gcs` backend then impersonate it, and the host identity needs only **Service Account Token Creator** on each one. This works in both modes.

**The migration guard is active for GCP from this release.** If `DEV_GCP_CREDENTIALS` is set and `credential_source` is not, infrapipe stops before any tool runs (locally, via `--remote` and as HTTP 400):

```text
credential_source not set for gcp but static credential variables are present (DEV_GCP_CREDENTIALS) — set cloudProvider.gcp.credential_source: env (keep using these variables) or ambient (use the workload identity)
```

Before this release that configuration ran with the key file. **To keep using the key, set `credential_source: env`:**

```yaml
cloudProvider:
  type: gcp
  gcp:
    credential_source: env   # keep using DEV_GCP_CREDENTIALS (mapped to GOOGLE_APPLICATION_CREDENTIALS)
```

In `env` mode `validate secrets` now requires `DEV_GCP_CREDENTIALS`; before this release it passed without it. See [cloudProvider.gcp](docs/configuration-reference.md#cloudprovidergcp) for the variables per mode.

**OCI defaults to `ambient`.** With no `credential_source`, infrapipe runs OCI operations as the instance principal (or the resource or OKE workload principal; `cloudProvider.oci.ambient_principal`, default `auto`), and the generated block carries only `auth` and `region`, no key material. Set `cloudProvider.oci.region` or `{INFRAENV}_OCI_REGION`. The principal needs a dynamic group and policies; see [OCI IAM setup](docs/configuration-reference.md#oci-iam-setup).

**The migration guard is active for OCI from this release.** If `DEV_USER_OCID`, `DEV_OCI_FINGERPRINT`, `DEV_OCI_PRIVATE_KEY`, `DEV_OCI_PRIVATE_KEY_PATH` or the legacy `DEV_OCI_USER_OCID` is set and `credential_source` is not, infrapipe stops before any tool runs (locally, via `--remote` and as HTTP 400) with the same message, naming the OCI variables. Before this release that configuration ran with the API signing key. **To keep using the key, set `credential_source: env`:**

```yaml
cloudProvider:
  type: oci
  oci:
    credential_source: env   # keep using DEV_TENANCY_OCID / _USER_OCID / _OCI_FINGERPRINT / _OCI_PRIVATE_KEY(_PATH)
```

In `env` mode, infrapipe maps the prefixed variables to the standard variables each tool reads, in the tool's subprocess environment:

- **Terraform/OpenTofu:** AWS (`{INFRAENV}_AWS_ACCESS_KEY` → `AWS_ACCESS_KEY_ID`, …), Azure (`{INFRAENV}_AZ_CLIENT_ID`/`_CLIENT_SECRET`/`_TENANT_ID`/`_SUBSCRIPTION_ID` → `ARM_*`), GCP (`{INFRAENV}_GCP_CREDENTIALS` → `GOOGLE_APPLICATION_CREDENTIALS`), Kubernetes (`{INFRAENV}_KUBECONFIG` → `KUBE_CONFIG_PATH` and friends), Incus and LXD (`{INFRAENV}_INCUS_CONF` → `INCUS_CONF`; `{INFRAENV}_<P>_TOKEN` → `TF_VAR_infrapipe_<p>_token`, which the generated `remote {}` block references as `token = var.infrapipe_<p>_token`), Cloudflare (`{INFRAENV}_CLOUDFLARE_API_TOKEN` → `CLOUDFLARE_API_TOKEN`), DigitalOcean (`{INFRAENV}_DO_TOKEN` → `DIGITALOCEAN_TOKEN`) and OCI (`OCI_TENANCY_OCID`, `OCI_USER_OCID`, `OCI_FINGERPRINT`, `OCI_PRIVATE_KEY` or `OCI_PRIVATE_KEY_PATH`, `OCI_REGION`; the generated block carries only `auth = "ApiKey"`; not `TF_VAR_*`, which Terraform would also hand to any same-named variable your code declares). Credentials are never written into generated `.tf` files, and with `llm.enabled` the generated `provider-*.tf`/`backend-*.tf` files are never sent to the LLM and the value of any set `{INFRAENV}_*` secret variable (tokens, keys, client secrets) is redacted from your own `.tf` files and from the plan text before upload. Contents of files that path variables point to are not redacted.
- **Pulumi:** the same AWS and Azure mappings, plus GCP (`GOOGLE_PROJECT`, `GOOGLE_APPLICATION_CREDENTIALS`), Cloudflare, DigitalOcean, OCI (`TF_VAR_tenancy_ocid`, `TF_VAR_user_ocid`, `TF_VAR_fingerprint`, `TF_VAR_private_key` or `TF_VAR_private_key_path`, `TF_VAR_region`; in `ambient` mode only `TF_VAR_auth` and `TF_VAR_region`), Kubernetes (`KUBECONFIG`), Incus and LXD.
- **CloudFormation:** AWS.
- **Bicep/ARM:** the `az` CLI ignores credential environment variables (Azure/azure-cli#10241), so infrapipe logs `az` in explicitly, in a private config directory, for every operation: as the `{INFRAENV}_AZ_*` service principal in `env` mode, as the workload identity in `ambient` mode. The host's own `az login` session (`~/.azure`) is never used.

For Pulumi and CloudFormation, `{INFRAENV}_AWS_ASSUME_ROLE_ARN` is assumed via STS from the base identity (the keys in `env` mode, the workload identity in `ambient` mode), and the tool runs with the role's session credentials (`AWS_ROLE_ARN` is never exported). Standard SDK variables are never read as configuration; infrapipe strictly enforces its own `{INFRAENV}_` convention.

### Server Mode and Remote Execution

`infrapipe serve` exposes plan, apply, destroy and validate over HTTP/JSON, and any command run with `--remote <host:port>` executes on that server instead of locally.

```bash
# Server: API-key auth over TLS (the key is read from INFRAPIPE_API_KEY by serve only)
INFRAPIPE_API_KEY=mysecret infrapipe serve --addr :8443 --auth-mode apikey --tls-cert server.pem --tls-key server-key.pem

# Client: the key from INFRAPIPE_REMOTE_API_KEY (or --api-key, which wins); --remote-ca trusts a private CA
INFRAPIPE_REMOTE_API_KEY=mysecret infrapipe --remote server:8443 --remote-ca ca.pem validate iac

# Server and client with mTLS (the default auth mode)
infrapipe serve --addr :8443 --tls-cert server.pem --tls-key server-key.pem --tls-ca ca.pem
infrapipe --remote server:8443 --remote-cert client.pem --remote-key client-key.pem --remote-ca ca.pem iac plan

# Local development only: no TLS, no auth
infrapipe serve --addr :8080 --auth-mode none --insecure
infrapipe --remote localhost:8080 iac plan
```

Client flags: `--remote-cert` and `--remote-key` (a client certificate for mTLS; one without the other is an error), `--remote-ca` (CA certificate to verify the server; without it the system roots are used) and `--api-key`, whose value defaults to the client-only `INFRAPIPE_REMOTE_API_KEY` environment variable; prefer the variable, since a flag shows in the process listing and shell history. Setting any of them, or the variable, makes the client use https. With none of them it uses plain http, which only a `serve --insecure` server accepts, so an API key is never sent in cleartext.

### Multi-Stage Workflows

Chain multiple infrapipe runs by passing outputs between stages. Any engine can produce outputs, and any engine consumes `--input-vars` (Terraform/OpenTofu as a tfvars file; Pulumi as encrypted stack config, the values on stdin; CloudFormation as stack parameters, bound at `iac plan`; Bicep/ARM as a temporary `--parameters @<file>`):

```bash
infrapipe iac apply --config .infrapipe-aws.yaml --output-vars /tmp/outputs.json
infrapipe iac apply --config .infrapipe-k8s.yaml --input-vars /tmp/outputs.json
```

See [docs/multi-stage.md](docs/multi-stage.md) for full documentation.

## Supported Platforms

| Cloud Provider | IaC Tools                                   | Default credential source |
|----------------|---------------------------------------------|---------------------------|
| AWS            | Terraform, OpenTofu, Pulumi, CloudFormation | ambient (instance profile, ECS task role, EKS IRSA or Pod Identity) |
| Azure (`azurerm`, `azuread`, `azapi`, `azureCombo`) | Terraform, OpenTofu, Pulumi, Bicep, ARM | ambient (managed identity, AKS workload identity or the az CLI) |
| Cloudflare     | Terraform, OpenTofu, Pulumi                 | env (API token)           |
| DigitalOcean   | Terraform, OpenTofu, Pulumi                 | env (API token)           |
| GCP            | Terraform, OpenTofu, Pulumi                 | ambient (Google ADC)      |
| OCI            | Terraform, OpenTofu, Pulumi                 | ambient (instance, resource or OKE workload principal) |
| Incus          | Terraform, OpenTofu, Pulumi                 | ambient (local socket); env for a remote |
| LXD            | Terraform, OpenTofu, Pulumi                 | ambient (local socket); env for a remote |
| Kubernetes     | Terraform, OpenTofu, Pulumi                 | ambient (in-cluster service account); env for a kubeconfig |

**State backends are not tied to the cloud.** `IaC.<tool>.backend` chooses the backend for any cloud: `s3`, `azurerm`, `gcs`, `oci` (Terraform ≥ 1.12 only, not OpenTofu) or `local` (the default). Any other name fails `validate config` and `iac init`. Pulumi uses its own `pulumi login` backend.

`azurerm`, `azuread` and `azapi` each declare one Terraform provider; `azureCombo` declares the azurerm, azuread and azapi providers together, for projects that use all three in one configuration.

## Configuration

Infrapipe is configured through a single `.infrapipe.yaml` file placed in your project root. The configuration defines your IaC engine, cloud provider, CI/CD context, secrets management, source control, deployment mappings, and provider version constraints.

For the full schema reference with all fields, defaults, and valid values, see [docs/configuration-reference.md](docs/configuration-reference.md).

### Provider Versions

Override default Terraform/OpenTofu provider version constraints:

```yaml
providerVersions:
  aws: "~> 5.0"
  azurerm: "~> 4.0"
  azuread: "~> 3.0"
  azapi: "~> 2.0"
  cloudflare: "~> 5.0"
  digitalocean: "~> 2.0"
  oci: "~> 6.0"
  gcp: "~> 6.0"
  incus: "~> 0.2"
  lxd: "~> 2.0"
  kubernetes: "~> 2.0"
```

All fields are optional. When omitted, sensible defaults are used. Exact version pins (e.g., `4.13.0`) trigger a warning because they prevent automatic security patches.

### Additional Providers

Infrapipe automatically generates `required_providers` declarations for secondary providers alongside the primary cloud provider. This eliminates the need for manual `extra_providers_override.tf` files.

```yaml
additionalProviders:
  helm:
    source: hashicorp/helm
    version: "~> 2.0"
  kubernetes:
    source: hashicorp/kubernetes
    version: "~> 2.0"
  kubectl:
    source: gavinbunney/kubectl
    version: "~> 1.14"
```

All additional providers are merged into a single `terraform { required_providers { ... } }` block alongside the primary provider. Auto-detection scans `.tf` files for provider usage patterns (e.g., `helm_release`, `kubernetes_namespace`) and includes them automatically.

### Credential Delegation

Infrapipe supports three credential delivery modes for fine-grained access control:

| Capability | Config Key | Purpose |
|---|---|---|
| Auth Mode | `auth_mode` | How the primary role reaches Terraform (`provider` or `environment`) |
| Exec Role | `exec_role_arn` | Scoped-down credentials for subprocess exec blocks |
| Aliases | `aliases` | Additional provider instances for cross-account resources |

```yaml
cloudProvider:
  type: aws
  aws:
    region: us-west-2
    auth_mode: provider                    # "provider" (default) or "environment"
    # Literal ARNs: infrapipe does not expand ${…} placeholders in .infrapipe.yaml.
    # The primary role comes from the DEV_AWS_ASSUME_ROLE_ARN environment variable.
    exec_role_arn: arn:aws:iam::123456789012:role/eks-readonly # Optional: narrow-scope role for subprocesses
    aliases:                               # Optional: cross-account provider aliases
      security:
        assume_role_arn: arn:aws:iam::123456789012:role/security-deploy
        region: us-east-1
```

## Documentation

- [Configuration Reference](docs/configuration-reference.md) -- full `.infrapipe.yaml` schema
- [Providers Overview](docs/providers/overview.md) -- how providers work and what each one generates
- [Multi-Stage Workflows](docs/multi-stage.md) -- passing outputs between stages
- [Server Mode](docs/server-mode.md) -- `infrapipe serve`, `--remote` client mode, authentication

## Support

Problems and questions: open an issue on the releases repository.

## License

MIT. See [LICENSE](LICENSE). Only the compiled binaries are distributed; the source code is not published.
