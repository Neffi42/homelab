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
