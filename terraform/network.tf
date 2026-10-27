# ---------------------------------------------------------------------------
# Demo VPC: three subnets (one per AZ) hosting the PrivateLink endpoint and the
# client host. Subnets are public only so the client host can reach package
# repos and SSM without a NAT gateway; nothing accepts inbound traffic.
# ---------------------------------------------------------------------------

data "aws_availability_zones" "available" {
  state = "available"

  filter {
    name   = "opt-in-status"
    values = ["opt-in-not-required"]
  }
}

# Or bring your own VPC (e.g. when the account is at its VPC quota). The
# subnets need a route to the internet (IGW or NAT) for the client host.
data "aws_vpc" "existing" {
  count = local.create_vpc ? 0 : 1
  id    = var.existing_vpc_id
}

data "aws_subnet" "existing" {
  for_each = toset(var.existing_subnet_ids)
  id       = each.key
}

locals {
  create_vpc = var.existing_vpc_id == ""
  azs        = slice(data.aws_availability_zones.available.names, 0, 3)

  vpc_id     = local.create_vpc ? aws_vpc.demo[0].id : var.existing_vpc_id
  vpc_cidr   = local.create_vpc ? var.vpc_cidr : data.aws_vpc.existing[0].cidr_block
  subnet_ids = local.create_vpc ? [for s in aws_subnet.demo : s.id] : var.existing_subnet_ids

  # zone ID (e.g. euw2-az1) => zone name (e.g. eu-west-2c), for zonal DNS records
  az_ids = local.create_vpc ? zipmap(slice(data.aws_availability_zones.available.zone_ids, 0, 3), local.azs) : {
    for s in data.aws_subnet.existing : s.availability_zone_id => s.availability_zone
  }
}

resource "aws_vpc" "demo" {
  count                = local.create_vpc ? 1 : 0
  cidr_block           = var.vpc_cidr
  enable_dns_support   = true
  enable_dns_hostnames = true

  tags = { Name = local.name }
}

resource "aws_internet_gateway" "demo" {
  count  = local.create_vpc ? 1 : 0
  vpc_id = aws_vpc.demo[0].id
  tags   = { Name = local.name }
}

resource "aws_subnet" "demo" {
  for_each = local.create_vpc ? { for i, az in local.azs : az => i } : {}

  vpc_id                  = aws_vpc.demo[0].id
  availability_zone       = each.key
  cidr_block              = cidrsubnet(var.vpc_cidr, 8, each.value)
  map_public_ip_on_launch = true

  tags = { Name = "${local.name}-${each.key}" }
}

resource "aws_route_table" "demo" {
  count  = local.create_vpc ? 1 : 0
  vpc_id = aws_vpc.demo[0].id

  route {
    cidr_block = "0.0.0.0/0"
    gateway_id = aws_internet_gateway.demo[0].id
  }

  tags = { Name = local.name }
}

resource "aws_route_table_association" "demo" {
  for_each       = aws_subnet.demo
  subnet_id      = each.value.id
  route_table_id = aws_route_table.demo[0].id
}

# ---------------------------------------------------------------------------
# PrivateLink endpoint to the Confluent Cloud PrivateLink attachment
# ---------------------------------------------------------------------------

resource "aws_security_group" "privatelink" {
  name        = "${local.name}-privatelink"
  description = "Kafka (9092) and HTTPS (443) from the demo VPC to Confluent Cloud PrivateLink"
  vpc_id      = local.vpc_id

  dynamic "ingress" {
    for_each = [80, 443, 9092]
    content {
      from_port   = ingress.value
      to_port     = ingress.value
      protocol    = "tcp"
      cidr_blocks = [local.vpc_cidr]
    }
  }

  tags = { Name = "${local.name}-privatelink" }
}

resource "aws_vpc_endpoint" "confluent" {
  vpc_id              = local.vpc_id
  service_name        = confluent_private_link_attachment.demo.aws[0].vpc_endpoint_service_name
  vpc_endpoint_type   = "Interface"
  security_group_ids  = [aws_security_group.privatelink.id]
  subnet_ids          = local.subnet_ids
  private_dns_enabled = false

  tags = { Name = local.name }
}

# Private DNS so cluster hostnames resolve to the endpoint inside the VPC.
resource "aws_route53_zone" "confluent" {
  name = confluent_private_link_attachment.demo.dns_domain

  vpc {
    vpc_id = local.vpc_id
  }
}

locals {
  endpoint_dns    = aws_vpc_endpoint.confluent.dns_entry[0]["dns_name"]
  endpoint_prefix = split(".", local.endpoint_dns)[0]
}

resource "aws_route53_record" "confluent_wildcard" {
  zone_id = aws_route53_zone.confluent.zone_id
  name    = "*.${aws_route53_zone.confluent.name}"
  type    = "CNAME"
  ttl     = 60
  records = [local.endpoint_dns]
}

resource "aws_route53_record" "confluent_zonal" {
  for_each = local.az_ids

  zone_id = aws_route53_zone.confluent.zone_id
  name    = "*.${each.key}.${aws_route53_zone.confluent.name}"
  type    = "CNAME"
  ttl     = 60
  records = ["${local.endpoint_prefix}-${each.value}${replace(local.endpoint_dns, local.endpoint_prefix, "")}"]
}
