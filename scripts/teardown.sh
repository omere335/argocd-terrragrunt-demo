#!/usr/bin/env bash
#
# Remove everything this demo created.
set -euo pipefail

MINIKUBE_PROFILE="${MINIKUBE_PROFILE:-hello-argocd}"
ARGOCD_NAMESPACE="${ARGOCD_NAMESPACE:-argocd}"
APP_NAMESPACE="${APP_NAMESPACE:-hello-app}"
APP_NAME="${APP_NAME:-hello-app}"
KEEP_CLUSTER="${KEEP_CLUSTER:-0}"

info() { printf '\n\033[1;34m==> %s\033[0m\n' "$*"; }
die() { printf '\033[1;31mERROR: %s\033[0m\n' "$*" >&2; exit 1; }

for cmd in kubectl minikube; do
  command -v "$cmd" >/dev/null 2>&1 || die "$cmd is not installed. See the README prerequisites."
done

info "Deleting the ArgoCD Application"
# The resources-finalizer on the Application cascades this to the deployed
# objects, so there is nothing left orphaned in the app namespace.
#
# Reachability is checked first: --ignore-not-found does not cover an unreachable
# API server (cluster already deleted, docker stopped, context gone), and under
# set -e that failure would abort the script BEFORE `minikube delete` - making a
# second `make down` fail at exactly the cleanup it was asked to repeat.
if kubectl get --raw /readyz --request-timeout=5s >/dev/null 2>&1; then
  # --timeout bounds the finalizer wait: if the ArgoCD controller itself is the
  # reason you're tearing down (unhealthy, crashlooping), the cascade never
  # completes and an unbounded --wait would hang here forever, under set -e,
  # before ever reaching `minikube delete` below - the one step that would
  # actually resolve things by removing the whole cluster. Failing to delete
  # within the timeout is a warning, not fatal: teardown keeps going.
  kubectl -n "${ARGOCD_NAMESPACE}" delete application "${APP_NAME}" \
    --ignore-not-found --wait=true --timeout=120s || \
    echo "WARNING: Application deletion did not finish within 120s (controller may be unhealthy); continuing teardown anyway."
  kubectl -n "${ARGOCD_NAMESPACE}" delete appproject "${APP_NAME}" --ignore-not-found
  # bootstrap.sh creates this namespace itself (the AppProject's empty
  # clusterResourceWhitelist means ArgoCD never will), so teardown owns
  # deleting it too - otherwise `KEEP_CLUSTER=1` leaves an empty namespace
  # behind on an otherwise-live cluster. --wait=false: namespace deletion can
  # itself hang on stuck finalizers in the resources it contained; this is
  # best-effort cleanup, not something worth blocking `make down` on.
  kubectl delete namespace "${APP_NAMESPACE}" --ignore-not-found --wait=false
else
  echo "Cluster is not reachable; skipping Application/AppProject/namespace deletion."
fi

if [ "${KEEP_CLUSTER}" = "1" ]; then
  info "KEEP_CLUSTER=1; leaving the minikube profile running"
elif minikube profile list -o json 2>/dev/null | grep -q "\"${MINIKUBE_PROFILE}\""; then
  info "Deleting minikube profile: ${MINIKUBE_PROFILE}"
  minikube delete --profile "${MINIKUBE_PROFILE}"
else
  info "minikube profile '${MINIKUBE_PROFILE}' not found; nothing to delete"
fi

info "Local Terraform state and caches"
echo "Left in place. Remove with:"
echo "  rm -rf .terragrunt-state .terragrunt-cache envs/*/*/.terragrunt-cache"
