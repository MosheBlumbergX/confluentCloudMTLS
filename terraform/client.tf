# ---------------------------------------------------------------------------
# Client host: an EC2 instance inside the VPC that runs the demo clients.
# Access is through SSM (no SSH key, no inbound ports). Client keystores are
# pushed to it through the S3 bucket by scripts/remote.sh; CA keys never
# leave your machine.
# ---------------------------------------------------------------------------

data "aws_ssm_parameter" "al2023" {
  name = "/aws/service/ami-amazon-linux-latest/al2023-ami-kernel-default-x86_64"
}

resource "aws_s3_bucket" "bundle" {
  bucket        = "${local.name}-bundle"
  force_destroy = true
}

resource "aws_s3_bucket_public_access_block" "bundle" {
  bucket                  = aws_s3_bucket.bundle.id
  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

resource "aws_iam_role" "client" {
  name = "${local.name}-client"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Service = "ec2.amazonaws.com" }
      Action    = "sts:AssumeRole"
    }]
  })
}

resource "aws_iam_role_policy_attachment" "client_ssm" {
  role       = aws_iam_role.client.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore"
}

resource "aws_iam_role_policy" "client_bundle" {
  name = "read-demo-bundle"
  role = aws_iam_role.client.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect   = "Allow"
      Action   = ["s3:GetObject"]
      Resource = "${aws_s3_bucket.bundle.arn}/*"
    }]
  })
}

resource "aws_iam_instance_profile" "client" {
  name = "${local.name}-client"
  role = aws_iam_role.client.name
}

resource "aws_security_group" "client" {
  name        = "${local.name}-client"
  description = "Demo client host: egress only"
  vpc_id      = local.vpc_id

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = { Name = "${local.name}-client" }
}

resource "aws_instance" "client" {
  ami                         = data.aws_ssm_parameter.al2023.value
  instance_type               = var.client_instance_type
  subnet_id                   = local.subnet_ids[0]
  associate_public_ip_address = true
  vpc_security_group_ids      = [aws_security_group.client.id]
  iam_instance_profile        = aws_iam_instance_profile.client.name

  metadata_options {
    http_tokens = "required"
  }

  root_block_device {
    volume_size = 20
    volume_type = "gp3"
    encrypted   = true
    tags        = merge(var.aws_tags, { Name = "${local.name}-client" })
  }

  user_data = templatefile("${path.module}/client-user-data.sh.tftpl", {
    kafka_version = var.kafka_cli_version
  })

  tags = { Name = "${local.name}-client" }

  # user_data only runs at first boot, so changing it later has no effect on
  # a running host; don't let it trigger a stop/start.
  lifecycle {
    ignore_changes = [ami, user_data]
  }
}
