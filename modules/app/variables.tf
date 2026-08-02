variable "name" {
  description = "Application name. Rendered into the values file as fullnameOverride, so it names every Kubernetes object the chart creates. Keep it in step with the release name in argocd/application.yaml."
  type        = string

  validation {
    condition     = can(regex("^[a-z0-9]([-a-z0-9]*[a-z0-9])?$", var.name)) && length(var.name) <= 63
    error_message = "The name must be a valid RFC 1123 DNS label: lowercase alphanumerics and '-', starting and ending alphanumeric, at most 63 characters."
  }
}

variable "image" {
  description = <<-EOT
    Fully qualified container image reference. Must be digest-pinned.

    A floating tag can be repointed at different bytes at any time, which makes a
    deployment irreproducible and is a supply-chain hole: what passed review is not
    necessarily what runs. Including the tag alongside the digest
    ("repo:1.0@sha256:...") keeps the reference readable while the digest is what
    is actually pulled.
  EOT
  type        = string

  validation {
    condition     = can(regex("@sha256:[a-f0-9]{64}$", var.image))
    error_message = "The image must be pinned by digest and end with '@sha256:<64 hex chars>'. Floating tags are rejected on purpose."
  }
}

variable "replicas" {
  description = "Number of pod replicas."
  type        = number
  default     = 2

  validation {
    condition     = var.replicas >= 1 && floor(var.replicas) == var.replicas
    error_message = "The replicas value must be a whole number and at least 1."
  }
}

variable "app_text" {
  description = "Body text served at '/'."
  type        = string
  default     = "Hello World"

  validation {
    condition     = length(var.app_text) > 0
    error_message = "The app_text value must not be empty."
  }
}

variable "container_port" {
  description = "Port the container listens on."
  type        = number
  default     = 8080

  validation {
    condition     = var.container_port >= 1 && var.container_port <= 65535 && floor(var.container_port) == var.container_port
    error_message = "The container_port value must be a whole number between 1 and 65535."
  }
}

variable "service_port" {
  description = "Port the ClusterIP Service exposes."
  type        = number
  default     = 80

  validation {
    condition     = var.service_port >= 1 && var.service_port <= 65535 && floor(var.service_port) == var.service_port
    error_message = "The service_port value must be a whole number between 1 and 65535."
  }
}

variable "resources" {
  description = <<-EOT
    Container resource requests and limits.

    The default deliberately sets a memory limit but no CPU limit. See the repository
    README, section "Resource requests and limits", for the reasoning.
  EOT

  type = object({
    requests = object({
      cpu    = string
      memory = string
    })
    limits = object({
      memory = string
    })
  })

  default = {
    requests = {
      cpu    = "10m"
      memory = "64Mi"
    }
    limits = {
      memory = "64Mi"
    }
  }
}

variable "network_policy_enabled" {
  description = "Render a default-deny NetworkPolicy. Requires a CNI that enforces NetworkPolicy; minikube's default CNI does not."
  type        = bool
  default     = true
}

variable "output_path" {
  description = "Absolute path of the Helm values file to render. This file is committed to Git and is what ArgoCD reads."
  type        = string

  validation {
    condition     = endswith(var.output_path, ".yaml")
    error_message = "The output_path value must end in '.yaml'."
  }
}
