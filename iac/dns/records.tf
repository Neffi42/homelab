resource "ovh_domain_zone_record" "routes" {
  for_each = toset(local.public_domains)

  zone      = var.domain
  subdomain = each.value
  fieldtype = "A"
  target    = var.ovh_target_ip
}

resource "ovh_domain_zone_record" "manual" {
  for_each = {
    for k, v in var.manual_dns_entries : k => v
    if v.provider == "ovh"
  }

  zone      = var.domain
  subdomain = each.value.subdomain
  fieldtype = "A"
  target    = each.value.target_ip
}

resource "pihole_dns_record" "routes" {
  for_each = toset(local.private_domains)

  domain = "${each.value}.${var.domain}"
  ip     = local.pihole_target_ip
}

resource "pihole_dns_record" "manual" {
  for_each = {
    for k, v in var.manual_dns_entries : k => v
    if v.provider == "pihole"
  }

  domain = "${each.value.subdomain}.${var.domain}"
  ip     = each.value.target_ip
}
