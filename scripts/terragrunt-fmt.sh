#!/usr/bin/env bash
#
# Run terragrunt's HCL formatter, tolerating the hclfmt -> hcl fmt rename in
# Terragrunt 0.78. Used by `make fmt`, `make lint`, and CI so the version
# probe lives in exactly one place instead of three copies that can drift
# out of sync (and disagree on which subcommand to probe first).
#
# Usage: terragrunt-fmt.sh [extra terragrunt args...]
#   terragrunt-fmt.sh                 # write formatting changes
#   terragrunt-fmt.sh --check --diff  # check only, non-zero exit on diff
set -euo pipefail

if terragrunt hcl fmt --help >/dev/null 2>&1; then
  exec terragrunt hcl fmt "$@"
else
  exec terragrunt hclfmt "$@"
fi
