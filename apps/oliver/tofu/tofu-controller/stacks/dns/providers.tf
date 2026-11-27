terraform {
  required_version = ">= 1.12.1"

  required_providers {
    kubernetes = {
      source  = "hashicorp/kubernetes"
      version = "3.5.0"
    }
    ovh = {
      source  = "ovh/ovh"
      version = "2.24.0"
    }
  }

  backend "kubernetes" {
    secret_suffix = "dns"
    namespace     = "tofu"
  }
}

provider "ovh" {
  endpoint      = var.ovh_endpoint
  client_id     = var.ovh_client_id
  client_secret = var.ovh_client_secret
}
