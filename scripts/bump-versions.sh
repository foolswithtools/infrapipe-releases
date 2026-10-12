#!/usr/bin/env bash
# Checks the tool versions pinned in the Dockerfile against upstream releases and, when a newer
# stable release exists, rewrites the pinned version AND its per-arch SHA-256 values.
#   usage: scripts/bump-versions.sh [--out FILE]      (needs gh, curl, jq, sort -V)
# Edits ./Dockerfile in place and writes a Markdown change list to FILE (default: stdout).
# Pinned tools: OpenTofu, Pulumi, Azure CLI. Base images (Alpine, Python) are not bumped here:
# patch updates arrive on every image rebuild; a new minor needs a deliberate change.
set -euo pipefail
cd "$(dirname "$0")/.."
out=/dev/stdout
[ "${1:-}" = "--out" ] && out="${2:?--out needs a file}"
df=Dockerfile
cur()     { sed -n "s/^ARG $1=//p" "$df" | head -1; }
set_arg() { sed -i.bak "s|^ARG $1=.*|ARG $1=$2|" "$df" && rm -f "$df.bak"; }
newer()   { [ "$1" != "$2" ] && [ "$(printf '%s\n%s\n' "$1" "$2" | sort -V | tail -1)" = "$1" ]; }
stable_max() { # repo -> highest stable semver (v prefix stripped)
  gh api "repos/$1/releases?per_page=60" --jq '.[] | select(.prerelease==false and .draft==false) | .tag_name' \
    | sed 's/^v//' | grep -E '^[0-9]+\.[0-9]+\.[0-9]+$' | sort -V | tail -1
}
changes=""

# --- OpenTofu
have="$(cur TOFU_VERSION)"; latest="$(stable_max opentofu/opentofu)"
if [ -n "$latest" ] && newer "$latest" "$have"; then
  sums="$(curl -fsSL "https://github.com/opentofu/opentofu/releases/download/v${latest}/tofu_${latest}_SHA256SUMS")"
  amd="$(printf '%s\n' "$sums" | awk -v f="tofu_${latest}_linux_amd64.zip" '$2==f{print $1}')"
  arm="$(printf '%s\n' "$sums" | awk -v f="tofu_${latest}_linux_arm64.zip" '$2==f{print $1}')"
  [ -n "$amd" ] && [ -n "$arm" ] || { echo "no checksums for OpenTofu $latest" >&2; exit 1; }
  set_arg TOFU_VERSION "$latest"; set_arg TOFU_SHA256_AMD64 "$amd"; set_arg TOFU_SHA256_ARM64 "$arm"
  changes="${changes}- OpenTofu ${have} -> ${latest} (checksums from the upstream SHA256SUMS)"$'\n'
fi

# --- Pulumi
have="$(cur PULUMI_VERSION)"; latest="$(stable_max pulumi/pulumi)"
if [ -n "$latest" ] && newer "$latest" "$have"; then
  sums="$(curl -fsSL "https://github.com/pulumi/pulumi/releases/download/v${latest}/pulumi-${latest}-checksums.txt")"
  amd="$(printf '%s\n' "$sums" | awk -v f="pulumi-v${latest}-linux-x64.tar.gz" '$2==f{print $1}')"
  arm="$(printf '%s\n' "$sums" | awk -v f="pulumi-v${latest}-linux-arm64.tar.gz" '$2==f{print $1}')"
  [ -n "$amd" ] && [ -n "$arm" ] || { echo "no checksums for Pulumi $latest" >&2; exit 1; }
  set_arg PULUMI_VERSION "$latest"; set_arg PULUMI_SHA256_AMD64 "$amd"; set_arg PULUMI_SHA256_ARM64 "$arm"
  changes="${changes}- Pulumi ${have} -> ${latest} (checksums from the upstream checksums file)"$'\n'
fi

# --- Azure CLI (PyPI; no checksum is pinned, pip verifies the wheel hashes it resolves)
have="$(cur AZURE_CLI_VERSION)"
latest="$(curl -fsSL https://pypi.org/pypi/azure-cli/json | jq -r '.info.version')"
if [ -n "$latest" ] && newer "$latest" "$have"; then
  set_arg AZURE_CLI_VERSION "$latest"
  changes="${changes}- Azure CLI ${have} -> ${latest}"$'\n'
fi

if [ -z "$changes" ]; then
  printf 'All pinned tool versions are current.\n' > "$out"
else
  printf '%s\n%s\n%s\n' "## Pinned tool versions are out of date" "$changes" \
    "Merging updates the Dockerfile only. Images are rebuilt and re-signed when the next release is promoted; run the smoke-test workflow against a rebuilt image before relying on it." > "$out"
fi
echo "$changes" | sed '/^$/d' >&2 || true
