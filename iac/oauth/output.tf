output "fb_quantum_oauth_secret" {
  description = "OAuth2 client secret for FileBrowser Quantum"
  value       = kanidm_oauth2_basic.fb_quantum.client_secret
  sensitive   = true
}

output "forgejo_oauth_secret" {
  description = "OAuth2 client secret for Forgejo"
  value       = kanidm_oauth2_basic.forgejo.client_secret
  sensitive   = true
}

output "continuwuity_oauth_secret" {
  description = "OAuth2 client secret for Continuwuity"
  value       = kanidm_oauth2_basic.continuwuity.client_secret
  sensitive   = true
}

output "jellyfin_oauth_secret" {
  description = "OAuth2 client secret for Jellyfin"
  value       = kanidm_oauth2_basic.jellyfin.client_secret
  sensitive   = true
}

output "go2rtc_oauth_secret" {
  description = "OAuth2 client secret for go2rtc"
  value       = kanidm_oauth2_basic.go2rtc.client_secret
  sensitive   = true
}

output "dufs_oauth_secret" {
  description = "OAuth2 client secret for dufs"
  value       = kanidm_oauth2_basic.dufs.client_secret
  sensitive   = true
}

output "firefox_oauth_secret" {
  description = "OAuth2 client secret for firefox"
  value       = kanidm_oauth2_basic.firefox.client_secret
  sensitive   = true
}

output "qbittorrent_oauth_secret" {
  description = "OAuth2 client secret for qBittorrent"
  value       = kanidm_oauth2_basic.qbittorrent.client_secret
  sensitive   = true
}
