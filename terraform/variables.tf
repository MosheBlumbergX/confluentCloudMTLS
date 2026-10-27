variable "name_prefix" {
  description = "Prefix for every resource name. A random suffix is appended so several people can run the demo in one org/account."
  type        = string
  default     = "mtls-demo"
}

variable "owner" {
  description = "Who owns this demo. Written into Confluent Cloud resource descriptions (Confluent Cloud resources do not support tags)."
  type        = string
}

variable "keep_until" {
  description = "Date (YYYY-MM-DD) after which the demo resources can be deleted. Written into Confluent Cloud resource descriptions."
  type        = string

  validation {
    condition     = can(regex("^\\d{4}-\\d{2}-\\d{2}$", var.keep_until))
    error_message = "keep_until must be YYYY-MM-DD."
  }
}

variable "aws_tags" {
  description = "Tags applied to every AWS resource (provider default_tags, plus EC2 volumes explicitly)."
  type        = map(string)
  default     = {}
}

# ---------------------------------------------------------------------------
# Confluent Cloud Enterprise cluster (AWS). Enterprise clusters use private
# networking, so the demo also builds a VPC with a PrivateLink endpoint and a
# client host inside it.
# ---------------------------------------------------------------------------

variable "region" {
  description = "AWS region for the Enterprise cluster, the VPC and the client host."
  type        = string
  default     = "us-east-2"
}

variable "availability" {
  description = "Enterprise cluster availability: SINGLE_ZONE or HIGH."
  type        = string
  default     = "HIGH"
}

variable "vpc_cidr" {
  description = "CIDR for the demo VPC."
  type        = string
  default     = "10.42.0.0/16"
}

variable "existing_vpc_id" {
  description = "Use this VPC instead of creating one (leave empty to create). Needs DNS hostnames enabled."
  type        = string
  default     = ""
}

variable "existing_subnet_ids" {
  description = "Subnets in existing_vpc_id for the PrivateLink endpoint (one per AZ). The first also hosts the client host and must reach the internet."
  type        = list(string)
  default     = []
}

variable "client_instance_type" {
  description = "EC2 instance type for the client host."
  type        = string
  default     = "t3.small"
}

variable "kafka_cli_version" {
  description = "Apache Kafka version whose CLI tools are installed on the client host (Java client demo)."
  type        = string
  default     = "4.3.2"
}

# ---------------------------------------------------------------------------
# mTLS
# ---------------------------------------------------------------------------

variable "ca_chain_file" {
  description = "PEM chain uploaded as the Confluent Cloud certificate authority (issuing CA first)."
  type        = string
  default     = "../pki/out/ca-chain.pem"
}

variable "crl_file" {
  description = "PEM CRL chain uploaded to the certificate authority. Set to \"\" to skip CRL upload."
  type        = string
  default     = "../pki/out/crl-chain.pem"
}

variable "require_crl" {
  description = "Fail closed: reject client certs when CRL validation cannot be completed."
  type        = bool
  default     = true
}
