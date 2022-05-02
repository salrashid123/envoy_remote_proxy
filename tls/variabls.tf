
variable "allowed_host" {
  type    = string
  default = "httpbin.org"
}

variable "billing_account" {
  type    = string
  default = "000C16-9779B5-123456"
}

variable "org_id" {
  type    = string
  default = "673208781234"
}

variable "regions" {
  type    = list(string)
  default = ["us-central1","us-east1"]
}

variable "allowedIP" {
  type    = list(string)
  default = ["72.83.22.111/32"]
}
