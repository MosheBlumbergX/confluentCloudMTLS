resource "random_id" "suffix" {
  byte_length = 3
}

locals {
  name        = "${var.name_prefix}-${random_id.suffix.hex}"
  description = "mTLS demo, owner=${var.owner}, keep_until=${var.keep_until}"
  cluster     = confluent_kafka_cluster.demo
  bootstrap   = replace(confluent_kafka_cluster.demo.bootstrap_endpoint, "SASL_SSL://", "")
}

# ---------------------------------------------------------------------------
# Environment and Enterprise cluster
# ---------------------------------------------------------------------------

resource "confluent_environment" "demo" {
  display_name = local.name

  stream_governance {
    package = "ESSENTIALS"
  }
}

resource "confluent_kafka_cluster" "demo" {
  display_name = local.name
  availability = var.availability
  cloud        = "AWS"
  region       = var.region

  enterprise {}

  environment {
    id = confluent_environment.demo.id
  }
}

# ---------------------------------------------------------------------------
# PrivateLink attachment: the environment-level PrivateLink service that the
# VPC endpoint in network.tf connects to.
# ---------------------------------------------------------------------------

resource "confluent_private_link_attachment" "demo" {
  cloud        = "AWS"
  region       = var.region
  display_name = local.name

  environment {
    id = confluent_environment.demo.id
  }
}

resource "confluent_private_link_attachment_connection" "demo" {
  display_name = local.name

  environment {
    id = confluent_environment.demo.id
  }

  aws {
    vpc_endpoint_id = aws_vpc_endpoint.confluent.id
  }

  private_link_attachment {
    id = confluent_private_link_attachment.demo.id
  }
}
