variable "deployment_id" { type = string }
variable "control_url" { type = string }
variable "cloud" { type = string }
variable "agent_token" {
  type      = string
  sensitive = true
}
variable "ingest_key" {
  type      = string
  sensitive = true
}
variable "collector_host" { type = string }
variable "acme_email" { type = string }
variable "namespace" {
  type    = string
  default = "flowhawk"
}
variable "storage_class" {
  type    = string
  default = ""
}
variable "clickhouse_storage_gb" { type = number }
variable "agent_image_tag" {
  type    = string
  default = ""
}
variable "ingress_annotations" {
  type    = map(string)
  default = {}
}
variable "ingress_nginx_version" {
  type    = string
  default = "4.13.3"
}
variable "cert_manager_version" {
  type    = string
  default = "v1.19.1"
}

variable "agent_chart_repo" {
  type    = string
  default = "oci://ghcr.io/flowhawk-dev/charts"
}

variable "agent_chart_version" {
  description = "The flowhawk-agent chart version; the same as this module's release tag."
  type        = string
  default     = "0.1.0"
}

variable "agent_chart_path" {
  description = "A local flowhawk-agent chart folder instead of the published chart (development only)."
  type        = string
  default     = ""
}
