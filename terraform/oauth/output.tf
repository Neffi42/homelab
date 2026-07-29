output "fb_quantum_oauth_secret" {
  description = "OAuth2 client secret for FileBrowser Quantum"
  value       = kanidm_oauth2_basic.fb_quantum.client_secret
  sensitive   = true
}

output "ispy_oauth_secret" {
  description = "OAuth2 client secret for Ispy AgentDVR"
  value       = kanidm_oauth2_basic.ispy.client_secret
  sensitive   = true
}
