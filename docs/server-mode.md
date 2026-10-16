# Server Mode

Infrapipe can run as a long-lived HTTP/JSON server, exposing all IaC and validation operations over the network. This enables centralized infrastructure management, remote execution from thin CLI clients, and integration with other tools.

**Server requirements:** The server needs local access to a git repo with IaC code, a valid `.infrapipe.yaml` config, the required IaC tools (terraform, tofu, pulumi, etc.), and cloud credentials according to each cloud's `credential_source`: in `ambient` mode (the AWS and Azure default) the server host's own workload identity plus per-environment identifiers such as `{INFRAENV}_AWS_TFSTATE_S3_BUCKET` and `{INFRAENV}_AWS_ASSUME_ROLE_ARN`, or `{INFRAENV}_AZ_SUBSCRIPTION_ID` and `{INFRAENV}_AZ_CLIENT_ID`; in `env` mode the `{INFRAENV}_` static credential variables.

**Client requirements:** The client needs NOTHING except network access to the server. No IaC tools, no credentials, no git repo, no config file. Use `infrapipe --remote server:8080 iac plan` to route commands through the server.

**Config resolution:** The server reads its own `.infrapipe.yaml` and does branch detection automatically — the client does not need to send config details. Request fields are optional overrides.

## Starting the Server

### Insecure (local development)

```bash
infrapipe serve --addr :8080 --auth-mode none --insecure
```

No TLS, no authentication, stated twice: `--insecure` alone is refused, because the default auth mode is mTLS, which needs TLS (see [Startup Postures](#startup-postures-fail-closed)). Suitable for local development only.

### mTLS (production default)

```bash
infrapipe serve --addr :8080 \
  --tls-cert server.pem \
  --tls-key server-key.pem \
  --tls-ca ca.pem
```

Requires a server certificate/key pair and a CA certificate for verifying client certificates. Clients must present a certificate signed by the same CA.

### API Key Authentication

```bash
INFRAPIPE_API_KEY=mysecretkey infrapipe serve --addr :8080 \
  --auth-mode apikey \
  --tls-cert server.pem \
  --tls-key server-key.pem
```

Clients must include the `X-API-Key` header in every request. TLS is still required (use `--tls-cert` and `--tls-key`), but client certificates are not needed.

### Serve Command Flags

| Flag | Default | Description |
|------|---------|-------------|
| `--addr` | `:8080` | Listen address (host:port) |
| `--tls-cert` | (required unless `--insecure`) | Path to TLS certificate file |
| `--tls-key` | (required unless `--insecure`) | Path to TLS private key file |
| `--tls-ca` | (optional) | CA certificate for client verification (mTLS) |
| `--auth-mode` | `mtls` | Authentication mode: `mtls`, `apikey`, or `none` |
| `--insecure` | `false` | Disable TLS entirely |

## API Reference

All endpoints use JSON request/response bodies. Content type is `application/json` unless streaming.

### GET /api/v1/health

Health check. Always bypasses authentication.

**Response:**
```json
{"status": "ok"}
```

### POST /api/v1/validate

Run a validation check.

**Request:**
```json
{
  "check": "iac",
  "iacType": "terraform",
  "iacVersion": "1.5.0"
}
```

Supported check types:
- `iac` -- Verify IaC tool installation. Requires `iacType` and optionally `iacVersion`.
- `scm` -- Verify git repository and remote configuration.
- `secrets` -- Verify environment variables are set. Requires `cloudType` and `infraEnv`.
- `ping` -- Check network connectivity. Requires `url`.

**Response:**
```json
{
  "success": true,
  "results": [
    {
      "check": "iac",
      "status": "pass",
      "message": "terraform v1.5.0 found"
    }
  ]
}
```

### POST /api/v1/iac/init

Initialize IaC configuration (generate provider and backend files).

**Request:**
```json
{
  "configPath": "./infra",
  "cloudType": "aws",
  "iacType": "terraform",
  "environment": "dev"
}
```

**Response:**
```json
{
  "success": true,
  "message": "Init accepted for terraform/aws in environment dev",
  "filesCreated": ["provider-aws.tf", "backend-terraform.tf"]
}
```

### POST /api/v1/iac/plan

Preview infrastructure changes.

**Request:**
```json
{
  "configPath": "./infra",
  "workspace": "dev-us-east-1"
}
```

**Response:**
```json
{
  "success": true,
  "planOutput": "Plan completed for workspace dev-us-east-1",
  "planText": "  # terraform_data.probe will be created\n  …\n\nPlan: 1 to add, 0 to change, 0 to destroy.\n",
  "planSummary": "Plan: 1 to add, 0 to change, 0 to destroy.",
  "llmExplanation": ""
}
```

`planText` is the engine's plan, redacted of the environment's credential values exactly like the LLM payload: Terraform/OpenTofu's `show -no-color` of the saved plan, CloudFormation's change set (one line per change), Bicep/ARM's what-if or Pulumi's preview. `planSummary` is its summary line: `Plan: …` or `No changes.`, `Change set: …`, `Resource changes: …`, `Resources: …`. With `"showPlanJSON": true` in the request the response also carries `planJSON`: Terraform/OpenTofu's `show -json` or CloudFormation's change set description; Bicep, ARM and Pulumi answer 400 before anything runs. The client prints `planText` and `planSummary` as the local `iac plan` does (`--no-show-plan` drops the text) and writes `planJSON` to `--plan-json <path>` (0600).

### POST /api/v1/iac/apply

Apply infrastructure changes. Supports synchronous and streaming responses.

**Request:**
```json
{
  "configPath": "./infra",
  "workspace": "dev-us-east-1"
}
```

**Synchronous response** (default, `Accept: application/json`):
```json
{
  "success": true,
  "message": "Apply accepted for workspace dev-us-east-1"
}
```

**Streaming response** (`Accept: text/event-stream`):

Returns newline-delimited JSON events:
```json
{"type":"log","message":"Starting apply...","level":"info","progress":0}
{"type":"progress","message":"Applying changes in workspace dev-us-east-1...","level":"info","progress":0.5}
{"type":"result","message":"apply complete","level":"info","progress":1}
```

### POST /api/v1/iac/destroy

Destroy infrastructure. Same request/response format and streaming behavior as apply.

**Request:**
```json
{
  "configPath": "./infra",
  "workspace": "dev-us-east-1"
}
```

## Client Mode

When the `--remote` flag is set, infrapipe operates as a thin client that delegates all operations to a remote server.

### Basic Usage

```bash
# Health check
infrapipe --remote localhost:8080 validate iac

# Run a plan on the remote server
infrapipe --remote localhost:8080 iac plan

# Apply with remote execution
infrapipe --remote localhost:8080 iac apply
```

### Client Authentication

The client authenticates with root flags, and fails closed: setting any of `--api-key` (or `INFRAPIPE_REMOTE_API_KEY`), `--remote-cert`, `--remote-key` or `--remote-ca` makes it use https, so an API key is never sent in cleartext. It also refuses a redirect from https to plain http.

- **Insecure:** with no auth flag the client connects over plain HTTP, which only a server started with `--insecure` accepts.
- **API key:** the `INFRAPIPE_REMOTE_API_KEY` environment variable, or `--api-key <key>`, which wins when non-empty; sent as the `X-API-Key` header. The variable is read only with `--remote`. The client does not read `INFRAPIPE_API_KEY`, and `serve` does not read `INFRAPIPE_REMOTE_API_KEY`, so a host running both never sends its server key to another remote.
- **mTLS:** `--remote-cert <path>` and `--remote-key <path>`. Setting one without the other is an error naming the missing flag.
- **Private CA:** `--remote-ca <path>` verifies the server against that CA; without it the system roots are used.

```bash
INFRAPIPE_REMOTE_API_KEY="$KEY" infrapipe --remote server:8443 --remote-ca ca.pem validate iac
infrapipe --remote server:8443 --remote-cert client.pem --remote-key client-key.pem --remote-ca ca.pem iac plan
```

## Context Contract (which workspace a request operates on)

Infrapipe supports two first-class execution modes with one invariant: **for the
same repository, branch, and configuration, local and remote execution resolve
the identical workspace, infrastructure environment, and code directory.**

### Who owns what

- **The server owns checkout-derived context.** It must run inside a checkout
  of the infrastructure repository, on a branch, with its own
  `.infrapipe.yaml`. From that checkout it derives: the git branch, the
  repository name (from the `origin` remote URL, else the lexicographically
  smallest remote, else the directory name), the deployment entry
  (`applications.deployment.<branch>` with `default` fallback), and the
  workspace name.
- **The client sends only operation parameters** (e.g. input variables) **and
  optional explicit overrides** (`workspace`, `infraEnv`, `codedir`,
  `iacType`, `cloudType`). Each non-empty override replaces exactly that
  field; everything else is still server-derived. The client's local git
  state is never transmitted.

### Workspace naming

Both modes name the workspace `<repository>-<encoded-branch>`, where encoding
replaces `/` and `_` with `-`.

**Worked example (local mode):** in a checkout of
`https://github.com/org/myrepo.git` on branch `feature/x`,
`infrapipe iac plan` targets workspace `myrepo-feature-x`.

**Worked example (server mode):** a server running in that same checkout
receives `POST /api/v1/iac/plan` with an empty body `{}` and targets the
same workspace `myrepo-feature-x`. A body of `{"workspace": "pinned"}`
targets `pinned` instead.

### No silent fallbacks

If the server cannot detect a git branch (detached HEAD, not a repository)
and the request carries no explicit `workspace`, the request is rejected
with HTTP 400 naming both remedies: run the server from a branch checkout,
or supply an explicit workspace. The server never silently substitutes a
default workspace.

### Migration note (older servers)

Servers older than the shared context resolver derived workspace names as `<encoded-branch>`
(without the repository prefix). If such a server created state, its
workspaces still exist under the old names: list them with your IaC tool
(`terraform workspace list` in the code directory) and either migrate state
to the new `<repository>-<encoded-branch>` name or keep addressing the old
workspace explicitly via the request's `workspace` field.

## Streaming vs Synchronous Responses

| Endpoint | Sync | Streaming |
|----------|------|-----------|
| `/api/v1/health` | Yes | No |
| `/api/v1/validate` | Yes | No |
| `/api/v1/iac/init` | Yes | No |
| `/api/v1/iac/plan` | Yes | No |
| `/api/v1/iac/apply` | Yes | Yes (`Accept: text/event-stream`) |
| `/api/v1/iac/destroy` | Yes | Yes (`Accept: text/event-stream`) |

Streaming is triggered by the `Accept: text/event-stream` request header. The response contains newline-delimited JSON `ActionEvent` objects:

```go
type ActionEvent struct {
    Type     string  `json:"type"`     // "log", "progress", "result", "error"
    Message  string  `json:"message"`
    Level    string  `json:"level"`    // "info", "warning", "error"
    Progress float64 `json:"progress"` // 0.0 to 1.0
}
```

The client library returns a `<-chan ActionEvent` channel for both sync and streaming modes. In sync mode, a single "result" event is emitted after the response is received.

Streaming apply specifics:

- **`captureOutputs` is sync-only.** A streaming apply with `"captureOutputs": true` is refused with HTTP 400 (`captureOutputs is not supported on a streaming apply; use the synchronous apply (Client.ApplySync)`) before any IaC subprocess runs. Outputs ride the synchronous `ApplyResponse` only.
- **AI findings stream as `log` events.** With `llm.enabled`, each pre-apply config-review finding is sent as one `{"type":"log","level":"warning"}` event, `[<severity>] <message> (fix: <fix>)`, before the apply's `progress` event. With LLM disabled none are sent. The `ActionEvent` shape is unchanged.

## TLS Certificate Setup

### Generate a self-signed CA and certificates for development

```bash
# Generate CA key and certificate
openssl ecparam -genkey -name prime256v1 -out ca-key.pem
openssl req -new -x509 -key ca-key.pem -out ca.pem -days 365 -subj "/CN=infrapipe-ca"

# Generate server certificate
openssl ecparam -genkey -name prime256v1 -out server-key.pem
openssl req -new -key server-key.pem -out server.csr -subj "/CN=localhost"
openssl x509 -req -in server.csr -CA ca.pem -CAkey ca-key.pem -CAcreateserial -out server.pem -days 365

# Generate client certificate (for mTLS)
openssl ecparam -genkey -name prime256v1 -out client-key.pem
openssl req -new -key client-key.pem -out client.csr -subj "/CN=infrapipe-client"
openssl x509 -req -in client.csr -CA ca.pem -CAkey ca-key.pem -CAcreateserial -out client.pem -days 365

# Clean up CSRs
rm -f server.csr client.csr
```

### Start server with generated certs

```bash
infrapipe serve --addr :8080 --tls-cert server.pem --tls-key server-key.pem --tls-ca ca.pem
```

### Test with curl

```bash
# mTLS
curl --cert client.pem --key client-key.pem --cacert ca.pem \
  https://localhost:8080/api/v1/health

# API key mode
curl -H "X-API-Key: mysecret" --cacert ca.pem \
  https://localhost:8080/api/v1/health
```

## Startup Postures (fail-closed)

The server refuses to start with any flag combination that cannot deliver the protection its auth mode promises — it never silently starts weaker than requested. Unauthenticated operation must be stated twice: explicit `--auth-mode none` plus either `--insecure` or TLS flags.

| Goal | Required flags | Result |
|------|----------------|--------|
| Production (mutual TLS) | `--auth-mode mtls --tls-cert --tls-key --tls-ca` (mtls is the default mode) | clients must present a CA-signed certificate |
| API key over TLS | `--auth-mode apikey --tls-cert --tls-key` + `INFRAPIPE_API_KEY` | key checked with a constant-time comparison |
| API key behind a TLS-terminating proxy | `--auth-mode apikey --insecure` + `INFRAPIPE_API_KEY` | starts with a cleartext-key warning |
| Encrypted, anonymous | `--auth-mode none --tls-cert --tls-key` | TLS without client auth, explicitly chosen |
| Local development | `--auth-mode none --insecure` | unauthenticated + unencrypted; banner says so |

Refused combinations (server exits with an actionable error): `mtls` without `--tls-ca`; `mtls` with `--insecure`; `--insecure` without an explicit `--auth-mode`; `apikey`/`none` with neither TLS material nor `--insecure`.

Stopping a running server with SIGTERM or SIGINT (Ctrl-C) is a clean exit: the server finishes the requests in flight, flushes telemetry (with OpenTelemetry enabled, bounded by 5 seconds when the collector is unreachable), then exits 0 with no error and no usage text. A startup failure such as a bound port or unreadable TLS material prints the `Error:` line alone; only a flag error prints the usage block.

## Code Directory Confinement

Every operation's code directory — whether from the server's `.infrapipe.yaml` or a request's `codedir` field — must resolve inside the repository checkout the server runs in. Absolute paths outside the checkout, `../` traversal, and symlinks that escape it are rejected with HTTP 400 before any file is read or written. Relative code directories anchor to the checkout root. Local CLI runs enforce the identical boundary. Files generated by releases prior to the server security gate with the Cloudflare, DigitalOcean, or OCI providers were written world-readable; re-run `iac init` (or `chmod 600` them) to fix their permissions.

## Local vs Remote Parity

Every `iac` and `validate` surface was audited for parity between local execution and `--remote`. Rows marked **parity** behave identically in both modes; anything a mode cannot do fails loudly — there are no silent no-ops.

| Surface | Status |
|---------|--------|
| `iac init` | parity (server resolves provider/backend from its own config) |
| `iac plan` / `--input-vars` | parity |
| `iac plan` AI explanation | parity (server computes, client displays) |
| `iac apply` / `--input-vars` | parity |
| `iac apply --output-vars` | parity — server captures outputs, client writes the file (same normalized JSON, mode 0600). Capture requests use the synchronous path; capture failure after a successful apply yields a warning, never a failed apply |
| `iac apply` AI findings | parity (server computes, client displays severity/message/fix); a streaming apply sends them as `log` events with level `warning` |
| `iac destroy` / `--input-vars` | parity |
| streaming apply/destroy | parity for event streams; when `--output-vars` is set the client uses the synchronous path so outputs can ride the response. A raw streaming apply with `captureOutputs` gets HTTP 400 (use the synchronous path), never a silent drop |
| exit codes | parity (success 0, any failure non-zero) |
| `validate iac` | parity — server checks its own configured tool/version when the request omits them |
| `validate secrets` | parity — server resolves cloud type and environment from its own configuration |
| `validate scm` | parity (checks the server's checkout) |
| `validate ping --url` | parity — the URL travels with the request |
| `validate system` | **not supported remotely** — inspects the invoking host; run it on the server host (refused client-side with guidance) |
| `validate config` | **not supported remotely** — inspects the host's config file; run it on the server host |
| `validate backend` | **not supported remotely** — checks reachability from the host; run it on the server host |

## Concurrency Model

The server serves concurrent clients safely:

| Two simultaneous requests… | Behavior |
|----------------------------|----------|
| targeting the **same code directory** (any workspaces, any of init/plan/apply/destroy, sync or streaming) | **Serialized** — the second queues automatically and starts when the first finishes; no client retry needed. Streaming operations hold their turn for the whole stream. |
| targeting **different code directories** | **Parallel** — no shared turn. |
| health or validate requests | Never queued. |

- **Why per-code-directory:** the IaC tool's active-workspace selection is on-disk state *of the code directory*, so even operations on different workspaces of the same directory conflict.
- **Delegated credentials never touch the server's process environment.** Exec-role credentials resolved for an operation travel only in that operation's context and appear only in the environment of *its own* subprocesses. Concurrent operations against different environments are fully isolated (race-detector-verified), and nothing lingers after an operation completes.
- **Request behavior is fixed at request start:** all configuration (context resolution, backend, LLM settings) is snapshotted once per request; changing configuration mid-flight never affects in-flight operations.
- **Cross-process caveat:** serialization is per server process. Running multiple server processes against the same checkout is not coordinated by infrapipe — the IaC tool's remote-state locking is the only guard there, and for the `s3` backend that lock exists only with `IaC.<tool>.use_lockfile: true`; without it two processes can both write one state object.
- **Cancellation:** a queued request whose client disconnects acquires its turn briefly and exits immediately via its cancelled request context.

## Security Considerations

- **Always use TLS in production.** The `--insecure` flag is for local development only, and requires an explicit `--auth-mode`.
- **mTLS is the default** and recommended authentication mode. It provides mutual authentication -- the server verifies the client, and the client verifies the server.
- **API keys should be treated as secrets.** The server reads its key from the `INFRAPIPE_API_KEY` environment variable, never a flag. On the client, prefer `INFRAPIPE_REMOTE_API_KEY` (how CI systems inject secrets) to `--api-key`: a flag appears in the client host's process listing while the command runs and in shell history, while the variable is visible only to the same user and root. On a shared client host, mTLS avoids a shared secret altogether.
- **The health endpoint bypasses authentication** by design, to support load balancer health checks.
- **TLS 1.2 is the minimum version** enforced by the server's TLS configuration.
- **Certificate rotation** requires a server restart. There is no automatic certificate reloading.
- **The ambient identity belongs to the server host.** In `credential_source: ambient` mode (the AWS default) every request runs as the server's workload identity (instance profile, task role, IRSA or Pod Identity), whoever the client is. The per-request `infraEnv` only selects per-environment *role ARNs* and identifiers (for example `{INFRAENV}_AWS_ASSUME_ROLE_ARN`); it never selects static keys. Environment isolation on a shared server therefore requires per-environment roles whose trust policies allow only the server host's identity. Without them, a client that can reach the server can act in every environment the host identity can. The client chooses `infraEnv`, and in `ambient` mode `{INFRAENV}_AWS_ASSUME_ROLE_ARN` is optional, so an environment with no role ARN runs as the raw host identity: give the host identity no permissions of its own beyond `sts:AssumeRole` on the per-environment roles.
- **On Azure, per-environment user-assigned identities give real environment separation.** Attach one user-assigned managed identity per environment to the server host (VM, VMSS or AKS node pool) and set each `{INFRAENV}_AZ_CLIENT_ID` to its client id: an ambient `DEV` request then authenticates as the `DEV` identity and holds only its role assignments, and never the `PROD` identity's. Give the system-assigned identity (used when `{INFRAENV}_AZ_CLIENT_ID` is unset) no role assignments. As with AWS, the client chooses `infraEnv`, so this separates what each environment *can* do, not who may ask for it; restrict who can reach the server.
- **Rate limiting and request size limits** are not currently implemented. Consider placing a reverse proxy (e.g., nginx, envoy) in front of the server for production deployments.
