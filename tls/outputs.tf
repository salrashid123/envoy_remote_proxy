output "project_id" {
  value = google_project.project.project_id
}
output "project_number" {
  value = google_project.project.number
}
output "regions" {
  value = var.regions
}
output "allowedIP" {
  value = var.allowedIP
}
output "lb_ip" {
  value = google_compute_address.lbip[*].address
}
