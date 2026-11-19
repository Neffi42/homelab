terraform {
  required_version = ">= 1.12.1"

  required_providers {
    kanidm = {
      source  = "seanlatimer/kanidm"
      version = "~> 0.1.10"
    }
    bitwarden = {
      source  = "maxlaverse/bitwarden"
      version = "0.23.0"
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

# Secrets Manager machine account, token from BWS_ACCESS_TOKEN.
provider "bitwarden" {
  client_implementation = "embedded"
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

resource "kanidm_group" "jellyfin_users" {
  name        = "jellyfin_users"
  description = "Jellyfin users"

  members = [
    kanidm_person.neffi.id,
    kanidm_person.cla.id,
  ]
}

resource "kanidm_group" "go2rtc_users" {
  name        = "go2rtc_users"
  description = "Camera viewers (cam.neffi.fr)"

  members = [
    kanidm_person.neffi.id,
    kanidm_person.cla.id,
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

resource "kanidm_oauth2_basic" "jellyfin" {
  name        = "jellyfin"
  displayname = "Jellyfin"
  origin      = var.jellyfin_url

  redirect_uris = [
    "${var.jellyfin_url}sso/OID/redirect/kanidm"
  ]

  scope_map {
    group  = kanidm_group.app_admins.id
    scopes = ["openid", "profile", "email", "groups_name"]
  }

  scope_map {
    group  = kanidm_group.jellyfin_users.id
    scopes = ["openid", "profile", "email", "groups_name"]
  }
}

resource "kanidm_oauth2_basic" "go2rtc" {
  name        = "go2rtc"
  displayname = "go2rtc"
  origin      = var.go2rtc_url

  redirect_uris = [
    "${var.go2rtc_url}oauth2/callback"
  ]

  scope_map {
    group  = kanidm_group.app_admins.id
    scopes = ["openid", "profile", "email", "groups_name"]
  }

  scope_map {
    group  = kanidm_group.go2rtc_users.id
    scopes = ["openid", "profile", "email", "groups_name"]
  }
}

resource "kanidm_oauth2_basic" "dufs" {
  name        = "dufs"
  displayname = "dufs"
  origin      = var.dufs_url

  redirect_uris = [
    "${var.dufs_url}oauth2/callback"
  ]

  scope_map {
    group  = kanidm_group.app_admins.id
    scopes = ["openid", "profile", "email", "groups_name"]
  }
}

resource "kanidm_oauth2_basic" "firefox" {
  name        = "firefox"
  displayname = "firefox"
  origin      = var.firefox_url

  redirect_uris = [
    "${var.firefox_url}oauth2/callback"
  ]

  scope_map {
    group  = kanidm_group.app_admins.id
    scopes = ["openid", "profile", "email", "groups_name"]
  }
}

resource "kanidm_oauth2_basic" "miniflux" {
  name                  = "miniflux"
  displayname           = "Miniflux"
  origin                = var.miniflux_url
  prefer_short_username = true

  redirect_uris = [
    "${var.miniflux_url}oauth2/oidc/callback"
  ]

  scope_map {
    group  = kanidm_group.app_admins.id
    scopes = ["openid", "profile", "email", "groups_name"]
  }
}

resource "kanidm_oauth2_basic" "readeck" {
  name                  = "readeck"
  displayname           = "Readeck"
  origin                = var.readeck_url
  prefer_short_username = true

  redirect_uris = [
    "${var.readeck_url}login/oidc"
  ]

  # Readeck only requests "groups" (group SPNs), never "groups_name".
  scope_map {
    group  = kanidm_group.app_admins.id
    scopes = ["openid", "profile", "email", "groups"]
  }
}

resource "kanidm_oauth2_basic" "traefik" {
  name        = "traefik"
  displayname = "Traefik"
  origin      = var.traefik_url

  redirect_uris = [
    "${var.traefik_url}oauth2/callback"
  ]

  scope_map {
    group  = kanidm_group.app_admins.id
    scopes = ["openid", "profile", "email", "groups_name"]
  }
}

resource "kanidm_oauth2_basic" "flux" {
  name        = "flux"
  displayname = "Flux"
  origin      = var.flux_url

  redirect_uris = [
    "${var.flux_url}oauth2/callback"
  ]

  scope_map {
    group  = kanidm_group.app_admins.id
    scopes = ["openid", "profile", "email", "groups_name"]
  }
}

locals {
  oauth2_basic_clients = {
    continuwuity = kanidm_oauth2_basic.continuwuity
    dufs         = kanidm_oauth2_basic.dufs
    fb_quantum   = kanidm_oauth2_basic.fb_quantum
    firefox      = kanidm_oauth2_basic.firefox
    flux         = kanidm_oauth2_basic.flux
    forgejo      = kanidm_oauth2_basic.forgejo
    go2rtc       = kanidm_oauth2_basic.go2rtc
    jellyfin     = kanidm_oauth2_basic.jellyfin
    miniflux     = kanidm_oauth2_basic.miniflux
    readeck      = kanidm_oauth2_basic.readeck
    traefik      = kanidm_oauth2_basic.traefik
  }
}

resource "bitwarden_secret" "oauth2_client_secret" {
  for_each = local.oauth2_basic_clients

  key        = "kanidm-oauth2-${each.key}-client-secret"
  value      = each.value.client_secret
  project_id = var.bitwarden_project_id
  note       = "Managed by iac/oauth"
}

# Secrets created by hand before tofu managed them; drop once applied.
import {
  for_each = {
    continuwuity = "6fdf8fc0-7667-4d8f-b430-b4a500db297a"
    dufs         = "bb1d494a-b866-443d-93f2-b4d200efe064"
    fb_quantum   = "ad80d021-959f-40e9-89a4-b457007375e8"
    firefox      = "5fe790e2-4464-4b54-8d3f-b4d200ef9699"
    flux         = "9b6141ef-8fba-414e-926f-b50700cf8dbb"
    forgejo      = "d49ced84-3a5c-4d00-9c35-b458010b3a95"
    go2rtc       = "031ea2b2-428b-42d3-9f68-b4d200f02f34"
    miniflux     = "c077d2d0-4c30-4e4b-96a3-b50500e48497"
    readeck      = "3baa3bdf-6cc1-4ff8-8da7-b50500e49406"
    traefik      = "161707ff-f8e0-4d58-ac6a-b50700cf7f45"
  }
  to = bitwarden_secret.oauth2_client_secret[each.key]
  id = each.value
}
