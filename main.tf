# Provider configuration
provider "aws" {
  region = "us-west-2"
}

# S3 buckets for source and destination
resource "aws_s3_bucket" "source_bucket" {
  bucket = "euanlimzx-source-video-bucket"
}

resource "aws_s3_bucket" "destination_bucket" {
  bucket = "euanlimzx-destination-video-bucket"
}

# S3 event bridge notification configuration
resource "aws_s3_bucket_notification" "bucket_notification" {
  bucket = aws_s3_bucket.source_bucket.id

  eventbridge = true
}

# IAM role for ECS task
resource "aws_iam_role" "video_processor_role" {
  name = "video-processor-role"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Action = "sts:AssumeRole"
        Effect = "Allow"
        Principal = {
          Service = "ecs-tasks.amazonaws.com"
        }
      }
    ]
  })
}

# IAM policy for S3 access
resource "aws_iam_policy" "s3_access_policy" {
  name        = "video-processor-s3-policy"
  description = "Policy for accessing S3 buckets for video processing"

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Action = [
          "s3:GetObject",
          "s3:ListBucket"
        ]
        Effect = "Allow"
        Resource = [
          aws_s3_bucket.source_bucket.arn,
          "${aws_s3_bucket.source_bucket.arn}/*"
        ]
      },
      {
        Action = [
          "s3:PutObject",
          "s3:ListBucket"
        ]
        Effect = "Allow"
        Resource = [
          aws_s3_bucket.destination_bucket.arn,
          "${aws_s3_bucket.destination_bucket.arn}/*"
        ]
      },
      {
      Action = [
        "s3:GetBucketNotification",
        "s3:PutBucketNotification"
      ]
      Effect = "Allow"
      Resource = aws_s3_bucket.source_bucket.arn
    }
    ]
  })
}

# Attach policy to role
resource "aws_iam_role_policy_attachment" "s3_policy_attachment" {
  role       = aws_iam_role.video_processor_role.name
  policy_arn = aws_iam_policy.s3_access_policy.arn
}

# IAM policy for ECR access
resource "aws_iam_policy" "ecr_access_policy" {
  name        = "ecr-access-policy"
  description = "Policy for pulling ECR images"

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Action = [
          "ecr:GetDownloadUrlForLayer",
          "ecr:BatchGetImage",
          "ecr:BatchCheckLayerAvailability"
        ]
        Effect   = "Allow"
        Resource = aws_ecr_repository.video_processor_repo.arn
      },
      {
        Action = [
          "ecr:GetAuthorizationToken"
        ]
        Effect   = "Allow"
        Resource = "*"
      }
    ]
  })
}

# Attach ECR policy to task execution role
resource "aws_iam_role_policy_attachment" "ecr_policy_attachment" {
  role       = aws_iam_role.video_processor_role.name
  policy_arn = aws_iam_policy.ecr_access_policy.arn
}

# IAM policy for CloudWatch Logs
resource "aws_iam_policy" "cloudwatch_logs_policy" {
  name        = "video-processor-logs-policy"
  description = "Policy for writing to CloudWatch Logs"

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Action = [
          "logs:CreateLogStream",
          "logs:PutLogEvents"
        ]
        Effect   = "Allow"
        Resource = "${aws_cloudwatch_log_group.video_processor_logs.arn}:*"
      }
    ]
  })
}

# Attach CloudWatch Logs policy to role
resource "aws_iam_role_policy_attachment" "logs_policy_attachment" {
  role       = aws_iam_role.video_processor_role.name
  policy_arn = aws_iam_policy.cloudwatch_logs_policy.arn
}

# ECR repository for Docker image
resource "aws_ecr_repository" "video_processor_repo" {
  name = "video-processor"
}

# ECS cluster
resource "aws_ecs_cluster" "video_processor_cluster" {
  name = "video-processor-cluster"
}

# ECS task definition
resource "aws_ecs_task_definition" "video_processor_task" {
  family                   = "video-processor"
  requires_compatibilities = ["FARGATE"]
  network_mode             = "awsvpc"
  cpu                      = "256"
  memory                   = "512"
  execution_role_arn       = aws_iam_role.video_processor_role.arn
  task_role_arn            = aws_iam_role.video_processor_role.arn

  container_definitions = jsonencode([
    {
      name      = "video-processor"
      image     = "${aws_ecr_repository.video_processor_repo.repository_url}:latest"
      essential = true
      environment = [
        {
          name  = "SOURCE_BUCKET"
          value = aws_s3_bucket.source_bucket.bucket
        },
        {
          name  = "DESTINATION_BUCKET"
          value = aws_s3_bucket.destination_bucket.bucket
        },
        {
          name  = "DEBUG",
          value = "true"
        },
        {
          name  = "VERBOSE_LOGGING",
          value = "true"
        }
      ]
      logConfiguration = {
        logDriver = "awslogs"
        options = {
          "awslogs-group"         = "/ecs/video-processor"
          "awslogs-region"        = "us-west-2"
          "awslogs-stream-prefix" = "ecs"
        }
      }
    }
  ])
}

# CloudWatch log group
resource "aws_cloudwatch_log_group" "video_processor_logs" {
  name              = "/ecs/video-processor"
  retention_in_days = 30
}

# EventBridge rule to trigger on S3 upload
resource "aws_cloudwatch_event_rule" "s3_upload_rule" {
  name        = "s3-video-upload-rule"
  description = "Trigger when a video is uploaded to the source bucket"

  event_pattern = jsonencode({
    source      = ["aws.s3"]
    detail-type = ["Object Created"]
    detail = {
      bucket = {
        name = [aws_s3_bucket.source_bucket.bucket]
      }
      object = {
        key = [{
          suffix = ".mp4"
          }, {
          suffix = ".avi"
          }, {
          suffix = ".mov"
          }, {
          suffix = ".mkv"
        }]
      }
    }
  })
}

# EventBridge target (ECS task)
resource "aws_cloudwatch_event_target" "ecs_task_target" {
  rule      = aws_cloudwatch_event_rule.s3_upload_rule.name
  target_id = "video-processor-target"
  arn       = aws_ecs_cluster.video_processor_cluster.arn
  role_arn  = aws_iam_role.event_bridge_execution_role.arn

  ecs_target {
    task_count          = 1
    task_definition_arn = aws_ecs_task_definition.video_processor_task.arn
    launch_type         = "FARGATE"

    network_configuration {
      subnets          = [aws_subnet.private.id]
      security_groups  = [aws_security_group.ecs_tasks.id]
      assign_public_ip = false
    }
    {
    containerOverrides = [
      {
        name = "name-of-container-to-override",
        environment = [
          {name: 'S3_BUCKET', value: "$.detail.bucket.name"},
          {name: 'S3_OBJECT_KEY', value: "$.detail.object.key"},
        ]
      }
    ]
  }
  }
}

# IAM role for EventBridge to invoke ECS
resource "aws_iam_role" "event_bridge_execution_role" {
  name = "event-bridge-execution-role"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Action = "sts:AssumeRole"
        Effect = "Allow"
        Principal = {
          Service = "events.amazonaws.com"
        }
      }
    ]
  })
}

# IAM policy for EventBridge to run ECS tasks
resource "aws_iam_policy" "event_bridge_execution_policy" {
  name        = "event-bridge-execution-policy"
  description = "Policy for EventBridge to run ECS tasks"

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Action = [
          "ecs:RunTask"
        ]
        Effect   = "Allow"
        Resource = aws_ecs_task_definition.video_processor_task.arn
      },
      {
        Action = [
          "iam:PassRole"
        ]
        Effect   = "Allow"
        Resource = "*"
        Condition = {
          StringLike = {
            "iam:PassedToService" = "ecs-tasks.amazonaws.com"
          }
        }
      }
    ]
  })
}

# Attach policy to role
resource "aws_iam_role_policy_attachment" "event_bridge_policy_attachment" {
  role       = aws_iam_role.event_bridge_execution_role.name
  policy_arn = aws_iam_policy.event_bridge_execution_policy.arn
}

# Basic VPC resources (required for Fargate)
resource "aws_vpc" "main" {
  cidr_block           = "10.0.0.0/16"
  enable_dns_support   = true
  enable_dns_hostnames = true

  tags = {
    Name = "video-processor-vpc"
  }
}

# Two private subnets in different AZs for high availability
resource "aws_subnet" "private" {
  vpc_id            = aws_vpc.main.id
  cidr_block        = "10.0.1.0/24"
  availability_zone = "us-west-2a"

  tags = {
    Name = "private-subnet-1"
  }
}

# Security group for ECS tasks
resource "aws_security_group" "ecs_tasks" {
  name        = "ecs-tasks-security-group"
  description = "Security group for ECS tasks"
  vpc_id      = aws_vpc.main.id

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = {
    Name = "ecs-tasks-sg"
  }
}

# Security group for VPC endpoints
resource "aws_security_group" "vpc_endpoints" {
  name        = "vpc-endpoints-security-group"
  description = "Security group for VPC endpoints"
  vpc_id      = aws_vpc.main.id

  ingress {
    from_port       = 443
    to_port         = 443
    protocol        = "tcp"
    security_groups = [aws_security_group.ecs_tasks.id]
  }

  tags = {
    Name = "vpc-endpoints-sg"
  }
}

# VPC Endpoint for ECR API
resource "aws_vpc_endpoint" "ecr_api" {
  vpc_id              = aws_vpc.main.id
  service_name        = "com.amazonaws.us-west-2.ecr.api"
  vpc_endpoint_type   = "Interface"
  subnet_ids          = [aws_subnet.private.id]
  security_group_ids  = [aws_security_group.vpc_endpoints.id]
  private_dns_enabled = true

  tags = {
    Name = "ecr-api-endpoint"
  }
}

# VPC Endpoint for ECR DKR (Docker Registry)
resource "aws_vpc_endpoint" "ecr_dkr" {
  vpc_id              = aws_vpc.main.id
  service_name        = "com.amazonaws.us-west-2.ecr.dkr"
  vpc_endpoint_type   = "Interface"
  subnet_ids          = [aws_subnet.private.id]
  security_group_ids  = [aws_security_group.vpc_endpoints.id]
  private_dns_enabled = true

  tags = {
    Name = "ecr-dkr-endpoint"
  }
}

# VPC Endpoint for S3
resource "aws_vpc_endpoint" "s3" {
  vpc_id            = aws_vpc.main.id
  service_name      = "com.amazonaws.us-west-2.s3"
  vpc_endpoint_type = "Gateway"
  route_table_ids   = [aws_route_table.private.id]

  tags = {
    Name = "s3-endpoint"
  }
}

# VPC Endpoint for CloudWatch Logs
resource "aws_vpc_endpoint" "logs" {
  vpc_id              = aws_vpc.main.id
  service_name        = "com.amazonaws.us-west-2.logs"
  vpc_endpoint_type   = "Interface"
  subnet_ids          = [aws_subnet.private.id]
  security_group_ids  = [aws_security_group.vpc_endpoints.id]
  private_dns_enabled = true

  tags = {
    Name = "logs-endpoint"
  }
}

# VPC Endpoint for EventBridge
resource "aws_vpc_endpoint" "events" {
  vpc_id              = aws_vpc.main.id
  service_name        = "com.amazonaws.us-west-2.events"
  vpc_endpoint_type   = "Interface"
  subnet_ids          = [aws_subnet.private.id]
  security_group_ids  = [aws_security_group.vpc_endpoints.id]
  private_dns_enabled = true

  tags = {
    Name = "events-endpoint"
  }
}

# Route table for private subnets
resource "aws_route_table" "private" {
  vpc_id = aws_vpc.main.id

  tags = {
    Name = "private-route-table"
  }
}

# Route table association for private subnet
resource "aws_route_table_association" "private" {
  subnet_id      = aws_subnet.private.id
  route_table_id = aws_route_table.private.id
}