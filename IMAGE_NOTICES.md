# Container image contents and licences

This file lists the third-party software shipped inside the `ghcr.io/foolswithtools/infrapipe` images, with its licence and where to get its source. It complements [THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md), which covers the libraries compiled into the `infrapipe` binary itself.

infrapipe is MIT licensed; its source code is not published. The components below are separate programs, each under its own licence, and are redistributed unmodified from their upstream or distribution packages. Licence identifiers are taken from each project's published licence; the authoritative licence texts ship inside the images (Alpine: `/usr/share/licenses`, Debian: `/usr/share/doc/<package>/copyright`, project directories for the tools installed from tarballs).

## Every image

| Component | Version | Licence | Source |
|---|---|---|---|
| OpenTofu | 1.13.1 | MPL-2.0 | https://github.com/opentofu/opentofu/tree/v1.13.1 (distributed unmodified from the official release; verified against its published SHA-256) |
| git | distribution package | GPL-2.0-only | Alpine: https://gitlab.alpinelinux.org/alpine/aports (package `git`); Debian: https://sources.debian.org/src/git/ |
| tini | distribution package | MIT | https://github.com/krallin/tini |
| CA certificates | distribution package | MPL-2.0 (Mozilla bundle) and MIT | https://wiki.mozilla.org/CA ; distribution `ca-certificates` source |
| Base image: Alpine Linux 3.23 (core, aws, pulumi) | 3.23 | various; musl libc MIT, BusyBox GPL-2.0-only, others per package | https://gitlab.alpinelinux.org/alpine/aports |
| Base image: Debian bookworm slim with Python 3.12 (azure) | `python:3.12-slim-bookworm` | various; Python PSF-2.0, Debian packages per package | https://github.com/docker-library/python ; https://sources.debian.org |

## Per variant

| Image tags | Component | Version | Licence | Source |
|---|---|---|---|---|
| `-aws`, `:aws` | AWS CLI v2 | Alpine 3.23 package `aws-cli` | Apache-2.0 | https://github.com/aws/aws-cli |
| `-pulumi`, `:pulumi` | Pulumi CLI | 3.268.0 | Apache-2.0 | https://github.com/pulumi/pulumi/tree/v3.268.0 (verified against its published SHA-256) |
| `-azure`, `:azure` | Azure CLI | 2.91.0 | MIT | https://github.com/Azure/azure-cli ; installed from PyPI into `/opt/az` together with its Python dependencies, each under its own licence (see `pip show` metadata inside the image) |

## What is not included

Terraform (BUSL-1.1) is deliberately not bundled. `gcloud` and `incus` are not included.

## Source availability for copyleft components

For GPL and MPL components, the corresponding upstream source is available at the links above for the exact versions listed (OpenTofu) or from the Alpine and Debian source package repositories for the distribution releases named. If you cannot obtain the source from those locations, open an issue on this repository.

This is a good-faith inventory and is not legal advice.
