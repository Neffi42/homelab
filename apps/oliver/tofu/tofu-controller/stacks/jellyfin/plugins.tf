resource "jellyfin_plugin_repository" "stable" {
  name    = "Jellyfin Stable"
  url     = "https://repo.jellyfin.org/files/plugin/manifest.json"
  enabled = true
}

resource "jellyfin_plugin_repository" "sso" {
  name    = "k0lin/jellyfin-plugin-sso"
  url     = "https://raw.githubusercontent.com/k0lin/jellyfin-plugin-sso/manifest-release/manifest.json"
  enabled = true
}

resource "jellyfin_plugin" "open_subtitles" {
  name           = "Open Subtitles"
  repository_url = jellyfin_plugin_repository.stable.url
}

# CredentialsInvalid is left out: the plugin sets it itself when the login fails.
resource "jellyfin_plugin_configuration" "open_subtitles" {
  plugin_id = jellyfin_plugin.open_subtitles.id

  configuration_json = jsonencode({
    Username = var.opensubtitles_username
    Password = var.opensubtitles_password
  })
}

resource "jellyfin_plugin" "sso" {
  name           = "SSO Authentication"
  repository_url = jellyfin_plugin_repository.sso.url

  # Only used at install, and a change reinstalls the plugin: the live install still records the
  # repository URL with a trailing space.
  lifecycle {
    ignore_changes = [repository_url]
  }
}

# Jellyfin replaces the whole plugin configuration on update: CanonicalLinks must list every
# SSO user, or they lose their link to their Jellyfin account.
resource "jellyfin_plugin_configuration" "sso" {
  plugin_id = jellyfin_plugin.sso.id

  configuration_json = jsonencode({
    SamlConfigs = {}
    OidConfigs = {
      kanidm = {
        OidEndpoint                                = "${var.kanidm_url}oauth2/openid/jellyfin/.well-known/openid-configuration"
        OidClientId                                = "jellyfin"
        OidSecret                                  = var.oidc_client_secret
        Enabled                                    = true
        EnableAuthorization                        = true
        EnableAllFolders                           = false
        EnableContentDownloading                   = null
        ApplyContentDownloadPermissionOnEveryLogin = false
        EnabledFolders                             = [jellyfin_library.movies.item_id, jellyfin_library.shows.item_id]
        AdminRoles                                 = ["app_admins"]
        PreserveAdminPermissions                   = false
        Roles                                      = ["app_admins", "jellyfin_users"]
        EnableFolderRoles                          = false
        EnableLiveTvRoles                          = false
        EnableLiveTv                               = false
        EnableLiveTvManagement                     = false
        LiveTvRoles                                = []
        LiveTvManagementRoles                      = []
        FolderRoleMapping                          = []
        RoleClaim                                  = "groups"
        OidScopes                                  = ["openid", "email", "profile", "groups_name"]
        OverrideDefaultScopes                      = false
        PortOverride                               = null
        NewPath                                    = true
        CanonicalLinks                             = { for login, id in jsondecode(var.sso_canonical_links) : login => replace(lower(id), "-", "") }
        DefaultUsernameClaim                       = "email"
        DisableHttps                               = false
        DisablePushedAuthorization                 = false
        DoNotValidateEndpoints                     = false
        DoNotValidateIssuerName                    = false
        DoNotLoadProfile                           = false
      }
    }
  })
}
