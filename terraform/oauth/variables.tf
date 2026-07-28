variable "kanidm_url" {
  description = "Url of the kanidm instance to administrate"
  type        = string
}

variable "kanidm_token" {
  description = "Token of the kanidm instance to administrate"
  type        = string
  sensitive   = true
}
