locals {
  # Public hostname => the HTTPRoute serving it, as external-dns labels its records.
  public_routes = merge(flatten([
    for ns, routes in data.kubernetes_resources.httproutes : [
      for route in routes.objects : {
        for hostname in try(route.spec.hostnames, []) :
        hostname => "httproute/${route.metadata.namespace}/${route.metadata.name}"
      }
      if contains(
        [for ref in try(route.spec.parentRefs, []) : ref.name],
        "public"
      )
    ]
  ])...)

  public_domains = [
    for hostname in keys(local.public_routes) : replace(hostname, ".${var.domain}", "")
    if hostname != var.domain
  ]
}
