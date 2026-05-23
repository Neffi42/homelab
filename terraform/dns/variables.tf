variable "domain" {
  description = "The domain to manage"
  type        = string
  default     = "neffi.fr"
}

variable "pihole_url" {
  description = "The URL of the Pi-hole instance"
  type        = string
}

variable "pihole_password" {
  description = "The admin password for the Pi-hole"
  type        = string
  sensitive   = true
}

variable "pihole_target_ip" {
  description = "The targeted ip address by pihole records"
  type        = string
}

variable "ovh_endpoint" {
  description = "The ovh endpoint to use"
  type        = string
  default     = "ovh-eu"
}

variable "ovh_client_id" {
  description = "The client id for ovh"
  type        = string
  sensitive   = true
}

variable "ovh_client_secret" {
  description = "The client secret for ovh"
  type        = string
  sensitive   = true
}

variable "ovh_target_ip" {
  description = "The targeted ip address by ovh records"
  type        = string
}

variable "manual_dns_entries" {
  description = "Manual DNS entries to create"
  type = map(object({
    subdomain = string
    target_ip = string
    provider  = string
  }))
  default = {}
}
