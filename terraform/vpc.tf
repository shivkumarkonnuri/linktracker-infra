# --- VPC ---
resource "google_compute_network" "vpc" {
  name    		  = var.vpc_name
  auto_create_subnetworks = false
}

# --- Private subnet for GKE nodes + pods/services secondary ranges ---
resource "google_compute_subnetwork" "private_subnet" {
  name          = "${var.vpc_name}-private"
  ip_cidr_range = var.subnet_cidr
  region        = var.region
  network       = google_compute_network.vpc.id

  private_ip_google_access = true

  secondary_ip_range {
    range_name      = "pods"
    ip_cidr_range   = var.pods_cidr
  }

  secondary_ip_range {
    range_name      = "services"
    ip_cidr_range   = var.services_cidr
  }
}

# --- Public subnet (reserved for future use: bastion, public LB resources) ---
resource "google_compute_subnetwork" "public_subnet" {
  name          = "${var.vpc_name}-public"
  ip_cidr_range = "10.10.16.0/20" 
  region        = var.region
  network       = google_compute_network.vpc.id
}

# --- Cloud Router (required for Cloud NAT) ---
resource "google_compute_router" "router" {
  name    = "${var.vpc_name}-router"
  region  = var.region
  network = google_compute_network.vpc.id
}

# --- Cloud NAT: lets nodes in the private subnet reach the internet
#     (pulling images, hitting APIs) without public IPs ---
resource "google_compute_router_nat" "nat" {
  name                               = "${var.vpc_name}-nat"
  router                             = google_compute_router.router.name
  region                             = var.region
  nat_ip_allocate_option             = "AUTO_ONLY"
  source_subnetwork_ip_ranges_to_nat = "ALL_SUBNETWORKS_ALL_IP_RANGES"
}

# --- Firewall: allow internal traffic within the VPC ---
resource "google_compute_firewall" "allow_internal" {
  name    = "${var.vpc_name}-allow-internal"
  network = google_compute_network.vpc.id

  allow {
    protocol = "tcp"
    ports    = ["0-65535"]
  }
  allow {
    protocol = "udp"
    ports    = ["0-65535"]
  }
  allow {
    protocol = "icmp"
  }

  source_ranges = [var.subnet_cidr, var.pods_cidr, var.services_cidr]
}

# --- Firewall: allow Google's health checks to reach nodes
#     (needed for GKE Gateway / load balancer backends) ---
resource "google_compute_firewall" "allow_health_checks" {
  name    = "${var.vpc_name}-allow-health-checks"
  network = google_compute_network.vpc.id

  allow {
    protocol = "tcp"
  }

  source_ranges = ["130.211.0.0/22", "35.191.0.0/16"]
}
  
