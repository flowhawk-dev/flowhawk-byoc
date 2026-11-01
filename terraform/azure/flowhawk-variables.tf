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
