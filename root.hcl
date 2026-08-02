# Terragrunt root configuration.

locals {
  repo_root = get_repo_root()
}

# Local state, written to a stable path in the repo (not .terragrunt-cache) so
# re-running `apply` is idempotent across cache clears. Single-operator, no
# locking - fine for this demo, wrong for anything shared.
remote_state {
  backend = "local"

  generate = {
    path      = "backend.tf"
    if_exists = "overwrite_terragrunt"
  }

  config = {
    path = "${local.repo_root}/.terragrunt-state/${path_relative_to_include()}/terraform.tfstate"
  }
}

terraform_version_constraint = "~> 1.9"

# Loose on purpose so the repo is not tied to one Terragrunt patch release. Note
# that the HCL formatting command was renamed in 0.78 (`hclfmt` -> `hcl fmt`);
# the Makefile handles both.
terragrunt_version_constraint = ">= 0.67"
