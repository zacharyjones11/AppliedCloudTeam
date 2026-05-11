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
