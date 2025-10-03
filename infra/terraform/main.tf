provider "aws" {
  region = var.aws_region
}

# --------------------------
# VPC & Networking
# --------------------------
resource "aws_vpc" "main" {
  cidr_block           = var.vpc_cidr
  enable_dns_hostnames = true
  tags = {
    Name = "solana-vpc"
  }
}

resource "aws_subnet" "public" {
  vpc_id                  = aws_vpc.main.id
  cidr_block              = var.public_subnet_cidr
  availability_zone       = var.availability_zone
  map_public_ip_on_launch = true

  tags = {
    Name = "solana-public-subnet"
  }
}

resource "aws_internet_gateway" "igw" {
  vpc_id = aws_vpc.main.id
  tags = {
    Name = "solana-igw"
  }
}

resource "aws_route_table" "public" {
  vpc_id = aws_vpc.main.id
  route {
    cidr_block = "0.0.0.0/0"
    gateway_id = aws_internet_gateway.igw.id
  }

  tags = {
    Name = "solana-public-rt"
  }
}

resource "aws_route_table_association" "public_assoc" {
  subnet_id      = aws_subnet.public.id
  route_table_id = aws_route_table.public.id
}

resource "aws_security_group" "ecs" {
  vpc_id      = aws_vpc.main.id
  name        = "solana-ecs-sg"
  description = "Allow HTTP access"

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

  tags = {
    Name = "solana-ecs-sg"
  }
}

# --------------------------
# ECR
# --------------------------
resource "aws_ecr_repository" "app" {
  name                 = var.ecr_repository_name
  image_tag_mutability = "MUTABLE"

  encryption_configuration {
    encryption_type = "AES256"
  }
}

# --------------------------
# ECS Cluster
# --------------------------
resource "aws_ecs_cluster" "app" {
  name = var.ecs_cluster_name
}

# --------------------------
# IAM Role for ECS Task
# --------------------------
resource "aws_iam_role" "ecs_task_execution_role" {
  name = "ecsTaskExecutionRole"

  assume_role_policy = jsonencode({
    Version = "2012-10-17",
    Statement = [{
      Action = "sts:AssumeRole",
      Effect = "Allow",
      Principal = {
        Service = "ecs-tasks.amazonaws.com"
      }
    }]
  })
}

resource "aws_iam_role_policy_attachment" "ecs_task_execution_role_policy" {
  role       = aws_iam_role.ecs_task_execution_role.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AmazonECSTaskExecutionRolePolicy"
}

# Allow ECS Task read SSM Parameters (untuk .env)
resource "aws_iam_role_policy" "ecs_task_ssm_access" {
  name = "ecs-task-ssm-access"
  role = aws_iam_role.ecs_task_execution_role.id

  policy = jsonencode({
    Version = "2012-10-17",
    Statement = [
      {
        Effect   = "Allow",
        Action   = ["ssm:GetParameters", "ssm:GetParameter"],
        Resource = "arn:aws:ssm:${var.aws_region}:${data.aws_caller_identity.current.account_id}:parameter/solana/*"
      }
    ]
  })
}

data "aws_caller_identity" "current" {}

# --------------------------
# SSM Parameters (from .env)
# --------------------------
resource "aws_ssm_parameter" "dev_db_url" {
  name  = "/solana/DEV_DB_URL"
  type  = "SecureString"
  value = "mongodb+srv://pittoy-tech:BtuuyEmk31rvmrcu@pittoyproject.kmvxv65.mongodb.net/solana-api"
}

resource "aws_ssm_parameter" "mongo_db" {
  name  = "/solana/MONGO_DB"
  type  = "String"
  value = "solana-api"
}

resource "aws_ssm_parameter" "default_api_key" {
  name  = "/solana/DEFAULT_API_KEY"
  type  = "String"
  value = "solana-api-key"
}

resource "aws_ssm_parameter" "discord_webhook_url" {
  name  = "/solana/DISCORD_WEBHOOK_URL"
  type  = "SecureString"
  value = "https://canary.discord.com/api/webhooks/xxxxxxx"
}

resource "aws_ssm_parameter" "port" {
  name  = "/solana/PORT"
  type  = "String"
  value = "8080"
}

# --------------------------
# ECS Task Definition
# --------------------------
resource "aws_ecs_task_definition" "app" {
  family                   = "solana-api-task"
  network_mode             = "awsvpc"
  requires_compatibilities = ["FARGATE"]
  cpu                      = "256"
  memory                   = "512"
  execution_role_arn       = aws_iam_role.ecs_task_execution_role.arn

  container_definitions = jsonencode([
    {
      name      = "solana-balance-api"
      image     = "${aws_ecr_repository.app.repository_url}:latest"
      essential = true
      portMappings = [
        {
          containerPort = 8080
          hostPort      = 8080
          protocol      = "tcp"
        }
      ]
      secrets = [
        {
          name      = "DEV_DB_URL"
          valueFrom = aws_ssm_parameter.dev_db_url.arn
        },
        {
          name      = "MONGO_DB"
          valueFrom = aws_ssm_parameter.mongo_db.arn
        },
        {
          name      = "DEFAULT_API_KEY"
          valueFrom = aws_ssm_parameter.default_api_key.arn
        },
        {
          name      = "DISCORD_WEBHOOK_URL"
          valueFrom = aws_ssm_parameter.discord_webhook_url.arn
        },
        {
          name      = "PORT"
          valueFrom = aws_ssm_parameter.port.arn
        }
      ]
    }
  ])
}

# --------------------------
# ECS Service
# --------------------------
resource "aws_ecs_service" "app" {
  name            = var.ecs_service_name
  cluster         = aws_ecs_cluster.app.id
  task_definition = aws_ecs_task_definition.app.arn
  desired_count   = 1
  launch_type     = "FARGATE"

  network_configuration {
    subnets         = [aws_subnet.public.id]
    security_groups = [aws_security_group.ecs.id]
    assign_public_ip = true
  }
}
