# `modules/app`

Renders a Helm values file. That is the whole module.

It creates exactly one resource, a `local_file`. It has no provider that talks to
Kubernetes, no `kubernetes_manifest`, no `helm_release`. This is deliberate: in this
repository Terraform's job is to turn typed, validated inputs into configuration in
Git, and ArgoCD's job is to get that configuration into a cluster. If Terraform also
applied to the cluster there would be two controllers with opinions about the same
objects, and the interesting question of the exercise - who owns what - would be
answered "both, sometimes".

## Inputs

| Name | Type | Default | Notes |
|---|---|---|---|
| `name` | string | - | RFC 1123 DNS label; rendered as `fullnameOverride`, so it names every object. Keep in step with `releaseName` in `argocd/application.yaml` |
| `image` | string | - | Must be digest-pinned |
| `replicas` | number | `2` | >= 1 |
| `app_text` | string | `"Hello World"` | Served at `/` |
| `container_port` | number | `8080` | 1-65535 |
| `service_port` | number | `80` | 1-65535 |
| `resources` | object | see below | Memory limit, no CPU limit |
| `network_policy_enabled` | bool | `true` | Needs a CNI that enforces policy |
| `output_path` | string | - | Absolute path; must end in `.yaml` |

Default `resources`:

```hcl
{
  requests = { cpu = "10m", memory = "64Mi" }
  limits   = { memory = "64Mi" }
}
```

The asymmetry is intentional and is explained in the repository README under
"Resource requests and limits".

## Note on the rendered file

The module writes to a path inside the repository and that file is committed. It is
a build artifact in Git, which is a real trade-off - see the repository README,
"Why the generated values file is committed".
