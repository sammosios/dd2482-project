resource "cloudflare_dns_record" "cp" {
  for_each = toset(var.hostnames)

  zone_id = var.cloudflare_zone_id
  name    = "${each.key}.${var.domain}"
  type    = "A"
  content = google_compute_address.cp.address
  ttl     = 300
  proxied = false
  comment = "Managed by Terraform (dd2482-project terraform/gcp)"
}
