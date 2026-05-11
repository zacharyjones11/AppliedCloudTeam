/*
################################################################################
# CAFE CLICKSTREAM DATA PIPELINE - ALL-IN-ONE TERRAFORM SCRIPT
################################################################################
#
# HOW TO USE
# ----------
# 1. Make sure AWS credentials are configured:
#       aws configure
#
# 2. Edit the variables block at the top of this file:
#       your_ip_cidr = "YOUR.PUBLIC.IP/32"
#       (find your IP: curl -s https://checkip.amazonaws.com)
#
# 3. Run:
#       terraform init
#       terraform plan
#       terraform apply
#
# 4. After apply, note the printed outputs:
#       ec2_public_ip            - SSH / SSM target
#       s3_bucket_name           - log archival bucket
#       cloudwatch_dashboard_url - analytics dashboard link
#
# AFTER APPLY (manual steps)
# --------------------------
# a) Wait ~90 seconds for EC2 bootstrap to finish.
# b) Connect via SSM (no key pair needed - IAM role handles auth):
#       aws ssm start-session --target <instance-id>
# c) Drop in your sample geo log:
#       sudo cp access_log_geo.log /var/log/www/access/access_log
# d) Open the dashboard URL from outputs. Allow 1-2 min for data to appear.
#
# TEARDOWN
# --------
#   terraform destroy
#   (Empty the S3 bucket first if it contains objects)
#
################################################################################
*/

###############################################################################
# TERRAFORM + PROVIDER
###############################################################################

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
# VARIABLES  -  edit these before running
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
  description = "Your public IP in CIDR notation (e.g. 203.0.113.5/32). Used to restrict SSH access."
  type        = string
  default     = "0.0.0.0/0" # Replace with your IP for security
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
  tags = { Name = "cafe-clickstream-vpc", Project = "cafe-clickstream" }
}

resource "aws_subnet" "cafe_public" {
  vpc_id                  = aws_vpc.cafe_vpc.id
  cidr_block              = "10.0.1.0/24"
  availability_zone       = "${var.aws_region}a"
  map_public_ip_on_launch = true
  tags = { Name = "cafe-public-subnet", Project = "cafe-clickstream" }
}

resource "aws_internet_gateway" "cafe_igw" {
  vpc_id = aws_vpc.cafe_vpc.id
  tags   = { Name = "cafe-igw", Project = "cafe-clickstream" }
}

resource "aws_route_table" "cafe_public_rt" {
  vpc_id = aws_vpc.cafe_vpc.id
  route {
    cidr_block = "0.0.0.0/0"
    gateway_id = aws_internet_gateway.cafe_igw.id
  }
  tags = { Name = "cafe-public-rt", Project = "cafe-clickstream" }
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

  tags = { Name = "cafe-clickstream-sg", Project = "cafe-clickstream" }
}

###############################################################################
# IAM ROLE + POLICIES + INSTANCE PROFILE
###############################################################################

data "aws_iam_policy_document" "ec2_assume_role" {
  statement {
    sid     = "AllowEC2AssumeRole"
    effect  = "Allow"
    actions = ["sts:AssumeRole"]
    principals {
      type        = "Service"
      identifiers = ["ec2.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "cafe_ec2_role" {
  name               = "cafe-clickstream-ec2-role"
  assume_role_policy = data.aws_iam_policy_document.ec2_assume_role.json
  description        = "Role for cafe clickstream EC2 - grants CloudWatch, SSM, and S3 access."
  tags               = { Project = "cafe-clickstream" }
}

resource "aws_iam_role_policy_attachment" "cloudwatch_agent" {
  role       = aws_iam_role.cafe_ec2_role.name
  policy_arn = "arn:aws:iam::aws:policy/CloudWatchAgentServerPolicy"
}

resource "aws_iam_role_policy_attachment" "ssm_managed" {
  role       = aws_iam_role.cafe_ec2_role.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore"
}

resource "aws_iam_role_policy_attachment" "s3_full_access" {
  role       = aws_iam_role.cafe_ec2_role.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonS3FullAccess"
}

resource "aws_iam_instance_profile" "cafe_profile" {
  name = "cafe-clickstream-instance-profile"
  role = aws_iam_role.cafe_ec2_role.name
  tags = { Project = "cafe-clickstream" }
}

###############################################################################
# EC2 INSTANCE
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

resource "aws_instance" "cafe_server" {
  ami                    = data.aws_ami.amazon_linux_2.id
  instance_type          = var.instance_type
  subnet_id              = aws_subnet.cafe_public.id
  vpc_security_group_ids = [aws_security_group.cafe_sg.id]
  iam_instance_profile   = aws_iam_instance_profile.cafe_profile.name

  depends_on = [
    aws_iam_instance_profile.cafe_profile,
    aws_cloudwatch_log_group.apache_access,
    aws_cloudwatch_log_group.apache_error,
  ]

  # --------------------------------------------------------------------------
  # USER DATA - full bootstrap script inlined
  # --------------------------------------------------------------------------
  user_data = <<-USERDATA
    #!/bin/bash
    set -euo pipefail
    exec > >(tee /var/log/user-data.log | logger -t user-data) 2>&1
    echo "=== Bootstrap started at $(date) ==="

    # -- Step 1: Install Apache httpd and PHP --
    yum update -y
    yum install -y httpd php

    # -- Step 2: Install CloudWatch agent --
    yum install -y amazon-cloudwatch-agent

    # -- Step 3: Create custom log directories --
    mkdir -p /var/log/www/access
    mkdir -p /var/log/www/error
    chown -R apache:apache /var/log/www
    chmod -R 755 /var/log/www

    # -- Step 4: Write CloudWatch agent config --
    cat > /opt/aws/amazon-cloudwatch-agent/bin/config.json << 'CWCONFIG'
    {
      "agent": {
        "metrics_collection_interval": 60,
        "run_as_user": "root"
      },
      "logs": {
        "logs_collected": {
          "files": {
            "collect_list": [
              {
                "file_path": "/var/log/www/access/access_log",
                "log_group_name": "apache/access",
                "log_stream_name": "{instance_id}/access_log",
                "timezone": "UTC",
                "retention_in_days": 180,
                "multi_line_start_pattern": "\\{"
              },
              {
                "file_path": "/var/log/www/error/error_log",
                "log_group_name": "apache/error",
                "log_stream_name": "{instance_id}/error_log",
                "timezone": "UTC",
                "retention_in_days": 180
              }
            ]
          }
        },
        "log_stream_name": "cafe-clickstream-default"
      }
    }
    CWCONFIG

    # -- Step 5: Patch httpd.conf with JSON logging --
    HTTPD_CONF="/etc/httpd/conf/httpd.conf"
    cp "$HTTPD_CONF" "$HTTPD_CONF.bak"

    sed -i 's|^ErrorLog.*|ErrorLog "/var/log/www/error/error_log"|' "$HTTPD_CONF"
    sed -i '/^ErrorLogFormat/d' "$HTTPD_CONF"
    sed -i 's|^CustomLog "logs/access_log" combined|#CustomLog "logs/access_log" combined|' "$HTTPD_CONF"

    cat >> "$HTTPD_CONF" << 'HTTPDAPPEND'
    # ---- Cafe Clickstream: JSON Logging ----
    ErrorLogFormat "{\"time\":\"%{cu}t\",\"function\":\"[%-m:%l]\",\"process\":\"[pid %P]\",\"message\":\"%M\"}"

    LogFormat "{\"time\":\"%{%Y-%m-%dT%H:%M:%S%z}t\",\"process\":\"%D\",\"filename\":\"%f\",\"remoteIP\":\"%a\",\"host\":\"%V\",\"request\":\"%U\",\"query\":\"%q\",\"method\":\"%m\",\"status\":\"%>s\",\"userAgent\":\"%{User-Agent}i\",\"referer\":\"%{Referer}i\"}" cloudwatch

    CustomLog "/var/log/www/access/access_log" cloudwatch
    HTTPDAPPEND

    httpd -t
    echo "--- httpd.conf syntax OK ---"

    # -- Step 6: Start and enable httpd --
    systemctl start httpd
    systemctl enable httpd

    # -- Step 7: Start CloudWatch agent --
    /opt/aws/amazon-cloudwatch-agent/bin/amazon-cloudwatch-agent-ctl \
      -a fetch-config \
      -m ec2 \
      -s \
      -c file:/opt/aws/amazon-cloudwatch-agent/bin/config.json

    systemctl enable amazon-cloudwatch-agent

    # -- Basic index page --
    cat > /var/www/html/index.html << 'INDEXHTML'
    <!DOCTYPE html>
    <html lang="en">
    <head><meta charset="UTF-8"><title>Cafe Clickstream Server</title></head>
    <body>
      <h1>Cafe Clickstream Analytics Server</h1>
      <p>Apache + CloudWatch Agent running. Drop access_log_geo.log into
         /var/log/www/access/access_log to begin ingesting clickstream data.</p>
    </body>
    </html>
    INDEXHTML

    echo "=== Bootstrap complete at $(date) ==="
    echo "httpd status   : $(systemctl is-active httpd)"
    echo "CWAgent status : $(systemctl is-active amazon-cloudwatch-agent)"
  USERDATA

  tags = { Name = "cafe-clickstream-server", Project = "cafe-clickstream" }
}

###############################################################################
# S3 BUCKET
###############################################################################

resource "aws_s3_bucket" "cafe_logs" {
  bucket = "cafe-clickstream-logs-${random_id.bucket_suffix.hex}"
  tags   = { Name = "cafe-clickstream-logs", Project = "cafe-clickstream" }
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
  tags              = { Project = "cafe-clickstream" }
}

resource "aws_cloudwatch_log_group" "apache_error" {
  name              = "apache/error"
  retention_in_days = 180
  tags              = { Project = "cafe-clickstream" }
}

###############################################################################
# CLOUDWATCH DASHBOARD
###############################################################################

resource "aws_cloudwatch_dashboard" "cafe_dashboard" {
  dashboard_name = "cafe-dashboard"

  dashboard_body = jsonencode({
    widgets = [
      {
        type   = "log"
        x      = 0
        y      = 0
        width  = 12
        height = 6
        properties = {
          title         = "Top 10 Cities - /cafe/menu.php Visitors"
          view          = "pie"
          region        = var.aws_region
          period        = 86400
          logGroupNames = ["apache/access"]
          query         = "fields @timestamp, city, request | filter request like /\\/cafe\\/menu\\.php/ | stats count(*) as visits by city | sort visits desc | limit 10"
        }
      },
      {
        type   = "log"
        x      = 12
        y      = 0
        width  = 12
        height = 6
        properties = {
          title         = "Top 10 Cities - /cafe/processOrder.php Orders"
          view          = "table"
          region        = var.aws_region
          period        = 86400
          logGroupNames = ["apache/access"]
          query         = "fields @timestamp, city, request | filter request like /\\/cafe\\/processOrder\\.php/ | stats count(*) as orders by city | sort orders desc | limit 10"
        }
      },
      {
        type   = "log"
        x      = 0
        y      = 6
        width  = 12
        height = 6
        properties = {
          title         = "Top 10 Regions - /cafe Visitors"
          view          = "pie"
          region        = var.aws_region
          period        = 86400
          logGroupNames = ["apache/access"]
          query         = "fields @timestamp, region, request | filter request like /\\/cafe/ | stats count(*) as visits by region | sort visits desc | limit 10"
        }
      },
      {
        type   = "log"
        x      = 12
        y      = 6
        width  = 12
        height = 6
        properties = {
          title         = "Top 10 Regions - /cafe/processOrder.php Orders"
          view          = "bar"
          region        = var.aws_region
          period        = 86400
          logGroupNames = ["apache/access"]
          query         = "fields @timestamp, region, request | filter request like /\\/cafe\\/processOrder\\.php/ | stats count(*) as orders by region | sort orders desc | limit 10"
        }
      }
    ]
  })
}

###############################################################################
# OUTPUTS
###############################################################################

output "ec2_public_ip" {
  description = "Public IP address of the cafe web server EC2 instance."
  value       = aws_instance.cafe_server.public_ip
}

output "s3_bucket_name" {
  description = "Name of the S3 bucket used for clickstream log archival."
  value       = aws_s3_bucket.cafe_logs.bucket
}

output "cloudwatch_dashboard_url" {
  description = "Direct URL to the cafe CloudWatch analytics dashboard."
  value       = "https://${var.aws_region}.console.aws.amazon.com/cloudwatch/home?region=${var.aws_region}#dashboards:name=cafe-dashboard"
}
