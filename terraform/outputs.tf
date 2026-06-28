output "cluster_name" {
  description = "GKE cluster name"
  value       = google_container_cluster.primary.name
}

output "cluster_location" {
  description = "Zone the cluster lives in"
  value       = google_container_cluster.primary.location
}

output "cluster_endpoint" {
  description = "GKE control plane endpoint"
  value       = google_container_cluster.primary.endpoint
  sensitive   = true
}


output "vpc_name" {
  description = "VPC network name"
  value       = google_compute_network.vpc.name
}
