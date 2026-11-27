variable "kanidm_url" {
  description = "Url of the kanidm instance to administrate"
  type        = string
  default     = "https://auth.neffi.fr/"
}

variable "kanidm_token" {
  description = "Token of the kanidm instance to administrate"
  type        = string
  sensitive   = true
}

variable "cla_mail" {
  description = "Cla's email"
  type        = string
  sensitive   = true
}

variable "forgejo_url" {
  description = "Url of the Forgejo instance to administrate"
  type        = string
  default     = "https://code.neffi.fr/"
}

variable "bot_oliver_mail" {
  description = "Bot Oliver's email"
  type        = string
  sensitive   = true
}

variable "continuwuity_url" {
  description = "Url of the Continuwuity instance to administrate"
  type        = string
  default     = "https://matrix.neffi.fr/"
}

variable "opencloud_url" {
  description = "Url of the OpenCloud instance to administrate"
  type        = string
  default     = "https://cloud.neffi.fr/"
}

variable "jellyfin_url" {
  description = "Url of the Jellyfin instance to administrate"
  type        = string
  default     = "https://jellyfin.neffi.fr/"
}

variable "go2rtc_url" {
  description = "Url of the go2rtc instance to administrate"
  type        = string
  default     = "https://cam.neffi.fr/"
}

variable "dufs_url" {
  description = "Url of the dufs instance to administrate"
  type        = string
  default     = "https://media.neffi.fr/"
}

variable "firefox_url" {
  description = "Url of the firefox instance to administrate"
  type        = string
  default     = "https://firefox.neffi.fr/"
}

variable "miniflux_url" {
  description = "Url of the Miniflux instance"
  type        = string
  default     = "https://rss.neffi.fr/"
}

variable "readeck_url" {
  description = "Url of the Readeck instance"
  type        = string
  default     = "https://read.neffi.fr/"
}

variable "traefik_url" {
  description = "Url of the Traefik dashboard"
  type        = string
  default     = "https://traefik.neffi.fr/"
}

variable "flux_url" {
  description = "Url of the Flux web UI"
  type        = string
  default     = "https://flux.neffi.fr/"
}

variable "bitwarden_project_id" {
  description = "Bitwarden Secrets Manager project receiving the OAuth2 client secrets"
  type        = string
  default     = "94043aae-da1a-4c68-adac-b50700d2311a"
}
