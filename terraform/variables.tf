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
  description = "An existing EC2 key pair name, for SSH to the web instance."
  type        = string
}

variable "admin_cidr" {
  description = "Your own address, as a /32. Find it with: curl https://checkip.amazonaws.com"
  type        = string
}

variable "repo_url" {
  description = "Where the instance clones the application from."
  type        = string
  default     = "https://github.com/CHANGE-ME/lnu-notes.git"
}

variable "db_password" {
  description = "Database password. It is written into the state file in clear text — see README."
  type        = string
  sensitive   = true
}
