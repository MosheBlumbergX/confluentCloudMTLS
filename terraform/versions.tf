terraform {
  required_version = ">= 1.5"

  required_providers {
    confluent = {
      source  = "confluentinc/confluent"
      version = ">= 2.40.0"
    }
    aws = {
      source  = "hashicorp/aws"
      version = ">= 5.30"
    }
    random = {
      source  = "hashicorp/random"
      version = ">= 3.5"
    }
  }
}

# Credentials come from CONFLUENT_CLOUD_API_KEY / CONFLUENT_CLOUD_API_SECRET.
# The key must belong to a principal with OrganizationAdmin (needed to manage
# certificate authorities and identity pools).
provider "confluent" {}

# Credentials come from the standard AWS chain (AWS_PROFILE, env vars, SSO).
provider "aws" {
  region = var.region

  default_tags {
    tags = var.aws_tags
  }
}
