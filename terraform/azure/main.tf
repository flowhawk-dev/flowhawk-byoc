# A Flowhawk cluster in your Azure subscription: a resource group, an AKS cluster with one node pool, Premium SSD v1
# disks for ClickHouse, and the Flowhawk agent (modules/apps). Flowhawk gets no credentials to the subscription; the
# agent only calls out.
terraform {
  required_version = ">= 1.6"
  required_providers {
    azurerm    = { source = "hashicorp/azurerm", version = "~> 5.0" }
    helm       = { source = "hashicorp/helm", version = "~> 3.0" }
    kubernetes = { source = "hashicorp/kubernetes", version = "~> 3.0" }
  }
}

variable "location" { type = string }
variable "subscription_id" { type = string }
variable "node_size" {
  type    = string
  default = "Standard_D4s_v5"
}

provider "azurerm" {
  features {}
  subscription_id = var.subscription_id
}

data "azurerm_client_config" "this" {}

resource "azurerm_resource_group" "flowhawk" {
  name     = var.cluster_name
  location = var.location
  tags     = { "flowhawk-deployment" = var.deployment_id }
}

resource "azurerm_kubernetes_cluster" "flowhawk" {
  name                = var.cluster_name
  location            = azurerm_resource_group.flowhawk.location
  resource_group_name = azurerm_resource_group.flowhawk.name
  dns_prefix          = var.cluster_name
  sku_tier            = "Standard"
  # Azure RBAC on the cluster, so support can be given a read-only role on it alone.
  azure_active_directory_role_based_access_control {
    tenant_id          = data.azurerm_client_config.this.tenant_id
    azure_rbac_enabled = true
  }
  default_node_pool {
    name                        = "flowhawk"
    vm_size                     = var.node_size
    node_count                  = var.node_count
    os_disk_size_gb             = 50
    zones                       = ["1", "2", "3"]
    temporary_name_for_rotation = "flowhawktmp"
  }
  identity { type = "SystemAssigned" }
  # Manual: this node pool only, no node autoprovisioning.
  node_provisioning_profile { mode = "Manual" }
  network_profile {
    network_plugin      = "azure"
    network_plugin_mode = "overlay"
    network_data_plane  = "cilium"
    network_policy      = "cilium"
    load_balancer_sku   = "standard"
  }
  tags = { "flowhawk-deployment" = var.deployment_id }
}

# Flowhawk support: may read the cluster's objects (not secrets), nothing else in the subscription.
resource "azurerm_role_assignment" "support" {
  count                = var.support_principal == "" ? 0 : 1
  scope                = azurerm_kubernetes_cluster.flowhawk.id
  role_definition_name = "Azure Kubernetes Service RBAC Reader"
  principal_id         = var.support_principal
}
resource "azurerm_role_assignment" "support_user" {
  count                = var.support_principal == "" ? 0 : 1
  scope                = azurerm_kubernetes_cluster.flowhawk.id
  role_definition_name = "Azure Kubernetes Service Cluster User Role"
  principal_id         = var.support_principal
}

locals {
  kube = azurerm_kubernetes_cluster.flowhawk.kube_admin_config[0]
}

provider "kubernetes" {
  host                   = local.kube.host
  client_certificate     = base64decode(local.kube.client_certificate)
  client_key             = base64decode(local.kube.client_key)
  cluster_ca_certificate = base64decode(local.kube.cluster_ca_certificate)
}
provider "helm" {
  kubernetes = {
    host                   = local.kube.host
    client_certificate     = base64decode(local.kube.client_certificate)
    client_key             = base64decode(local.kube.client_key)
    cluster_ca_certificate = base64decode(local.kube.cluster_ca_certificate)
  }
}

resource "kubernetes_storage_class_v1" "premium" {
  metadata { name = "flowhawk-premium" }
  storage_provisioner    = "disk.csi.azure.com"
  reclaim_policy         = "Retain"
  volume_binding_mode    = "WaitForFirstConsumer"
  allow_volume_expansion = true
  parameters             = { skuName = "Premium_ZRS" }
  depends_on             = [azurerm_kubernetes_cluster.flowhawk]
}

module "apps" {
  source                = "../modules/apps"
  deployment_id         = var.deployment_id
  control_url           = var.control_url
  cloud                 = "azure"
  agent_token           = var.agent_token
  ingest_key            = var.ingest_key
  collector_host        = var.collector_host
  acme_email            = var.acme_email
  storage_class         = kubernetes_storage_class_v1.premium.metadata[0].name
  clickhouse_storage_gb = var.clickhouse_storage_gb
  agent_image_tag       = var.agent_image_tag
  ingress_annotations = {
    "service.beta.kubernetes.io/azure-load-balancer-health-probe-request-path" = "/healthz"
  }
  depends_on = [azurerm_kubernetes_cluster.flowhawk]
}

output "collector_ingress_address" {
  description = "Point collector_host at this IP (an A record)."
  value       = module.apps.collector_ingress_address
}
output "cluster_name" { value = azurerm_kubernetes_cluster.flowhawk.name }
output "kubeconfig_command" { value = "az aks get-credentials --resource-group ${azurerm_resource_group.flowhawk.name} --name ${azurerm_kubernetes_cluster.flowhawk.name}" }
