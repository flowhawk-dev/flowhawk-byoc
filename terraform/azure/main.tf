# A Flowhawk cluster in your Azure subscription: a resource group, an AKS cluster with one node pool, Premium SSD
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

variable "location" {
  type = string
  validation {
    condition     = !startswith(lower(var.location), "china")
    error_message = "Azure China (21Vianet) isn't supported: it is a separate cloud and needs image mirrors inside China."
  }
}
variable "subscription_id" { type = string }
variable "node_size" {
  type    = string
  default = "Standard_D4s_v5"
}

locals {
  # Azure Government's locations (usgov*, usdod*) live in their own cloud.
  environment = can(regex("^(usgov|usdod)", lower(var.location))) ? "usgovernment" : "public"
}

provider "azurerm" {
  features {}
  subscription_id = var.subscription_id
  environment     = local.environment
}

# Only some locations have availability zones (West US, UK West, Canada East and others don't). Where they exist the
# nodes spread over them; elsewhere the nodes and the backup account stay in the one datacenter.
data "azurerm_location" "this" { location = var.location }
locals {
  zones = sort(distinct([for z in data.azurerm_location.this.zone_mappings : z.logical_zone]))
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
    name    = "flowhawk"
    vm_size = var.node_size
    # The cluster autoscaler adds nodes, up to node_count_max, when pods (more collectors) don't fit.
    auto_scaling_enabled        = true
    min_count                   = var.node_count
    max_count                   = max(var.node_count, var.node_count_max)
    os_disk_size_gb             = 50
    zones                       = length(local.zones) > 0 ? local.zones : null
    temporary_name_for_rotation = "flowhawktmp"
  }
  # Who may reach the Kubernetes API: left out when it is open to everyone (AKS's default).
  dynamic "api_server_access_profile" {
    for_each = contains(var.api_allowed_cidrs, "0.0.0.0/0") ? [] : [1]
    content { authorized_ip_ranges = var.api_allowed_cidrs }
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
  # Locally redundant, in the zone of the node ClickHouse runs on (WaitForFirstConsumer), as on AWS and Google Cloud.
  # Zone-redundant disks exist in only some zoned locations.
  parameters = { skuName = "Premium_LRS" }
  depends_on = [azurerm_kubernetes_cluster.flowhawk]
}

# Nightly backups (backup_days): a storage account with no public access and a private container; a lifecycle rule
# deletes backups a week after backup_days. ClickHouse writes with the account's key, kept in a secret in the cluster.
resource "azurerm_storage_account" "backups" {
  count                           = var.backup_days > 0 ? 1 : 0
  name                            = "fhbackups${substr(md5("${var.subscription_id}/${var.deployment_id}"), 0, 14)}"
  resource_group_name             = azurerm_resource_group.flowhawk.name
  location                        = azurerm_resource_group.flowhawk.location
  account_tier                    = "Standard"
  account_replication_type        = length(local.zones) > 0 ? "ZRS" : "LRS"
  min_tls_version                 = "TLS1_2"
  allow_nested_items_to_be_public = false
  https_traffic_only_enabled      = true
  tags                            = { "flowhawk-deployment" = var.deployment_id }
}
resource "azurerm_storage_container" "backups" {
  count                 = var.backup_days > 0 ? 1 : 0
  name                  = "flowhawk-backups"
  storage_account_id    = azurerm_storage_account.backups[0].id
  container_access_type = "private"
}
resource "azurerm_storage_management_policy" "backups" {
  count              = var.backup_days > 0 ? 1 : 0
  storage_account_id = azurerm_storage_account.backups[0].id
  rule {
    name    = "expire-backups"
    enabled = true
    filters { blob_types = ["blockBlob"] }
    actions {
      base_blob { delete_after_days_since_creation_greater_than = var.backup_days + 7 }
    }
  }
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
  clickhouse_cpu        = var.clickhouse_cpu
  clickhouse_memory_gb  = var.clickhouse_memory_gb
  agent_image_tag       = var.agent_image_tag
  backup = var.backup_days == 0 ? null : {
    kind      = "azure"
    endpoint  = azurerm_storage_account.backups[0].primary_blob_endpoint
    container = azurerm_storage_container.backups[0].name
    keepDays  = var.backup_days
  }
  backup_credentials = var.backup_days == 0 ? {} : {
    "account-name" = azurerm_storage_account.backups[0].name
    "account-key"  = azurerm_storage_account.backups[0].primary_access_key
  }
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
output "backup_bucket" {
  description = "Where ClickHouse's nightly backups go: the storage account (empty when backup_days is 0)."
  value       = var.backup_days > 0 ? azurerm_storage_account.backups[0].name : ""
}
output "kubeconfig_command" { value = "az aks get-credentials --resource-group ${azurerm_resource_group.flowhawk.name} --name ${azurerm_kubernetes_cluster.flowhawk.name}" }
