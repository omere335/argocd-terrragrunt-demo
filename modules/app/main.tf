locals {
  values = {

    fullnameOverride = var.name

    replicaCount = var.replicas

    image = {
      reference = var.image
    }

    app = {
      text = var.app_text
      port = var.container_port
    }

    service = {
      port = var.service_port
    }

    resources = var.resources

    networkPolicy = {
      enabled = var.network_policy_enabled
    }
  }

  header = <<-EOT
    # GENERATED FILE - DO NOT EDIT BY HAND.
    #
    # Rendered by the Terraform module in modules/app and committed to Git.
    # ArgoCD reads this file - Terraform never talks to the cluster.
    #
    # To change it: edit the inputs in envs/<env>/app/terragrunt.hcl, run
    # `terragrunt apply`, then commit the result. The commit is the audit trail.
  EOT
}

resource "local_file" "values" {
  filename = var.output_path

  content = "${local.header}${yamlencode(local.values)}"

  file_permission = "0644"
}
