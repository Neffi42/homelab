terraform {
  required_version = ">= 1.12.1"

  required_providers {
    jellyfin = {
      source  = "ThePhaseless/jellyfin"
      version = "0.9.0"
    }
  }

  backend "kubernetes" {
    secret_suffix = "jellyfin"
    namespace     = "tofu"
  }
}

# Each provider release supports exactly one Jellyfin release: bump it together with the image.
provider "jellyfin" {
  endpoint = var.jellyfin_endpoint
  api_key  = var.jellyfin_api_key
}

