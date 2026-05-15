resource "ovh_domain_zone_record" "routes" {
  for_each = toset(local.public_domains)

  zone      = var.domain
  subdomain = each.value
  fieldtype = "A"
  target    = var.ovh_target_ip
}

resource "pihole_dns_record" "routes" {
  for_each = toset(local.private_domains)

  domain = "${each.value}.${var.domain}"
  ip     = var.pihole_target_ip
}
