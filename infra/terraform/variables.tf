# AWS region
variable "aws_region" {
  type    = string
  default = "ap-southeast-1"
}

# ECS / ECR names
variable "ecr_repository_name" {
  type    = string
  default = "solana-balance-api"
}

variable "ecs_cluster_name" {
  type    = string
  default = "solana-api-cluster"
}

variable "ecs_service_name" {
  type    = string
  default = "solana-api-service"
}

# VPC / Subnet CIDR
variable "vpc_cidr" {
  type    = string
  default = "10.0.0.0/16"
}

variable "public_subnet_cidr" {
  type    = string
  default = "10.0.1.0/24"
}

# Availability Zone
variable "availability_zone" {
  type    = string
  default = "ap-southeast-1a"
}
