variable "project_id" {
  description = "GCP project ID"
  type        = string
  default     = "project-4e5f01c9-f728-4af1-bc0"
}

variable "region" {
  description = "GCP region for all resources"
  type        = string
  default     = "us-central1"
}

variable "zone" {
  description = "GCP zone for zonal resources (node pool)"
  type        = string
  default     = "us-central1-a"
}

variable "my_ip_cidr" {
  description = "Your laptop's public IP in CIDR form (e.g. 1.2.3.4/32) — allowlisted to reach the GKE control plane via kubectl"
  type        = string
}

variable "cluster_name" {
  description = "Name of the GKE cluster"
  type        = string
  default     = "linktracker-prod"
}

variable "vpc_name" {
  description = "Name of the VPC network"
  type        = string
  default     = "linktracker-vpc"
}

variable "subnet_cidr" {
  description = "CIDR range for the primary subnet"
  type        = string
  default     = "10.10.0.0/20"
}

variable "pods_cidr" {
  description = "Secondary range CIDR for GKE pods (VPC-native cluster)"
  type        = string
  default     = "10.20.0.0/16"
}

variable "services_cidr" {
  description = "Secondary range CIDR for GKE services (VPC-native cluster)"
  type        = string
  default     = "10.30.0.0/20"
}

variable "node_machine_type" {
  description = "Machine type for GKE node pool"
  type        = string
  default     = "e2-standard-2"
}

variable "node_count" {
  description = "Initial number of nodes in the node pool"
  type        = number
  default     = 2
}

variable "min_node_count" {
  description = "Minimum nodes for autoscaling"
  type        = number
  default     = 1
}

variable "max_node_count" {
  description = "Maximum nodes for autoscaling"
  type        = number
  default     = 3
}

variable "artifact_repo_name" {
  description = "Name of the Artifact Registry Docker repository"
  type        = string
  default     = "linktracker"
}
