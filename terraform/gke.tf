# --- GKE cluster control plane ---
# Note: we create the cluster with `remove_default_node_pool = true` and
# define our own node pool below — this is the standard Terraform pattern
# for GKE Standard clusters, since the default node pool can't be fully
# customized (machine type, autoscaling, etc.) inline.
resource "google_container_cluster" "primary" {
  name     = var.cluster_name
  location = var.zone # zonal cluster keeps cost lower than regional

  network    = google_compute_network.vpc.id
  subnetwork = google_compute_subnetwork.private_subnet.id

  remove_default_node_pool = true
  initial_node_count       = 1

  networking_mode = "VPC_NATIVE"

  ip_allocation_policy {
    cluster_secondary_range_name  = "pods"
    services_secondary_range_name = "services"
  }

  # Private nodes: no public IPs on nodes themselves.
  # master_ipv4_cidr_block is required for the control plane's private peering range.
  private_cluster_config {
    enable_private_nodes    = true
    enable_private_endpoint = false # keep this false so you can kubectl from your laptop
    master_ipv4_cidr_block  = "172.16.0.0/28"
  }

  # Without this, kubectl from your laptop will time out even though the
  # endpoint is "public" — GKE still firewalls the control plane by IP.
  # var.my_ip_cidr is your laptop's public IP, set in terraform.tfvars.
  master_authorized_networks_config {
    gcp_public_cidrs_access_enabled = true
    private_endpoint_enforcement_enabled = false
    cidr_blocks {
      cidr_block   = var.my_ip_cidr
      display_name = "shivkumar-laptop"
    }
  }

  # Gateway API support
  gateway_api_config {
    channel = "CHANNEL_STANDARD"
  }

  deletion_protection = false # set true once this is a real long-lived cluster
}

# --- Managed node pool (this is what you scale/upgrade independently of the control plane) ---
resource "google_container_node_pool" "primary_nodes" {
  name     = "${var.cluster_name}-node-pool"
  location = var.zone
  cluster  = google_container_cluster.primary.name

  initial_node_count = var.node_count

  autoscaling {
    min_node_count = var.min_node_count
    max_node_count = var.max_node_count
  }

  management {
    auto_repair  = true
    auto_upgrade = true
  }

  node_config {
    machine_type = var.node_machine_type

    oauth_scopes = [
      "https://www.googleapis.com/auth/cloud-platform",
    ]

    labels = {
      env = "prod"
      app = "linktracker"
    }
  }
}
