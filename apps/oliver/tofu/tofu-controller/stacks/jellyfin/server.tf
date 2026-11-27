resource "jellyfin_system_configuration" "this" {
  server_name                 = "jellyfin-oliver"
  ui_culture                  = "en-US"
  preferred_metadata_language = "en"
  metadata_country_code       = "FR"
  log_file_retention_days     = 3
  activity_log_retention_days = 30
  quick_connect_available     = true
  enable_metrics              = false

  cast_receiver_applications = [
    { id = "F007D354", name = "Stable" },
    { id = "6F511C87", name = "Unstable" },
  ]
}

resource "jellyfin_networking_configuration" "this" {
  base_url                  = ""
  enable_https              = false
  enable_ipv4               = true
  enable_ipv6               = false
  enable_remote_access      = true
  auto_discovery            = true
  known_proxies             = ["10.42.0.0/16"]
  ignore_virtual_interfaces = true
  virtual_interface_names   = ["veth"]
}

resource "jellyfin_encoding_configuration" "this" {
  hardware_acceleration_type = "none"
  enable_hardware_encoding   = true
  enable_subtitle_extraction = true
  allow_hevc_encoding        = false
  allow_av1_encoding         = false
}

resource "jellyfin_branding_configuration" "this" {
  splashscreen_enabled = false

  login_disclaimer = chomp(<<-EOT
    <form action="${var.jellyfin_url}sso/OID/start/kanidm">
      <button class="raised block emby-button button-submit">
        Sign in with SSO
      </button>
    </form>
  EOT
  )

  custom_css = chomp(<<-EOT
    @import url("https://cdn.jsdelivr.net/gh/lscambo13/ElegantFin@main/Theme/ElegantFin-jellyfin-theme-build-latest-minified.css");

    a.raised.emby-button {
      padding: 0.9em 1em;
      color: inherit !important;
    }

    .disclaimerContainer {
      display: block;
    }

    .manualLoginForm {
      display: none;
    }
  EOT
  )
}
