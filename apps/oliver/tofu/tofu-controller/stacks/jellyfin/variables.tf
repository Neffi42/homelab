variable "jellyfin_endpoint" {
  description = "Url of the Jellyfin instance to administrate"
  type        = string
  default     = "http://jellyfin.media.svc:8096"
}

variable "jellyfin_api_key" {
  description = "Jellyfin API key, created on the dashboard's API Keys page"
  type        = string
  sensitive   = true
}

variable "jellyfin_url" {
  description = "Public url of the Jellyfin instance, used by the SSO login button"
  type        = string
  default     = "https://jellyfin.neffi.fr/"
}

variable "kanidm_url" {
  description = "Url of the kanidm instance"
  type        = string
  default     = "https://auth.neffi.fr/"
}

variable "oidc_client_secret" {
  description = "Secret of the Kanidm jellyfin OAuth2 client"
  type        = string
  sensitive   = true
}

variable "sso_canonical_links" {
  description = "JSON object of SSO login (email) to Jellyfin user ID, as the SSO-Auth plugin recorded them"
  type        = string
  sensitive   = true
}

variable "opensubtitles_username" {
  description = "OpenSubtitles.com account used by the Open Subtitles plugin"
  type        = string
  sensitive   = true
}

variable "opensubtitles_password" {
  description = "Password of the OpenSubtitles.com account"
  type        = string
  sensitive   = true
}
