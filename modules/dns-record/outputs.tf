output "hostname" {
  value       = var.enabled ? cloudflare_dns_record.this[0].name : null
  description = "The fully-qualified record name (e.g. rova-dev.qnsc.vn), or null when disabled."
}

output "record_id" {
  value       = var.enabled ? cloudflare_dns_record.this[0].id : null
  description = "Cloudflare record ID, or null when disabled."
}
