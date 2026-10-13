# Configuration Reference

Infrapipe is configured through a `.infrapipe.yaml` file in your project root. This document describes every section, field, and valid value.

**Where infrapipe finds it:** Every command finds it the same way: `--config <path>` when given (a missing or unreadable file fails every command, `serve` included, never a fallback; `validate config` reports an unreadable one in its own check table), else `.infrapipe.yaml` in the git checkout root (the current directory outside a checkout), else `$HOME/.infrapipe.yaml`. One file is used, never a merge; a command that needs a config and finds none fails naming every path searched, and one whose file cannot be read (malformed YAML, unreadable, a `--config` without a `.yaml` extension) fails naming the file.

**Quick start:** Run `infrapipe init config` to interactively generate a valid `.infrapipe.yaml` with guided prompts for your IaC engine, cloud provider, state backend, and SDLC environments. Without `--output` it saves the file at the git checkout root (the current directory outside a checkout), the first place every command looks.

## Top-Level Structure

```yaml
IaC:              # Required -- Infrastructure as Code engine settings
cloudProvider:    # Required -- Target cloud platform
cicd:             # Optional -- CI/CD execution context
secrets:          # Optional -- Secret management
scm:              # Optional -- Source control settings
applications:     # Required -- Deployment mappings
providerVersions:    # Optional -- Provider version constraints
additionalProviders: # Optional -- Secondary provider declarations
llm:                 # Optional -- LLM integration settings
```

**Validation:** Run `infrapipe validate config` to check that your configuration file exists and parses correctly, contains valid IaC and cloud provider types and (for Terraform/OpenTofu) a valid state backend, your current git branch maps to a deployment entry, and the configured `codedir` exists. Loading the file also runs the field rules, so any of these fails the check too:

- `applications.deployment` is missing, or two entries map the same `branch`;
- a `credential_source` other than `ambient` or `env`, or `ambient` for DigitalOcean or Cloudflare;
- an `auth_mode` other than `provider` or `environment` (AWS, Azure, GCP);
- an exec role that is not literal or carries a secret: a `${…}` placeholder in `cloudProvider.aws.exec_role_arn` or any `exec_role` field, an Azure `exec_role.client_secret`, or a GCP `exec_role.impersonate_service_account` that is not a service-account e-mail;
- an unknown `cloudProvider.azurerm.ambient_method` or `cloudProvider.oci.ambient_principal`;
- an AWS alias with no `assume_role_arn`;
- an `additionalProviders` entry with no `source`.

**Multi-stage workflows:** Use `--output-vars` on `iac apply` to capture outputs, and `--input-vars` on `iac plan`, `iac apply`, or `iac destroy` to inject variables from earlier stages. See [docs/multi-stage.md](multi-stage.md) for details.

**Backend validation:** Run `infrapipe validate backend` to verify that your state backend (S3 bucket, Azure Storage container, GCS bucket, OCI bucket, Pulumi backend) is reachable. It checks the bucket or account `iac init` writes, as the identity `plan` uses. The S3 bucket is `{INFRAENV}_AWS_TFSTATE_S3_BUCKET`, checked with the `credential_source` mapping of [cloudProvider.aws](#cloudprovideraws): in `env` mode `aws` runs with `{INFRAENV}_AWS_ACCESS_KEY`/`_SECRET_KEY` (and `_SESSION_TOKEN`) as `AWS_*`, never the host's keys; in `ambient` mode an inherited `AWS_ACCESS_KEY_ID`/`AWS_SECRET_ACCESS_KEY` fails the check. With `{INFRAENV}_AWS_ASSUME_ROLE_ARN` set (and `auth_mode` not `environment`) the generated backend assumes that role, so the check does too: it runs `aws sts assume-role` (session name `infrapipe-<infraenv>`) from that base identity, then `sts get-caller-identity` and `s3api head-bucket` as the session, and reports the identity it checked as. With `cloudProvider.aws.region` set, the `sts assume-role` and `sts get-caller-identity` calls get it as `AWS_DEFAULT_REGION`, as the executor's STS call does, so a regional STS endpoint (GovCloud, China, an SCP denying the global endpoint) behaves the same in both; `head-bucket` keeps `--region` from `IaC.<terraform|tofu>.region`, the region the backend uses. The Azure storage account is `{INFRAENV}_AZ_TFSTATE_STORAGE_ACCOUNT` (checked in a temporary `AZURE_CONFIG_DIR`, never `~/.azure`, as the ambient identity in `credential_source: ambient` mode and as the `{INFRAENV}_AZ_*` service principal in `env` mode; see [cloudProvider.azurerm](#cloudproviderazurerm)). A leftover `IaC.<terraform|tofu>.bucket` or `storage_account_name` key is ignored with a warning naming the variable to set. The GCS bucket is `{INFRAENV}_GCP_TFSTATE_BUCKET`. Every bucket and account here needs the branch's deployment to resolve, in both credential modes, and an unset one fails the check before any `aws`, `az` or `gcloud` call or HTTP request. The OCI check is structural: the bucket and namespace from `{INFRAENV}_OCI_TFSTATE_BUCKET`/`_NAMESPACE`, the region and a credential mode the backend accepts. Each `aws`, `gcloud` and `pulumi` command of the check is bounded to 2 minutes, as each `az` command is, so a hang with nobody to press Ctrl-C (CI) fails as `<step> timed out after 2m0s` (for example `aws sts get-caller-identity timed out after 2m0s`). A `local` or unset Terraform/OpenTofu backend passes as local state (nothing to reach); an unregistered name fails, as in `validate config`. For GCS backends, validation uses `gcloud` when available and falls back to the GCS JSON API when the Google Cloud SDK is not installed. In `credential_source: ambient` mode (the GCP default) the fallback needs no key file: it reports the ambient identity from the metadata server, or the type of the ADC file in `GOOGLE_APPLICATION_CREDENTIALS`. In `env` mode it reads `GOOGLE_APPLICATION_CREDENTIALS`: unset is a `warn` (the bucket cannot be verified), a path to a missing file is a `fail`; see [cloudProvider.gcp](#cloudprovidergcp). For an `s3`, `azurerm`, `gcs` or `oci` backend the cloud's `credential_source` is resolved first, so the [migration guard](#credential-source) fails `validate backend` too.

---

## IaC

Configures the Infrastructure as Code engine.

| Field | Type | Required | Valid Values | Description |
|-------|------|----------|--------------|-------------|
| `type` | string | Yes | `terraform`, `tofu`, `cloudformation`, `bicep`, `arm`, `pulumi` | IaC engine to use |

### IaC.terraform

Used when `IaC.type` is `terraform`.

| Field | Type | Required | Default | Description |
|-------|------|----------|---------|-------------|
| `version` | string | No | -- | Terraform version |
| `backend` | string | No | `local` | State backend: `s3`, `azurerm`, `gcs`, `oci` (Terraform ≥ 1.12 only) or `local`. `local` or unset keeps state on local disk (no backend file). Any other value fails `validate config` and `iac init` (HTTP 400 server-side) before anything is written |
| `key` | string | For `azurerm` | -- (`oci`: `terraform.tfstate`) | State file key/path (s3, azurerm, oci); required by `azurerm`. Ignored by `gcs`, which always writes `prefix = "terraform/state"` |
| `region` | string | No | -- | S3 backend region; read only by `s3` (the `oci` backend takes `cloudProvider.oci.region` or `{INFRAENV}_OCI_REGION`) |
| `resource_group_name` | string | For `azurerm` with `credential_source: env` | -- | Azure backend resource group. Required with `cloudProvider.azurerm.credential_source: env`, where the backend lists the storage account key in it; optional in `ambient` mode (`use_azuread_auth`) |
| `container_name` | string | For `azurerm` | -- | Azure backend blob container; required by `azurerm` |

#### State backend variables

Each backend reads its own `{INFRAENV}_*` variables, whatever `cloudProvider.type` and `credential_source` are. `validate secrets` (and `POST /api/v1/validate`) requires exactly these for the configured `IaC.<terraform|tofu>.backend`, and `init config` lists them. `init config` never asks for the bucket or storage account; after the backend choice it asks only for the `IaC.<tool>` fields that backend reads: `s3` region and key, `azurerm` resource group, container and key, `oci` key, `gcs` nothing:

| `backend` | Required variables |
|-----------|--------------------|
| `s3` | `{INFRAENV}_AWS_TFSTATE_S3_BUCKET` |
| `azurerm` | `{INFRAENV}_AZ_TFSTATE_STORAGE_ACCOUNT` |
| `gcs` | `{INFRAENV}_GCP_TFSTATE_BUCKET` |
| `oci` | `{INFRAENV}_OCI_TFSTATE_BUCKET`, `{INFRAENV}_OCI_TFSTATE_NAMESPACE`, plus a region (`cloudProvider.oci.region`, else `{INFRAENV}_OCI_REGION`) and, with `cloudProvider.oci.credential_source: env`, the API-key identity (`{INFRAENV}_TENANCY_OCID`, `_USER_OCID`, `_OCI_FINGERPRINT`, `_OCI_PRIVATE_KEY_PATH`) |
| `local` or unset | none |

For `oci` the region and identity depend on the oci credential source and principal, so `validate secrets` applies the backend's own rules (shared with `iac init` and `validate backend`): it fails whenever `iac init` would refuse the backend's inputs (no region for any principal, an env-mode identity without a key *path*, `OKEWorkloadIdentity`, OpenTofu, Terraform below 1.12); in `env` mode it also requires `{INFRAENV}_OCI_PRIVATE_KEY_PATH` to name a regular file, as `validate backend` does (`iac init` renders the path verbatim, since the key may be mounted later), and the oci credential source's [migration guard](#credential-source) fires even when `cloudProvider.type` is another cloud. The variables `init config` and `validate secrets` list for `oci` follow the same inputs, so exporting exactly the ones marked required passes on every cloud: `{INFRAENV}_OCI_REGION` is **required** unless `cloudProvider.oci.region` is set (which takes precedence; the variable is then optional), on the oci cloud in `ambient` mode too (in `env` mode the oci provider reads only the variable, so it stays required), and the provider's `OCI_RESOURCE_PRINCIPAL_REGION` fallback is not offered, because the backend needs a region under every principal. `init config` writes `cloudProvider.oci.region` only for `cloudProvider.type: oci`, so on another cloud a generated config needs the variable. With `cloudProvider.oci.credential_source: env` (hand-set on another cloud, or the oci cloud in env mode) the API-key identity `{INFRAENV}_TENANCY_OCID`, `_USER_OCID`, `_OCI_FINGERPRINT` and `_OCI_PRIVATE_KEY_PATH` is required too; the key is listed by *path* only, and on the oci cloud `_OCI_PRIVATE_KEY` is no longer offered as an alternative, since the backend renders `private_key_path` and never key content.

Only `IaC.terraform.backend` and `IaC.tofu.backend` take these names. CloudFormation, Bicep and ARM have no state backend, and `IaC.pulumi.backend` is a URL (`s3://…`, `azblob://…`, `file://…`), so no backend variable is required for them.

**Azure backend note**: with `backend: azurerm`, `container_name` and `key` are required in both `credential_source` modes, and `resource_group_name` is required when `cloudProvider.azurerm.credential_source` is `env` (the account-key lookup is scoped to it) but optional in `ambient` mode, where the backend authenticates with Entra ID (`use_azuread_auth`). The azurerm backend reads `cloudProvider.azurerm.credential_source` whatever `cloudProvider.type` is. A missing field fails `iac init` (HTTP 400 server-side) naming the key, e.g. `the azurerm state backend needs IaC.terraform.container_name (the blob container that holds the state)`, before `backend-azurerm.tf` is written, `validate config` fails the same configs with the same message in its `State backend fields` row, and `validate backend` fails them with the same message before running any `az` command (one shared rule). In earlier releases the generator rendered `container_name = ""` and the failure surfaced only at `terraform init`.

**S3 backend note:** When `backend` is `s3`, the generated `backend-s3.tf` uses the assignment `assume_role = { role_arn = "..." }` instead of the deprecated top-level `role_arn` attribute (deprecated in Terraform 1.6+); OpenTofu 1.9 requires the `=`. The `assume_role` assignment is included only when `{INFRAENV}_AWS_ASSUME_ROLE_ARN` is set and `cloudProvider.aws.auth_mode` is not `environment` (credentials are then already in the environment, and assuming the role again could fail); otherwise it is omitted entirely.

**OCI backend note**: `backend: oci` generates `backend-oci.tf` for Terraform's native `oci` backend, which needs **Terraform ≥ 1.12**. A `version` below 1.12 fails `iac init`; an unset `version` logs a warning. OpenTofu has no `oci` backend (opentofu/opentofu#1011), so `IaC.tofu.backend: oci` fails `validate config` and `iac init` (HTTP 400 server-side) before anything is written. The bucket comes from `{INFRAENV}_OCI_TFSTATE_BUCKET` and the namespace from `{INFRAENV}_OCI_TFSTATE_NAMESPACE` (both required, not secret, and checked by `validate secrets` for any cloud, with the region and identity below); `key` defaults to `terraform.tfstate`; the region is `cloudProvider.oci.region`, else `{INFRAENV}_OCI_REGION`, in both `credential_source` modes (required for every principal; the env-mode *provider* differs and reads only `{INFRAENV}_OCI_REGION`, see [cloudProvider.oci](#cloudprovideroci)). The file never carries key material:

- `credential_source: ambient` renders `auth = "InstancePrincipal"` or `"ResourcePrincipal"` (chosen by `cloudProvider.oci.ambient_principal`) and `region`. `OKEWorkloadIdentity` is a hard error: Terraform's backend validation rejects it, so use `ambient_principal: instance` for state, or `credential_source: env`.
- `credential_source: env` renders `auth = "ApiKey"`, `tenancy_ocid`, `user_ocid`, `fingerprint` and `private_key_path` from `{INFRAENV}_OCI_PRIVATE_KEY_PATH`. With only `{INFRAENV}_OCI_PRIVATE_KEY` (PEM content) set, or PEM content in `{INFRAENV}_OCI_PRIVATE_KEY_PATH`, `iac init` refuses to render key content: write the key to a 0600 file and set the path.
- Bucket and namespace must be OCI names (letters, digits, `.`, `_`, `-`) and the region an OCI region identifier; the key and the env-mode identity values may not contain quotes, backslashes, `${`, `%{` or control characters.

```hcl
terraform {
  backend "oci" {
    bucket    = "tfstate"
    namespace = "axaxnpcrorw5"
    key       = "terraform.tfstate"
    region    = "us-ashburn-1"
    auth      = "InstancePrincipal"
  }
}
```

`validate backend` applies the same rules as `iac init` (one shared resolver), so a configuration `iac init` rejects fails `validate backend` too. The check is structural and calls no OCI CLI; an unset `version` is reported as a note. The state principal needs object access to the bucket; see [OCI IAM setup](#oci-iam-setup).

### IaC.tofu

Used when `IaC.type` is `tofu`. Same fields as `IaC.terraform` (including the S3 backend `assume_role` behavior described above).

| Field | Type | Required | Default | Description |
|-------|------|----------|---------|-------------|
| `version` | string | No | -- | OpenTofu version |
| `backend` | string | No | `local` | State backend: `s3`, `azurerm`, `gcs` or `local` (OpenTofu has no `oci` backend, so `oci` fails `validate config` and `iac init` too). `local` or unset keeps state on local disk (no backend file). Any other value fails `validate config` and `iac init` (HTTP 400 server-side) before anything is written |
| `key` | string | For `azurerm` | -- | State file key/path (s3, azurerm); required by `azurerm`. Ignored by `gcs`, which always writes `prefix = "terraform/state"` |
| `region` | string | No | -- | S3 backend region; read only by `s3` (the `oci` backend takes `cloudProvider.oci.region` or `{INFRAENV}_OCI_REGION`) |
| `resource_group_name` | string | For `azurerm` with `credential_source: env` | -- | Azure backend resource group. Required with `cloudProvider.azurerm.credential_source: env`, where the backend lists the storage account key in it; optional in `ambient` mode (`use_azuread_auth`) |
| `container_name` | string | For `azurerm` | -- | Azure backend blob container; required by `azurerm` |

### IaC.cloudformation

Used when `IaC.type` is `cloudformation`.

`iac init` writes nothing for CloudFormation, locally and over `--remote`: the template is yours, and credentials reach the aws CLI through the subprocess environment according to `cloudProvider.aws.credential_source`. `IaC.terraform.backend` is not read.

| Field | Type | Required | Default | Description |
|-------|------|----------|---------|-------------|
| `region` | string | No | -- | AWS region for CloudFormation |

### IaC.bicep

Used when `IaC.type` is `bicep`. Requires the Azure CLI (`az`) to be installed.

`iac init` writes nothing for Bicep, locally and over `--remote`: no provider or backend file, since az reads your template and logs in per operation as described below. `IaC.terraform.backend` is not read.

**Ambient login (`cloudProvider.azurerm.credential_source: ambient`).** The az CLI ignores credential environment variables (Azure/azure-cli#10241), so before every operation that reaches Azure (plan, apply, destroy, output capture) infrapipe logs az in as the workload's identity, then runs every az call of that operation (`what-if`, `create`, `group delete`, ...) against that login:

- `msi` and `azure_cli`: `az login --identity --allow-no-subscriptions [--client-id {INFRAENV}_AZ_CLIENT_ID]`;
- `workload_identity`: `az login --service-principal -u <client id> -t <tenant id> --federated-token=@<AZURE_FEDERATED_TOKEN_FILE> --allow-no-subscriptions`;
- then `az account set --subscription {INFRAENV}_AZ_SUBSCRIPTION_ID`.

The login lands in a fresh `0700` temporary `AZURE_CONFIG_DIR` that is removed when the operation ends (also on failure; a process killed with `SIGKILL` cannot clean up, so an `infrapipe-az-*` directory holding that login's token cache can remain in the temp directory). `~/.azure` is never read or written, a developer's own `az login` session is never reused, and concurrent server requests never share a login. Requires **az ≥ 2.73.0** (checked with `az version`; 2.69.0 added `--client-id` for managed identities, and 2.73.0 moved managed-identity login to MSAL, which is what reaches the Container Apps/App Service identity endpoint). Each login step (`az version`, the login, `az account set`) is bounded to 2 minutes, so a hung login (an unreachable identity endpoint, a DNS stall) fails the operation as `az login --identity timed out after 2m0s` (naming the step) instead of blocking until it is cancelled; a cancelled operation reports `<step> was cancelled`. Once an operation is cancelled (Ctrl-C, a server request cancel), every command it started is killed and returns within half a second, even when a process that command started (az's python, a Terraform or Pulumi plugin) still holds its output open. The workload-identity token is never on az's command line: az replaces an argument, or the value of a `--flag=value` argument, that starts with `@` by the contents of the file it names, so infrapipe passes the token file's path and az reads the token itself. infrapipe still reads the file first, failing early when it is unreadable or empty, and redacts the token from every log line and error in case az echoes it. The inherited-static check applies.

**Service-principal login (`credential_source: env`).** The same per-operation login, as the `{INFRAENV}_AZ_*` service principal:

- `az login --service-principal -u {INFRAENV}_AZ_CLIENT_ID -t {INFRAENV}_AZ_TENANT_ID --password=@- --allow-no-subscriptions`, with `{INFRAENV}_AZ_CLIENT_SECRET` written to az's stdin;
- then `az account set --subscription {INFRAENV}_AZ_SUBSCRIPTION_ID`.

All four variables are required; a missing one fails the operation before az runs, never falling back to the host's session. The same isolated `AZURE_CONFIG_DIR`, cleanup, 2-minute step bound and az ≥ 2.73.0 floor apply. The secret is never on az's command line, where other users of the host could read it in the process table: az expands the argument `@-` to its standard input, and infrapipe writes the secret, byte-exact, to the login's stdin only. A secret that itself starts with `@` therefore reaches az literally and is never read as a file name. infrapipe also redacts it from every log line and error and never maps it, or any `{INFRAENV}_AZ_*` credential, into the az environment as `AZURE_*`/`ARM_*` (a configured `cloudProvider.azurerm.exec_role` reaches az only as `TF_VAR_infrapipe_exec_arm_*`, never `ARM_*`, and never overrides the operation's `AZURE_CONFIG_DIR`). Nor does any subprocess an `iac` operation starts inherit the raw `{INFRAENV}_AZ_CLIENT_SECRET` or `{INFRAENV}_AZ_EXEC_CLIENT_SECRET`: both are removed from every child environment, so neither `/proc/<pid>/environ` of `az` nor a tool that runs `az` itself (Terraform's `azure_cli` auth) can read them. This applies to every `iac` subprocess, so a `local-exec` provisioner or `external` data source that read `{INFRAENV}_AZ_CLIENT_SECRET` directly now sees it unset; read the mapped `ARM_CLIENT_SECRET` (env mode) or the exec role's `TF_VAR_infrapipe_exec_arm_client_secret` instead.

**Destroy waits for the resource group delete.** `iac destroy` for Bicep and ARM runs `az group delete --name <workspace> --yes` against that login and returns only when ARM has finished: it exits non-zero when az reports a failed delete (a `ScopeLocked` lock, a resource that refuses deletion), with az's reason in the error, and a delete that runs past 30 minutes fails as `az group delete timed out after 30m0s`; Ctrl-C fails it as `az group delete was cancelled`. In both cases only infrapipe stops waiting: the delete itself continues in Azure, so a later `destroy` of a group that has since vanished fails on `ResourceGroupNotFound`. In earlier releases the delete ran with az's no-wait flag, so destroy reported success as soon as ARM accepted it, while the group and everything in it could still exist for minutes, and a delete that later failed was never reported.

| Field | Type | Required | Default | Description |
|-------|------|----------|---------|-------------|
| `resourceGroup` | string | Yes | -- | Azure resource group for deployment |
| `template` | string | No | `main.bicep` | Bicep template file |
| `parameters` | string | No | -- | Parameters file (JSON) |
| `region` | string | No | -- | Azure region for deployment |

### IaC.arm

Used when `IaC.type` is `arm`. Requires the Azure CLI (`az`) to be installed. Authentication is the same as [IaC.bicep](#iacbicep), including the ambient `az login`, and so is destroy: the resource group named after the workspace is deleted and the delete is waited for. `iac init` writes nothing for ARM either, locally and over `--remote`.

| Field | Type | Required | Default | Description |
|-------|------|----------|---------|-------------|
| `resourceGroup` | string | Yes | -- | Azure resource group for deployment |
| `template` | string | No | `main.json` | ARM template file (JSON) |
| `parameters` | string | No | -- | Parameters file (JSON) |
| `region` | string | No | -- | Azure region for deployment |

### IaC.pulumi

Used when `IaC.type` is `pulumi`. Requires the Pulumi CLI to be installed.

| Field | Type | Required | Default | Description |
|-------|------|----------|---------|-------------|
| `runtime` | string | No | `go` | Pulumi runtime language (`go`, `python`, `typescript`, `dotnet`) |
| `backend` | string | No | -- | State backend URL (e.g., `file://~/.pulumi-state`, `s3://bucket`, `azblob://container`) |
| `stackPrefix` | string | No | -- | Prefix for Pulumi stack names |

**`iac init`**: for Pulumi, `iac init` writes no provider or backend file (Pulumi reads `Pulumi.yaml` in the code directory) and logs in to the Pulumi backend with `pulumi login`, through the same credential mapping as `plan`/`apply`/`destroy`, so an unreachable backend fails at init, as `terraform init` does for the other engines. With `backend` set the login is `pulumi login <backend>`; otherwise it is a bare `pulumi login`, which pulumi resolves from `PULUMI_BACKEND_URL`, from `PULUMI_ACCESS_TOKEN` (Pulumi Cloud) or from the `current` backend recorded in `$PULUMI_HOME/credentials.json` (default `~/.pulumi/credentials.json`). With none of the four configured, `iac init` fails before running pulumi (`no Pulumi backend configured: …`; HTTP 400 over `--remote`): a bare `pulumi login` with nothing configured fails in a non-interactive shell, and in an environment pulumi recognises as an AI agent (pulumi 3.268.0 looks for markers such as `AI_AGENT` or `CLAUDECODE`) it creates an ephemeral Pulumi Cloud account instead. `pulumi login` records the backend it logged in to as `current` in that credentials file, so an `iac init` with `PULUMI_BACKEND_URL=file://…` leaves that path as the host's current backend. `--remote iac init` behaves the same and reports `filesCreated: []`.

**Credential mapping:** Pulumi, like every executor (Terraform and OpenTofu included, for the clouds they map: AWS, Azure, GCP, Kubernetes, Incus, LXD, Cloudflare, DigitalOcean and OCI), uses standard cloud SDK environment variables internally. Infrapipe automatically maps its `{INFRAENV}_`-prefixed variables to the SDK variables when invoking these tools, so users only need to set the standard infrapipe variables (e.g., `DEV_AZ_CLIENT_ID`, or `DEV_AWS_ACCESS_KEY` with `credential_source: env`). The mapping is transparent -- no additional configuration is required.

**AWS (Pulumi and CloudFormation).** Credentials follow `cloudProvider.aws.credential_source`: `env` maps `{INFRAENV}_AWS_ACCESS_KEY`/`_SECRET_KEY`/`_SESSION_TOKEN`; `ambient` exports no keys and lets the SDK use the workload identity. When `{INFRAENV}_AWS_ASSUME_ROLE_ARN` is set (and `auth_mode` is not `environment`), infrapipe assumes the role with `aws sts assume-role` (session name `infrapipe-<infraenv>`) from that base identity and passes the session's `AWS_ACCESS_KEY_ID`/`AWS_SECRET_ACCESS_KEY`/`AWS_SESSION_TOKEN` to the tool. `AWS_ROLE_ARN` is never exported, so an IRSA webhook role reaches the tool unmodified. If the base identity is itself a role, AWS limits the chained session to 1 hour.

**Pulumi `aws:skipMetadataApiCheck` (ambient mode).** pulumi-aws disables the EC2 instance metadata service by default. With `credential_source: ambient`, after selecting the stack infrapipe runs `pulumi config get aws:skipMetadataApiCheck` and, only if the key is unset, `pulumi config set aws:skipMetadataApiCheck false`. This writes `Pulumi.<stack>.yaml` in your code directory; commit it or set the key yourself. An explicit value is never changed.

**Important:** Infrapipe strictly enforces its own `{INFRAENV}_` variable convention. Standard SDK variables (`AWS_ACCESS_KEY_ID`, `ARM_CLIENT_ID`, `GOOGLE_PROJECT`, etc.) are never a source of the credentials infrapipe maps. All executors map infrapipe variables to SDK variables internally via `RunCommandWithEnv`. infrapipe does read some SDK variables, either to detect the ambient identity or to refuse a host credential that would override the mapped one:

- **AWS** (`ambient`): an inherited `AWS_ACCESS_KEY_ID`/`AWS_SECRET_ACCESS_KEY` is refused; see [cloudProvider.aws](#cloudprovideraws).
- **Azure** (`ambient`): `AZURE_FEDERATED_TOKEN_FILE`, `IDENTITY_ENDPOINT`/`IDENTITY_HEADER` pick the `ambient_method`, and `AZURE_CLIENT_ID`/`AZURE_TENANT_ID` stand in for `{INFRAENV}_AZ_CLIENT_ID`/`_TENANT_ID` under workload identity; an inherited static `ARM_*`/`AZURE_*` credential is refused; see [cloudProvider.azurerm](#cloudproviderazurerm).
- **GCP** (`ambient`): an inherited `GOOGLE_CREDENTIALS`, `GOOGLE_CLOUD_KEYFILE_JSON`, `GCLOUD_KEYFILE_JSON`, `GOOGLE_OAUTH_ACCESS_TOKEN` or `GOOGLE_BACKEND_CREDENTIALS` is refused, and the `type` of the `GOOGLE_APPLICATION_CREDENTIALS` file decides whether it passes; see [cloudProvider.gcp](#cloudprovidergcp).
- **OCI**: in `ambient` mode `OCI_RESOURCE_PRINCIPAL_VERSION` and `KUBERNETES_SERVICE_HOST` pick the principal; in `env` mode an inherited `TF_VAR_<attr>` or `OCI_<ATTR>` identity variable that the mapping does not shadow is refused, for Terraform/OpenTofu and Pulumi alike; see [cloudProvider.oci](#cloudprovideroci).
- **Kubernetes** (`ambient`): inherited `KUBE_*`/`KUBECONFIG` are warned about, never refused; see [cloudProvider.kubernetes](#cloudproviderkubernetes).

**Examples:**

```yaml
IaC:
  type: pulumi
  pulumi:
    runtime: go
    backend: "file://~/.pulumi-state"
    stackPrefix: "dev"
```

```yaml
IaC:
  type: terraform
  terraform:
    version: "1.7.0"
    backend: s3
    key: "myproject/terraform.tfstate"
    region: "us-east-1"
```

```yaml
IaC:
  type: bicep
  bicep:
    resourceGroup: "rg-myapp-dev"
    template: "main.bicep"
    parameters: "parameters.json"
    region: "eastus"
```

```yaml
IaC:
  type: arm
  arm:
    resourceGroup: "rg-myapp-dev"
    template: "main.json"
    parameters: "parameters.json"
    region: "eastus"
```

---

## cloudProvider

Configures the target cloud platform.

| Field | Type | Required | Valid Values | Description |
|-------|------|----------|--------------|-------------|
| `type` | string | Yes | `aws`, `azurerm`, `azuread`, `azapi`, `azureCombo`, `gcp`, `cloudflare`, `digitalocean`, `oci`, `incus`, `lxd`, `kubernetes` | Cloud provider. `azurerm`, `azuread` and `azapi` each declare that one Terraform provider; `azureCombo` declares all three (azurerm, azuread and azapi) together for projects that use them in one configuration. The Azure types share the `cloudProvider.azurerm` block and its `{INFRAENV}_AZ_*` variables |

### Credential source

Every `cloudProvider.<cloud>` block accepts `credential_source`:

- `ambient` — use the host's workload identity: EC2 instance profile, ECS task role, EKS IRSA/Pod Identity, Azure managed identity, the GCP metadata server, OCI instance principal, an in-cluster Kubernetes service account, or the local Incus/LXD socket.
- `env` — use the `{INFRAENV}_*` static credential variables.

The knob lives in the cloud's own block; `azuread`, `azapi` and `azureCombo` use `cloudProvider.azurerm.credential_source`. DigitalOcean and Cloudflare offer no workload identity, so they accept only `env`; `ambient` fails `validate config` and every IaC operation.

**Default.** AWS, the Azure family (`azurerm`, `azuread`, `azapi`, `azureCombo`), GCP, OCI, Kubernetes, Incus and LXD default to `ambient`: leaving the key out runs AWS operations as the host's workload identity, Azure operations as the host's managed identity, AKS workload identity or Container Apps identity, GCP operations as Google Application Default Credentials (the metadata server, GKE workload identity or workload identity federation), OCI operations as the instance, resource or OKE workload principal, Kubernetes operations as the pod's service account, and Incus/LXD operations against the local daemon's unix socket. DigitalOcean and Cloudflare offer no workload identity and stay `env`.

**Where `ambient` is honoured.** Every cloud with a workload identity honours `ambient` end to end: `validate secrets` (the cloud's static credential variables are reported as `not required`), the provider and backend generators, and every executor. AWS: Terraform/OpenTofu (see [cloudProvider.aws](#cloudprovideraws)), Pulumi and CloudFormation (see [IaC.pulumi](#iacpulumi)). The Azure family: Terraform/OpenTofu and Pulumi for every `ambient_method`, Bicep/ARM through an isolated `az login` (see [cloudProvider.azurerm](#cloudproviderazurerm) and [IaC.bicep](#iacbicep)). GCP: Terraform/OpenTofu and Pulumi (see [cloudProvider.gcp](#cloudprovidergcp)). OCI: Terraform/OpenTofu (the generated provider block uses `auth = InstancePrincipal|ResourcePrincipal|OKEWorkloadIdentity`), Pulumi (`TF_VAR_auth`), the `oci` state backend (instance or resource principal) and `validate backend` (see [cloudProvider.oci](#cloudprovideroci) and the [OCI backend note](#iacterraform)). Kubernetes: Terraform/OpenTofu and Pulumi (see [cloudProvider.kubernetes](#cloudproviderkubernetes)). Incus and LXD: Terraform/OpenTofu and Pulumi, where `ambient` is the local unix socket (see [Incus and LXD credential source](#incus-and-lxd-credential-source)).

**Migration guard.** For a cloud whose default is `ambient`, leaving `credential_source` unset while that cloud's static credential variables are present is an error — infrapipe never silently picks an identity. The guard fires only for a cloud whose default is `ambient`, i.e. from that cloud's default-flip release on; while a cloud defaults to `env` it is inert. **It is active for AWS, the Azure family, GCP, OCI, Kubernetes, Incus and LXD:** a config with `DEV_AWS_ACCESS_KEY` or `DEV_AWS_SECRET_KEY` set and no `cloudProvider.aws.credential_source` (or, for the Azure family, `DEV_AZ_CLIENT_SECRET` and no `cloudProvider.azurerm.credential_source`; for GCP, `DEV_GCP_CREDENTIALS` and no `cloudProvider.gcp.credential_source`; for OCI, any of `DEV_USER_OCID`, `DEV_OCI_FINGERPRINT`, `DEV_OCI_PRIVATE_KEY`, `DEV_OCI_PRIVATE_KEY_PATH`, `DEV_OCI_USER_OCID` and no `cloudProvider.oci.credential_source`; for Kubernetes, `DEV_KUBECONFIG` or `DEV_KUBE_TOKEN` and no `cloudProvider.kubernetes.credential_source`; for Incus/LXD, any of `DEV_<P>_ADDR`, `_TOKEN`, `_CONF` (Incus only), `_TLS_CLIENT_CERT`, `_TLS_CLIENT_KEY` and no `cloudProvider.<incus|lxd>.credential_source`) fails `iac init`/`plan`/`apply`/`destroy` (locally, via `--remote`, and as HTTP 400 from the server), `validate secrets`, and `validate backend` for an `s3`, `azurerm`, `gcs` or `oci` state backend, before any IaC tool runs. The message is:

```text
credential_source not set for aws but static credential variables are present (DEV_AWS_ACCESS_KEY) — set cloudProvider.aws.credential_source: env (keep using these variables) or ambient (use the workload identity)
```

`credential_source` is orthogonal to `auth_mode`: `auth_mode` controls where `assume_role` happens, `credential_source` where the base credentials come from.

### cloudProvider.aws

Used when `cloudProvider.type` is `aws`.

| Field | Type | Required | Default | Description |
|-------|------|----------|---------|-------------|
| `region` | string | No | -- | AWS region |
| `ssm_path` | string | No | -- | SSM parameter store path for secrets |
| `auth_mode` | string | No | `provider` | `provider` (assume_role in .tf) or `environment` (pre-resolved env vars) |
| `exec_role_arn` | string | No | -- | Narrow-scope role ARN for subprocess exec blocks (STS AssumeRole) |
| `exec_session_name` | string | No | `infrapipe-exec` | Session name for exec role STS AssumeRole call |
| `aliases` | map | No | -- | Cross-account provider aliases (see below) |
| `credential_source` | string | No | `ambient` | `ambient` (workload identity) or `env` (`{INFRAENV}_*` variables). See [Credential source](#credential-source) |

**Example:**

```yaml
cloudProvider:
  type: aws
  aws:
    region: "us-east-1"
    ssm_path: "/myapp/config"
```

**Environment variables.**

| Variable | `env` mode | `ambient` mode (default) |
|----------|-----------|--------------------------|
| `{INFRAENV}_AWS_ACCESS_KEY` | required | not required; with no `credential_source` set it trips the migration guard |
| `{INFRAENV}_AWS_SECRET_KEY` | required | not required; with no `credential_source` set it trips the migration guard |
| `{INFRAENV}_AWS_ASSUME_ROLE_ARN` | optional: the role to assume; omit to deploy as the static-key identity (`validate secrets` reports `not set (optional)`) | optional: omit to deploy as the workload identity |
| `{INFRAENV}_AWS_TFSTATE_S3_BUCKET` | required for an `s3` state backend (any cloud), otherwise unused | required for an `s3` state backend (any cloud), otherwise unused |
| `{INFRAENV}_AWS_SESSION_TOKEN` | optional (temporary credentials) | not used |
| `{INFRAENV}_AWS_DEFAULT_REGION` | optional (CloudFormation and Pulumi region) | optional (CloudFormation and Pulumi region) |

`validate secrets` (and `POST /api/v1/validate`) checks the rows marked required for the configured mode and [state backend](#state-backend-variables); `init config` lists the same variables. **Behaviour change:** `env` mode no longer requires the role ARN, which nothing else required.

**Region for CloudFormation and Pulumi.** The region is `{INFRAENV}_AWS_DEFAULT_REGION`, else `IaC.cloudformation.region` (CloudFormation only), else `cloudProvider.aws.region`, exported as both `AWS_REGION` and `AWS_DEFAULT_REGION`. Terraform/OpenTofu take the region from the generated provider and backend blocks instead.

**Credentials for Terraform/OpenTofu.** Credentials are never written into the generated `.tf` files; they reach Terraform/OpenTofu through the subprocess environment.

- `credential_source: env` — both `{INFRAENV}_AWS_ACCESS_KEY` and `{INFRAENV}_AWS_SECRET_KEY` are required before any tool runs, for every engine: `iac init`, `plan`, `apply` and `destroy` (and the Pulumi `iac init`, before `pulumi login`) fail with `missing required environment variable: {INFRAENV}_AWS_SECRET_KEY (credential_source: env for aws)` (every missing name listed, never a value), over `--remote` as HTTP 400 (the streaming apply/destroy as an `error` event), and terraform, tofu, pulumi or aws never starts; `validate backend` and `validate secrets` apply the same rule. A half pair used to start the tool with `AWS_ACCESS_KEY_ID` alone, which the AWS SDK treats as "not configured" and falls through to the host's profile or instance role, an identity you did not select. Every Terraform/OpenTofu subprocess receives the pair as `AWS_ACCESS_KEY_ID`/`AWS_SECRET_ACCESS_KEY`, plus `AWS_SESSION_TOKEN` from the optional `{INFRAENV}_AWS_SESSION_TOKEN` (for temporary credentials).
- `credential_source: ambient` (the default) — no static keys are required (the S3 backend still requires `{INFRAENV}_AWS_TFSTATE_S3_BUCKET`, an identifier; `{INFRAENV}_AWS_ASSUME_ROLE_ARN` is optional) and none are exported; the AWS SDK default chain supplies the workload identity. If infrapipe's own environment carries `AWS_ACCESS_KEY_ID` or `AWS_SECRET_ACCESS_KEY`, plan/apply/destroy refuse to run, because the SDK chain would use that static key instead of the workload identity. `AWS_PROFILE`, `AWS_WEB_IDENTITY_TOKEN_FILE`/`AWS_ROLE_ARN` and the container-credential variables are allowed.
- In both modes the provider's `assume_role` block is emitted only when `{INFRAENV}_AWS_ASSUME_ROLE_ARN` is set and `auth_mode` is not `environment`.

**Note:** The exec role is assumed via `aws sts assume-role` using the base credentials: `{INFRAENV}_AWS_ACCESS_KEY` in `env` mode, the workload identity in `ambient` mode. The exec role's IAM trust policy must allow the base IAM user or account root to assume it.

#### Operating with workload identity

In `ambient` mode infrapipe runs as whatever identity the host's AWS SDK default chain resolves: an EC2 instance profile through IMDSv2, an ECS task role, EKS IRSA (`AWS_WEB_IDENTITY_TOKEN_FILE` + `AWS_ROLE_ARN`) or EKS Pod Identity. Things infrapipe cannot fix for you:

- **IMDSv2 hop limit.** A container on EC2 (Docker on an instance, a self-hosted CI runner in a container) is one network hop further from the metadata service than the instance itself. Set the instance's `HttpPutResponseHopLimit` to `2` (`aws ec2 modify-instance-metadata-options --http-put-response-hop-limit 2`); with the default of `1` the SDK finds no credentials. infrapipe cannot change this setting.
- **Role chaining caps sessions at 1 hour.** When the workload identity is itself a role and `{INFRAENV}_AWS_ASSUME_ROLE_ARN` is set, assuming the second role is role chaining, and AWS limits that session to 1 hour regardless of the role's maximum session duration. Long `apply` runs can outlive it; size work accordingly, or grant the workload role the permissions directly.
- **One host, one identity.** Every environment that a host deploys runs from the same workload identity. Environment separation comes from a per-environment `{INFRAENV}_AWS_ASSUME_ROLE_ARN` (`DEV_…`, `PROD_…`), each role's trust policy allowing only the host identity. Without those roles, `DEV` and `PROD` run with the same permissions.
- **Static `AWS_ACCESS_KEY_ID` in the host environment beats ambient.** The SDK chain reads environment keys before the workload identity, so an `AWS_ACCESS_KEY_ID`/`AWS_SECRET_ACCESS_KEY` left in infrapipe's own environment would silently replace it. In `ambient` mode infrapipe therefore refuses to run while either is set, and names the variable. Unset it, or use `credential_source: env` with `{INFRAENV}_AWS_ACCESS_KEY`/`_SECRET_KEY`.

**Exec role credentials** are exported as `TF_VAR_infrapipe_exec_*` (not `AWS_*`) to avoid overwriting the primary credentials used by the S3 backend; Azure and GCP exec roles follow the same pattern (`TF_VAR_infrapipe_exec_arm_*`, `TF_VAR_infrapipe_exec_gcp_*`). Set `exec_role_arn` as a literal ARN: infrapipe does not expand `${…}` placeholders, and one is an error. A configured exec role that cannot be resolved fails the operation instead of running without it: non-zero CLI exit; from the server HTTP 400 for a configuration error and HTTP 502 when the role cannot be assumed (an STS failure). The server resolves the exec role of the request's cloud, not the configured `cloudProvider.type`.

The `TF_VAR_infrapipe_exec_*` variables are in the environment of every subprocess of the operation, for every engine; Pulumi, CloudFormation and Bicep/ARM do not read them themselves, so a Pulumi program that wants the exec identity reads them from its process environment. If a root module declares one of these variables, Terraform stores its value in the plan file (`out.tfplan`) even when it is `sensitive`, so do not archive plan files of a module that declares the secret ones. Your HCL exec blocks must reference these variables:

```hcl
variable "infrapipe_exec_access_key_id" { sensitive = true; default = "" }
variable "infrapipe_exec_secret_access_key" { sensitive = true; default = "" }
variable "infrapipe_exec_session_token" { sensitive = true; default = "" }

provider "kubernetes" {
  exec {
    command = "aws"
    args    = ["eks", "get-token", "--cluster-name", var.cluster_name]
    env = {
      AWS_ACCESS_KEY_ID     = var.infrapipe_exec_access_key_id
      AWS_SECRET_ACCESS_KEY = var.infrapipe_exec_secret_access_key
      AWS_SESSION_TOKEN     = var.infrapipe_exec_session_token
    }
  }
}
```

**Aliases:** Each entry under `aliases` generates an additional `provider "aws" { alias = "..." }` block.

| Field | Type | Required | Default | Description |
|-------|------|----------|---------|-------------|
| `assume_role_arn` | string | Yes | -- | Role ARN for the alias |
| `region` | string | No | parent region | Override region for this alias |

### cloudProvider.azurerm

Used when `cloudProvider.type` is `azurerm`, `azuread`, `azapi` or `azureCombo`: the whole Azure family reads this block.

**Generated provider file.** `iac init` with Terraform or OpenTofu writes `provider-<cloudProvider.type>.tf` (`provider-azurerm.tf`, `provider-azuread.tf`, `provider-azapi.tf`, `provider-azureCombo.tf`), the same name locally and over `--remote`. In earlier releases the local CLI wrote `provider-azrm.tf`, `provider-azad.tf` and `provider-azCombo.tf` while the server wrote the regular names, so a checkout initialised both ways carried two files declaring the same provider and `terraform init` failed on the duplicate. **Migration:** after upgrading, a checkout initialised by the old CLI still holds the old file; re-running `iac init` writes the new name beside it, leaves the old file in place (infrapipe never deletes a user's file) and warns naming it (locally in the log, over `--remote` in the `Remote init:` message). Delete the old file by hand: `rm provider-azrm.tf` (or `provider-azad.tf`, `provider-azCombo.tf`). The file content is identical, so nothing else changes.

| Field | Type | Required | Default | Description |
|-------|------|----------|---------|-------------|
| `region` | string | No | -- | Azure region |
| `auth_mode` | string | No | `provider` | `provider` or `environment` |
| `exec_role` | object | No | -- | Exec role credentials for subprocess auth |
| `aliases` | map | No | -- | Cross-subscription provider aliases |
| `credential_source` | string | No | `ambient` | `ambient` (managed or workload identity) or `env` (`{INFRAENV}_AZ_*` service principal). Default `ambient`; see [Credential source](#credential-source) |
| `ambient_method` | string | No | `auto` | How an ambient run authenticates: `auto`, `msi`, `workload_identity` or `azure_cli`. Ignored (with a warning) when the effective source is `env` |

**Environment variables.**

| Variable | `env` mode | `ambient` mode (default) |
|----------|-----------|--------------------------|
| `{INFRAENV}_AZ_SUBSCRIPTION_ID` | required | required (always) |
| `{INFRAENV}_AZ_TFSTATE_STORAGE_ACCOUNT` | required for an `azurerm` state backend (any cloud), otherwise unused | required for an `azurerm` state backend (any cloud), otherwise unused |
| `{INFRAENV}_AZ_CLIENT_ID` | required | optional: the user-assigned or workload identity client id. Unset means system-assigned for `msi` and `azure_cli`; `workload_identity` needs a client id and falls back to `AZURE_CLIENT_ID` |
| `{INFRAENV}_AZ_TENANT_ID` | required | optional; `workload_identity` needs a tenant and falls back to `AZURE_TENANT_ID` |
| `{INFRAENV}_AZ_CLIENT_SECRET` | required | not required; with no `credential_source` set it trips the migration guard |

`validate secrets` (and `POST /api/v1/validate`) checks exactly this table for the configured mode and backend; in ambient mode it also resolves the identity and reports `ambient method: <msi|workload_identity|azure_cli>` and `identity client id: <id|system-assigned>`. `init config` lists the same variables, marking the optional ones.

**Credentials for Terraform, OpenTofu and Pulumi.** With `credential_source: env`, all four of `{INFRAENV}_AZ_CLIENT_ID`, `_CLIENT_SECRET`, `_TENANT_ID` and `_SUBSCRIPTION_ID` are required and every subprocess receives them as `ARM_CLIENT_ID`, `ARM_CLIENT_SECRET`, `ARM_TENANT_ID` and `ARM_SUBSCRIPTION_ID`. A missing one fails `iac init`, `plan`, `apply` and `destroy` with `missing required environment variable: {INFRAENV}_AZ_CLIENT_SECRET (credential_source: env)` before any tool runs (the Terraform/OpenTofu `iac init` in the provider generator, which in earlier releases required only the first three, in other words, and answered 500 over `--remote`), over `--remote` as HTTP 400 (the streaming apply/destroy as an `error` event, the status OCI's env mode has had since #302); Bicep and ARM apply the same rule before their az login. Ambient mode is described under **ambient_method** below.

**exec_role fields:** `client_id` and `tenant_id` (identifiers, set as literal values: infrapipe does not expand `${…}` placeholders in `.infrapipe.yaml`, and a `${` in any `exec_role` field is an error). The exec role's client secret comes from the environment variable `{INFRAENV}_AZ_EXEC_CLIENT_SECRET`, never the config file: `exec_role.client_secret` is rejected with an error that names the variable. With `credential_source: ambient` a set `{INFRAENV}_AZ_EXEC_CLIENT_SECRET` is rejected too when an exec_role is configured (ambient mode carries no long-lived secret), and ignored with a warning when none is; a `client_id`-only exec_role is allowed. `auth_mode: environment` skips the exec role, as for AWS.

The exec identity is exported **only** as `TF_VAR_infrapipe_exec_arm_client_id`, `TF_VAR_infrapipe_exec_arm_client_secret` and `TF_VAR_infrapipe_exec_arm_tenant_id`, never as `ARM_*`, so it cannot replace the primary identity of the provider, the state backend or Pulumi. Wire it into exec blocks explicitly:

```hcl
variable "infrapipe_exec_arm_client_id" { default = "" }
variable "infrapipe_exec_arm_client_secret" { sensitive = true; default = "" }
variable "infrapipe_exec_arm_tenant_id" { default = "" }

provider "kubernetes" {
  exec {
    command = "kubelogin"
    args    = ["get-token", "--login", "spn", "--server-id", "6dae42f8-4368-4678-94ff-3960e28e3630"]
    env = {
      AAD_SERVICE_PRINCIPAL_CLIENT_ID     = var.infrapipe_exec_arm_client_id
      AAD_SERVICE_PRINCIPAL_CLIENT_SECRET = var.infrapipe_exec_arm_client_secret
      AZURE_TENANT_ID                     = var.infrapipe_exec_arm_tenant_id
    }
  }
}
```

**Behaviour change:** before this release the exec role was exported as `ARM_CLIENT_ID`/`ARM_CLIENT_SECRET`/`ARM_TENANT_ID` into every subprocess, overriding the primary identity. Exec blocks that relied on inheriting those must now read the `TF_VAR_infrapipe_exec_arm_*` variables as above, and a user-assigned identity is selected with `{INFRAENV}_AZ_CLIENT_ID`, not `exec_role.client_id`.

**ambient_method** (`credential_source: ambient` only). `auto` picks, in order:

1. `workload_identity` when `AZURE_FEDERATED_TOKEN_FILE` is set (AKS Workload Identity; the webhook also sets `AZURE_CLIENT_ID` and `AZURE_TENANT_ID`).
2. `azure_cli` when `IDENTITY_ENDPOINT` and `IDENTITY_HEADER` are both set (Container Apps and App Service). azurerm's managed-identity client cannot use that endpoint (terraform-provider-azurerm#25726), so the only working path is `az login --identity` plus CLI auth. An explicit `msi` with `IDENTITY_ENDPOINT` set is an error for the same reason.
3. `msi` otherwise (managed identity through IMDS: VM, VMSS, ACI, AKS node identity).

An explicit `workload_identity` without `AZURE_FEDERATED_TOKEN_FILE` is an error. In ambient mode:

- `{INFRAENV}_AZ_SUBSCRIPTION_ID` is required for every method (azurerm 4.x needs a subscription). The `azurerm` state backend also needs `{INFRAENV}_AZ_TFSTATE_STORAGE_ACCOUNT`. No secret is ever required. `msi` and `azure_cli` need no client id or tenant; `workload_identity` needs both, from `{INFRAENV}_AZ_CLIENT_ID`/`_TENANT_ID` or the webhook's `AZURE_CLIENT_ID`/`AZURE_TENANT_ID`, and fails without them.
- `{INFRAENV}_AZ_CLIENT_ID` picks a user-assigned identity. Unset means system-assigned for `msi`; `workload_identity` falls back to `AZURE_CLIENT_ID`. Giving each infraEnv its own client id separates environments on a shared host.
- `{INFRAENV}_AZ_TENANT_ID` is required for `workload_identity` (falling back to `AZURE_TENANT_ID`) and optional otherwise.
- The generated `azurerm` backend sets `use_azuread_auth = true`, so the identity needs `Storage Blob Data Contributor` on the state container instead of the storage account keys. An empty `tenant_id` is omitted.
- Terraform, OpenTofu and Pulumi receive exactly one method through `ARM_*` variables: `msi` sets `ARM_USE_MSI=true` and `ARM_USE_OIDC=false` (plus `ARM_CLIENT_ID`/`ARM_TENANT_ID` when a client id or tenant is set); `workload_identity` sets `ARM_USE_OIDC=true`, `ARM_OIDC_TOKEN_FILE_PATH`, `ARM_CLIENT_ID`, `ARM_TENANT_ID` and `ARM_USE_MSI=false`; both set `ARM_USE_CLI=false` and `ARM_SUBSCRIPTION_ID` and never `ARM_CLIENT_SECRET`, even when `{INFRAENV}_AZ_CLIENT_SECRET` is set. The providers read the token file once per run, so a workload-identity apply must finish within the token's lifetime. `azure_cli` sets `ARM_USE_CLI=true`, `ARM_USE_MSI=false`, `ARM_USE_OIDC=false`, `ARM_SUBSCRIPTION_ID` and `AZURE_CONFIG_DIR`: before each operation infrapipe runs `az login --identity --allow-no-subscriptions [--client-id {INFRAENV}_AZ_CLIENT_ID]` and `az account set` into a fresh temporary `AZURE_CONFIG_DIR` (removed when the operation ends), and the provider's CLI auth uses that login only (az ≥ 2.73.0; see [IaC.bicep](#iacbicep)).
- `azure_cli` is the Container Apps/App Service path: azurerm's managed-identity client cannot reach `IDENTITY_ENDPOINT` (terraform-provider-azurerm#25726), but `az login --identity` can — azure-cli ≥ 2.73.0 authenticates managed identities through MSAL, which uses the App Service endpoint when `IDENTITY_ENDPOINT` and `IDENTITY_HEADER` are set ([Container Apps managed identity](https://learn.microsoft.com/en-us/azure/container-apps/managed-identity)). An explicit `ambient_method: azure_cli` elsewhere (for example a developer laptop) still runs `az login --identity` and fails without a managed identity: ambient never reuses a personal `az login` session.
- Infrapipe refuses to run when the process already has a static Azure credential that the SDK chain would prefer over the workload identity: `ARM_CLIENT_SECRET`, `ARM_CLIENT_SECRET_FILE_PATH`, `ARM_CLIENT_CERTIFICATE`, `ARM_CLIENT_CERTIFICATE_PATH`, `ARM_CLIENT_CERTIFICATE_PASSWORD`, `ARM_ACCESS_KEY`, `ARM_SAS_TOKEN`, `AZURE_CLIENT_SECRET`, `AZURE_CLIENT_CERTIFICATE_PATH`, `AZURE_CLIENT_CERTIFICATE_PASSWORD`, `AZURE_USERNAME` or `AZURE_PASSWORD`.

**`validate backend` in ambient mode** never uses your `~/.azure` session: it logs `az` in as the ambient identity (the same `az login` argv as Bicep/ARM) into a temporary `AZURE_CONFIG_DIR`, reports `identity: <user.name>` from `az account show`, checks the storage account, reads the container with `--auth-mode login` (Entra ID, like the generated backend), and removes the directory. The storage account is `{INFRAENV}_AZ_TFSTATE_STORAGE_ACCOUNT`, the one the generated backend uses; a leftover `IaC.<terraform|tofu>.storage_account_name` key is ignored with a warning.

**`validate backend` in env mode** never uses your `~/.azure` session either: it requires all four of `{INFRAENV}_AZ_CLIENT_ID`/`_CLIENT_SECRET`/`_TENANT_ID`/`_SUBSCRIPTION_ID` (a missing one fails naming it, before any `az` call), logs `az` in as that service principal (the same `az login --service-principal … --password=@-` argv as Bicep/ARM, with the secret on stdin, never argv) into a temporary `AZURE_CONFIG_DIR`, reports `identity: <user.name>`, checks the storage account, reads the container with the account key (the env-mode generated backend has no `use_azuread_auth`), and removes the directory. With `IaC.<terraform|tofu>.resource_group_name` set, the key is listed in that resource group (`az storage account keys list --account-name … --resource-group …`, the same `listKeys` call the Terraform backend makes) and handed to `az storage container show` as `AZURE_STORAGE_KEY`, never on argv, and redacted from every message, so the check makes only the calls `plan` makes and needs the same permissions: `Microsoft.Storage/storageAccounts/read` and `Microsoft.Storage/storageAccounts/listKeys/action` on the account (Reader plus Storage Account Key Operator Service Role, or Contributor). A failed or empty listing fails the check naming the account and resource group. A failed container read says `not found` only when `az` reports `ContainerNotFound`. An account with `allowSharedKeyAccess: false` refuses the key (`KeyBasedAuthenticationNotPermitted`), so the check fails saying the account disallows shared-key access: the env-mode backend reads with the account key, so `plan` would fail too; enable shared-key access on the account or use `credential_source: ambient` (Entra ID, `use_azuread_auth`). Any other failure, in either mode (an ambient RBAC refusal such as `AuthorizationPermissionMismatch` included), fails as `could not read Azure storage container …`. In every case the redacted `az` error is in the details. Without `resource_group_name` the check fails naming it, before any `az` call, as `iac init` and `validate config` do; in earlier releases it let `az` find the key itself by listing the subscription's storage accounts, a call the Terraform backend never makes (a principal scoped to one resource group may make it). The secret is redacted from every message, and it is not in the environment of any subprocess `validate backend` starts: every `{INFRAENV}_AZ_CLIENT_SECRET` and `{INFRAENV}_AZ_EXEC_CLIENT_SECRET` is removed from the environment `az` inherits, so neither `/proc/<pid>/environ` nor the tools `az` spawns can read it. Each `az` step is bounded at 2 minutes, so a hung `az login` (an unreachable identity endpoint, a DNS stall) fails as `az login with … timed out after 2m0s` instead of blocking. Ctrl-C ends the check at once: `az` is killed and the check stops waiting within a quarter second for any process it started (a lingering `az` child has no secret in its environment), and the temporary `AZURE_CONFIG_DIR` is still removed. In both modes every `az` call runs with `AZURE_STORAGE_CONNECTION_STRING`, `AZURE_STORAGE_KEY`, `AZURE_STORAGE_SAS_TOKEN` and `AZURE_STORAGE_AUTH_MODE` blanked: `az storage` would authenticate with them in place of the logged-in identity, and the Terraform backend never reads them.

**Version notes for ambient Azure.**

- **az:** `az login --identity --client-id` needs az ≥ 2.69; infrapipe requires **az ≥ 2.73.0** for every ambient login (Bicep/ARM, `azure_cli`, `validate backend`) and for the `env` service-principal login (Bicep/ARM and `validate backend`), the first release that reaches the Container Apps/App Service identity endpoint through MSAL.
- **OpenTofu `azurerm` backend:** a user-assigned identity's `client_id` (`ARM_CLIENT_ID`) is honoured only from OpenTofu **1.11.5**; older releases use the system-assigned identity for state.
- **Terraform `azurerm` backend:** `use_aks_workload_identity` exists only from Terraform 1.11, but infrapipe does not use it. Workload identity is passed as an OIDC token file (`ARM_USE_OIDC` + `ARM_OIDC_TOKEN_FILE_PATH`), which older releases also support.

**Testing ambient Azure locally.** Without a real managed identity, point the providers at a local IMDS stand-in: azurerm, azuread and the Terraform `azurerm` backend read `ARM_MSI_ENDPOINT`; the OpenTofu ≥ 1.11 `azurerm` backend reads `MSI_ENDPOINT` instead ([OpenTofu docs](https://opentofu.org/docs/language/settings/backends/azurerm/)). The endpoint must answer only requests carrying `Metadata: true`.

### cloudProvider.gcp

Used when `cloudProvider.type` is `gcp`.

| Field | Type | Required | Default | Description |
|-------|------|----------|---------|-------------|
| `project` | string | No | -- | GCP project ID |
| `region` | string | No | -- | GCP region |
| `auth_mode` | string | No | `provider` | `provider` or `environment` |
| `exec_role` | object | No | -- | Exec role credentials for subprocess auth |
| `aliases` | map | No | -- | Cross-project provider aliases |
| `credential_source` | string | No | `ambient` | `ambient` (Google ADC: metadata server, GKE workload identity, workload identity federation, `gcloud auth application-default login`) or `env` (`{INFRAENV}_GCP_CREDENTIALS`). See [Credential source](#credential-source) |

**Environment variables.**

| Variable | `env` mode | `ambient` mode (default) |
|----------|-----------|--------------------------|
| `{INFRAENV}_GCP_PROJECT` | required | required (always) |
| `{INFRAENV}_GCP_REGION` | required | required (always) |
| `{INFRAENV}_GCP_TFSTATE_BUCKET` | required for a `gcs` state backend (any cloud), otherwise unused | required for a `gcs` state backend (any cloud), otherwise unused |
| `{INFRAENV}_GCP_CREDENTIALS` | required | not required; with no `credential_source` set it trips the migration guard |
| `{INFRAENV}_GCP_IMPERSONATE_SERVICE_ACCOUNT` | optional | optional |

`validate secrets` (and `POST /api/v1/validate`) checks exactly this table for the configured mode; `init config` lists the same variables, marking the optional one. The Terraform/OpenTofu `iac init` renders the project and region into `provider-gcp.tf` and refuses without them, in either mode: `missing required environment variable: DEV_GCP_PROJECT (required by the gcp provider in every credential_source)` (`config.CheckGCPProviderEnv`, HTTP 400 over `--remote`). **Behaviour change:** in `env` mode `validate secrets` now fails without `{INFRAENV}_GCP_CREDENTIALS`; it used to pass. In `ambient` mode `validate secrets` also fails, with the inherited-static-credential message, when the process carries an inherited static Google credential (see below), so it cannot pass a setup that `iac plan` refuses.

**Default and migration.** `ambient` is the default: with no `credential_source`, infrapipe exports no key file and the tools find credentials through ADC. Before this release the same config ran in `env` mode. With `{INFRAENV}_GCP_CREDENTIALS` set and no `credential_source`, the [migration guard](#credential-source) now stops every IaC operation before any tool runs, locally, via `--remote` and as HTTP 400 from the server. Set `credential_source: env` to keep using the key file:

```yaml
cloudProvider:
  type: gcp
  gcp:
    credential_source: env   # keep using DEV_GCP_CREDENTIALS
```

**One host, one identity (server mode).** An ambient host has a single identity, so one `infrapipe serve` deploys every environment as it. Use `{INFRAENV}_GCP_IMPERSONATE_SERVICE_ACCOUNT` (below) to give each environment its own deploying service account.

**exec_role fields:** `credentials_file` (a key or credential-config file path) and `impersonate_service_account` (a service account e-mail; needs no key file, because the google provider impersonates it from the primary identity). Set them as literal values: a `${…}` placeholder is not expanded and is an error. The exec role is exported **only** as `TF_VAR_infrapipe_exec_gcp_credentials_file`, `TF_VAR_infrapipe_exec_gcp_impersonate_sa`, `TF_VAR_infrapipe_exec_gcp_project` and `TF_VAR_infrapipe_exec_gcp_region` (from `cloudProvider.gcp.project`/`region`), never as `GOOGLE_APPLICATION_CREDENTIALS` (which ADC reads ahead of the metadata server) or `GOOGLE_PROJECT`/`GOOGLE_REGION`. `auth_mode: environment` skips the exec role. With `credential_source: ambient` the `credentials_file` type is checked first: a `service_account` key (directly, or as the `source_credentials` of an `impersonated_service_account`), an unknown type, or an unreadable file is refused, because ambient mode carries no long-lived key. Workload identity federation (`external_account`, `external_account_authorized_user`), `authorized_user` and impersonation configs stay allowed.

```hcl
variable "infrapipe_exec_gcp_impersonate_sa" { default = "" }

provider "google" {
  alias                       = "exec"
  impersonate_service_account = var.infrapipe_exec_gcp_impersonate_sa
}
```

**Behaviour change:** before this release `credentials_file` was exported as `GOOGLE_APPLICATION_CREDENTIALS` (plus `GOOGLE_PROJECT`/`GOOGLE_REGION`) into every subprocess, making it the primary identity. Read the `TF_VAR_infrapipe_exec_gcp_*` variables instead.

**Credentials by engine:**

| `credential_source` | Terraform / OpenTofu | Pulumi |
|---|---|---|
| `env` | `{INFRAENV}_GCP_CREDENTIALS` (required) → `GOOGLE_APPLICATION_CREDENTIALS` | `{INFRAENV}_GCP_CREDENTIALS` (required) → `GOOGLE_APPLICATION_CREDENTIALS`; `{INFRAENV}_GCP_PROJECT` → `GOOGLE_PROJECT`, `{INFRAENV}_GCP_REGION` → `GOOGLE_REGION`, `{INFRAENV}_GCP_IMPERSONATE_SERVICE_ACCOUNT` → `GOOGLE_IMPERSONATE_SERVICE_ACCOUNT` when set |
| `ambient` | nothing exported: ADC (metadata server or workload identity federation) | no credential: `GOOGLE_PROJECT` / `GOOGLE_REGION`, plus `GOOGLE_IMPERSONATE_SERVICE_ACCOUNT` when `{INFRAENV}_GCP_IMPERSONATE_SERVICE_ACCOUNT` is set |

**`env` mode** requires `{INFRAENV}_GCP_CREDENTIALS` for every engine and fails `iac init`, `plan`, `apply` and `destroy` without it, before any tool runs (the Terraform/OpenTofu `iac init` in the provider generator, which in earlier releases wrote `provider-gcp.tf` and exited 0), with `missing required environment variable: {INFRAENV}_GCP_CREDENTIALS (credential_source: env)`; over `--remote` that is HTTP 400 (the streaming apply/destroy an `error` event).

Credentials are never written into `provider-gcp.tf` or `backend-gcs.tf`. In `ambient` mode a set `{INFRAENV}_GCP_CREDENTIALS` is warned about and not exported, and infrapipe refuses to run when the process already carries a static Google credential that ADC would prefer: any of `GOOGLE_CREDENTIALS`, `GOOGLE_CLOUD_KEYFILE_JSON`, `GCLOUD_KEYFILE_JSON`, `GOOGLE_OAUTH_ACCESS_TOKEN`, `GOOGLE_BACKEND_CREDENTIALS`, or a `GOOGLE_APPLICATION_CREDENTIALS` file that the exec_role check above would refuse. A `GOOGLE_APPLICATION_CREDENTIALS` pointing at a federation config (e.g. from `google-github-actions/auth`) passes through unchanged.

**Per-environment impersonation:** set `{INFRAENV}_GCP_IMPERSONATE_SERVICE_ACCOUNT` (e.g. `PROD_GCP_IMPERSONATE_SERVICE_ACCOUNT=deploy@my-project.iam.gserviceaccount.com`) to run each environment as its own service account from one host identity, in either mode. It is rendered as `impersonate_service_account` in both the `google` provider block and the `gcs` backend block, and exported to Pulumi as `GOOGLE_IMPERSONATE_SERVICE_ACCOUNT`. The value must match `<name>@<domain>.gserviceaccount.com`; anything else fails `iac init`. The base identity (workload identity or the env-mode key) needs `roles/iam.serviceAccountTokenCreator` on the target service account.

**Example:**

```yaml
cloudProvider:
  type: gcp
  gcp:
    project: "my-project-id"
    region: "us-central1"
```

**Backend validation:** When `IaC.terraform.backend` or `IaC.tofu.backend` is `gcs`, `infrapipe validate backend` checks the GCS bucket (`{INFRAENV}_GCP_TFSTATE_BUCKET` of the deployment for the current branch). The bucket is required in both modes: a branch with no resolvable deployment, or an unset variable, fails the check before `gcloud` or the fallback runs, rather than checking `gs://`. The effective `credential_source` is resolved first, so the migration guard fails the check too. In `ambient` mode the inherited-static check runs next, before `gcloud` and the fallback alike: a static credential every ambient run would refuse (a `service_account` key, or one of the static credential variables above) fails the check with the inherited-static-credential message without running `gcloud`, whose active account need not be the ADC identity Terraform uses. It then tries `gcloud auth print-access-token` and `gcloud storage ls` (requires Google Cloud SDK; `gcloud` itself reads the metadata server and federation configs). If `gcloud` is not installed, it falls back to the GCS JSON API (`https://storage.googleapis.com/storage/v1/b/<bucket>`, an unauthenticated existence check):

- **`env` mode** requires `GOOGLE_APPLICATION_CREDENTIALS` to point to an existing key file, and warns when it is unset.
- **`ambient` mode** does not require it. A set `GOOGLE_APPLICATION_CREDENTIALS` must exist, and its `type` is reported (`credentials file type: external_account`). A static credential every ambient run would refuse has already failed the inherited-static check above. With no ADC file, infrapipe asks the metadata server (`$GCE_METADATA_HOST`, else `metadata.google.internal`; `Metadata-Flavor: Google`, 2 s timeout) for the default service account. It reports `ambient identity: <email>`, or warns `no ambient GCP identity detected (not on GCE/GKE/Cloud Run and no ADC file)`.

### cloudProvider.incus

Used when `cloudProvider.type` is `incus`.

> **Local daemon.** With the default `credential_source: ambient`, infrapipe uses the local Incus unix socket, so a local daemon is required, and `infrapipe validate system` requires the `incus` binary. With `credential_source: env` and `{ENV}_INCUS_ADDR` set, the remote is rendered into the provider's `remote {}` block; the lxc/incus provider documents that this works on a system where Incus is not installed, so `validate system` only recommends the binary and does not fail without it.

| Field | Type | Required | Default | Description |
|-------|------|----------|---------|-------------|
| `credential_source` | string | No | `ambient` | `ambient` (the local unix socket) or `env` (`{INFRAENV}_INCUS_*` variables). See [Incus and LXD credential source](#incus-and-lxd-credential-source) |

The daemon address and remote name are per environment, so they have no YAML field (the never-read `remote`/`addr` fields were removed; a config that still sets them loads unchanged).

**Environment variables (`env` mode):** `{INFRAENV}_INCUS_ADDR` (selects a remote daemon; omit for the local socket), `{INFRAENV}_INCUS_REMOTE`, `{INFRAENV}_INCUS_TOKEN`, `{INFRAENV}_INCUS_CONF`

**Example:**

```yaml
cloudProvider:
  type: incus
  incus:
    credential_source: ambient   # the local unix socket
```

### cloudProvider.lxd

Used when `cloudProvider.type` is `lxd`. LXD is the original Canonical container hypervisor (separate from Incus, the community fork).

| Field | Type | Required | Default | Description |
|-------|------|----------|---------|-------------|
| `credential_source` | string | No | `ambient` | `ambient` (the local unix socket) or `env` (`{INFRAENV}_LXD_*` variables). See [Incus and LXD credential source](#incus-and-lxd-credential-source) |

As for Incus, the address and remote name have no YAML field (the never-read `remote`/`addr` were removed).

**Environment variables (`env` mode):** `{INFRAENV}_LXD_ADDR` (selects a remote daemon; omit for the local socket), `{INFRAENV}_LXD_REMOTE`, `{INFRAENV}_LXD_TOKEN`

**Example:**

```yaml
cloudProvider:
  type: lxd
  lxd:
    credential_source: env
# with DEV_LXD_ADDR=https://lxd.example.com:8443 for a remote daemon (needs credential_source: env)
```

#### Incus and LXD credential source

Both providers authenticate ambiently: with no remote configured they talk to the local unix socket, authorised by the socket's file permissions. `credential_source` makes the choice explicit, and **`ambient` is the default**.

**Default and migration.** With no `credential_source` and no `{INFRAENV}_<P>_*` variables nothing changes: before this release that config already used the local socket. With `{INFRAENV}_<P>_ADDR` (or `_TOKEN`, `_CONF` (Incus only), `_TLS_CLIENT_CERT`, `_TLS_CLIENT_KEY`) set and no `credential_source`, the [migration guard](#credential-source) now stops every IaC operation before any tool runs, locally, via `--remote` and as HTTP 400 from the server; before this release the same config ran against the remote daemon. To keep targeting the remote, set `credential_source: env`:

```yaml
cloudProvider:
  type: incus             # or lxd
  incus:
    credential_source: env   # keep using DEV_INCUS_ADDR (and _REMOTE/_TOKEN/_CONF)
```

**Socket permissions (who the ambient identity is).** Whoever can connect to the socket is the identity:

- **Incus:** membership of `incus-admin` grants full access to `/var/lib/incus/unix.socket`. Membership of `incus` grants the restricted per-user socket (`unix.socket.user`, served by `incus-user`), which confines you to your own project. Add the user with `sudo usermod -aG incus-admin "$USER"` and start a new login session (or use `sg incus-admin -c '…'`).
- **LXD:** membership of the `lxd` group, or of the group set by the snap's `daemon.group` (`sudo snap set lxd daemon.group=<group>`), grants access to `/var/snap/lxd/common/lxd/unix.socket`.

Membership of either admin group is equivalent to root on the host.

| | `ambient` (default) | `env` |
|---|---|---|
| Generated block | always `provider "<incus\|lxd>" {}` (the local socket) | when `{INFRAENV}_<P>_ADDR` is set: `accept_remote_certificate = true`, `generate_client_certificates = true` and one `remote {}` block, plus `token = var.infrapipe_<p>_token` when `{INFRAENV}_<P>_TOKEN` is set. LXD and Incus 0.x: `remote { name, address, default = true }` (Incus 0.x splits an `https://` URL into `scheme`/`address`/`port`); Incus v1: `remote { name, address }` with provider-level `default_remote`, see [the 0.x vs v1 shape](#incus-and-lxd-credential-source) below. Otherwise `provider "<incus\|lxd>" {}` |
| `{INFRAENV}_<P>_ADDR` set | **error**: `credential_source: ambient uses the local unix socket, but DEV_INCUS_ADDR is set — set credential_source: env to target the remote` (HTTP 400 server-side), never silently ignored | selects the remote daemon |
| Exported to the subprocess | nothing | see the mapping below |
| `validate secrets` | `pass` when a writable socket is on the provider's search path, otherwise `warn`; also `warn` when inherited `<P>_REMOTE`, `<P>_ADDR` or `<P>_TOKEN` could redirect the subprocess | `pass` (local or remote), except **`fail`** for Incus with Terraform/OpenTofu when `{INFRAENV}_INCUS_ADDR` is set and `providerVersions.incus` admits both majors or cannot be parsed, the combination `iac init` refuses |
| `init config` hint | nothing to export | `{INFRAENV}_<P>_ADDR`, optional, for a remote daemon |

`<P>` is `INCUS` or `LXD`. Socket search path, mirroring the providers (the first variable set wins and is searched alone): Incus `$INCUS_SOCKET`, `$INCUS_DIR/unix.socket[.user]`, `/var/lib/incus/unix.socket[.user]`, `/run/incus/unix.socket[.user]`; LXD `$LXD_SOCKET`, `$LXD_DIR/unix.socket`, `/var/snap/lxd/common/lxd/unix.socket`, `/var/lib/lxd/unix.socket`.

**Environment variable mapping (`env` mode):**

| infrapipe variable | Terraform / OpenTofu | Pulumi | Consumed by the provider |
|---|---|---|---|
| `{INFRAENV}_INCUS_ADDR` | -- (written to the `remote {}` block; an `https://` URL as `scheme`, `address` and `port`, see below) | an `https://` URL as `INCUS_SCHEME=https`, `INCUS_ADDR=<host>`, `INCUS_PORT` (default `8443`); any other value as `INCUS_SCHEME=unix` and `INCUS_ADDR`, see below | yes |
| `{INFRAENV}_INCUS_REMOTE` | -- (the `remote {}` block's name) | `INCUS_REMOTE` (default `remote` when `{INFRAENV}_INCUS_ADDR` is set) | yes |
| `{INFRAENV}_INCUS_TOKEN` | `TF_VAR_infrapipe_incus_token` (the `remote {}` block's `token`) | `INCUS_TOKEN` | yes, see below |
| `{INFRAENV}_INCUS_CONF` | `INCUS_CONF` | `INCUS_CONF` | yes: the directory holding `client.crt`/`client.key` (lxc/incus **v0.4.0+**) |
| `{INFRAENV}_LXD_ADDR` | -- (written to the `remote {}` block) | `LXD_ADDR` | yes |
| `{INFRAENV}_LXD_REMOTE` | -- (the `remote {}` block's name) | `LXD_REMOTE` | yes |
| `{INFRAENV}_LXD_TOKEN` | `TF_VAR_infrapipe_lxd_token` (the `remote {}` block's `token`, terraform-lxd/lxd **v2.2.0+**) | `LXD_TOKEN` (terraform-lxd/lxd **v2.2.0+**) | yes, see below |

- **Trust tokens and the generated `remote {}` block.** Both providers read `<P>_TOKEN` only into the remote they build from `<P>_REMOTE`/`<P>_ADDR` in the environment, never into an explicit `remote {}` block. So when `{INFRAENV}_<P>_TOKEN` is set at `iac init`, the generated block carries `token = var.infrapipe_<p>_token` and the file declares that variable (`type = string`, `default = ""`, `sensitive = true`); `plan`/`apply`/`destroy` export the token as `TF_VAR_infrapipe_<p>_token`. The value is never written to the file. Terraform does record root variable values, sensitive ones included, in the saved plan (`out.tfplan`), so treat that file as secret while the token is valid. A trust token enrols the client certificate once (`generate_client_certificates = true` creates it); after that the trusted certificate authenticates and the token can be unset. Without `{INFRAENV}_<P>_TOKEN` at `iac init` the block has no `token` attribute, as before; re-run `iac init` after setting it. A client certificate that is already trusted keeps working without a token (Incus: `{INFRAENV}_INCUS_CONF`; LXD: the provider's default config directory).
- **Incus `https://` addresses.** lxc/incus 0.x (the `~> 0.2` pin) defaults a remote's `scheme` to `unix`, joins `https://<address>:<port>` itself, and sends a trust token only for `scheme = "https"`. So an `https://host[:port]` value of `{INFRAENV}_INCUS_ADDR` is rendered as `scheme = "https"`, `address = "host"` and, when given, `port` (the provider's default is 8443); in earlier releases the URL was rendered verbatim as `address` and the provider treated it as a socket path. Any other value is rendered verbatim. lxc/incus v1 removed `scheme`, `port` and the remote's `default` attribute, so the remote `{}` shape follows the major that `providerVersions.incus` selects:
  - **Only 0.x** (unset, `~> 0.2`, `>= 0.2, < 1.0`): the 0.x block above, `scheme`/`address`/`port` and `default = true`, unchanged.
  - **Only v1** (`~> 1.0`, `~> 1.2`, `1.2.0`, `>= 1.0, < 2.0`): `address` is the `{INFRAENV}_INCUS_ADDR` URL verbatim (`https://host:8443`, not split), and the provider block sets `default_remote = "<name>"` instead of the remote's `default`. v1 dials a unix socket only for a `unix:` address and sends anything else to its HTTPS client, so a bare socket path such as `/var/lib/incus/unix.socket` is rendered as `unix:///var/lib/incus/unix.socket`. The token, `accept_remote_certificate` and `generate_client_certificates` are rendered as for 0.x. Checked with `terraform validate` against lxc/incus 1.0.0 and 1.2.0.
  - **Both majors** (`>= 0.2`, `> 0.5.1`, `<= 1.0`, `!= 0.5.1`), or a constraint infrapipe cannot parse: with an address set, `iac init` refuses before writing anything (HTTP 400 from `POST /api/v1/iac/init`). The constraint alone does not say which major `.terraform.lock.hcl` has selected, and each major rejects the other's block with `Unsupported argument`. Pin `~> 0.2` (0.x) or `~> 1.0` (v1). An invalid constraint string is already replaced by the `~> 0.2` default, with a warning, before this check runs.

  When you change major on an existing checkout, re-run `iac init` and let `terraform init -upgrade` update the lock file. `validate secrets` fails the same combinations for Terraform and OpenTofu, locally and via `--remote`; Pulumi does not read `providerVersions`. Without an address the generated block is empty and any version works. Pulumi, which reads no generated block, gets the same split as environment variables: lxc/incus 0.x builds its environment remote from `INCUS_SCHEME`, `INCUS_ADDR` and `INCUS_PORT` separately, with no port default, and only when `INCUS_REMOTE` is set, so infrapipe exports all four (in earlier releases the URL went verbatim to `INCUS_ADDR`, which the provider read as a socket path, and the token was never sent). A non-`https` value is exported with `INCUS_SCHEME=unix`, so an inherited `INCUS_SCHEME` cannot reinterpret it. lxc/incus v1 reads the full URL from `INCUS_ADDR` and has no `INCUS_SCHEME`/`INCUS_PORT`; infrapipe targets the 0.x pin for Pulumi too, since Pulumi bridges its own provider version and never reads `providerVersions.incus`.
- **Version floors.** The pinned constraints (`incus ~> 0.2`, `lxd ~> 2.0`) resolve to the newest matching release on a fresh `init`, but a lock file can hold older ones: `INCUS_CONF` needs lxc/incus v0.4.0, and the remote block's `token` (rendered only when `{INFRAENV}_LXD_TOKEN` is set) and `LXD_TOKEN` need terraform-lxd/lxd v2.2.0; with an older lock, `init` fails with `Unsupported argument` while a token is set.
- **`{INFRAENV}_<P>_TLS_CLIENT_CERT` / `_TLS_CLIENT_KEY`** were documented here before, but neither provider reads a TLS client variable, so they never took effect. infrapipe no longer exports them and logs a warning when they are set, pointing at `{INFRAENV}_INCUS_CONF` (Incus) or a trusted client certificate in the provider's default config directory (LXD).
- Pulumi has no Incus package in its registry; LXD is available only as a bridged Terraform provider.
- terraform-lxd/lxd v3 removed every `LXD_*` environment variable. infrapipe pins `~> 2.0`.

### cloudProvider.kubernetes

Used when `cloudProvider.type` is `kubernetes`.

| Field | Type | Required | Default | Description |
|-------|------|----------|---------|-------------|
| `context` | string | No | -- | kubectl context name. Not read by infrapipe today; set `{INFRAENV}_KUBE_CONTEXT` instead |
| `credential_source` | string | No | `ambient` | `ambient` (the pod's service account) or `env` (`{INFRAENV}_KUBECONFIG`). See [Credential source](#credential-source) |

The generated block is always `provider "kubernetes" {}`: no `config_path`, `config_context`, `host` or `token` is ever written to the file. Credentials reach the provider through the subprocess environment (`env`) or the in-cluster service account (`ambient`).

| | `ambient` | `env` |
|---|---|---|
| Required variables | none | `{INFRAENV}_KUBECONFIG` |
| What authenticates | the pod's service-account token (`KUBERNETES_SERVICE_HOST` + `/var/run/secrets/kubernetes.io/serviceaccount/token`) | the kubeconfig file |
| Exported to the subprocess | nothing | see the mapping below |
| `validate secrets` | `pass` in a pod with a readable service-account token, otherwise `warn` | `fail` when `{INFRAENV}_KUBECONFIG` is missing |

**Environment variable mapping (`env` mode):**

| infrapipe variable | Terraform / OpenTofu (`hashicorp/kubernetes`) | Pulumi |
|---|---|---|
| `{INFRAENV}_KUBECONFIG` (required) | `KUBE_CONFIG_PATH` | `KUBECONFIG` |
| `{INFRAENV}_KUBE_CONTEXT` | `KUBE_CTX` | not mapped (Pulumi takes the context only from the `kubernetes:context` stack config); a warning is logged if set |
| `{INFRAENV}_KUBE_HOST` | `KUBE_HOST` | not mapped (warning) |
| `{INFRAENV}_KUBE_TOKEN` | `KUBE_TOKEN` | not mapped (warning) |
| `{INFRAENV}_KUBE_CA_CERT` | `KUBE_CLUSTER_CA_CERT_DATA` (PEM data, not a file path) | not mapped (warning) |

Earlier releases exported `KUBE_CONTEXT`, which no provider reads; it is never exported now.

**`{INFRAENV}_KUBECONFIG` is required before any tool runs.** In `env` mode the executors require it themselves, not only `validate secrets`: `iac init`, `plan`, `apply` and `destroy`, for every engine, fail in infrapipe, before terraform, tofu or pulumi starts, with `missing required environment variable: DEV_KUBECONFIG (credential_source: env for kubernetes)` (HTTP 400 over `--remote`, the streaming apply/destroy ending with the `error` event; `config.CheckKubernetesEnv`, the one definition `validate secrets` lists from). A host and token without a kubeconfig are not an env-mode identity. Earlier releases started the tool with whatever was set, and with nothing set the `hashicorp/kubernetes` provider fell back to the in-cluster service account and Pulumi to `~/.kube/config`, an identity the operator did not select. The Terraform/OpenTofu `iac init` runs the same rule before writing the provider block (`failed to create provider configuration: ` and the message above, HTTP 400 over `--remote`).

**Inherited environment wins over the service account.** infrapipe's subprocesses inherit its own environment. In `ambient` mode, any of these in infrapipe's environment is used *instead of* the pod's service account:

- Terraform / OpenTofu: `KUBE_CONFIG_PATH`, `KUBE_CONFIG_PATHS`, `KUBE_CTX`, `KUBE_CTX_AUTH_INFO`, `KUBE_CTX_CLUSTER`, `KUBE_HOST`, `KUBE_TOKEN`, `KUBE_USER`, `KUBE_PASSWORD`, `KUBE_CLIENT_CERT_DATA`, `KUBE_CLIENT_KEY_DATA`, `KUBE_CLUSTER_CA_CERT_DATA`;
- Pulumi: `KUBECONFIG`, then `~/.kube/config`, both read before the in-cluster config.

`validate secrets` reports each one present as a `warn`, and `iac init` logs a warning naming each Terraform variable. infrapipe never removes them and never fails on them; unset them if the service account should be used.

#### Exec plugins

A kubeconfig whose user runs an exec plugin is an `env`-mode kubeconfig (set `credential_source: env` and `{INFRAENV}_KUBECONFIG`), but the credential the plugin uses can itself be ambient:

- **EKS:** `aws eks get-token`, which uses the AWS SDK chain (instance profile, IRSA, Pod Identity):

  ```yaml
  users:
    - name: eks
      user:
        exec:
          apiVersion: client.authentication.k8s.io/v1beta1
          command: aws
          args: ["eks", "get-token", "--cluster-name", "my-cluster", "--region", "us-east-1"]
  ```

- **GKE:** [`gke-gcloud-auth-plugin`](https://cloud.google.com/kubernetes-engine/docs/how-to/cluster-access-for-kubectl), which uses Application Default Credentials:

  ```yaml
  users:
    - name: gke
      user:
        exec:
          apiVersion: client.authentication.k8s.io/v1beta1
          command: gke-gcloud-auth-plugin
          provideClusterInfo: true
  ```

- **AKS:** [`kubelogin`](https://azure.github.io/kubelogin/concepts/exec-plugin.html) with a managed identity (`-l msi`) or the Azure CLI login (`-l azurecli`). Convert an existing kubeconfig with `kubelogin convert-kubeconfig -l msi`:

  ```yaml
  users:
    - name: aks
      user:
        exec:
          apiVersion: client.authentication.k8s.io/v1beta1
          command: kubelogin
          args: ["get-token", "--login", "msi", "--server-id", "6dae42f8-4368-4678-94ff-3960e28e3630"]
  ```

**Default and migration.** `ambient` is the default: with no `credential_source`, infrapipe needs no `{INFRAENV}_KUBECONFIG` and authenticates as the pod's service account. Before this release the same config ran in `env` mode. With `{INFRAENV}_KUBECONFIG` or `{INFRAENV}_KUBE_TOKEN` set and no `credential_source`, the [migration guard](#credential-source) now stops every IaC operation before any tool runs; set `credential_source: env` to keep using the kubeconfig.

**Example:**

```yaml
cloudProvider:
  type: kubernetes
  kubernetes:
    # credential_source: ambient   # the default: in-cluster, the pod's service account
    credential_source: env         # opt out: keep using DEV_KUBECONFIG
```

**RBAC for the service account.** In `ambient` mode the pod's service account is the deploying identity, so it needs RBAC for every resource your code manages, and nothing more. This is the shape that works in-cluster: a namespaced Role for ConfigMaps, bound to the service account the infrapipe pod runs as. `automountServiceAccountToken` must not be `false` on the pod or its service account.

```yaml
apiVersion: v1
kind: ServiceAccount
metadata:
  name: infrapipe-runner
  namespace: infrapipe-e2e
---
apiVersion: rbac.authorization.k8s.io/v1
kind: Role
metadata:
  name: configmap-manager
  namespace: infrapipe-e2e
rules:
  - apiGroups: [""]
    resources: ["configmaps"]
    verbs: ["get", "list", "watch", "create", "update", "patch", "delete"]
---
apiVersion: rbac.authorization.k8s.io/v1
kind: RoleBinding
metadata:
  name: infrapipe-runner-configmap-manager
  namespace: infrapipe-e2e
subjects:
  - kind: ServiceAccount
    name: infrapipe-runner
    namespace: infrapipe-e2e
roleRef:
  apiGroup: rbac.authorization.k8s.io
  kind: Role
  name: configmap-manager
```

Run infrapipe in a pod with `serviceAccountName: infrapipe-runner`. A request the Role does not allow fails with `forbidden` for `system:serviceaccount:<namespace>:<name>`, which names the identity in use.

### cloudProvider.oci

Used when `cloudProvider.type` is `oci`.

| Field | Type | Required | Default | Description |
|-------|------|----------|---------|-------------|
| `credential_source` | string | No | `ambient`  | `ambient` (workload identity) or `env` (`{INFRAENV}_*` variables). See [Credential source](#credential-source) |
| `region` | string | No | -- | The OCI region identifier (e.g. `us-ashburn-1`; anything else fails `iac init`), ahead of `{INFRAENV}_OCI_REGION`. Read by the ambient-mode provider and by the `oci` state backend in **both** modes. The env-mode provider ignores it and maps only `{INFRAENV}_OCI_REGION` (`OCI_REGION`, Pulumi `TF_VAR_region`) |
| `ambient_principal` | string | No | `auto` | Ambient mode only: `auto`, `instance`, `resource` or `oke_workload_identity`. Any other value fails `validate config` and `iac init` |

**`credential_source: ambient`** (Terraform/OpenTofu): `iac init` generates a provider block with only `auth` and `region`, and no key material, even when `{INFRAENV}_TENANCY_OCID`/`_USER_OCID`/`_OCI_FINGERPRINT`/`_OCI_PRIVATE_KEY` are set (they are ignored and not required):

```hcl
provider "oci" {
	auth = "InstancePrincipal"
	region = "us-ashburn-1"
}
```

`auth` is written into the block, not exported, so an inherited `TF_VAR_auth` or `OCI_AUTH` cannot override it. `ambient_principal` selects it:

| `ambient_principal` | `auth` |
|---|---|
| `instance` | `InstancePrincipal` |
| `resource` | `ResourcePrincipal` |
| `oke_workload_identity` | `OKEWorkloadIdentity` (oracle/oci ≥ 5.40.0; a `providerVersions.oci` constraint admitting older releases logs a warning) |
| `auto` (default) | `OKEWorkloadIdentity` when `OCI_RESOURCE_PRINCIPAL_VERSION` and `KUBERNETES_SERVICE_HOST` are both set; `ResourcePrincipal` when only `OCI_RESOURCE_PRINCIPAL_VERSION` is set; otherwise `InstancePrincipal` |

`KUBERNETES_SERVICE_HOST` alone is deliberately not a signal: every pod has it, and a pod on an OKE node without workload identity can use the node's instance principal. The chosen `auth` and the reason are logged at info level.

`region` comes from `cloudProvider.oci.region`, then `{INFRAENV}_OCI_REGION`. `InstancePrincipal` and `OKEWorkloadIdentity` need one, so `iac init` fails when neither is set. `ResourcePrincipal` omits `region` and falls back to `OCI_RESOURCE_PRINCIPAL_REGION`. The native `oci` state backend honours `ambient` with the instance or resource principal and always needs a region; see the [OCI backend note](#iacterraform).

**OCI variables**. Every OCI consumer (the Terraform/OpenTofu generator, the Pulumi mapping, `validate secrets` and `init config`) reads these names:

| Variable | Meaning | Secret? | `env` mode | `ambient` mode |
|---|---|---|---|---|
| `{INFRAENV}_TENANCY_OCID` | tenancy OCID | no | required | not used |
| `{INFRAENV}_USER_OCID` | API-signing user OCID | no | required | not used |
| `{INFRAENV}_OCI_FINGERPRINT` | key fingerprint | no | required | not used |
| `{INFRAENV}_OCI_PRIVATE_KEY` | PEM **content** | **yes** | one of these two | not used |
| `{INFRAENV}_OCI_PRIVATE_KEY_PATH` | path to a PEM file | no | one of these two (wins when both are set); with `backend: oci` the path is required and `validate secrets`/`validate backend` require it to name a regular file | not used |
| `{INFRAENV}_OCI_REGION` | region | no | required | optional (`cloudProvider.oci.region` wins); with `backend: oci` required unless `cloudProvider.oci.region` is set |

The `oci` state backend's `{INFRAENV}_OCI_TFSTATE_BUCKET` and `_NAMESPACE` are required whenever `backend: oci`, for any cloud; see [State backend variables](#state-backend-variables).

- **Deprecated aliases:** `{INFRAENV}_OCI_TENANCY_OCID` and `{INFRAENV}_OCI_USER_OCID` (which `init config` used to advise) are still read as fallbacks, with a warning naming the canonical variable; `validate secrets` reports `warn`. They will be removed in a later release.
- **Required set** (`env`): the executors require the table's `env` column before any tool starts, through the one rule `validate secrets` lists from (`config.CheckOCIAPIKeyEnv`, the suffixes in `config.OCIAPIKeyVarSuffixes`): `iac init`, `plan`, `apply` and `destroy` fail with `missing required environment variable: {INFRAENV}_OCI_FINGERPRINT (credential_source: env for oci)` (every missing name listed in table order, the key pair as `_OCI_PRIVATE_KEY or _OCI_PRIVATE_KEY_PATH`), over `--remote` as HTTP 400 (the streaming apply/destroy as an `error` event), and terraform, tofu or pulumi never runs; you no longer read the provider's `did not find a proper configuration for keyFingerprint` after a provider download. The deprecated aliases satisfy the tenancy and user. Ambient mode requires none of them.
- **Terraform/OpenTofu** (`env`): the generated provider block is only `provider "oci" { auth = "ApiKey" }`; no OCID, fingerprint, key or path is written into it. The executor maps `_TENANCY_OCID` → `OCI_TENANCY_OCID`, `_USER_OCID` → `OCI_USER_OCID`, `_OCI_FINGERPRINT` → `OCI_FINGERPRINT`, `_OCI_PRIVATE_KEY` → `OCI_PRIVATE_KEY`, `_OCI_PRIVATE_KEY_PATH` → `OCI_PRIVATE_KEY_PATH` and `_OCI_REGION` → `OCI_REGION` into the subprocess environment; the oracle/oci provider reads its arguments from them. Not `TF_VAR_*`: Terraform would also hand those to any same-named `variable` your code declares and store the value in `out.tfplan`. Because the provider reads `TF_VAR_<attr>` first, then `OCI_<ATTR>`, env mode refuses any inherited identity variable the mapping does not shadow: `TF_VAR_tenancy_ocid`, `TF_VAR_user_ocid`, `TF_VAR_fingerprint`, `TF_VAR_private_key`, `TF_VAR_private_key_path`, and the same attributes under their `OCI_<ATTR>` names (e.g. a host `OCI_FINGERPRINT` with no `{INFRAENV}_OCI_FINGERPRINT`, or a host `OCI_PRIVATE_KEY_PATH` beside mapped key content), since either would silently override the mapped identity. An inherited name the mapping itself sets passes; since the required set comes first, a host `OCI_FINGERPRINT` with no `{INFRAENV}_OCI_FINGERPRINT` is reported as the missing variable. An inherited `TF_VAR_region` that differs from `{INFRAENV}_OCI_REGION` is warned about.
- **Key path:** `{INFRAENV}_OCI_PRIVATE_KEY_PATH` is mapped to the key-path variable (`OCI_PRIVATE_KEY_PATH`, Pulumi `TF_VAR_private_key_path`) instead of the key-content one. A value of `{INFRAENV}_OCI_PRIVATE_KEY` that has no `-----BEGIN` and names a regular file is treated as a path too, with a warning to use `{INFRAENV}_OCI_PRIVATE_KEY_PATH` (Pulumi users used to put a path there).
- **Pulumi** (`env`): `_TENANCY_OCID` → `TF_VAR_tenancy_ocid`, `_USER_OCID` → `TF_VAR_user_ocid`, `_OCI_FINGERPRINT` → `TF_VAR_fingerprint`, `_OCI_PRIVATE_KEY` → `TF_VAR_private_key`, `_OCI_PRIVATE_KEY_PATH` → `TF_VAR_private_key_path`, `_OCI_REGION` → `TF_VAR_region`, with the same refusal of unshadowed inherited `TF_VAR_<attr>`/`OCI_<ATTR>` identity variables as Terraform/OpenTofu (pulumi-oci is bridged from oracle/oci and reads them in the same order). **Pulumi** (`ambient`): only `TF_VAR_auth=<auth>` (selected as above) and `TF_VAR_region` when a region is known; no tenancy, user, fingerprint or key, even when they are set. Pulumi does not document `TF_VAR_auth` (upstream reads it the same way as the documented names); the real pulumi-oci takes the instance-principal branch from it.
- **`validate secrets`** (`ambient`): passes with `principal=<auth> (<reason>)` and `region=<source>`. It warns when `InstancePrincipal`/`OKEWorkloadIdentity` has no region, or when an unprefixed `OCI_PRIVATE_KEY`, `TF_VAR_private_key` or `OCI_CLI_KEY_CONTENT` is inherited (the explicit `auth` makes the provider ignore it).
- The `{INFRAENV}_USER_OCID`, `_OCI_FINGERPRINT`, `_OCI_PRIVATE_KEY`, `_OCI_PRIVATE_KEY_PATH` and legacy `_OCI_USER_OCID` variables are OCI's static credential variables. OCI defaults to `ambient`, so setting one with no `credential_source` is an error (the [migration guard](#credential-source)); add `credential_source: env` to keep the API key.

#### OCI IAM setup

An ambient principal has no permissions until a policy grants them. Write policies for the compartment infrapipe manages, with the verbs your configuration needs (`inspect`, `read`, `use`, `manage`). In a non-Default identity domain, qualify the group name: `dynamic-group '<domain>'/'<name>'`.

- **Instance principal** (`InstancePrincipal`, compute instances and self-hosted CI runners). Create a dynamic group whose matching rule selects the instance, e.g. `ALL {instance.id = '<instance-ocid>'}` or `ALL {instance.compartment.id = '<compartment-ocid>'}`, then a policy:

  ```text
  Allow dynamic-group <dynamic-group> to manage all-resources in compartment <compartment>
  ```

  Source: [Calling services from an instance](https://docs.oracle.com/en-us/iaas/Content/Identity/Tasks/callingservicesfrominstances.htm).

- **State bucket** (`backend: oci`). The instance or resource principal that reads and writes Terraform state needs:

  ```text
  Allow dynamic-group <dynamic-group> to read buckets in compartment <compartment>
  Allow dynamic-group <dynamic-group> to manage objects in compartment <compartment> where target.bucket.name = '<bucket>'
  ```

- **Resource principal** (`ResourcePrincipal`). A dynamic group matching on `resource.type` and `resource.compartment.id`, e.g. `ALL {resource.type = 'fnfunc', resource.compartment.id = '<compartment-ocid>'}` for OCI Functions, plus a policy like the one above. Functions is the documented case; the `resource.type` value for other services (Container Instances, Data Science, …) differs, so verify it for your service.

- **OKE workload identity** (`OKEWorkloadIdentity`, enhanced clusters only). No dynamic group: the policy names the workload directly:

  ```text
  Allow any-user to <verb> <resource> in compartment <compartment> where all {request.principal.type = 'workload', request.principal.namespace = '<namespace>', request.principal.service_account = '<service-account>', request.principal.cluster_id = '<cluster-ocid>'}
  ```

  Not usable for state: Terraform's `oci` backend rejects `OKEWorkloadIdentity`.

  The pod must set `OCI_RESOURCE_PRINCIPAL_VERSION` (`2.2`) and `OCI_RESOURCE_PRINCIPAL_REGION`; with both it and `KUBERNETES_SERVICE_HOST` set, `ambient_principal: auto` selects `OKEWorkloadIdentity`. Source: [Granting workloads access to OCI resources](https://docs.oracle.com/en-us/iaas/Content/ContEng/Tasks/contenggrantingworkloadaccesstoresources.htm).

### cloudProvider.digitalocean

Used when `cloudProvider.type` is `digitalocean`.

| Field | Type | Required | Default | Description |
|-------|------|----------|---------|-------------|
| `credential_source` | string | No | `env` | Only `env` is accepted; `ambient` is rejected (no workload identity). See [Credential source](#credential-source) |

**Environment variables.** `{INFRAENV}_DO_TOKEN` is required before any tool runs: `iac init`, `plan`, `apply` and `destroy` fail in infrapipe, for every engine,, before terraform, tofu or pulumi starts, with `missing required environment variable: DEV_DO_TOKEN (credential_source: env for digitalocean)` (HTTP 400 over `--remote`, the streaming apply/destroy ending with the `error` event; `config.CheckTokenCredentialEnv`, the one definition `validate secrets` lists from). It is mapped to `DIGITALOCEAN_TOKEN` for Terraform/OpenTofu and Pulumi. The generated `provider "digitalocean" {}` carries no token, but the Terraform/OpenTofu `iac init` runs the same rule before writing it (`failed to create provider configuration: ` and the message above, HTTP 400 over `--remote`).

### cloudProvider.cloudflare

Used when `cloudProvider.type` is `cloudflare`.

| Field | Type | Required | Default | Description |
|-------|------|----------|---------|-------------|
| `credential_source` | string | No | `env` | Only `env` is accepted; `ambient` is rejected (no workload identity). See [Credential source](#credential-source) |

**Environment variables.** `{INFRAENV}_CLOUDFLARE_API_TOKEN` is required before any tool runs: `iac init`, `plan`, `apply` and `destroy` fail in infrapipe, for every engine,, before terraform, tofu or pulumi starts, with `missing required environment variable: DEV_CLOUDFLARE_API_TOKEN (credential_source: env for cloudflare)` (HTTP 400 over `--remote`, the streaming apply/destroy ending with the `error` event; `config.CheckTokenCredentialEnv`, the one definition `validate secrets` lists from). It is mapped to `CLOUDFLARE_API_TOKEN` for Terraform/OpenTofu and Pulumi. The generated `provider "cloudflare" {}` carries no token, but the Terraform/OpenTofu `iac init` runs the same rule before writing it (`failed to create provider configuration: ` and the message above, HTTP 400 over `--remote`).

---

## cicd

Configures the CI/CD execution context.

| Field | Type | Required | Valid Values | Description |
|-------|------|----------|--------------|-------------|
| `type` | string | No | `local`, `github`, `gitlab` | CI/CD system type |

### cicd.local

Used for local development execution.

| Field | Type | Required | Default | Description |
|-------|------|----------|---------|-------------|
| `enabled` | bool | No | `false` | Enable local execution mode |

**Example:**

```yaml
cicd:
  type: local
  local:
    enabled: true
```

---

## secrets

Configures secret management.

| Field | Type | Required | Valid Values | Description |
|-------|------|----------|--------------|-------------|
| `type` | string | No | `envars` | Secrets source type |

### secrets.envars

| Field | Type | Required | Default | Description |
|-------|------|----------|---------|-------------|
| `enabled` | bool | No | `false` | Enable environment variable secrets |

**Example:**

```yaml
secrets:
  type: envars
  envars:
    enabled: true
```

---

## scm

Configures source control management.

| Field | Type | Required | Default | Description |
|-------|------|----------|---------|-------------|
| `remote` | string | No | -- | Git remote name |

### scm.gitcli

| Field | Type | Required | Default | Description |
|-------|------|----------|---------|-------------|
| `version` | string | No | -- | Expected git CLI version |

**Example:**

```yaml
scm:
  gitcli:
    version: "2.40"
  remote: origin
```

---

## applications

Maps git branches to deployment environments. This is the core of infrapipe's opinionated workflow — **the current git branch determines which environment you deploy to and which credentials are used**.

When you run `infrapipe iac plan` on the `develop` branch:
1. Infrapipe detects the current branch (`develop`)
2. Looks up `applications.deployment.develop` in the config
3. Reads `infraenv: DEV` → uses the `DEV_*` variables: identifiers such as `DEV_AWS_TFSTATE_S3_BUCKET`, `DEV_AWS_ASSUME_ROLE_ARN` and `DEV_AZ_CLIENT_ID`, plus, with `credential_source: env`, static credentials such as `DEV_AWS_ACCESS_KEY` or `DEV_AZ_CLIENT_SECRET`
4. Reads `codedir: infra` → runs IaC commands in the `infra` directory of the checkout

If the branch isn't found, infrapipe falls back to the `default` deployment entry.

At least one deployment entry is required.

### applications.deployment.\<name\>

Each entry under `deployment` is a named deployment mapping.

| Field | Type | Required | Default | Description |
|-------|------|----------|---------|-------------|
| `branch` | string | No | -- | Git branch name |
| `infraenv` | string | No | -- | Infrastructure environment label |
| `appenv` | string | No | -- | Application environment label |
| `postfix` | string | No | -- | Resource name postfix |
| `domain` | string | No | -- | Domain for this environment |
| `codedir` | string | No | -- | Code directory override |

**Example:**

```yaml
applications:
  deployment:
    dev:
      branch: develop
      infraenv: dev
      appenv: development
      postfix: "-dev"
      domain: dev.example.com
    prod:
      branch: main
      infraenv: prod
      appenv: production
      postfix: ""
      domain: example.com
```

---

## providerVersions

Override default version constraints for Terraform/OpenTofu providers. All fields are optional. When omitted, defaults from the table below are used.

Version constraints use standard Terraform syntax: `~>` (pessimistic), `>=`, `<=`, `>`, `<`, `!=`, `=`, or comma-separated compound constraints (e.g., `>= 4.0.0, < 5.0.0`).

| Field | Type | Default | Registry Source |
|-------|------|---------|-----------------|
| `aws` | string | `~> 5.0` | `hashicorp/aws` |
| `azurerm` | string | `~> 4.0` | `hashicorp/azurerm` |
| `azuread` | string | `~> 3.0` | `hashicorp/azuread` |
| `azapi` | string | `~> 2.0` | `Azure/azapi` |
| `cloudflare` | string | `~> 5.0` | `cloudflare/cloudflare` |
| `digitalocean` | string | `~> 2.0` | `digitalocean/digitalocean` |
| `oci` | string | `~> 6.0` | `oracle/oci` |
| `gcp` | string | `~> 6.0` | `hashicorp/google` |
| `incus` | string | `~> 0.2` | `lxc/incus` |
| `lxd` | string | `~> 2.0` | `terraform-lxd/lxd` |
| `kubernetes` | string | `~> 2.0` | `hashicorp/kubernetes` |

Exact version pins (e.g., `4.13.0`) are valid but trigger a warning because they prevent automatic security patches. Prefer pessimistic constraints (`~> X.0`).

**Example:**

```yaml
providerVersions:
  aws: ">= 5.30.0, < 6.0.0"
  azurerm: "~> 4.0"
```

---

## additionalProviders

Optional. Declares secondary Terraform/OpenTofu providers alongside the primary cloud provider. Eliminates the need for manual `extra_providers_override.tf` files.

Each entry generates a `required_providers` declaration in the same `terraform {}` block as the primary provider.

| Field | Type | Required | Description |
|-------|------|----------|-------------|
| `<name>` | object | -- | Provider name (e.g., `helm`, `kubernetes`, `kubectl`) |
| `<name>.source` | string | Yes | Registry source (e.g., `hashicorp/helm`). `validate config` fails an entry without it (`additionalProviders.<name>: source is required`) |
| `<name>.version` | string | No | Version constraint (e.g., `~> 2.0`). Unset falls back to `providerVersions.<name>`, else the built-in default below; a `providerVersions.<name>` that differs from the default wins over this field |

**Built-in secondary provider defaults:**

| Provider | Source | Default Version |
|----------|--------|-----------------|
| `helm` | `hashicorp/helm` | `~> 2.0` |
| `kubectl` | `gavinbunney/kubectl` | `~> 1.14` |
| `tls` | `hashicorp/tls` | `~> 4.0` |
| `random` | `hashicorp/random` | `~> 3.0` |
| `null` | `hashicorp/null` | `~> 3.0` |
| `local` | `hashicorp/local` | `~> 2.0` |
| `external` | `hashicorp/external` | `~> 2.0` |

**Note:** YAML treats bare `null` as a null value. To use the null provider, quote it: `"null"`.

**Auto-detection:** Infrapipe scans `.tf` files in the stage directory for provider usage patterns (e.g., `helm_release`, `kubernetes_namespace`) and includes matching providers automatically. Auto-detection is additive — it supplements explicit config, never removes declared providers.

**Backward compatibility:** If an `extra_providers_override.tf` file exists, auto-detection is skipped for that directory.

**Example:**

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

---

## LLM

Optional. Enables AI-powered features like installation script generation.

| Field | Type | Required | Description |
|-------|------|----------|-------------|
| `enabled` | boolean | No | Enable LLM integration (default: false) |
| `provider` | string | When enabled | LLM provider: `anthropic`, `openai`, or `ollama` |
| `model` | string | No | Model name (default: `claude-sonnet-4-20250514` / `gpt-4o` / `llama3`) |
| `apiKeyEnv` | string | For anthropic/openai | Environment variable containing the API key (not needed for ollama) |
| `hooks.explainPlan` | boolean | No | AI explanation of plan output |
| `hooks.validateConfig` | boolean | No | AI review of generated config |
| `hooks.suggestConfig` | boolean | No | AI-generated config suggestions |

**Example:**

```yaml
# Cloud provider (Anthropic or OpenAI):
llm:
  enabled: true
  provider: "anthropic"
  model: "claude-sonnet-4-20250514"
  apiKeyEnv: "ANTHROPIC_API_KEY"
  hooks:
```

```yaml
# Local provider (Ollama — no API key, data stays on machine):
llm:
  enabled: true
  provider: "ollama"
  model: "llama3.1:8b"
  # apiKeyEnv not needed
  hooks:
    explainPlan: true
    validateConfig: false
    suggestConfig: false
```
