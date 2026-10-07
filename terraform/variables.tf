variable "aws_region" {
  description = "AWS region to deploy into"
  type        = string
  default     = "eu-west-2"
}

variable "project_name" {
  description = "Prefix used on all resource names/tags"
  type        = string
  default     = "bluegreen-bankapp"
}

variable "vpc_cidr" {
  type    = string
  default = "10.20.0.0/16"
}

variable "public_subnet_cidrs" {
  type    = list(string)
  default = ["10.20.1.0/24", "10.20.2.0/24"]
}

variable "private_subnet_cidrs" {
  type    = list(string)
  default = ["10.20.11.0/24", "10.20.12.0/24"]
}

variable "azs" {
  type    = list(string)
  default = ["eu-west-2a", "eu-west-2b"]
}

variable "instance_type" {
  type    = string
  default = "t3.micro"
}

variable "jenkins_instance_type" {
  description = "t3.micro (1GB) is too small for Jenkins plus Maven builds"
  type        = string
  default     = "t3.small"
}

variable "key_name" {
  description = "Existing EC2 key pair name for SSH access"
  type        = string
}

variable "my_ip_cidr" {
  description = "Your IPv4 in CIDR form, e.g. 203.0.113.4/32, used to restrict SSH and Jenkins"
  type        = string
}

variable "app_port" {
  description = "Port the Java app listens on inside each instance"
  type        = number
  default     = 8080
}

variable "db_name" {
  type    = string
  default = "bankapp"
}

variable "db_username" {
  type    = string
  default = "bankapp_admin"
}

variable "db_password" {
  description = "RDS master password, pass via TF_VAR_db_password"
  type        = string
  sensitive   = true
}

variable "ami_id" {
  description = "AMI for all EC2 instances (Amazon Linux 2023)"
  type        = string
}

variable "alert_email" {
  description = "Optional email address for CloudWatch alarm notifications (leave empty to skip)"
  type        = string
  default     = ""
}
