# A Flowhawk cluster in your Google Cloud project: a VPC, a regional GKE cluster with one node pool, balanced
# persistent disks for ClickHouse, and the Flowhawk agent (modules/apps). Flowhawk gets no credentials to the project;
# the agent only calls out.
terraform {
  required_version = ">= 1.6"
  required_providers {
    google     = { source = "hashicorp/google", version = "~> 8.0" }
    helm       = { source = "hashicorp/helm", version = "~> 3.0" }
    kubernetes = { source = "hashicorp/kubernetes", version = "~> 3.0" }
  }
}

variable "project" { type = string }
variable "region" { type = string }
variable "node_size" {
  type    = string
  default = "e2-standard-4"
}

provider "google" {
  project        = var.project
  region         = var.region
  default_labels = { "flowhawk-deployment" = replace(lower(var.deployment_id), "/[^a-z0-9_-]/", "-") }
}

resource "google_project_service" "apis" {
  for_each           = toset(["container.googleapis.com", "compute.googleapis.com"])
  service            = each.value
  disable_on_destroy = false
}

resource "google_compute_network" "flowhawk" {
  name                    = var.cluster_name
  auto_create_subnetworks = false
  depends_on              = [google_project_service.apis]
}

resource "google_compute_subnetwork" "flowhawk" {
  name                     = var.cluster_name
  network                  = google_compute_network.flowhawk.id
  region                   = var.region
  ip_cidr_range            = "10.42.0.0/20"
  private_ip_google_access = true
  secondary_ip_range {
    range_name    = "pods"
    ip_cidr_range = "10.44.0.0/14"
  }
  secondary_ip_range {
    range_name    = "services"
    ip_cidr_range = "10.48.0.0/20"
  }
}

# Private nodes reach Flowhawk, the image registries and Let's Encrypt through Cloud NAT.
resource "google_compute_router" "flowhawk" {
  name    = var.cluster_name
  network = google_compute_network.flowhawk.id
  region  = var.region
}
resource "google_compute_router_nat" "flowhawk" {
  name                               = var.cluster_name
  router                             = google_compute_router.flowhawk.name
  region                             = var.region
  nat_ip_allocate_option             = "AUTO_ONLY"
  source_subnetwork_ip_ranges_to_nat = "ALL_SUBNETWORKS_ALL_IP_RANGES"
}

resource "google_container_cluster" "flowhawk" {
  name                     = var.cluster_name
  location                 = var.region
  network                  = google_compute_network.flowhawk.id
  subnetwork               = google_compute_subnetwork.flowhawk.id
  remove_default_node_pool = true
  initial_node_count       = 1
  deletion_protection      = false
  networking_mode          = "VPC_NATIVE"
  ip_allocation_policy {
    cluster_secondary_range_name  = "pods"
    services_secondary_range_name = "services"
  }
  private_cluster_config {
    enable_private_nodes    = true
    enable_private_endpoint = false
    master_ipv4_cidr_block  = "172.16.42.0/28"
  }
  # NetworkPolicy (charts/flowhawk-clickstack) needs Dataplane V2.
  datapath_provider = "ADVANCED_DATAPATH"
  release_channel { channel = "REGULAR" }
  workload_identity_config { workload_pool = "${var.project}.svc.id.goog" }
}

resource "google_container_node_pool" "flowhawk" {
  name     = "flowhawk"
  cluster  = google_container_cluster.flowhawk.id
  location = var.region
  # A regional cluster puts this many nodes in each of its zones.
  node_count = max(1, ceil(var.node_count / 3))
  node_config {
    machine_type = var.node_size
    disk_size_gb = 50
    oauth_scopes = ["https://www.googleapis.com/auth/cloud-platform"]
    workload_metadata_config { mode = "GKE_METADATA" }
    shielded_instance_config { enable_secure_boot = true }
  }
  management {
    auto_repair  = true
    auto_upgrade = true
  }
}

# Flowhawk support: may look at the cluster's objects, nothing else in the project.
resource "google_project_iam_member" "support" {
  count   = var.support_principal == "" ? 0 : 1
  project = var.project
  role    = "roles/container.viewer"
  member  = var.support_principal
}

data "google_client_config" "this" {}

provider "kubernetes" {
  host                   = "https://${google_container_cluster.flowhawk.endpoint}"
  cluster_ca_certificate = base64decode(google_container_cluster.flowhawk.master_auth[0].cluster_ca_certificate)
  token                  = data.google_client_config.this.access_token
}
provider "helm" {
  kubernetes = {
    host                   = "https://${google_container_cluster.flowhawk.endpoint}"
    cluster_ca_certificate = base64decode(google_container_cluster.flowhawk.master_auth[0].cluster_ca_certificate)
    token                  = data.google_client_config.this.access_token
  }
}

resource "kubernetes_storage_class_v1" "balanced" {
  metadata { name = "flowhawk-balanced" }
  storage_provisioner    = "pd.csi.storage.gke.io"
  reclaim_policy         = "Retain"
  volume_binding_mode    = "WaitForFirstConsumer"
  allow_volume_expansion = true
  parameters             = { type = "pd-balanced" }
  depends_on             = [google_container_node_pool.flowhawk]
}

module "apps" {
  source                = "../modules/apps"
  deployment_id         = var.deployment_id
  control_url           = var.control_url
  cloud                 = "gcp"
  agent_token           = var.agent_token
  ingest_key            = var.ingest_key
  collector_host        = var.collector_host
  acme_email            = var.acme_email
  storage_class         = kubernetes_storage_class_v1.balanced.metadata[0].name
  clickhouse_storage_gb = var.clickhouse_storage_gb
  agent_image_tag       = var.agent_image_tag
  depends_on            = [google_container_node_pool.flowhawk]
}

output "collector_ingress_address" {
  description = "Point collector_host at this IP (an A record)."
  value       = module.apps.collector_ingress_address
}
output "cluster_name" { value = google_container_cluster.flowhawk.name }
output "kubeconfig_command" { value = "gcloud container clusters get-credentials ${google_container_cluster.flowhawk.name} --region ${var.region} --project ${var.project}" }
