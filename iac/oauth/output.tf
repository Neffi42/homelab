output "oauth2_client_secret_ids" {
  description = "Bitwarden secret UUID of each OAuth2 client secret, for ExternalSecret remoteRef.key"
  value       = { for name, secret in bitwarden_secret.oauth2_client_secret : name => secret.id }
}
