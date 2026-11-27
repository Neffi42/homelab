resource "ovh_domain_zone_record" "routes" {
  for_each = toset(local.public_domains)

  zone      = var.domain
  subdomain = each.value
  fieldtype = "A"
  target    = var.ovh_target_ip
}

# Ownership records in external-dns' TXT registry format (owner "oliver", prefix
# "_extdns-%{record_type}."), so external-dns adopts the existing A records in place.
resource "ovh_domain_zone_record" "external_dns_ownership" {
  for_each = local.public_routes

  zone      = var.domain
  subdomain = each.key == var.domain ? "_extdns-a" : "_extdns-a.${trimsuffix(each.key, ".${var.domain}")}"
  fieldtype = "TXT"
  target    = "\"heritage=external-dns,external-dns/owner=oliver,external-dns/resource=${each.value}\""
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
