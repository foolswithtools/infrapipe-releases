# Providers Overview

Providers generate the Terraform/OpenTofu provider file (`provider-<name>.tf`, e.g. `provider-aws.tf`) for specific cloud platforms. Infrapipe ships with providers for AWS, Azure, GCP, Cloudflare, DigitalOcean, OCI, Incus, LXD, and Kubernetes.

## How Providers Work

Only `infrapipe iac init` generates files; `plan`, `apply` and `destroy` never regenerate the provider or backend file. When `iac init` runs for Terraform or OpenTofu:

1. The cloud provider type is read from `.infrapipe.yaml`.
2. The matching provider generator is selected.
3. `iac init` picks the file name (`provider-<name>.tf`; the Azure family uses `provider-azrm.tf`, `provider-azad.tf`, `provider-azapi.tf` and `provider-azCombo.tf`) and writes it, mode 0600, in the code directory. A state backend, when configured, is written beside it as `backend-<name>.tf`.
4. Provider version constraints are resolved from your `providerVersions` configuration first, then fall back to the built-in defaults listed below.

No generator renders a credential into the file: secrets reach the IaC tool through the subprocess environment. Each cloud's `credential_source` (`ambient` or `env`) defaults to `ambient` except for DigitalOcean and Cloudflare.

## Current Providers

| Provider | Registry Source | Default Version | Notes |
|----------|-----------------|-----------------|-------|
| AWS | `hashicorp/aws` | `~> 5.0` | |
| Azure (azurerm) | `hashicorp/azurerm` | `~> 4.0` | |
| Azure AD | `hashicorp/azuread` | `~> 3.0` | |
| Azure API | `Azure/azapi` | `~> 2.0` | |
| Azure combo (azureCombo) | `hashicorp/azurerm` + `hashicorp/azuread` + `Azure/azapi` | the three versions above | One file with all three providers. Uses the `cloudProvider.azurerm` block and the `azurerm`/`azuread`/`azapi` version keys |
| Cloudflare | `cloudflare/cloudflare` | `~> 5.0` | Env-only. Renders `provider "cloudflare" {}`; `{INFRAENV}_CLOUDFLARE_API_TOKEN` reaches the tool as `CLOUDFLARE_API_TOKEN` in the subprocess env, never the file |
| DigitalOcean | `digitalocean/digitalocean` | `~> 2.0` | Env-only. Renders `provider "digitalocean" {}`; `{INFRAENV}_DO_TOKEN` reaches the tool as `DIGITALOCEAN_TOKEN` in the subprocess env, never the file |
| GCP | `hashicorp/google` | `~> 6.0` | Recommends `gcloud` CLI; HTTP API fallback available |
| OCI | `oracle/oci` | `~> 6.0` | `credential_source: ambient` → `auth = InstancePrincipal\|ResourcePrincipal\|OKEWorkloadIdentity` plus `region`, with no key material. `env` renders only `auth = "ApiKey"`; the `{INFRAENV}_*` API signing key reaches the tool as `OCI_*` (Terraform/OpenTofu) or `TF_VAR_*` (Pulumi) in the subprocess env, never the file (see [cloudProvider.oci](../configuration-reference.md#cloudprovideroci)) |
| Incus | `lxc/incus` | `~> 0.2` | Community fork of LXD. Needs a local Incus daemon only for the ambient local socket; an env-mode remote needs no local installation. `credential_source: ambient`: always the empty block, i.e. the local unix socket; a set `{ENV}_INCUS_ADDR` is an error. `credential_source: env`: the empty block, or a `remote {}` block with the address when `{ENV}_INCUS_ADDR` is set. Its shape follows the lxc/incus major `providerVersions.incus` admits: 0.x splits an `https://` address into `scheme`/`address`/`port` with `default = true`; v1 (e.g. `~> 1.0`) renders the address as a URL plus provider-level `default_remote`; a constraint admitting both majors (e.g. `>= 0.2`) is refused. No credential in the file: `INCUS_CONF` via env, and a set `{ENV}_INCUS_TOKEN` renders `token = var.infrapipe_incus_token`, filled via `TF_VAR_infrapipe_incus_token` |
| LXD | `terraform-lxd/lxd` | `~> 2.0` | Canonical LXD. Works remotely without local installation. `credential_source: ambient`: always the empty block, i.e. the local unix socket; a set `{ENV}_LXD_ADDR` is an error. `credential_source: env`: the empty block, or `remote {}` with the address when `{ENV}_LXD_ADDR` is set (no credential in the file; a set `{ENV}_LXD_TOKEN` renders `token = var.infrapipe_lxd_token`, filled via `TF_VAR_infrapipe_lxd_token`) |
| Kubernetes | `hashicorp/kubernetes` | `~> 2.0` | K8s resource management. `credential_source: ambient` uses the pod's service account (no variables); `env` maps `{INFRAENV}_KUBECONFIG` to `KUBE_CONFIG_PATH` (Terraform/OpenTofu) or `KUBECONFIG` (Pulumi) — see [cloudProvider.kubernetes](../configuration-reference.md#cloudproviderkubernetes). Live tested with remote EC2 k3s via both Terraform and OpenTofu |

## Provider and IaC Type Compatibility

The following table shows which IaC types each provider supports. It is descriptive: infrapipe does not reject other pairings. Bicep and ARM ignore `cloudProvider.type` and always log az in with the `cloudProvider.azurerm` credentials; CloudFormation always uses AWS credentials.

| Provider | IaC Types Supported |
|----------|---------------------|
| AWS | terraform, tofu, cloudformation, pulumi |
| Azure (azurerm) | terraform, tofu, bicep, arm, pulumi |
| Azure AD (azuread) | terraform, tofu, pulumi |
| Azure API (azapi) | terraform, tofu, pulumi |
| Azure combo (azureCombo) | terraform, tofu, pulumi |
| Cloudflare | terraform, tofu, pulumi |
| DigitalOcean | terraform, tofu, pulumi |
| GCP | terraform, tofu, pulumi |
| OCI | terraform, tofu, pulumi |
| Incus | terraform, tofu, pulumi |
| LXD | terraform, tofu, pulumi |
| Kubernetes | terraform, tofu, pulumi |
