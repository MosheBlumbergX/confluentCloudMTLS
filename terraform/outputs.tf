output "environment_id" {
  value = confluent_environment.demo.id
}

output "kafka_cluster_id" {
  value = local.cluster.id
}

output "bootstrap_servers" {
  value = local.bootstrap
}

output "certificate_authority_id" {
  value = confluent_certificate_authority.acme.id
}

output "certificate_pools" {
  description = "Pool name => { id, filter }"
  value = {
    for k, p in confluent_certificate_pool.this : k => { id = p.id, filter = p.filter }
  }
}

output "crl_uploaded" {
  value = local.upload_crl
}

output "region" {
  value = var.region
}

output "client_instance_id" {
  value = aws_instance.client.id
}

output "bundle_bucket" {
  value = aws_s3_bucket.bundle.id
}

output "console_url" {
  value = "https://confluent.cloud/environments/${confluent_environment.demo.id}/clusters/${local.cluster.id}/overview"
}
