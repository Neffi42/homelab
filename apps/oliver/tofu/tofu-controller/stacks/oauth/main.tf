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
    namespace     = "tofu"
  }
}

provider "kanidm" {
  url   = var.kanidm_url
  token = var.kanidm_token
}

# Secrets Manager machine account, token from BWS_ACCESS_TOKEN.
provider "bitwarden" {
  client_implementation = "embedded"
  server                = "https://vault.bitwarden.eu"
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

resource "kanidm_group" "home_users" {
  name        = "home_users"
  description = "Home users (cam.neffi.fr, home.neffi.fr)"

  members = [
    kanidm_person.neffi.id,
    kanidm_person.cla.id,
  ]
}

resource "kanidm_group" "opencloud_users" {
  name        = "opencloud_users"
  description = "OpenCloud users"

  members = [
    kanidm_person.neffi.id,
    kanidm_person.cla.id,
  ]
}

# Public: the OpenCloud desktop and mobile apps can't hold a secret and send none (PKCE only).
# The desktop client also needs `kanidm system oauth2 enable-localhost-redirects opencloud`:
# the provider has no attribute for it.
resource "kanidm_oauth2_public" "opencloud" {
  name                  = "opencloud"
  displayname           = "OpenCloud"
  origin                = var.opencloud_url
  prefer_short_username = true

  redirect_uris = [
    var.opencloud_url,
    "${var.opencloud_url}oidc-callback.html",
    "${var.opencloud_url}oidc-silent-redirect.html",
    "oc://android.opencloud.eu",
    "oc://ios.opencloud.eu",
    "http://127.0.0.1/",
    "http://localhost/",
  ]

  scope_map {
    group  = kanidm_group.opencloud_users.id
    scopes = ["openid", "profile", "email", "offline_access"]
  }

  claim_map {
    name   = "roles"
    join   = "array"
    group  = kanidm_group.app_admins.id
    values = ["opencloudAdmin"]
  }

  claim_map {
    name   = "roles"
    join   = "array"
    group  = kanidm_group.opencloud_users.id
    values = ["opencloudUser"]
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

  lifecycle {
    replace_triggered_by = [terraform_data.oauth2_client_rotation["forgejo"]]
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

  lifecycle {
    replace_triggered_by = [terraform_data.oauth2_client_rotation["continuwuity"]]
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

  lifecycle {
    replace_triggered_by = [terraform_data.oauth2_client_rotation["jellyfin"]]
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
    group  = kanidm_group.home_users.id
    scopes = ["openid", "profile", "email", "groups_name"]
  }

  lifecycle {
    replace_triggered_by = [terraform_data.oauth2_client_rotation["go2rtc"]]
  }
}

# Public (PKCE only): hass-oidc-auth's recommended mode, nothing to write to Bitwarden.
resource "kanidm_oauth2_public" "home_assistant" {
  name                  = "home-assistant"
  displayname           = "Home Assistant"
  origin                = "${var.home_assistant_url}auth/oidc/welcome"
  prefer_short_username = true

  redirect_uris = [
    "${var.home_assistant_url}auth/oidc/callback"
  ]

  scope_map {
    group  = kanidm_group.app_admins.id
    scopes = ["openid", "profile", "email", "groups"]
  }

  scope_map {
    group  = kanidm_group.home_users.id
    scopes = ["openid", "profile", "email", "groups"]
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

  lifecycle {
    replace_triggered_by = [terraform_data.oauth2_client_rotation["dufs"]]
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

  lifecycle {
    replace_triggered_by = [terraform_data.oauth2_client_rotation["firefox"]]
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

  lifecycle {
    replace_triggered_by = [terraform_data.oauth2_client_rotation["miniflux"]]
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

  lifecycle {
    replace_triggered_by = [terraform_data.oauth2_client_rotation["readeck"]]
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

  lifecycle {
    replace_triggered_by = [terraform_data.oauth2_client_rotation["traefik"]]
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

  lifecycle {
    replace_triggered_by = [terraform_data.oauth2_client_rotation["flux"]]
  }
}

locals {
  oauth2_basic_clients = {
    continuwuity = kanidm_oauth2_basic.continuwuity
    dufs         = kanidm_oauth2_basic.dufs
    firefox      = kanidm_oauth2_basic.firefox
    flux         = kanidm_oauth2_basic.flux
    forgejo      = kanidm_oauth2_basic.forgejo
    go2rtc       = kanidm_oauth2_basic.go2rtc
    jellyfin     = kanidm_oauth2_basic.jellyfin
    miniflux     = kanidm_oauth2_basic.miniflux
    readeck      = kanidm_oauth2_basic.readeck
    traefik      = kanidm_oauth2_basic.traefik
  }

  # Bump a client's number to rotate its secret: the Kanidm provider only reads it on create,
  # so rotating replaces the client.
  oauth2_client_rotation = {
    continuwuity = 1
    dufs         = 1
    firefox      = 1
    flux         = 1
    forgejo      = 1
    go2rtc       = 1
    jellyfin     = 2
    miniflux     = 1
    readeck      = 1
    traefik      = 1
  }
}

resource "terraform_data" "oauth2_client_rotation" {
  for_each = local.oauth2_client_rotation

  input = each.value
}

resource "bitwarden_secret" "oauth2_client_secret" {
  for_each = local.oauth2_basic_clients

  key        = "kanidm-oauth2-${each.key}-client-secret"
  value      = each.value.client_secret
  project_id = var.bitwarden_project_id
  note       = "Managed by iac/oauth"
}
