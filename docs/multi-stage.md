# Multi-Stage Workflows

Infrapipe supports multi-stage IaC workflows where one stage's outputs
feed into the next stage's inputs. Each stage runs independently with
its own config file. `iac apply --output-vars` captures a stage's outputs
to a JSON file, and `--input-vars` feeds that file to a later stage.

Every supported engine can **produce** outputs, and every supported engine
(**Terraform, OpenTofu, Pulumi, CloudFormation, Bicep and ARM**) can
**consume** them, each through its own mechanism (see [Support
Matrix](#support-matrix)).

## Quick Example

```bash
# Stage 1: any engine (here Terraform) provisions AWS infrastructure
infrapipe iac apply --config .infrapipe-aws.yaml --output-vars /tmp/aws-outputs.json

# Stage 2: a Terraform/OpenTofu (or Pulumi, CloudFormation, Bicep, ARM) stage consumes the AWS outputs
infrapipe iac apply --config .infrapipe-k8s.yaml --input-vars /tmp/aws-outputs.json
```

Stage 2's code declares a `variable` block for each key it uses, for
example `variable "vpc_id" { type = string }`.

Two Terraform or OpenTofu stages may share one code directory with
different state backends (two config files that differ in the S3 `key`,
say). `iac init --config <stage>` rewrites the backend file, and the
stage's next `plan`, `apply` or `destroy` initializes the engine with
`-reconfigure`, so the rewritten backend replaces the one the engine
recorded in its `.terraform` directory and no state migrates between the stages. No
manual cleanup of `.terraform/terraform.tfstate` is needed.

## How It Works

### Output Capture (--output-vars)

After a successful `iac apply`, infrapipe captures the IaC engine's outputs
and normalizes them to a flat JSON object (one key per output), written
with `0600` permissions. The flag accepts a file path where the JSON will
be written.

Each engine's native output format is different, but infrapipe normalizes
them all to the same flat key-value structure:

- **Terraform / OpenTofu:** Runs `terraform output -json` (or `tofu output -json`)
  and flattens the result by extracting each output's `value` field.
- **Pulumi:** Runs `pulumi stack output --json` and writes the result directly
  (Pulumi's output is already flat key-value JSON).
- **CloudFormation:** Parses the stack's `Outputs` array from
  `aws cloudformation describe-stacks` and maps each `OutputKey` to its
  `OutputValue`.
- **Bicep / ARM:** Parses the deployment outputs from
  `az deployment group show` and extracts each output's `value` field.

Sensitive Terraform outputs are written in clear text: treat the file as
a secret.

If the apply step fails, no output file is written and infrapipe exits
with a non-zero status code.

### Input Injection (--input-vars)

Input injection is supported for **Terraform, OpenTofu, Pulumi,
CloudFormation, Bicep and ARM**.

**Numbers pass through exactly.** Infrapipe keeps every number in the file
with the digits written, locally and over `--remote`, and never rounds it
through a 64-bit float. An integer beyond 2^53 (`9007199254740993`) or a
value of 1e21 or more (`1000000000000000000000`) reaches every engine
unchanged, and no engine refuses one. A number written in
exponent form (`1e21`) is passed on in that form.

#### Terraform and OpenTofu

Before running `iac plan`, `iac apply`, or `iac destroy`, infrapipe reads
the JSON file and writes it, unchanged, to `infrapipe-inputs.auto.tfvars.json` in
the stage's code directory (`0600` permissions). Terraform and OpenTofu
load `*.auto.tfvars.json` files automatically, so:

- The code must declare a matching `variable` block for each key it uses,
  with a type that fits the JSON value (a list output needs, say,
  `list(string)`). Keys with no matching `variable` are not an error;
  Terraform and OpenTofu only warn about them.
- The file stays in the code directory after the run; add
  `infrapipe-inputs.auto.tfvars.json` to `.gitignore`, and note that a later
  run without `--input-vars` still loads the values from the previous one.
- No `TF_VAR_*` environment variables are set.

#### Pulumi

Each value becomes encrypted stack config. After `iac plan`, `iac apply` or
`iac destroy` selects (or creates) the stack, and before `pulumi
preview`/`up`/`destroy`, infrapipe runs one `pulumi config set --stack
<stack> --secret --raw -- <key>` per key, keys sorted, with the value on
the command's **standard input**:

- **The values never reach a command line or a log line.** Only the key
  is on argv (after `--`, so a key starting with `-` is safe). A `config
  set` error that echoes a value is redacted (`[REDACTED]`; a value of
  1–3 characters only as a whole token, see Bicep and ARM below), and fails the
  operation before `preview`/`up`/`destroy` runs: for example a stack
  whose config lives in Pulumi ESC, which `config set` refuses.
- **Values are written as strings**, since a top-level Pulumi config value
  is one: a JSON string is written as-is (byte for byte, a trailing
  newline included); a number, boolean, object or array as its compact
  JSON text (`42`, `true`, `{"a":[1,2]}`). Read them with the SDK's
  typed getters (`requireNumber`, `requireBoolean`, `requireObject`, or
  `config.Require*`), which parse that text. In a Pulumi YAML program,
  leave such a key out of the `Pulumi.yaml` `config:` block (or declare it
  `type: string`): the CLI rejects a stored string for a key declared
  `type: object`.
- **Every key is written.** A Pulumi program declares nothing, so there is
  no filter and no warning for a key no program reads; the `Pulumi.yaml`
  `config:` block is not treated as a declaration list.
- **Keys are plain names.** An empty key, a key containing `:` (which
  would select a config namespace: `aws:region` is provider config) and a
  JSON `null` fail the command before any `pulumi` runs; the error names the key,
  never the value. `--path` is not used, so `.` and `[` stay literal.
- **The values stay in `Pulumi.<stack>.yaml`**, encrypted (`secure:`) by
  the stack's secrets provider (`PULUMI_CONFIG_PASSPHRASE` for the
  passphrase provider, or the provider the stack was created with), like
  Terraform's leftover tfvars file. Pulumi recommends committing that
  file. An injected key overwrites a same-named key you set yourself, and
  a later run without `--input-vars` reuses the previous values.
- **`iac destroy` accepts `--input-vars`** and writes the values as for
  plan and apply, but `pulumi destroy` does not run the program, so they
  go unused.

#### CloudFormation

The values become stack parameters of the change set that `iac plan`
creates (`aws cloudformation create-change-set --parameters file://…`):

- **They bind at `iac plan`.** `iac apply` executes the change set the plan
  created, and `iac destroy` runs `delete-stack`, which takes no
  parameters. Both accept `--input-vars` and log why they pass nothing.
  Run the plan with the same file.
- **`iac plan` reports only on a change set it created.** For an existing
  stack it first deletes any `<ws>-chgset` left by an earlier run, so a
  plan never reports on old parameters. It creates an `UPDATE` change set
  only when the stack is `CREATE_COMPLETE`, `UPDATE_COMPLETE`,
  `UPDATE_ROLLBACK_COMPLETE`, `IMPORT_COMPLETE` or
  `IMPORT_ROLLBACK_COMPLETE`, and a `CREATE` change set when it is
  `REVIEW_IN_PROGRESS` (planned but never applied). Any other status fails
  the plan before any change-set call, naming the status and the remedy:
  delete a `ROLLBACK_COMPLETE` stack, wait for an `*_IN_PROGRESS` one. This
  holds with or without `--input-vars`. The stale-set lookup uses
  `list-change-sets`; if the role cannot list, the plan still fails when a
  stale set exists, because `create-change-set` refuses the name.
- **A `FAILED` change set is "no changes" only when CloudFormation says
  so.** Plan and apply read its `StatusReason`. Only "didn't contain
  changes" and "No updates are to be performed" are no-ops. Any other
  reason (a value outside `AllowedValues`, a missing required parameter)
  fails the plan or apply and shows the reason, with every injected value
  redacted (a value of 1–3 characters as a whole token only, see Bicep and
  ARM below).
  The plan keeps a no-change change set and the apply deletes it once
  read: the apply proves a plan ran by reading `<ws>-chgset`,
  so `iac plan` then `iac apply` on an unchanged stack is a no-op, and a
  kept change set no apply ever read goes with the next plan.
- **`iac apply` needs a planned change set.** With no `<ws>-chgset`
  (never planned, or already executed: executing removes the stack's
  change sets), or one in any status other than `CREATE_COMPLETE` or a
  no-change `FAILED`, apply fails: ``no usable change set <ws>-chgset for
  stack <ws>: run `iac plan` first: …``. It never reports success without
  `execute-change-set`. A `CREATE_COMPLETE` change set must also be
  executable: any `ExecutionStatus` other than `AVAILABLE` (`OBSOLETE`
  when the stack changed after the plan, `EXECUTE_*` once it has run,
  `UNAVAILABLE`) fails the same way, before the input check and
  `execute-change-set`: ``… change set <ws>-chgset is not executable
  (ExecutionStatus OBSOLETE): run iac plan again``. A no-change `FAILED`
  change set is always `UNAVAILABLE` and stays a no-op.
  With `--input-vars`, the check below runs on a
  no-change `FAILED` change set too, so different inputs are never
  reported as "no changes".
- **`iac apply` checks the change set first.** Before
  `execute-change-set`, it reads the change set's parameters
  (`describe-change-set --query Parameters`, never logged) and compares
  each declared key in the file, converted as below, with them. A value
  that differs, or a key the change set lacks, fails the apply without
  executing: ``change set <ws>-chgset: change set parameters differ from
  --input-vars; re-run `iac plan` with the same --input-vars (keys: …)``,
  naming the keys, never a value. With `--remote` the synchronous apply
  answers HTTP 400 with that message and the streaming apply ends in an
  `error` event. **`NoEcho` parameters are not checked:** CloudFormation
  returns them masked (`*****`), so apply skips them and logs their keys.
  A declared key whose value `iac plan` would refuse fails the apply too.
- **Only declared parameters are passed.** Infrapipe reads the template's
  parameter keys with `aws cloudformation get-template-summary` and drops
  any other key, whatever its value, with a warning that names the key,
  never its value. The plan does not fail on a dropped key.
- **Values are converted to strings**, since CloudFormation takes every
  parameter value as one: a string is passed through, a number is written
  with the digits in the file (`3`, `1.5`, `9007199254740993`), a boolean
  is `true` or `false`, and an
  array of scalars is comma-joined, which fits `CommaDelimitedList` and
  `List<…>` parameters. For a declared key, an object, a nested array,
  `null` or an
  array member that contains a comma fails `iac plan` before the change
  set is created; the error names the key, never the value.
- **A declared parameter missing from the file is omitted**, so
  CloudFormation uses the template's `Default`, as without `--input-vars`.
  That holds on an update too: a parameter an earlier plan set returns to
  its `Default` (or the change set fails, if it has none) when a later plan
  leaves it out, so plan every update with the full file.
- **The values never reach a command line or a log line.** They are
  written to `parameters.json` (`0600`) in a fresh temp directory (`0700`)
  outside the code directory, which is removed when the plan returns,
  whether it succeeds or fails. The change-set description, which lists the
  parameters, is never logged, and an `aws` error that echoes a value is
  redacted.

#### Bicep and ARM

`iac plan` and `iac apply` pass the values to `az deployment group what-if`
and `az deployment group create` as an ARM parameters file
(`--parameters @<path>`):

- **Only declared parameters are passed.** Infrapipe reads the parameter
  names the template declares (`template.json` directly; `main.bicep`
  compiled with `az bicep build --stdout`, offline) and drops any other
  key with a warning that names the key, never its value. The deployment
  does not fail on a dropped key; if no key is declared, no
  `--parameters` is passed. Names match case-insensitively, as ARM matches
  a parameters file, and the file uses the template's spelling; two keys
  naming one parameter in different cases are an error.
- **Values keep their native JSON types** (`"…"`, `3`, `true`, objects and
  arrays). A JSON `null` fails the command before any `az` runs; the error
  names the key, never the value.
- **The values never reach a command line.** They are written to
  `parameters.json` (`0600`) in a fresh temp directory (`0700`) outside the
  code directory, which is removed when the operation returns, whether it
  succeeds or fails. Only the path is on `az`'s argv.
- **`iac destroy` accepts `--input-vars` and ignores it:** `az group
  delete` takes no parameters, and its command line is unchanged.
- **az's output is redacted.** `what-if` and `create` can echo parameter
  values (the what-if properties, `create`'s `properties.parameters`, a
  validation error); infrapipe replaces every string value, nested ones
  included, with `[REDACTED]` in the lines it logs and in the error it
  returns. Numbers and booleans are not redacted. A value of 4 or more
  characters is replaced wherever it occurs. A value of 1–3 characters (a
  region such as `eu`, a SKU such as `S1`) is replaced only as a whole
  token, bounded on each side by the start or end of the text or by a
  character outside `[A-Za-z0-9_]` (quotes, spaces, punctuation: how az
  echoes a value), so it no longer garbles the words around it in the
  logs and in the error. A short value fused into a longer
  token, such as `dev` in the resource name `devstorage`, is left as is.
  The same rule applies to the Pulumi and CloudFormation redaction above,
  and to every secret infrapipe redacts (`runCommandRedacted`).
- **Limitation:** Azure keeps a deployment's non-secure parameters in its
  deployment history. Declare a parameter `@secure()` (Bicep) or
  `securestring`/`secureObject` (ARM) to keep its value out of the history
  and out of az's output.

#### Engines without input injection

Every registered engine injects today. An engine without input injection
fails closed: `--input-vars` with a non-empty file is an error: `iac plan`, `iac apply` and `iac destroy` exit non-zero with
`executor "<engine>" cannot inject N input variable(s), refusing to run
without them (supported by: <engines>): --input-vars is not supported by
this engine`, where `<engines>` lists the engines that inject today,
before any IaC command (or the exec role's `aws sts`) runs, so a dependent
stage never runs with missing inputs. With `--remote`, the server refuses
the request with HTTP 400 and the same message, for synchronous and streaming apply/destroy alike. A file containing `{}` is a
no-op on every engine. Pass values to such an engine through its own
configuration instead.

### Using Both Flags Together

A stage on any engine can consume inputs and produce outputs
simultaneously:

```bash
infrapipe iac apply \
  --config .infrapipe-network.yaml \
  --input-vars /tmp/base-outputs.json \
  --output-vars /tmp/network-outputs.json
```

This is useful for chaining three or more stages together.

## Support Matrix

Every engine's outputs share one JSON format, so any engine can feed a
stage on any engine.

| Engine         | Output Capture (`--output-vars`) | Input Injection (`--input-vars`)          |
|----------------|----------------------------------|-------------------------------------------|
| Terraform      | `terraform output -json`         | `infrapipe-inputs.auto.tfvars.json`       |
| OpenTofu       | `tofu output -json`              | `infrapipe-inputs.auto.tfvars.json`       |
| Pulumi         | `pulumi stack output --json`     | encrypted stack config (`pulumi config set --secret`, stdin) |
| CloudFormation | `describe-stacks` Outputs        | stack parameters (`create-change-set --parameters file://`) |
| Bicep          | `az deployment group show`       | `--parameters @<temp file>`, filtered to the declared parameters |
| ARM            | `az deployment group show`       | `--parameters @<temp file>`, filtered to the declared parameters |

This table lists exactly which engines support each direction.

## Normalized JSON Format

All engines output to the same flat object: string keys, and each value
keeps its native JSON type. Strings stay strings, numbers and booleans
stay numbers and booleans, and lists and maps are JSON arrays and objects:

```json
{
  "vpc_id": "vpc-0abc123def456",
  "public_ip": "203.0.113.10",
  "instance_count": 3,
  "subnet_ids": ["subnet-aaa", "subnet-bbb"],
  "tags": {"team": "platform"}
}
```

CloudFormation output values are always strings, because
`describe-stacks` reports every `OutputValue` as a string.

## CI/CD Examples

### GitHub Actions

```yaml
name: Multi-Stage Deploy
on:
  push:
    branches: [main]

jobs:
  deploy:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4

      - name: Stage 1 - Provision AWS networking
        run: |
          infrapipe iac apply \
            --config .infrapipe-network.yaml \
            --output-vars /tmp/network-outputs.json

      - name: Stage 2 - Deploy Kubernetes resources (Terraform/OpenTofu stage)
        run: |
          infrapipe iac apply \
            --config .infrapipe-k8s.yaml \
            --input-vars /tmp/network-outputs.json
```

### Azure DevOps

```yaml
trigger:
  branches:
    include:
      - main

stages:
  - stage: Network
    jobs:
      - job: ProvisionNetwork
        steps:
          - script: |
              infrapipe iac apply \
                --config .infrapipe-network.yaml \
                --output-vars $(Build.ArtifactStagingDirectory)/network-outputs.json
          - publish: $(Build.ArtifactStagingDirectory)/network-outputs.json
            artifact: network-outputs

  - stage: Application
    dependsOn: Network
    jobs:
      - job: DeployApp
        steps:
          - download: current
            artifact: network-outputs
          # .infrapipe-app.yaml is a Terraform/OpenTofu stage
          - script: |
              infrapipe iac apply \
                --config .infrapipe-app.yaml \
                --input-vars $(Pipeline.Workspace)/network-outputs/network-outputs.json
```

## Shell Script Example

A complete multi-stage deployment. Any stage could be Pulumi,
CloudFormation, Bicep or ARM instead:

```bash
#!/usr/bin/env bash
set -euo pipefail

OUTPUTS_DIR=$(mktemp -d)
trap 'rm -rf "$OUTPUTS_DIR"' EXIT

echo "=== Stage 1: Base infrastructure (Terraform on AWS) ==="
infrapipe iac apply \
  --config .infrapipe-base.yaml \
  --output-vars "$OUTPUTS_DIR/base.json"

echo "=== Stage 2: Kubernetes cluster (Terraform on AWS) ==="
infrapipe iac apply \
  --config .infrapipe-k8s.yaml \
  --input-vars "$OUTPUTS_DIR/base.json" \
  --output-vars "$OUTPUTS_DIR/k8s.json"

echo "=== Stage 3: Application (OpenTofu on Kubernetes) ==="
infrapipe iac apply \
  --config .infrapipe-app.yaml \
  --input-vars "$OUTPUTS_DIR/k8s.json"

echo "=== All stages complete ==="
```

## Error Handling

- If any stage fails, infrapipe exits with a non-zero status code and
  does not write the `--output-vars` file. Subsequent stages that depend
  on that file will fail immediately with a clear error message.
- If the apply succeeds but its outputs cannot be captured (the capture
  command fails, or the executor cannot capture outputs), `iac apply
  --output-vars <file>` still exits non-zero and writes no `<file>`. The
  error starts with `apply succeeded but --output-vars capture failed`:
  the infrastructure change **was applied**, so fix the capture and re-run
  rather than assuming nothing happened. `--remote` behaves the same way;
  the server reports the apply as completed and the client fails on the
  capture warning.
- If `--input-vars` points to a file that does not exist, infrapipe exits
  with an error before running any IaC commands. This holds for every
  engine.
- If `--input-vars` points to a file containing invalid JSON, infrapipe
  exits with a parse error.

## Limitations

- The JSON format is a flat object of string keys; values keep their
  native JSON types (see [Normalized JSON Format](#normalized-json-format)).
- `--input-vars` is consumed by every engine, each in its own way (see
  [Input Injection](#input-injection---input-vars)). Pulumi writes the
  values as strings, read with the SDK's typed getters, and keeps them
  encrypted in `Pulumi.<stack>.yaml` after the run.
- `--output-vars` is only supported with `iac apply`, not with `iac plan`
  or `iac init`. Planning does not produce outputs.
- `--input-vars` is supported with `iac plan`, `iac apply`, and `iac destroy`
  (Terraform/OpenTofu), so you can preview changes, apply, or tear down with
  injected variables. On CloudFormation the values bind at `iac plan`;
  `iac apply` only checks them against the change set (`NoEcho` parameters
  unchecked) and `iac destroy` does not use them. On Pulumi `iac destroy`
  writes them but does not run the program.
