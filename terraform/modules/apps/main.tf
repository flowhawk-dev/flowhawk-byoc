# What goes on the cluster in every cloud: ingress-nginx and cert-manager for the collector's public address, and the
# Flowhawk agent, which installs ClickHouse and the collector (charts/flowhawk-clickstack) itself.
terraform {
  required_providers {
    helm       = { source = "hashicorp/helm", version = "~> 3.0" }
    kubernetes = { source = "hashicorp/kubernetes", version = "~> 3.0" }
  }
}

resource "kubernetes_namespace_v1" "flowhawk" {
  metadata {
    name   = var.namespace
    labels = { "app.kubernetes.io/part-of" = "flowhawk" }
  }
}

resource "helm_release" "ingress_nginx" {
  name             = "ingress-nginx"
  namespace        = "ingress-nginx"
  create_namespace = true
  repository       = "https://kubernetes.github.io/ingress-nginx"
  chart            = "ingress-nginx"
  version          = var.ingress_nginx_version
  values = [yamlencode({
    controller = {
      service = {
        annotations           = var.ingress_annotations
        externalTrafficPolicy = "Local"
      }
      config = { "proxy-body-size" = "16m" }
    }
  })]
}

resource "helm_release" "cert_manager" {
  count            = var.acme_email == "" ? 0 : 1
  name             = "cert-manager"
  namespace        = "cert-manager"
  create_namespace = true
  repository       = "https://charts.jetstack.io"
  chart            = "cert-manager"
  version          = var.cert_manager_version
  values           = [yamlencode({ crds = { enabled = true } })]
}

resource "helm_release" "agent" {
  name      = "flowhawk-agent"
  namespace = kubernetes_namespace_v1.flowhawk.metadata[0].name
  # The published chart of this module's release (ghcr.io/flowhawk-dev/charts). agent_chart_path points at a local
  # copy instead, for development.
  repository = var.agent_chart_path == "" ? var.agent_chart_repo : null
  chart      = var.agent_chart_path == "" ? "flowhawk-agent" : var.agent_chart_path
  version    = var.agent_chart_path == "" ? var.agent_chart_version : null
  values = [yamlencode({
    deploymentId  = var.deployment_id
    controlUrl    = var.control_url
    cloud         = var.cloud
    collectorHost = var.collector_host
    acmeEmail     = var.acme_email
    image         = var.agent_image_tag == "" ? {} : { tag = var.agent_image_tag }
    clickstack = {
      clickhouse = merge({ storage = "${var.clickhouse_storage_gb}Gi" }, var.storage_class == "" ? {} : { storageClass = var.storage_class })
    }
  })]
  set_sensitive = [
    { name = "agentToken", value = var.agent_token },
    { name = "ingestKey", value = var.ingest_key },
  ]
  depends_on = [helm_release.ingress_nginx, helm_release.cert_manager]
}

data "kubernetes_service_v1" "ingress" {
  metadata {
    name      = "ingress-nginx-controller"
    namespace = "ingress-nginx"
  }
  depends_on = [helm_release.ingress_nginx]
}

locals {
  ingress = try(data.kubernetes_service_v1.ingress.status[0].load_balancer[0].ingress[0], null)
}
