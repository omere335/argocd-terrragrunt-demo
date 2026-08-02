# Only values something actually reads live here - namespace and the Git branch
# ArgoCD tracks are owned by argocd/*.yaml, not duplicated here.
locals {
  env = "dev"
}
