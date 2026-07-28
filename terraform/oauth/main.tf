terraform {
  required_version = "~> 1.15.1"

  required_providers {
    kanidm = {
      source  = "seanlatimer/kanidm"
      version = "~> 0.1.10"
    }
  }

  backend "kubernetes" {
    secret_suffix = "oauth"
    namespace     = "terraform"
  }
}

provider "kanidm" {
  url   = var.kanidm_url
  token = var.kanidm_token
}

resource "kanidm_person" "neffi" {
  name                                    = "neffi"
  displayname                             = "Neffi"
  mail                                    = ["me@neffi.fr"]
  generate_initial_credential_reset_token = true
}

resource "kanidm_group" "app_admins" {
  name        = "app_admins"
  description = "Administrator team for downstream apps"

  members = [
    kanidm_person.neffi.id,
  ]
}
