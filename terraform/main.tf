# ---------------------------------------------------------------------------
# lnu-notes — the whole environment, as code.
#
#   terraform init      download the AWS provider
#   terraform plan      show what would change, before anything does
#   terraform apply     make reality match this file
#   terraform destroy   remove everything it created
#
# The real test of infrastructure as code is the last two in sequence:
# destroy, then apply, and the application comes back without you touching
# the console. If it does not, something exists that nobody wrote down.
# ---------------------------------------------------------------------------

terraform {
  required_version = ">= 1.6"
  required_providers {
    aws = { source = "hashicorp/aws", version = "~> 5.0" }
  }
}

provider "aws" {
  region = var.region
}

data "aws_caller_identity" "me" {}

# The current Ubuntu image, looked up rather than pasted. Image identifiers
# differ per region and change with every release.
data "aws_ssm_parameter" "ubuntu" {
  name = "/aws/service/canonical/ubuntu/server/24.04/stable/current/amd64/hvm/ebs-gp3/ami-id"
}

# ----------------------------------------------------------------- network
resource "aws_vpc" "main" {
  cidr_block           = "10.0.0.0/16"
  enable_dns_hostnames = true
  tags                 = { Name = var.project }
}

resource "aws_subnet" "public" {
  vpc_id                  = aws_vpc.main.id
  cidr_block              = "10.0.1.0/24"
  map_public_ip_on_launch = true
  tags                    = { Name = "${var.project}-public" }
}

resource "aws_internet_gateway" "gw" {
  vpc_id = aws_vpc.main.id
  tags   = { Name = var.project }
}

resource "aws_route_table" "public" {
  vpc_id = aws_vpc.main.id

  # Everything not inside the VPC goes out through the gateway.
  route {
    cidr_block = "0.0.0.0/0"
    gateway_id = aws_internet_gateway.gw.id
  }
  tags = { Name = "${var.project}-public" }
}

resource "aws_route_table_association" "public" {
  subnet_id      = aws_subnet.public.id
  route_table_id = aws_route_table.public.id
}

# --------------------------------------------------------- security groups
resource "aws_security_group" "web" {
  name        = "${var.project}-web"
  description = "web tier"
  vpc_id      = aws_vpc.main.id

  ingress {
    description = "HTTP from anywhere"
    from_port   = 80
    to_port     = 80
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  ingress {
    description = "SSH from one address only"
    from_port   = 22
    to_port     = 22
    protocol    = "tcp"
    cidr_blocks = [var.admin_cidr]
  }

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }
}

resource "aws_security_group" "db" {
  name        = "${var.project}-db"
  description = "database tier"
  vpc_id      = aws_vpc.main.id

  # The source is another security group, not an address. It names a role,
  # so it keeps working when the web instance is replaced.
  ingress {
    description     = "MySQL from the web tier only"
    from_port       = 3306
    to_port         = 3306
    protocol        = "tcp"
    security_groups = [aws_security_group.web.id]
  }

  # No SSH rule at all. Task 9 asks you to defend that choice.

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }
}

# ------------------------------------------------------------------ bucket
resource "aws_s3_bucket" "notes" {
  bucket        = "${var.project}-${data.aws_caller_identity.me.account_id}-notes"
  force_destroy = true # lab convenience: lets destroy remove a bucket with objects
}

# An account-level deny that no bucket policy can argue with.
resource "aws_s3_bucket_public_access_block" "notes" {
  bucket                  = aws_s3_bucket.notes.id
  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

resource "aws_s3_bucket_server_side_encryption_configuration" "notes" {
  bucket = aws_s3_bucket.notes.id
  rule {
    apply_server_side_encryption_by_default { sse_algorithm = "AES256" }
  }
}

# Versioning keeps the previous copy of an overwritten object — the part
# that makes a mistake survivable.
resource "aws_s3_bucket_versioning" "notes" {
  bucket = aws_s3_bucket.notes.id
  versioning_configuration { status = "Enabled" }
}

# ------------------------------------------------------------------ identity
resource "aws_iam_role" "web" {
  name = "${var.project}-web"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Service = "ec2.amazonaws.com" }
      Action    = "sts:AssumeRole"
    }]
  })
}

# Least privilege: one bucket, four actions, and only over TLS.
resource "aws_iam_role_policy" "web_s3" {
  name = "s3-notes"
  role = aws_iam_role.web.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid      = "ListOnlyThisBucket"
        Effect   = "Allow"
        Action   = ["s3:ListBucket"]
        Resource = aws_s3_bucket.notes.arn
      },
      {
        Sid      = "ReadWriteObjectsOverTLS"
        Effect   = "Allow"
        Action   = ["s3:GetObject", "s3:PutObject", "s3:DeleteObject"]
        Resource = "${aws_s3_bucket.notes.arn}/*"
        Condition = {
          Bool = { "aws:SecureTransport" = "true" }
        }
      }
    ]
  })
}

resource "aws_iam_instance_profile" "web" {
  name = "${var.project}-web"
  role = aws_iam_role.web.name
}

# ---------------------------------------------------------------- instances
resource "aws_instance" "db" {
  ami                         = data.aws_ssm_parameter.ubuntu.value
  instance_type               = var.instance_type
  subnet_id                   = aws_subnet.public.id
  vpc_security_group_ids      = [aws_security_group.db.id]
  associate_public_ip_address = false # no address on the internet at all
  key_name                    = var.key_name

  user_data = templatefile("${path.module}/cloud-config-db.yaml.tftpl", {
    db_pass = var.db_password
  })

  tags = { Name = "${var.project}-db" }
}

resource "aws_instance" "web" {
  ami                         = data.aws_ssm_parameter.ubuntu.value
  instance_type               = var.instance_type
  subnet_id                   = aws_subnet.public.id
  vpc_security_group_ids      = [aws_security_group.web.id]
  associate_public_ip_address = true
  key_name                    = var.key_name
  iam_instance_profile        = aws_iam_instance_profile.web.name

  # Referring to aws_instance.db.private_ip is what orders the two: the
  # database must exist before this file can be rendered.
  user_data = templatefile("${path.module}/cloud-config-web.yaml.tftpl", {
    db_host = aws_instance.db.private_ip
    db_pass = var.db_password
    bucket  = aws_s3_bucket.notes.id
    region  = var.region
    repo    = var.repo_url
  })

  tags = { Name = "${var.project}-web" }
}
