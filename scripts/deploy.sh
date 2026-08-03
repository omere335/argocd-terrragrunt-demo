#!/usr/bin/env bash
#
# Render config with Terragrunt, then point ArgoCD at it.
#
# Note the ordering, and the push. ArgoCD reads Git, not your working tree, so an
# uncommitted values file changes nothing in the cluster. That is the point of the
# design, not a limitation of it: every cluster change arrives as a reviewable commit.
set -euo pipefail

ENV_NAME="${ENV_NAME:-dev}"
APP_NAME="${APP_NAME:-hello-app}"
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
UNIT_DIR="${REPO_ROOT}/envs/${ENV_NAME}/app"
VALUES_FILE="${UNIT_DIR}/values.generated.yaml"

info() { printf '\n\033[1;34m==> %s\033[0m\n' "$*"; }
die() { printf '\033[1;31mERROR: %s\033[0m\n' "$*" >&2; exit 1; }

for cmd in terragrunt terraform kubectl git; do
  command -v "$cmd" >/dev/null 2>&1 || die "$cmd is not installed. See the README prerequisites."
done

# The branch ArgoCD tracks, read straight out of the Application manifest so this
# script cannot disagree with it. Matching on the exact first field (not a loose
# regex) keeps comments containing "targetRevision" from being picked up, and
# reading EVERY occurrence lets us enforce the documented invariant that both
# sources track the same branch - nothing else checks that link.
TRACKED_REVISIONS=()
while IFS= read -r rev; do
  TRACKED_REVISIONS+=("$rev")
done < <(awk '$1 == "targetRevision:" {print $2}' "${REPO_ROOT}/argocd/application.yaml")
[ "${#TRACKED_REVISIONS[@]}" -ge 1 ] || die "could not read targetRevision from argocd/application.yaml"
TRACKED_BRANCH="${TRACKED_REVISIONS[0]}"
for rev in "${TRACKED_REVISIONS[@]}"; do
  [ "$rev" = "$TRACKED_BRANCH" ] || die \
    "the sources in argocd/application.yaml track different revisions (${TRACKED_REVISIONS[*]}). Both must name the same branch - see the README."
done
CURRENT_BRANCH=$(git -C "${REPO_ROOT}" rev-parse --abbrev-ref HEAD)

info "Rendering Helm values with Terragrunt (${ENV_NAME})"
(cd "${UNIT_DIR}" && terragrunt apply -auto-approve -input=false)

info "Generated values"
cat "${VALUES_FILE}"

if [ "${CURRENT_BRANCH}" != "${TRACKED_BRANCH}" ]; then
  cat <<EOF

You are on branch '${CURRENT_BRANCH}', but ArgoCD tracks '${TRACKED_BRANCH}'.

Nothing you commit here will deploy until it is merged into '${TRACKED_BRANCH}'.
That is the intended promotion path, not a problem - but it does mean this deploy
will reconcile whatever is on '${TRACKED_BRANCH}' right now, not your local work.

EOF
fi

# `git status --porcelain` covers every local state ArgoCD cannot see: untracked
# (the first-ever render), staged-but-uncommitted, and unstaged modifications.
# (`git diff` alone is silent for untracked and staged files.) On top of that,
# check for commits that exist locally but not on the tracked remote branch -
# ArgoCD reads the remote, so "committed" is still not "deployed" until pushed.
PENDING=""
if [ -n "$(git -C "${REPO_ROOT}" status --porcelain -- "${VALUES_FILE}")" ]; then
  PENDING="is untracked or has uncommitted changes"
elif git -C "${REPO_ROOT}" rev-parse --verify -q "origin/${TRACKED_BRANCH}" >/dev/null 2>&1 &&
  [ -n "$(git -C "${REPO_ROOT}" rev-list "origin/${TRACKED_BRANCH}..HEAD" -- "${VALUES_FILE}" 2>/dev/null)" ]; then
  PENDING="has commits that are not on 'origin/${TRACKED_BRANCH}' yet"
fi

if [ -n "${PENDING}" ]; then
  cat <<EOF

The generated values file ${PENDING}.

ArgoCD syncs from the Git remote, so it will not see this until it is committed
and pushed to '${TRACKED_BRANCH}':

  git add ${VALUES_FILE#"${REPO_ROOT}/"}
  git commit -m "Update ${ENV_NAME} values"
  git push

EOF
  # Guard the prompt itself: under `set -e`, `read` on a closed/non-interactive
  # stdin (CI, cron, a piped invocation) fails at EOF and would abort the script
  # right here - silently, without ever reaching the die() below. Fail loudly
  # and explain why instead.
  if [ ! -t 0 ]; then
    die "Stopped: stdin is not a terminal, refusing to guess. Commit and push ${VALUES_FILE#"${REPO_ROOT}/"}, or re-run interactively to confirm."
  fi
  read -r -p "Continue applying the ArgoCD manifests anyway? [y/N] " reply
  [ "${reply}" = "y" ] || [ "${reply}" = "Y" ] || die "Stopped."
fi

info "Applying the AppProject and Application"
kubectl apply -f "${REPO_ROOT}/argocd/appproject.yaml"
kubectl apply -f "${REPO_ROOT}/argocd/application.yaml"

info "Waiting for the Application to become Synced and Healthy"
# Both, deliberately. Healthy alone is satisfied by an Application that is still
# running the PREVIOUS revision (e.g. the new sync failed against the AppProject
# whitelist, or the push never happened) - Synced is what proves the reconcile
# actually happened.
kubectl -n argocd wait --for=jsonpath='{.status.sync.status}'=Synced \
  "application/${APP_NAME}" --timeout=300s
kubectl -n argocd wait --for=jsonpath='{.status.health.status}'=Healthy \
  "application/${APP_NAME}" --timeout=300s

info "Done. Run 'make verify' to check it properly."
