provider "google" {}

resource "random_id" "id" {
  byte_length = 8
  prefix      = "ts-"
}

resource "google_project" "project" {
  name                = random_id.id.hex
  project_id          = random_id.id.hex
  billing_account     = var.billing_account
  org_id              = var.org_id
  auto_create_network = true
  labels              = {}
}

resource "google_project_service" "service" {
  for_each = toset([
    "compute.googleapis.com",
    "storage-api.googleapis.com",
    "storage-component.googleapis.com",
    "logging.googleapis.com",
    "monitoring.googleapis.com",
  ])
  service                    = each.key
  project                    = google_project.project.project_id
  disable_on_destroy         = false
  disable_dependent_services = false
  timeouts {
    create = "30m"
    update = "40m"
  }
}

data "template_file" "cloud-init" {
  template = file("cloud-init.yaml.tmpl")
  vars = {
    allowed_host = var.allowed_host
  }
}

resource "google_service_account" "proxysa" {
  project      = google_project.project.project_id
  account_id   = "proxy-svc"
  display_name = "Service Account"
}

resource "google_project_iam_binding" "logwriterpolicy" {
  project = google_project.project.project_id
  role    = "roles/logging.logWriter"
  members = [
    "serviceAccount:${google_service_account.proxysa.email}"
  ]
}

resource "google_compute_instance_template" "default" {
  name         = "tcp-proxy-xlb-mig-template"
  provider     = google
  project      = google_project.project.project_id
  machine_type = "e2-small"
  tags         = ["allow-health-check", "envoy"]

  network_interface {
    network = "default"
    # access_config {
    #   # add external ip to fetch packages
    # }
  }
  disk {
    source_image = "cos-cloud/cos-85-13310-1453-5"
    auto_delete  = true
    boot         = true
  }
  service_account {
    email  = google_service_account.proxysa.email
    scopes = ["cloud-platform"]
  }
  metadata = {
    "user-data"              = "${data.template_file.cloud-init.rendered}"
    "google-logging-enabled" = "true"
  }
  lifecycle {
    create_before_destroy = true
  }
  depends_on = [
    google_project_service.service,
  ] 
}


resource "google_compute_address" "lbip" {
  name         = "extip-${var.regions[count.index]}"
  provider     = google
  project      = google_project.project.project_id
  address_type = "EXTERNAL"
  count        = length(var.regions)
  region       = var.regions[count.index]
  depends_on = [
    google_project_service.service,
  ]
}


resource "google_compute_router" "router" {
  name    = "router-${var.regions[count.index]}"
  project = google_project.project.project_id
  count   = length(var.regions)
  region  = var.regions[count.index]
  network = "default"
  depends_on = [
    google_project_service.service,
  ]  
}


resource "google_compute_router_nat" "nat" {
  name                               = "nat-${var.regions[count.index]}"
  project                            = google_project.project.project_id
  count                              = length(var.regions)
  region                             = var.regions[count.index]
  router                             = google_compute_router.router[count.index].name
  nat_ip_allocate_option             = "AUTO_ONLY"
  source_subnetwork_ip_ranges_to_nat = "ALL_SUBNETWORKS_ALL_IP_RANGES"
  depends_on = [
    google_project_service.service,
  ]
}


resource "google_compute_firewall" "allowhome" {
  name          = "tcp-proxy-xlb-fw-allow-home"
  provider      = google
  project       = google_project.project.project_id
  direction     = "INGRESS"
  network       = "default"
  source_ranges = var.allowedIP
  allow {
    protocol = "tcp"
    ports    = ["3128","9000"]
  }
  target_tags = ["envoy"]
  depends_on = [
    google_project_service.service,
  ]
}

resource "google_compute_firewall" "allowhc" {
  name          = "tcp-proxy-xlb-fw-allow-hc"
  provider      = google
  project       = google_project.project.project_id
  direction     = "INGRESS"
  network       = "default"
  source_ranges = ["209.85.152.0/22", "35.191.0.0/16", "209.85.204.0/22"]
  allow {
    protocol = "tcp"
    ports    = ["3128"]
  }
  target_tags = ["allow-health-check"]
  depends_on = [
    google_project_service.service,
  ]
}


# MIG
resource "google_compute_region_instance_group_manager" "mig" {
  name     = "tcp-proxy-xlb-${var.regions[count.index]}"
  provider = google
  project  = google_project.project.project_id
  count    = length(var.regions)
  region   = var.regions[count.index]
  named_port {
    name = "tcp"
    port = 3128
  }
  version {
    instance_template = google_compute_instance_template.default.id
    name              = "primary"
  }
  base_instance_name = "vm"
}

resource "google_compute_region_autoscaler" "as" {
  name     = "tcp-proxy-xlb-as-${var.regions[count.index]}"
  provider = google
  project  = google_project.project.project_id
  count    = length(var.regions)
  region   = var.regions[count.index]
  target   = google_compute_region_instance_group_manager.mig[count.index].id

  autoscaling_policy {
    max_replicas    = 5
    min_replicas    = 1
    cooldown_period = 60

    cpu_utilization {
      target = 0.5
    }
  }
}


resource "google_compute_forwarding_rule" "default" {
  name   = "tcp-proxy-xlb-forwarding-rule-${var.regions[count.index]}"
  provider              = google
  count  = length(var.regions)
  region = var.regions[count.index]
  project               = google_project.project.project_id
  ip_protocol           = "TCP"
  load_balancing_scheme = "EXTERNAL"
  ports = ["3128","9000"]
  ip_address            = google_compute_address.lbip[count.index].address
  backend_service       = google_compute_region_backend_service.backend[count.index].id
}

resource "google_compute_region_backend_service" "backend" {
  provider              = google
  project               = google_project.project.project_id

  name   = "tcp-proxy-xlb-backend-service-${var.regions[count.index]}"
  protocol              = "TCP"
  port_name             = "tcp"
  count  = length(var.regions)
  region = var.regions[count.index]

  load_balancing_scheme = "EXTERNAL"
  timeout_sec           = 10
  health_checks         = [google_compute_region_health_check.default[count.index].id]
  backend {
    group          = google_compute_region_instance_group_manager.mig[count.index].instance_group
    balancing_mode = "CONNECTION"
  }
}

resource "google_compute_region_health_check" "default" {
  provider = google
  project  = google_project.project.project_id

  name   = "tcp-proxy-hc-${var.regions[count.index]}"
  count  = length(var.regions)
  region = var.regions[count.index]

  timeout_sec        = 1
  check_interval_sec = 1

  tcp_health_check {
    port = "3128"
  }
  depends_on = [
    google_project_service.service,
  ]  
}
