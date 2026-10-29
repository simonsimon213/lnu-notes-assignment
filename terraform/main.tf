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
    aws    = { source = "hashicorp/aws", version = "~> 5.0" }
    random = { source = "hashicorp/random", version = "~> 3.6" }
  }
}

provider "aws" {
  region = var.region
}

data "aws_caller_identity" "me" {}

# The database password, generated rather than typed. Its result is stored in
# terraform.tfstate in clear text — open the file and look. That is task 16.


data "aws_availability_zones" "here" {
  state = "available"
}

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
  availability_zone       = data.aws_availability_zones.here.names[0]
  map_public_ip_on_launch = true
  tags                    = { Name = "${var.project}-public" }
}

# The database lives here. No route to the internet gateway, so nothing on the
# internet can reach it — and it has no public address to reach.
resource "aws_subnet" "private" {
  vpc_id            = aws_vpc.main.id
  cidr_block        = "10.0.2.0/24"
  availability_zone = data.aws_availability_zones.here.names[0]
  tags              = { Name = "${var.project}-private" }
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

# An internet gateway only serves instances that have a public address. The
# database deliberately has none, so without this it cannot download MariaDB
# at first boot. A NAT gateway lets the private subnet start connections out
# (apt, updates) while still refusing every connection that starts outside.
#
# Cost: about $0.045 an hour plus its address, billed while it exists.
# terraform destroy removes it. Do not leave it running between sessions.
resource "aws_eip" "nat" {
  domain = "vpc"
  tags   = { Name = "${var.project}-nat" }
}

resource "aws_nat_gateway" "nat" {
  allocation_id = aws_eip.nat.id
  subnet_id     = aws_subnet.public.id # the NAT itself must sit in the public subnet
  tags          = { Name = var.project }
  depends_on    = [aws_internet_gateway.gw]
}

resource "aws_route_table" "private" {
  vpc_id = aws_vpc.main.id
  route {
    cidr_block     = "0.0.0.0/0"
    nat_gateway_id = aws_nat_gateway.nat.id
  }
  tags = { Name = "${var.project}-private" }
}

resource "aws_route_table_association" "private" {
  subnet_id      = aws_subnet.private.id
  route_table_id = aws_route_table.private.id
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

# "The web instance may read and write the bucket; your laptop may not."
# An IAM policy can only GRANT. You are an administrator, so to keep even you
# out, the bucket itself must DENY everyone except the web role. Deny beats
# every allow — including AdministratorAccess. Bucket settings and deletion are
# not covered, so Terraform can still manage and destroy it.
resource "aws_s3_bucket_policy" "notes" {
  bucket = aws_s3_bucket.notes.id
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Sid       = "OnlyTheWebRoleReadsAndWritesObjects"
      Effect    = "Deny"
      Principal = "*"
      Action    = ["s3:GetObject", "s3:PutObject"]
      Resource  = "${aws_s3_bucket.notes.arn}/*"
      Condition = { ArnNotEquals = { "aws:PrincipalArn" = aws_iam_role.web.arn } }
    }]
  })
  # Block Public Access must be in place first, or it may reject the policy call.
  depends_on = [aws_s3_bucket_public_access_block.notes]
}

resource "aws_iam_instance_profile" "web" {
  name = "${var.project}-web"
  role = aws_iam_role.web.name
}

# ---------------------------------------------------------------- instances
resource "aws_instance" "db" {
  ami                         = data.aws_ssm_parameter.ubuntu.value
  instance_type               = var.instance_type
  subnet_id                   = aws_subnet.private.id
  vpc_security_group_ids      = [aws_security_group.db.id]
  associate_public_ip_address = false # no address on the internet at all
  key_name                    = var.key_name
  

  # cloud-init only runs on first boot. Without this, changing the user data
  # updates the instance in place and the new script never executes — task 16
  # would look finished while nothing actually read from SSM.
  user_data_replace_on_change = true
  user_data = templatefile("${path.module}/cloud-config-db.yaml.tftpl", {
    region = var.region
  })

  # Nothing in this block refers to the NAT route, so Terraform would happily
  # boot the instance before the route exists — and apt would fail. This makes
  # the ordering explicit.
  depends_on = [aws_route_table_association.private]

  # A new Ubuntu image every week or two would otherwise make every later plan
  # offer to replace both instances, which hides the change you actually made.
  lifecycle {
    ignore_changes = [ami]
  }

  tags = { Name = "${var.project}-db" }

  iam_instance_profile = aws_iam_instance_profile.db.name
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
  user_data_replace_on_change = true
  user_data = templatefile("${path.module}/cloud-config-web.yaml.tftpl", {
    db_host = aws_instance.db.private_ip
  # db_pass = random_password.db.result
    bucket  = aws_s3_bucket.notes.id
    region  = var.region
    repo    = var.repo_url
  })

  lifecycle {
    ignore_changes = [ami]
  }

  tags = { Name = "${var.project}-web" }
}
