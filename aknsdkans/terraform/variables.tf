variable "region" {
  description = "An EU region. Resources in different regions cannot see each other."
  type        = string
  default     = "eu-north-1"
}

variable "project" {
  description = "Prefix for every resource name, so you can find and delete them."
  type        = string
  default     = "2dv705"
}

variable "instance_type" {
  description = "Changing this one value is how test and production differ."
  type        = string
  default     = "t3.micro"
}

variable "key_name" {
  description = "Name of an EC2 key pair that already exists in this region, for SSH to the web instance."
  type        = string
  default     = "2dv705"
}

variable "admin_cidr" {
  description = "Your own public address WITH /32 on the end, e.g. 203.0.113.25/32. Find it with: curl -s https://checkip.amazonaws.com"
  type        = string

  validation {
    condition     = can(cidrhost(var.admin_cidr, 0)) && strcontains(var.admin_cidr, "/")
    error_message = "admin_cidr must be an address with /32 on the end, e.g. 203.0.113.25/32 — not the bare address."
  }
}

variable "repo_url" {
  description = "Public Git URL the web instance clones the application from, e.g. https://github.com/NAME/lnu-notes.git"
  type        = string

  validation {
    condition     = startswith(var.repo_url, "https://") && !strcontains(var.repo_url, "CHANGE-ME") && !strcontains(var.repo_url, "YOUR-NAME")
    error_message = "repo_url must be the real https:// address of a PUBLIC repository — the instance clones it at boot and has no credentials."
  }
}
