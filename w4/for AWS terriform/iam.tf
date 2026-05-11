###############################################################################
# IAM ROLE, POLICIES, AND INSTANCE PROFILE
###############################################################################

# Trust policy - allows EC2 service to assume this role
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
  description        = "Role for the cafe clickstream EC2 instance - grants CloudWatch, SSM, and S3 access."

  tags = {
    Project = "cafe-clickstream"
  }
}

# Attach AWS managed policies
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

# Instance profile wrapping the role - referenced by the EC2 resource
resource "aws_iam_instance_profile" "cafe_profile" {
  name = "cafe-clickstream-instance-profile"
  role = aws_iam_role.cafe_ec2_role.name

  tags = {
    Project = "cafe-clickstream"
  }
}
