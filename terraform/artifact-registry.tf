resource "google_artifact_registry_repository" "linktracker_repo" {
  location      = var.region
  repository_id = var.artifact_repo_name
  description   = "Docker images for LinkTracker (frontend + backend)"
  format        = "DOCKER"
}
