#!/bin/bash
# =============================================================================
# CAFE CLICKSTREAM SERVER BOOTSTRAP
# Runs as root on first boot via EC2 user_data.
# Terraform templatefile() substitutes: s3_bucket_name, aws_region
# =============================================================================

set -euo pipefail
exec > >(tee /var/log/user-data.log | logger -t user-data) 2>&1
echo "=== Bootstrap started at $(date) ==="

# -----------------------------------------------------------------------------
# STEP 1: Install Apache httpd and PHP
# -----------------------------------------------------------------------------
echo "--- Installing httpd and PHP ---"
yum update -y
yum install -y httpd php

# -----------------------------------------------------------------------------
# STEP 2: Install amazon-cloudwatch-agent
# -----------------------------------------------------------------------------
echo "--- Installing CloudWatch agent ---"
yum install -y amazon-cloudwatch-agent

# -----------------------------------------------------------------------------
# STEP 3: Create custom log directories
# -----------------------------------------------------------------------------
echo "--- Creating log directories ---"
mkdir -p /var/log/www/access
mkdir -p /var/log/www/error
chown -R apache:apache /var/log/www
chmod -R 755 /var/log/www

# -----------------------------------------------------------------------------
# STEP 4: Write CloudWatch agent configuration
# Collects access_log -> apache/access  (180-day retention)
# Collects error_log  -> apache/error   (180-day retention)
# -----------------------------------------------------------------------------
echo "--- Writing CloudWatch agent config ---"
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

# -----------------------------------------------------------------------------
# STEP 5: Patch httpd.conf
#   - Redirect ErrorLog to custom path
#   - Add JSON ErrorLogFormat
#   - Add JSON "cloudwatch" LogFormat
#   - Add CustomLog pointing to access path using the cloudwatch format
# -----------------------------------------------------------------------------
echo "--- Patching httpd.conf ---"
HTTPD_CONF="/etc/httpd/conf/httpd.conf"

# Backup original config
cp "$HTTPD_CONF" "$HTTPD_CONF.bak"

# Replace the default ErrorLog directive
sed -i 's|^ErrorLog.*|ErrorLog "/var/log/www/error/error_log"|' "$HTTPD_CONF"

# Remove any existing ErrorLogFormat lines to avoid duplicates
sed -i '/^ErrorLogFormat/d' "$HTTPD_CONF"

# Append JSON error log format and custom access log configuration
cat >> "$HTTPD_CONF" << 'HTTPDAPPEND'

# ---- Cafe Clickstream: JSON Logging Configuration ----

# JSON format for the error log
ErrorLogFormat "{\"time\":\"%{cu}t\",\"function\":\"[%-m:%l]\",\"process\":\"[pid %P]\",\"message\":\"%M\"}"

# JSON format for CloudWatch Logs Insights parsing
# Fields: time, process, filename, remoteIP, host, request, query, method,
#         status, userAgent, referer, city, region, country
LogFormat "{\"time\":\"%{%Y-%m-%dT%H:%M:%S%z}t\",\"process\":\"%D\",\"filename\":\"%f\",\"remoteIP\":\"%a\",\"host\":\"%V\",\"request\":\"%U\",\"query\":\"%q\",\"method\":\"%m\",\"status\":\"%>s\",\"userAgent\":\"%{User-Agent}i\",\"referer\":\"%{Referer}i\"}" cloudwatch

# Route access logs to the custom path using the cloudwatch JSON format
CustomLog "/var/log/www/access/access_log" cloudwatch
HTTPDAPPEND

# Comment out the default combined access log line to avoid dual-logging
sed -i 's|^CustomLog "logs/access_log" combined|#CustomLog "logs/access_log" combined|' "$HTTPD_CONF"

# Verify config syntax before proceeding
httpd -t
echo "--- httpd.conf syntax OK ---"

# -----------------------------------------------------------------------------
# STEP 6: Start and enable httpd
# -----------------------------------------------------------------------------
echo "--- Starting httpd ---"
systemctl start httpd
systemctl enable httpd
echo "--- httpd started and enabled ---"

# -----------------------------------------------------------------------------
# STEP 7: Start the CloudWatch agent
# -----------------------------------------------------------------------------
echo "--- Starting CloudWatch agent ---"
/opt/aws/amazon-cloudwatch-agent/bin/amazon-cloudwatch-agent-ctl \
  -a fetch-config \
  -m ec2 \
  -s \
  -c file:/opt/aws/amazon-cloudwatch-agent/bin/config.json

systemctl enable amazon-cloudwatch-agent
echo "--- CloudWatch agent started ---"

# -----------------------------------------------------------------------------
# OPTIONAL: Create a basic index page so HTTP health checks pass
# -----------------------------------------------------------------------------
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

# -----------------------------------------------------------------------------
# Log environment info for debugging
# -----------------------------------------------------------------------------
echo "=== Bootstrap complete at $(date) ==="
echo "Instance ID    : $(curl -s http://169.254.169.254/latest/meta-data/instance-id)"
echo "Public IP      : $(curl -s http://169.254.169.254/latest/meta-data/public-ipv4)"
echo "S3 Bucket      : ${s3_bucket_name}"
echo "AWS Region     : ${aws_region}"
echo "httpd status   : $(systemctl is-active httpd)"
echo "CWAgent status : $(systemctl is-active amazon-cloudwatch-agent)"
