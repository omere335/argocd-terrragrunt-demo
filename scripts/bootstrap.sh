#!/usr/bin/env bash
#
# Bring up a local cluster and install ArgoCD into it.
#
# ArgoCD is installed here, by a pinned script, rather than by Terraform. Terraform
# in this repo renders configuration into Git and never talks to a cluster; letting
# it also install the GitOps controller would blur exactly the boundary this
# exercise is about.
set -euo pipefail

MINIKUBE_PROFILE="${MINIKUBE_PROFILE:-hello-argocd}"
K8S_VERSION="${K8S_VERSION:-v1.34.10}"
ARGOCD_VERSION="${ARGOCD_VERSION:-v3.4.4}"
APP_NAMESPACE="${APP_NAMESPACE:-hello-app}"
MINIKUBE_DRIVER="${MINIKUBE_DRIVER:-docker}"

info() { printf '\n\033[1;34m==> %s\033[0m\n' "$*"; }
die() { printf '\033[1;31mERROR: %s\033[0m\n' "$*" >&2; exit 1; }

for cmd in minikube kubectl; do
  command -v "$cmd" >/dev/null 2>&1 || die "$cmd is not installed. See the README prerequisites."
done

info "Starting minikube (profile: ${MINIKUBE_PROFILE}, kubernetes ${K8S_VERSION})"
# --cni=calico is not optional.
#
# minikube's default CNI does not enforce NetworkPolicy. The chart's default-deny
# policy would still be accepted by the API server and would still show up in
# `kubectl get networkpolicy` - it just would not do anything. A security control
# that silently does nothing is worse than no control at all, because it looks
# like one.
#
# Calico adds roughly 60-90 seconds to first start. That is not a hang.
if minikube status --profile "${MINIKUBE_PROFILE}" >/dev/null 2>&1; then
  echo "Profile ${MINIKUBE_PROFILE} already running; leaving it alone."
else
  minikube start \
    --profile "${MINIKUBE_PROFILE}" \
    --kubernetes-version "${K8S_VERSION}" \
    --driver "${MINIKUBE_DRIVER}" \
    --cni calico \
    --memory 4096 \
    --cpus 2
fi

kubectl config use-context "${MINIKUBE_PROFILE}"

info "Waiting for Calico to be ready"
# minikube silently IGNORES --cni on a profile that already exists, so a profile
# first created without Calico stays that way no matter what this script passes.
# Catch that here with a remediation hint instead of dying below with a raw
# "daemonset not found" from rollout status.
if ! kubectl -n kube-system get daemonset calico-node >/dev/null 2>&1; then
  die "calico-node daemonset not found. The '${MINIKUBE_PROFILE}' profile was probably created without --cni=calico (minikube ignores --cni on an existing profile). Fix: minikube delete --profile ${MINIKUBE_PROFILE} && make up"
fi
kubectl -n kube-system rollout status daemonset/calico-node --timeout=300s
kubectl wait --for=condition=Ready nodes --all --timeout=300s

# minikube ignores --kubernetes-version (and --driver/--memory/--cpus) on an
# existing profile the same way it ignores --cni - CNI gets a hard failure
# above because a silently-inert security control is unacceptable; a version
# mismatch is a WARN, because running Kubernetes vX when vY was asked for is
# surprising but not a broken control.
running_k8s_version=$(kubectl get nodes -o jsonpath='{.items[0].status.nodeInfo.kubeletVersion}' 2>/dev/null || echo "")
if [ -n "${running_k8s_version}" ] && [ "${running_k8s_version}" != "${K8S_VERSION}" ]; then
  echo "NOTE: cluster is running Kubernetes ${running_k8s_version}, but K8S_VERSION=${K8S_VERSION} was requested."
  echo "      minikube ignores --kubernetes-version on an existing profile, same as --cni."
  echo "      Fix: minikube delete --profile ${MINIKUBE_PROFILE} && make up"
fi

info "Installing ArgoCD ${ARGOCD_VERSION}"
# Pinned by tag, never "stable". "stable" moves, which makes the cluster's control
# plane version a function of when you happened to run this script.
#
# This is the one place a tag is the right answer: it is a one-off fetch of an
# immutable upstream release artifact, not the GitOps source of truth. The
# Application's own targetRevision is a branch - see argocd/application.yaml.
kubectl create namespace argocd --dry-run=client -o yaml | kubectl apply -f -
# --server-side: the applicationsets CRD exceeds the 256KiB annotation cap that
# client-side apply needs for last-applied-configuration, so client-side fails.
# --force-conflicts: re-running after a previous client-side apply must be able
# to take ownership of those fields instead of dying on a conflict.
kubectl apply --server-side --force-conflicts -n argocd -f \
  "https://raw.githubusercontent.com/argoproj/argo-cd/${ARGOCD_VERSION}/manifests/install.yaml"

info "Waiting for ArgoCD to come up (this takes a few minutes on first run)"
kubectl -n argocd rollout status deployment/argocd-repo-server --timeout=600s
kubectl -n argocd rollout status deployment/argocd-server --timeout=600s
kubectl -n argocd rollout status statefulset/argocd-application-controller --timeout=600s

info "Creating application namespace: ${APP_NAMESPACE}"
# Created here, not by ArgoCD's CreateNamespace option, so that the AppProject can
# keep an empty clusterResourceWhitelist. A namespace is cluster infrastructure;
# the Application should only ever manage things inside it.
kubectl create namespace "${APP_NAMESPACE}" --dry-run=client -o yaml | kubectl apply -f -

cat <<EOF

Cluster is ready.

  Next:   make deploy      # render values, then apply the ArgoCD Application
  UI:     kubectl -n argocd port-forward svc/argocd-server 8081:443
          then https://localhost:8081  (user: admin)
  Login:  kubectl -n argocd get secret argocd-initial-admin-secret \\
            -o jsonpath='{.data.password}' | base64 -d; echo

Delete that secret once you have logged in and changed the password - it is a
cluster-admin credential sitting in plain text in etcd:

  kubectl -n argocd delete secret argocd-initial-admin-secret

EOF
