#!/usr/bin/env bash
# Smoke test for an infrapipe container image.
# usage: scripts/smoke.sh IMAGE [VARIANT]     (VARIANT: core | aws | pulumi | azure)
#
# Checks that the image starts, that the bundled tools run, that it is not root, and that
# infrapipe itself can validate a minimal project inside the container: `validate config`,
# `validate iac` (the bundled OpenTofu is installed and its version matches the config) and
# `validate system`. Needs docker and git on the host. Exits non-zero on the first failure.
set -euo pipefail
img="${1:?usage: smoke.sh IMAGE [VARIANT]}"
variant="${2:-core}"
here="$(cd "$(dirname "$0")" && pwd)"
tv="$(sed -n 's/^ARG TOFU_VERSION=//p' "$here/../Dockerfile" | head -1)"
[ -n "$tv" ] || { echo "could not read TOFU_VERSION from the Dockerfile" >&2; exit 1; }

work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT
git -C "$work" init -q -b main
git -C "$work" -c user.name=smoke -c user.email=smoke@example.com commit -q --allow-empty -m init
cat > "$work/.infrapipe.yaml" <<YAML
IaC:
  type: tofu
  tofu:
    version: "$tv"
    backend: local
cloudProvider:
  type: aws
  aws:
    region: "us-east-1"
cicd:
  type: local
  local:
    enabled: true
secrets:
  type: envars
  envars:
    enabled: true
scm:
  gitcli:
    version: "2.40"
  remote: origin
applications:
  deployment:
    dev:
      branch: main
      infraenv: dev
      appenv: development
      postfix: "-dev"
      domain: dev.example.com
YAML
chmod -R a+rX "$work"

step() { printf '\n== %s\n' "$*"; }
run()  { docker run --rm "$@"; }
proj() { docker run --rm -v "$work:/workspace" "$img" "$@"; }

step "infrapipe version";            run "$img" version
step "bundled OpenTofu";             run --entrypoint tofu "$img" version
step "bundled git";                  run --entrypoint git "$img" --version
step "runs as uid 10001"
[ "$(run --entrypoint id "$img" -u)" = "10001" ] || { echo "image does not run as uid 10001" >&2; exit 1; }
case "$variant" in
  aws)    step "aws cli";    run --entrypoint aws "$img" --version ;;
  azure)  step "az cli";     run --entrypoint az "$img" version ;;
  pulumi) step "pulumi cli"; run --entrypoint pulumi "$img" version ;;
esac
step "validate config";  proj validate config --config .infrapipe.yaml
step "validate iac (engine installed, version matches config $tv)"
out="$(proj validate iac --config .infrapipe.yaml 2>&1)"; printf '%s\n' "$out" | grep -E "Version match|IaC\.tofu\.version" || true
printf '%s\n' "$out" | grep -q "Version match" || { echo "validate iac did not report a version match" >&2; exit 1; }
step "validate system";  proj validate system --config .infrapipe.yaml
echo; echo "smoke OK: $img ($variant)"
