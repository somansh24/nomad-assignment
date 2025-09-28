variable "aws_region" {
  default = "eu-north-1"
}

variable "instance_type_server" {
  default = "t3.micro"
}

variable "instance_type_client" {
  default = "t3.micro"
}

variable "client_count" {
  default = 1
}

variable "nomad_pubkey" {
  description = "Nomad SSH public key"
  type = string
}

variable "my_ip_cidr" {
  description = "Your public IP with /32 mask"
  type        = string
  default     = "27.60.14.205/32"   # <-- replace manually each time
}


