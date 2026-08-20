locals {
  public_domains = flatten([
    for ns, routes in data.kubernetes_resources.httproutes : [
      for route in routes.objects : [
        for hostname in try(route.spec.hostnames, []) : replace(hostname, ".${var.domain}", "")
      ]
      if contains(
        [for ref in try(route.spec.parentRefs, []) : ref.name],
        "public"
      )
    ]
  ])

  private_domains = flatten([
    for ns, routes in data.kubernetes_resources.httproutes : [
      for route in routes.objects : [
        for hostname in try(route.spec.hostnames, []) : replace(hostname, ".${var.domain}", "")
      ]
      if contains(
        [for ref in try(route.spec.parentRefs, []) : ref.name],
        "private"
      )
    ]
  ])

  # This cluster's own "private" Gateway advertises its Tailscale address via
  # spec.addresses — read it back instead of a static var, so each cluster's
  # private HTTPRoutes always resolve to that cluster's own Tailscale IP.
  private_gateway_addresses = flatten([
    for ns, gateways in data.kubernetes_resources.gateways : [
      for gateway in gateways.objects : [
        for address in try(gateway.spec.addresses, []) : address.value
        if try(address.type, "IPAddress") == "IPAddress" && can(regex("^\\d+\\.\\d+\\.\\d+\\.\\d+$", address.value))
      ]
      if gateway.metadata.name == "private"
    ]
  ])

  pihole_target_ip = one(local.private_gateway_addresses)
}
