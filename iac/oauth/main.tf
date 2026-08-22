terraform {
  required_version = ">= 1.12.1"

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
  name        = "neffi"
  displayname = "Neffi"
  mail        = ["me@neffi.fr"]
}

resource "kanidm_person" "cla" {
  name        = "cla"
  displayname = "Clara Touraine"
  mail        = [var.cla_mail]
}

resource "kanidm_person" "bot_oliver" {
  name        = "bot-oliver"
  displayname = "Bot Oliver"
  mail        = [var.bot_oliver_mail]
}

resource "kanidm_group" "app_admins" {
  name        = "app_admins"
  description = "Administrator team for downstream apps"

  members = [
    kanidm_person.neffi.id,
  ]
}

resource "kanidm_group" "fb_quantum_users" {
  name        = "fb_quantum_users"
  description = "FileBrowser Quantum standard users"

  members = [
    kanidm_person.neffi.id,
  ]
}

resource "kanidm_group" "forgejo_users" {
  name        = "forgejo_users"
  description = "Forgejo users"

  members = [
    kanidm_person.neffi.id,
    kanidm_person.bot_oliver.id,
  ]
}

resource "kanidm_group" "continuwuity_users" {
  name        = "continuwuity_users"
  description = "Continuwuity users"

  members = [
    kanidm_person.neffi.id,
  ]
}

resource "kanidm_oauth2_basic" "fb_quantum" {
  name        = "fb_quantum"
  displayname = "FileBrowser Quantum"
  origin      = var.fb_quantum_url

  redirect_uris = [
    "${var.fb_quantum_url}api/auth/oidc/callback"
  ]
  allow_insecure_client_disable_pkce = true

  scope_map {
    group  = kanidm_group.app_admins.id
    scopes = ["openid", "profile", "email", "groups_name"]
  }
}

resource "kanidm_oauth2_basic" "forgejo" {
  name        = "forgejo"
  displayname = "Forgejo"
  origin      = var.forgejo_url

  redirect_uris = [
    "${var.forgejo_url}user/oauth2/kanidm/callback"
  ]
  allow_insecure_client_disable_pkce = true

  scope_map {
    group  = kanidm_group.app_admins.id
    scopes = ["openid", "profile", "email", "groups_name"]
  }

  scope_map {
    group  = kanidm_group.forgejo_users.id
    scopes = ["openid", "profile", "email", "groups_name"]
  }
}

resource "kanidm_oauth2_basic" "continuwuity" {
  name        = "continuwuity"
  displayname = "Continuwuity"
  origin      = var.continuwuity_url

  redirect_uris = [
    "${var.continuwuity_url}_continuwuity/oidc/complete"
  ]

  scope_map {
    group  = kanidm_group.app_admins.id
    scopes = ["openid", "profile", "email", "groups_name"]
  }

  scope_map {
    group  = kanidm_group.continuwuity_users.id
    scopes = ["openid", "profile", "email", "groups_name"]
  }
}
