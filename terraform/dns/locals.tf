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
}
