include "root" {
  path = find_in_parent_folders("root.hcl")
}

locals {
  env_vars  = read_terragrunt_config(find_in_parent_folders("env.hcl"))
  env       = local.env_vars.locals.env
  repo_root = get_repo_root()
}

terraform {
  source = "${local.repo_root}//modules/app"
}

# Only inputs that this environment actually decides. Everything else
# (replicas, app_text, ports, resources, network_policy_enabled) takes the
# module default from modules/app/variables.tf - restating a default here just
# creates a second copy that can drift. Override a value only when this env
# genuinely differs.
inputs = {
  # Keep in step with releaseName/metadata.name in argocd/application.yaml.
  name = "hello-app"

  # Digest-pinned. This is hashicorp/http-echo:1.0, a distroless/static image with
  # no shell and no writable filesystem. The module rejects any reference without
  # an @sha256 digest. This is the ONLY place the digest lives.
  image = "hashicorp/http-echo:1.0@sha256:fcb75f691c8b0414d670ae570240cbf95502cc18a9ba57e982ecac589760a186"

  # Stable, predictable path: this is exactly what the ArgoCD Application
  # references as $values/envs/dev/app/values.generated.yaml.
  output_path = "${local.repo_root}/envs/${local.env}/app/values.generated.yaml"
}
