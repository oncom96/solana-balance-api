provider "aws" {
  region = var.aws_region
}

###############################
# 1. VPC + Subnet + Internet GW
###############################

resource "aws_vpc" "main" {
  cidr_block           = var.vpc_cidr
  enable_dns_support   = true
  enable_dns_hostnames = true
  tags = { Name = "solana-vpc" }
}

resource "aws_internet_gateway" "igw" {
  vpc_id = aws_vpc.main.id
  tags   = { Name = "solana-igw" }
}

resource "aws_subnet" "public_subnet" {
  vpc_id                  = aws_vpc.main.id
  cidr_block              = var.public_subnet_cidr
  map_public_ip_on_launch = true
  availability_zone       = var.availability_zone
  tags                    = { Name = "solana-public-subnet" }
}

resource "aws_route_table" "public_rt" {
  vpc_id = aws_vpc.main.id
  route {
    cidr_block = "0.0.0.0/0"
    gateway_id = aws_internet_gateway.igw.id
  }
  tags = { Name = "solana-public-rt" }
}

resource "aws_route_table_association" "public_assoc" {
  subnet_id      = aws_subnet.public_subnet.id
  route_table_id = aws_route_table.public_rt.id
}

###############################
# 2. Security Group
###############################

resource "aws_security_group" "ecs_sg" {
  name        = "solana-ecs-sg"
  description = "Allow HTTP access"
  vpc_id      = aws_vpc.main.id

  ingress {
    from_port   = 8080
    to_port     = 8080
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = { Name = "solana-ecs-sg" }
}

###############################
# 3. ECR Repository
###############################

resource "aws_ecr_repository" "solana_balance_api" {
  name = var.ecr_repository_name
}

###############################
# 4. ECS Cluster
###############################

resource "aws_ecs_cluster" "solana_api_cluster" {
  name = var.ecs_cluster_name
}

###############################
# 5. IAM Role for ECS Task
###############################

resource "aws_iam_role" "ecs_task_execution_role" {
  name = "ecsTaskExecutionRole"
  assume_role_policy = jsonencode({
    Version = "2012-10-17",
    Statement = [
      {
        Effect = "Allow",
        Principal = { Service = "ecs-tasks.amazonaws.com" },
        Action = "sts:AssumeRole"
      }
    ]
  })
}

resource "aws_iam_role_policy_attachment" "ecs_task_execution_role_policy" {
  role       = aws_iam_role.ecs_task_execution_role.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AmazonECSTaskExecutionRolePolicy"
}

###############################
# 6. ECS Task Definition
###############################

resource "aws_ecs_task_definition" "solana_api_task" {
  family                   = "solana-api-task"
  cpu                      = "256"
  memory                   = "512"
  network_mode             = "awsvpc"
  requires_compatibilities = ["FARGATE"]
  execution_role_arn       = aws_iam_role.ecs_task_execution_role.arn

  container_definitions = jsonencode([
    {
      name      = "solana-balance-api"
      image     = "${aws_ecr_repository.solana_balance_api.repository_url}:latest"
      essential = true
      portMappings = [
        {
          containerPort = 8080
          hostPort      = 8080
        }
      ]
    }
  ])
}

###############################
# 7. ECS Service
###############################

resource "aws_ecs_service" "solana_api_service" {
  name            = var.ecs_service_name
  cluster         = aws_ecs_cluster.solana_api_cluster.id
  task_definition = aws_ecs_task_definition.solana_api_task.arn
  desired_count   = 1
  launch_type     = "FARGATE"

  network_configuration {
    subnets         = [aws_subnet.public_subnet.id]
    security_groups = [aws_security_group.ecs_sg.id]
    assign_public_ip = true
  }

  depends_on = [aws_iam_role_policy_attachment.ecs_task_execution_role_policy]
}

###############################
# 8. Terraform Outputs
###############################

output "ecr_repo_url" {
  value = aws_ecr_repository.solana_balance_api.repository_url
}

output "ecs_cluster_name" {
  value = aws_ecs_cluster.solana_api_cluster.name
}

output "ecs_service_name" {
  value = aws_ecs_service.solana_api_service.name
}

output "ecs_service_public_subnet" {
  value = aws_subnet.public_subnet.id
}
