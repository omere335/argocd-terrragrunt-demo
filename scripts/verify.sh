#!/usr/bin/env bash
#
# Prove the deployment actually works.

set -euo pipefail

APP_NAMESPACE="${APP_NAMESPACE:-hello-app}"
APP_NAME="${APP_NAME:-hello-app}"
ARGOCD_NAMESPACE="${ARGOCD_NAMESPACE:-argocd}"
CURL_IMAGE="${CURL_IMAGE:-curlimages/curl:8.11.1}"
EXPECTED_TEXT="${EXPECTED_TEXT:-Hello World}"

FAILED=0
pass() { printf '\033[1;32m  PASS\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33m  WARN\033[0m %s\n' "$*"; }
fail() { printf '\033[1;31m  FAIL\033[0m %s\n' "$*"; FAILED=1; }
info() { printf '\n\033[1;34m==> %s\033[0m\n' "$*"; }
die() { printf '\033[1;31mERROR: %s\033[0m\n' "$*" >&2; exit 1; }

for cmd in kubectl curl git; do
  command -v "$cmd" >/dev/null 2>&1 || die "$cmd is not installed. See the README prerequisites."
done

# check <description> <actual> <expected>
check() {
  if [ "$2" = "$3" ]; then
    pass "$1 = $3"
  else
    fail "$1 = '$2' (expected '$3')"
  fi
}

info "ArgoCD Application state"
sync=$(kubectl -n "${ARGOCD_NAMESPACE}" get application "${APP_NAME}" \
  -o jsonpath='{.status.sync.status}' 2>/dev/null || echo "MISSING")
health=$(kubectl -n "${ARGOCD_NAMESPACE}" get application "${APP_NAME}" \
  -o jsonpath='{.status.health.status}' 2>/dev/null || echo "MISSING")
check "sync status" "$sync" "Synced"
check "health status" "$health" "Healthy"

# The Application must track a branch, not a tag or a pinned commit. A tag would
# make "what is deployed" immutable and would stop merges from deploying, which is
# the opposite of the promotion model this repo documents - so a change to it
# should fail here, loudly.
revision=$(kubectl -n "${ARGOCD_NAMESPACE}" get application "${APP_NAME}" \
  -o jsonpath='{.spec.sources[1].targetRevision}' 2>/dev/null || echo "")
repo_url=$(kubectl -n "${ARGOCD_NAMESPACE}" get application "${APP_NAME}" \
  -o jsonpath='{.spec.sources[1].repoURL}' 2>/dev/null || echo "")

if [ -z "$revision" ]; then
  fail "could not read targetRevision from the Application"
elif printf '%s' "$revision" | grep -qE '^[0-9a-f]{7,40}$'; then
  fail "targetRevision '${revision}' looks like a pinned commit, not a branch"
elif [ -z "$repo_url" ]; then
  warn "targetRevision is '${revision}'; no repoURL to check it against"
elif remote_refs=$(git ls-remote --heads --tags "$repo_url" 2>/dev/null); then
  # The remote is reachable, so a missing ref is a hard failure (a typo'd or
  # deleted branch means ArgoCD can never sync anything new), not a WARN.
  if printf '%s\n' "$remote_refs" | grep -q "refs/heads/${revision}\$"; then
    pass "targetRevision '${revision}' is a branch on the remote"
  elif printf '%s\n' "$remote_refs" | grep -q "refs/tags/${revision}\$"; then
    fail "targetRevision '${revision}' is a TAG. GitOps here tracks branches - see the README."
  else
    fail "targetRevision '${revision}' does not exist on the remote - not a branch, not a tag"
  fi
else
  # Only a genuinely unreachable remote is a tooling gap rather than a failure.
  warn "targetRevision is '${revision}'; could not reach the remote to confirm it is a branch"
fi

# One kubectl call for every field pulled off the Deployment, instead of nine
# separate round trips (replicas, readyReplicas, six security-context fields,
# image) - each `kubectl get` is its own API server request. "|" is safe as a
# separator here: none of these fields can contain it.
IFS='|' read -r desired ready run_as_non_root seccomp_type automount \
  ro_root allow_priv_esc cap_drop image <<<"$(
  kubectl -n "${APP_NAMESPACE}" get deploy "${APP_NAME}" -o jsonpath='{.spec.replicas}|{.status.readyReplicas}|{.spec.template.spec.securityContext.runAsNonRoot}|{.spec.template.spec.securityContext.seccompProfile.type}|{.spec.template.spec.automountServiceAccountToken}|{.spec.template.spec.containers[0].securityContext.readOnlyRootFilesystem}|{.spec.template.spec.containers[0].securityContext.allowPrivilegeEscalation}|{.spec.template.spec.containers[0].securityContext.capabilities.drop[0]}|{.spec.template.spec.containers[0].image}' 2>/dev/null || true
)"
desired="${desired:-0}"
ready="${ready:-0}"

info "Workload"
if [ "$ready" = "$desired" ] && [ "$desired" != "0" ]; then
  pass "${ready}/${desired} replicas ready"
else
  fail "${ready}/${desired} replicas ready"
fi

info "Security posture (asserted, not assumed)"
check "runAsNonRoot" "$run_as_non_root" "true"
check "seccompProfile" "$seccomp_type" "RuntimeDefault"
check "token automount disabled" "$automount" "false"
check "readOnlyRootFilesystem" "$ro_root" "true"
check "allowPrivilegeEscalation" "$allow_priv_esc" "false"
check "capabilities dropped" "$cap_drop" "ALL"

case "$image" in
  *@sha256:*) pass "image is digest-pinned" ;;
  *) fail "image is not digest-pinned: ${image}" ;;
esac

info "HTTP response"
kubectl -n "${APP_NAMESPACE}" port-forward "svc/${APP_NAME}" 18080:80 >/dev/null 2>&1 &
pf_pid=$!
trap 'kill "$pf_pid" 2>/dev/null || true' EXIT
for _ in $(seq 1 20); do
  sleep 0.5
  if curl -sS -m 2 "http://127.0.0.1:18080/health" >/dev/null 2>&1; then
    break
  fi
done
body=$(curl -sS -m 5 "http://127.0.0.1:18080/" 2>/dev/null || echo "")
health_body=$(curl -sS -m 5 "http://127.0.0.1:18080/health" 2>/dev/null || echo "")
kill "$pf_pid" 2>/dev/null || true
trap - EXIT

check "GET /" "$(printf '%s' "$body" | tr -d '\r\n')" "$EXPECTED_TEXT"
case "$health_body" in
  *'"status":"ok"'*) pass 'GET /health -> {"status":"ok"}' ;;
  *) fail "GET /health -> '${health_body}'" ;;
esac

info "NetworkPolicy"
# A policy is only meaningful if the CNI enforces it. Checked first - before any
# policy-related PASS is printed - so that a green line about the policy on a
# cluster which silently ignores NetworkPolicy is impossible.
if kubectl -n kube-system get daemonset calico-node >/dev/null 2>&1; then
  pass "CNI is Calico (NetworkPolicy is enforced)"
else
  fail "Calico not found - NetworkPolicy will NOT be enforced. Start minikube with --cni=calico."
fi

if kubectl -n "${APP_NAMESPACE}" get networkpolicy "${APP_NAME}" >/dev/null 2>&1; then
  pass "policy object exists"
else
  fail "policy object missing"
fi

# Ingress, positive case: a pod without the app's labels is not selected by the
# policy's podSelector, and the policy allows ingress to the app port, so this
# must succeed.
#
# --pod-running-timeout is the flag that actually bounds the wait for the pod to
# start (kubectl run's --timeout only bounds the --rm deletion). The pre-delete
# clears a pod a previously interrupted run may have left behind.
kubectl -n "${APP_NAMESPACE}" delete pod np-ingress-test --ignore-not-found --wait=true >/dev/null 2>&1 || true
if kubectl -n "${APP_NAMESPACE}" run np-ingress-test \
    --image="${CURL_IMAGE}" --restart=Never --rm -i --quiet --pod-running-timeout=120s \
    --command -- curl -sS -m 8 "http://${APP_NAME}/" 2>/dev/null | grep -q "${EXPECTED_TEXT}"; then
  pass "in-cluster request to the Service is allowed"
else
  fail "in-cluster request to the Service was blocked or failed"
fi

# Egress, negative case: run inside a real app pod via an ephemeral container,
# which shares the pod's network namespace and so is covered by the policy. The
# app image is distroless and has no shell, which is why this needs `kubectl debug`
# rather than `kubectl exec`.
app_pod=$(kubectl -n "${APP_NAMESPACE}" get pods -l "app.kubernetes.io/name=${APP_NAME}" \
  -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || echo "")
if [ -z "$app_pod" ]; then
  warn "no app pod found; skipping the egress check"
else
  # Unique container name per run: ephemeral containers can never be removed or
  # reused, so a fixed name makes every second run of this script error out.
  # stdout carries only curl's -w '%{http_code}' (000 when blocked); kubectl's own
  # errors go to stderr, so an empty result means the probe itself never ran -
  # which must NOT be scored as "egress blocked".
  egress_container="np-egress-test-$$-${RANDOM}"
  egress_code=$(kubectl -n "${APP_NAMESPACE}" debug "pod/${app_pod}" \
    --image="${CURL_IMAGE}" --quiet --attach --container="${egress_container}" -- \
    curl -sS -m 8 -o /dev/null -w '%{http_code}' https://example.com 2>/dev/null || true)
  egress_code=$(printf '%s' "$egress_code" | tr -d '[:space:]')
  case "$egress_code" in
    2[0-9][0-9]|3[0-9][0-9]|4[0-9][0-9]|5[0-9][0-9])
      fail "egress to the internet succeeded (HTTP ${egress_code}) - default-deny egress is NOT working" ;;
    000)
      pass "egress to the internet is blocked" ;;
    "")
      warn "egress probe did not run (kubectl debug failed); egress enforcement was NOT verified" ;;
    *)
      fail "egress probe returned unexpected output '${egress_code}'" ;;
  esac
fi

echo
if [ "$FAILED" -eq 0 ]; then
  printf '\033[1;32mAll checks passed.\033[0m\n'
else
  printf '\033[1;31mSome checks failed.\033[0m\n'
  exit 1
fi
