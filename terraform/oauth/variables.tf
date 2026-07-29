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

variable "fb_quantum_url" {
  description = "Url of the FileBrowser Quantum instance to administrate"
  type        = string
  default     = "https://cloud.neffi.fr/"
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
