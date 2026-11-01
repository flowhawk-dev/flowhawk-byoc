output "collector_ingress_address" {
  description = "Point collector_host at this address (a CNAME for a hostname, an A record for an IP)."
  value       = local.ingress == null ? "" : coalesce(local.ingress.hostname, local.ingress.ip)
}
