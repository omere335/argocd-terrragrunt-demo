# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What this repo is

A Hello World web service on minikube, deployed via ArgoCD, configured by Terraform +
Terragrunt. The point of the repo is not the app — it's a clean separation of
responsibilities between three tools, and a security posture that's checked by scripts
rather than asserted in prose. Read `README.md` before making non-trivial changes; it
documents the reasoning behind almost every design decision here, and duplicating that
reasoning below would only let it drift out of sync.

**The one rule that shapes everything else:** Terraform renders config into Git.
ArgoCD reads config from Git. They never talk to each other and neither talks to the
other's domain (Terraform never touches a cluster; ArgoCD never generates values).

| Tool | Owns | Never does |
|---|---|---|
| Terraform (`modules/app`) | Turning typed, validated inputs into a rendered Helm values file | Talk to a cluster |
| Terragrunt (`root.hcl`, `envs/`) | Per-environment instantiation; DRY backend/version config | Contain resource logic |
| ArgoCD (`argocd/`) | Reconciling Git into the cluster | Read configuration from anywhere but Git |

## Commands

```bash
make up        # start minikube (--cni=calico) + install pinned ArgoCD  -> scripts/bootstrap.sh
make deploy    # terragrunt apply, then apply the ArgoCD Application    -> scripts/deploy.sh
make verify    # assert the deployment + security controls are real    -> scripts/verify.sh
make down      # delete the Application, then the minikube profile     -> scripts/teardown.sh

make render    # render envs/dev/app/values.generated.yaml only, no cluster needed
make fmt       # terraform fmt + terragrunt hcl fmt (via scripts/terragrunt-fmt.sh)
make lint      # the CI checks: fmt/validate, helm lint/template, yamllint, plus
               # kubeconform/actionlint when installed (skipped with a notice otherwise)
make clean     # remove local Terraform state/caches
make help      # list targets (also the default goal)
```

`scripts/terragrunt-fmt.sh` is the single place that probes for the `hclfmt` →
`hcl fmt` rename (Terragrunt 0.78+) — `make fmt`, `make lint`, and the CI
`terraform` job all call it rather than each carrying their own copy of that
probe, which is what let them drift out of sync with each other before.

There is no test suite in the traditional sense — correctness is asserted by `make
lint` (static checks) and `make verify` (runtime checks against a live cluster). There
is no "run a single test"; the closest equivalents are running one static check by
hand (e.g. `helm lint charts/hello-app --values envs/dev/app/values.generated.yaml`)
or one `check` block from `scripts/verify.sh` via `kubectl` directly.

`ENV_NAME` (default `dev`) parametrizes `UNIT_DIR`/`VALUES_FILE` across most Make
targets — pass `ENV_NAME=staging make render` etc. once another environment exists.

CI (`.github/workflows/ci.yaml`) runs three jobs: `terraform` (fmt/validate +
Terragrunt hclfmt), `helm` (`helm lint`/`template` + `kubeconform -strict`), and
`lint` (yamllint + actionlint). There is currently no CI-time check that the
committed `values.generated.yaml` matches what Terraform would render — the security
context and branch-tracking ARE asserted, but only at runtime by `make verify`
against a live cluster, not statically in CI. (Earlier drafts referenced Python
`scripts/check-*.py` for this; those never existed and the references were removed.)

## Architecture

### Data flow (author → Git → cluster)

1. Edit inputs in `envs/dev/app/terragrunt.hcl` (image, replicas, resources, etc.)
2. `terragrunt apply` in that directory runs the module in `modules/app`, which has
   exactly one resource — a `local_file` — and renders `envs/dev/app/values.generated.yaml`
   via `yamlencode` (never `templatefile`: string-templating free text into YAML lets a
   newline in an input inject arbitrary keys).
3. Commit and push `values.generated.yaml`. **This is the deploy step.** ArgoCD only
   reads from the Git remote's tracked branch, never from a local working tree.
4. ArgoCD (`argocd/application.yaml`) polls that branch and reconciles chart +
   generated values into the cluster. `selfHeal: true` means manual `kubectl edit`
   against the live objects gets reverted — Git is authoritative, not aspirational.

### Multi-source Application, and why

The chart (`charts/hello-app`) and the generated values file (`envs/dev/app/`) are in
different directories, and Helm rejects `valueFiles` paths outside the chart
directory. `argocd/application.yaml` works around this with a two-source
`Application`: one source (`ref: values`) contributes no manifests and exists only to
be referenced as `$values/envs/dev/app/values.generated.yaml` by the other. Both
sources must track the same branch (`targetRevision: main`) — `scripts/deploy.sh`
reads every `targetRevision` in the manifest and refuses to deploy if they diverge.

### AppProject scoping

`argocd/appproject.yaml` deliberately replaces ArgoCD's `default` project (which
allows any repo/cluster/namespace/kind) with one scoped to a single repo, a single
namespace, and exactly the five kinds the chart renders. `clusterResourceWhitelist` is
empty on purpose — that's why `scripts/bootstrap.sh` creates the `hello-app` namespace
itself instead of using ArgoCD's `CreateNamespace=true`.

### Adding an environment

Copy `envs/dev/` to `envs/<name>/`, edit `env.hcl` (the environment name), edit
`envs/<name>/app/terragrunt.hcl` inputs. `modules/app` itself never changes. The
namespace and tracked branch live in the ArgoCD manifests, so you will also need a
second `Application`/`AppProject` pair naming them (or, per the README's production
notes, an app-of-apps/ApplicationSet once there's more than one environment — not
implemented yet).

### Repo URL forking gotcha

The repo URL is hardcoded in three places and ArgoCD refuses the source if they
disagree: `argocd/appproject.yaml` (`spec.sourceRepos[0]`) and
`argocd/application.yaml` (`spec.sources[0].repoURL` and `spec.sources[1].repoURL`).

### Security posture (asserted by `scripts/verify.sh`, not just written down)

- Pod: `runAsNonRoot`, `seccompProfile: RuntimeDefault`, `readOnlyRootFilesystem: true`,
  `allowPrivilegeEscalation: false`, `capabilities.drop: [ALL]`, no ServiceAccount
  token automount.
- Image must be digest-pinned (`modules/app/variables.tf` rejects any `var.image`
  without `@sha256:<64 hex>` at the Terraform layer, before it ever reaches the chart).
- Default-deny `NetworkPolicy` on both ingress (app port only) and egress (DNS UDP+TCP
  53 only). **minikube's default CNI does not enforce NetworkPolicy** — this is why
  `scripts/bootstrap.sh` always passes `--cni calico`, and why `verify.sh` checks for
  the Calico daemonset before trusting any policy-related pass/fail.
- Resource shape is deliberately asymmetric: `limits.memory == requests.memory`
  (a leak OOMKills the one pod instead of pressuring the node), but **no CPU limit**
  (CPU is compressible; a limit only adds CFS-throttling latency, the CPU *request*
  is what the scheduler actually uses). Note the QoS class is Burstable, not
  Guaranteed - Guaranteed would require the CPU limit this repo deliberately omits.

### Local Terraform state

`root.hcl` writes state to `.terragrunt-state/` inside the repo (not
`.terragrunt-cache`), so `apply` stays idempotent across cache clears. It's local,
single-operator, unlocked — fine for this demo, wrong for anything shared.

## Layout

```
root.hcl                              Terragrunt root: backend, version constraints
modules/app/                          Terraform module (renders values.generated.yaml only)
envs/dev/env.hcl                      Per-environment values (the environment name)
envs/dev/app/terragrunt.hcl           The unit: inputs for this env
envs/dev/app/values.generated.yaml    Rendered by Terraform, committed, read by ArgoCD
charts/hello-app/                     Helm chart, with a values JSON schema
argocd/appproject.yaml                Scoped project (not "default")
argocd/application.yaml               Multi-source Application, branch-tracking
scripts/                              bootstrap, deploy, verify, teardown
.github/workflows/ci.yaml             Static checks (3 parallel jobs)
```
