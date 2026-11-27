data "kubernetes_all_namespaces" "namespaces" {}

data "kubernetes_resources" "httproutes" {
  for_each = toset(data.kubernetes_all_namespaces.namespaces.namespaces)

  api_version = "gateway.networking.k8s.io/v1"
  kind        = "HTTPRoute"
  namespace   = each.value
}
