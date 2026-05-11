###############################################################################
# VARIABLES
###############################################################################

variable "aws_region" {
  description = "AWS region to deploy all resources into."
  type        = string
  default     = "us-east-1"
}

variable "instance_type" {
  description = "EC2 instance type for the cafe web server."
  type        = string
  default     = "t3.micro"
}

variable "your_ip_cidr" {
  description = <<-EOT
    Your public IP address in CIDR notation (e.g. \"203.0.113.5/32\").
    Used to restrict SSH (port 22) access to the EC2 instance.
    Set this in terraform.tfvars - do not commit real IPs to version control.
  EOT
  type        = string
  default     = "0.0.0.0/0" # Fallback: open to all. Override in tfvars.
}
