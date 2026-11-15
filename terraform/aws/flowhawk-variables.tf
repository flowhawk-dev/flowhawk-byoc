# Inputs every cloud's module takes. Settings > Storage shows the block to apply.
variable "deployment_id" {
  description = "The cluster's id in Flowhawk (Settings > Storage)."
  type        = string
  validation {
    condition     = can(regex("^byoc_[A-Za-z0-9_-]+$", var.deployment_id))
    error_message = "deployment_id is the byoc_ id from Settings > Storage."
  }
}
variable "control_url" {
  description = "Flowhawk's API."
  type        = string
  default     = "https://api.flowhawk.dev"
  validation {
    condition     = startswith(var.control_url, "https://")
    error_message = "control_url must be https."
  }
}
variable "agent_token" {
  description = "The agent token, shown once in Settings > Storage."
  type        = string
  sensitive   = true
}
variable "ingest_key" {
  description = "A workspace ingest key (Settings > API keys) for the collector."
  type        = string
  sensitive   = true
}
variable "collector_host" {
  description = "The name your SDKs, browser pages and log drains send to (otel.example.com). Point it at the collector_ingress_address output."
  type        = string
}
variable "acme_email" {
  description = "An email for Let's Encrypt, which then issues the collector's certificate. Empty: put your own in the flowhawk-collector-tls secret."
  type        = string
  default     = ""
}
variable "support_principal" {
  description = "Flowhawk's support identity, given read-only access to the cluster. Empty keeps support out."
  type        = string
  default     = ""
}
variable "api_allowed_cidrs" {
  description = "Addresses that may reach the cluster's Kubernetes API, as CIDRs. The default leaves it open to the internet (still behind your cloud's sign-in); narrow it to your office or CI runner's range. Flowhawk itself never calls this API: the agent runs inside the cluster. Whoever runs Terraform must be inside these ranges."
  type        = list(string)
  default     = ["0.0.0.0/0"]
  validation {
    condition     = length(var.api_allowed_cidrs) > 0 && alltrue([for c in var.api_allowed_cidrs : can(cidrhost(c, 0))])
    error_message = "api_allowed_cidrs is a non-empty list of CIDRs, like [\"203.0.113.0/24\"]."
  }
}
variable "cluster_name" {
  type    = string
  default = "flowhawk"
}
variable "node_count" {
  description = "Nodes for ClickHouse and the collector."
  type        = number
  default     = 3
}
variable "clickhouse_storage_gb" {
  type    = number
  default = 200
}
variable "agent_image_tag" {
  description = "Pin the agent's image; empty uses the chart's version."
  type        = string
  default     = ""
}
variable "backup_days" {
  description = "Nightly ClickHouse backups to a bucket in this account, kept this many days (a weekly full backup and daily incremental ones). 0 turns them off."
  type        = number
  default     = 30
  validation {
    condition     = var.backup_days == 0 || (var.backup_days >= 7 && var.backup_days <= 365)
    error_message = "backup_days is 0 (off) or 7 to 365."
  }
}
variable "node_count_max" {
  description = "Most nodes the cluster grows to when the collectors scale out (node autoscaling); at least node_count."
  type        = number
  default     = 6
}
variable "clickhouse_cpu" {
  description = "CPU cores reserved for ClickHouse. Raise it (and node_size) as ingest and queries grow."
  type        = number
  default     = 2
}
variable "clickhouse_memory_gb" {
  description = "Memory for ClickHouse, in GiB; it needs a node with this much free."
  type        = number
  default     = 8
}
