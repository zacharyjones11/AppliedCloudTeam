/*
################################################################################
# CAFE CLICKSTREAM DATA PIPELINE - TERRAFORM INFRASTRUCTURE
################################################################################
#
# README / APPLY GUIDE
# --------------------
# This configuration provisions a full clickstream analytics pipeline for a
# cafe website. It creates:
#   - VPC / subnet / IGW / routing / security group
#   - EC2 (Amazon Linux 2, t3.micro) with Apache + CloudWatch Agent auto-configured
#   - IAM role + instance profile (CloudWatch, SSM, S3 permissions)
#   - S3 bucket for log archival (versioned, private)
#   - CloudWatch Log Groups (apache/access, apache/error)
#   - CloudWatch Dashboard with four analytics widgets
#
# APPLY ORDER
# -----------
# 1. Ensure your AWS credentials are configured (env vars, ~/.aws/credentials,
#    or an assumed role). No account IDs or secrets are hardcoded.
# 2. Copy terraform.tfvars.example to terraform.tfvars and set your_ip_cidr
#    to your public CIDR (e.g. "203.0.113.5/32") for SSH access.
# 3. Run:
#       terraform init
#       terraform plan
#       terraform apply
# 4. After apply completes, note the outputs:
#       ec2_public_ip            - SSH target
#       s3_bucket_name           - bucket for log archival
#       cloudwatch_dashboard_url - direct link to the dashboard
#
# MANUAL POST-STEPS
# -----------------
# a) Wait ~90 seconds for the EC2 user_data bootstrap to finish.
# b) SSH into the instance:
#       ssh -i <your-key>.pem ec2-user@<ec2_public_ip>
# c) Drop in the sample geo-enriched access log:
#       sudo cp access_log_geo.log /var/log/www/access/access_log
# d) The CloudWatch agent will pick up new log lines automatically.
#    Dashboard widgets run CloudWatch Logs Insights queries; allow 1-2 min
#    for data to appear after log ingestion.
# e) (Optional) Upload raw logs to S3:
#       aws s3 cp access_log_geo.log s3://<s3_bucket_name>/raw/
#
# TEARDOWN
# --------
#   terraform destroy
#   (S3 bucket must be emptied manually before destroy if versioning has
#    created delete markers - or add a force_destroy = true to the bucket
#    resource for lab environments.)
#
################################################################################
*/

terraform {
  required_version = ">= 1.5"
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = ">= 5.0"
    }
    random = {
      source  = "hashicorp/random"
      version = ">= 3.5"
    }
  }
}

provider "aws" {
  region = var.aws_region
}

###############################################################################
# RANDOM SUFFIX for globally-unique S3 bucket name
###############################################################################
resource "random_id" "bucket_suffix" {
  byte_length = 4
}

###############################################################################
# NETWORKING
###############################################################################

resource "aws_vpc" "cafe_vpc" {
  cidr_block           = "10.0.0.0/16"
  enable_dns_support   = true
  enable_dns_hostnames = true

  tags = {
    Name    = "cafe-clickstream-vpc"
    Project = "cafe-clickstream"
  }
}

resource "aws_subnet" "cafe_public" {
  vpc_id                  = aws_vpc.cafe_vpc.id
  cidr_block              = "10.0.1.0/24"
  availability_zone       = "${var.aws_region}a"
  map_public_ip_on_launch = true

  tags = {
    Name    = "cafe-public-subnet"
    Project = "cafe-clickstream"
  }
}

resource "aws_internet_gateway" "cafe_igw" {
  vpc_id = aws_vpc.cafe_vpc.id

  tags = {
    Name    = "cafe-igw"
    Project = "cafe-clickstream"
  }
}

resource "aws_route_table" "cafe_public_rt" {
  vpc_id = aws_vpc.cafe_vpc.id

  route {
    cidr_block = "0.0.0.0/0"
    gateway_id = aws_internet_gateway.cafe_igw.id
  }

  tags = {
    Name    = "cafe-public-rt"
    Project = "cafe-clickstream"
  }
}

resource "aws_route_table_association" "cafe_public_rta" {
  subnet_id      = aws_subnet.cafe_public.id
  route_table_id = aws_route_table.cafe_public_rt.id
}

###############################################################################
# SECURITY GROUP
###############################################################################

resource "aws_security_group" "cafe_sg" {
  name        = "cafe-clickstream-sg"
  description = "Allow HTTP (80) and SSH (22) inbound; all outbound"
  vpc_id      = aws_vpc.cafe_vpc.id

  ingress {
    description = "HTTP from anywhere"
    from_port   = 80
    to_port     = 80
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  ingress {
    description = "SSH from operator IP"
    from_port   = 22
    to_port     = 22
    protocol    = "tcp"
    cidr_blocks = [var.your_ip_cidr]
  }

  egress {
    description = "All outbound"
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = {
    Name    = "cafe-clickstream-sg"
    Project = "cafe-clickstream"
  }
}

###############################################################################
# DATA SOURCES
###############################################################################

data "aws_ami" "amazon_linux_2" {
  most_recent = true
  owners      = ["amazon"]

  filter {
    name   = "name"
    values = ["amzn2-ami-hvm-*-x86_64-gp2"]
  }

  filter {
    name   = "virtualization-type"
    values = ["hvm"]
  }
}

###############################################################################
# EC2 INSTANCE
###############################################################################

resource "aws_instance" "cafe_server" {
  ami                    = data.aws_ami.amazon_linux_2.id
  instance_type          = var.instance_type
  subnet_id              = aws_subnet.cafe_public.id
  vpc_security_group_ids = [aws_security_group.cafe_sg.id]
  iam_instance_profile   = aws_iam_instance_profile.cafe_profile.name

  user_data = templatefile("${path.module}/userdata.sh", {
    s3_bucket_name = aws_s3_bucket.cafe_logs.bucket
    aws_region     = var.aws_region
  })

  # Ensure IAM profile exists before the instance launches so the agent
  # can authenticate on first boot.
  depends_on = [
    aws_iam_instance_profile.cafe_profile,
    aws_cloudwatch_log_group.apache_access,
    aws_cloudwatch_log_group.apache_error,
  ]

  tags = {
    Name    = "cafe-clickstream-server"
    Project = "cafe-clickstream"
  }
}

###############################################################################
# S3 BUCKET
###############################################################################

resource "aws_s3_bucket" "cafe_logs" {
  bucket = "cafe-clickstream-logs-${random_id.bucket_suffix.hex}"

  tags = {
    Name    = "cafe-clickstream-logs"
    Project = "cafe-clickstream"
  }
}

resource "aws_s3_bucket_versioning" "cafe_logs_versioning" {
  bucket = aws_s3_bucket.cafe_logs.id
  versioning_configuration {
    status = "Enabled"
  }
}

resource "aws_s3_bucket_public_access_block" "cafe_logs_block" {
  bucket                  = aws_s3_bucket.cafe_logs.id
  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

###############################################################################
# CLOUDWATCH LOG GROUPS
###############################################################################

resource "aws_cloudwatch_log_group" "apache_access" {
  name              = "apache/access"
  retention_in_days = 180

  tags = {
    Project = "cafe-clickstream"
  }
}

resource "aws_cloudwatch_log_group" "apache_error" {
  name              = "apache/error"
  retention_in_days = 180

  tags = {
    Project = "cafe-clickstream"
  }
}

###############################################################################
# CLOUDWATCH DASHBOARD
###############################################################################

resource "aws_cloudwatch_dashboard" "cafe_dashboard" {
  dashboard_name = "cafe-dashboard"

  dashboard_body = jsonencode({
    widgets = [
      # -----------------------------------------------------------------------
      # Widget 1: Pie chart - Top 10 cities visiting /cafe/menu.php
      # -----------------------------------------------------------------------
      {
        type   = "log"
        x      = 0
        y      = 0
        width  = 12
        height = 6
        properties = {
          title   = "Top 10 Cities - /cafe/menu.php Visitors"
          view    = "pie"
          region  = var.aws_region
          period  = 86400
          logGroupNames = ["apache/access"]
          query = <<-EOQ
            fields @timestamp, city, request
            | filter request like /\/cafe\/menu\.php/
            | stats count(*) as visits by city
            | sort visits desc
            | limit 10
          EOQ
        }
      },

      # -----------------------------------------------------------------------
      # Widget 2: Logs table - Top 10 cities ordering via processOrder.php
      # -----------------------------------------------------------------------
      {
        type   = "log"
        x      = 12
        y      = 0
        width  = 12
        height = 6
        properties = {
          title   = "Top 10 Cities - /cafe/processOrder.php Orders"
          view    = "table"
          region  = var.aws_region
          period  = 86400
          logGroupNames = ["apache/access"]
          query = <<-EOQ
            fields @timestamp, city, request
            | filter request like /\/cafe\/processOrder\.php/
            | stats count(*) as orders by city
            | sort orders desc
            | limit 10
          EOQ
        }
      },

      # -----------------------------------------------------------------------
      # Widget 3: Pie chart - Top 10 regions visiting /cafe
      # -----------------------------------------------------------------------
      {
        type   = "log"
        x      = 0
        y      = 6
        width  = 12
        height = 6
        properties = {
          title   = "Top 10 Regions - /cafe Visitors"
          view    = "pie"
          region  = var.aws_region
          period  = 86400
          logGroupNames = ["apache/access"]
          query = <<-EOQ
            fields @timestamp, region, request
            | filter request like /\/cafe/
            | stats count(*) as visits by region
            | sort visits desc
            | limit 10
          EOQ
        }
      },

      # -----------------------------------------------------------------------
      # Widget 4: Bar chart - Top 10 regions ordering via processOrder.php
      # -----------------------------------------------------------------------
      {
        type   = "log"
        x      = 12
        y      = 6
        width  = 12
        height = 6
        properties = {
          title   = "Top 10 Regions - /cafe/processOrder.php Orders"
          view    = "bar"
          region  = var.aws_region
          period  = 86400
          logGroupNames = ["apache/access"]
          query = <<-EOQ
            fields @timestamp, region, request
            | filter request like /\/cafe\/processOrder\.php/
            | stats count(*) as orders by region
            | sort orders desc
            | limit 10
          EOQ
        }
      }
    ]
  })
}
