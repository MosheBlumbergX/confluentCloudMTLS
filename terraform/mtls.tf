# ---------------------------------------------------------------------------
# 1. Certificate authority: tells Confluent Cloud which CA signs trusted
#    client certificates. Org-wide: once uploaded, every mTLS-capable
#    cluster in the organization accepts certificates from this CA.
# ---------------------------------------------------------------------------

locals {
  upload_crl = var.crl_file != "" && fileexists(var.crl_file)
}

resource "confluent_certificate_authority" "acme" {
  display_name               = "${local.name}-acme-ca"
  description                = "Acme demo issuing CA, ${local.description}"
  certificate_chain_filename = basename(var.ca_chain_file)
  certificate_chain          = file(var.ca_chain_file)

  crl_chain                         = local.upload_crl ? file(var.crl_file) : null
  require_crl_on_client_certificate = local.upload_crl ? var.require_crl : false
}

# ---------------------------------------------------------------------------
# 2. Certificate identity pools: CEL filters map certificate metadata to an
#    identity. A client never names its pool; every pool whose filter matches
#    the presented certificate applies, and permissions are the union.
#
#    CEL identifiers: CN, O, OU, C, ST, L, DC, UID (subject DN parts),
#    DN (full subject), SAN, SNID (serial), SHA1 (fingerprint).
# ---------------------------------------------------------------------------

locals {
  pools = {
    # Enterprise clusters have a private REST endpoint, so topics are created
    # over Kafka by this identity rather than by Terraform.
    platform-admins = {
      description = "Platform team: manages topics"
      filter      = "O == \"Acme Corp\" && OU == \"platform\""
      bindings = [
        { role = "DeveloperManage", resource = "topic=*" },
      ]
    }

    payments-producers = {
      description = "Payments team services: may write to orders"
      filter      = "O == \"Acme Corp\" && OU == \"payments\""
      bindings = [
        { role = "DeveloperWrite", resource = "topic=orders" },
      ]
    }

    analytics-readers = {
      description = "Analytics team: read-only on orders"
      filter      = "O == \"Acme Corp\" && OU == \"analytics\""
      bindings = [
        { role = "DeveloperRead", resource = "topic=orders" },
        { role = "DeveloperRead", resource = "group=analytics-*" },
      ]
    }

    # Workload identity via a SPIFFE-style URI SAN instead of the subject DN.
    risk-workloads = {
      description = "Risk namespace workloads, matched on SPIFFE URI SAN"
      filter      = "SAN.contains(\"URI:spiffe://acme.demo/ns/risk/\")"
      bindings = [
        { role = "DeveloperRead", resource = "topic=orders" },
        { role = "DeveloperWrite", resource = "topic=fraud-alerts" },
        { role = "DeveloperRead", resource = "group=fraud-*" },
      ]
    }
  }

  # Flatten to one entry per (pool, role, resource) for for_each.
  pool_bindings = merge([
    for pool, cfg in local.pools : {
      for b in cfg.bindings : "${pool}:${b.role}:${b.resource}" => merge(b, { pool = pool })
    }
  ]...)
}

resource "confluent_certificate_pool" "this" {
  for_each = local.pools

  certificate_authority {
    id = confluent_certificate_authority.acme.id
  }

  display_name = "${local.name}-${each.key}"
  description  = "${each.value.description}. ${local.description}"
  filter       = each.value.filter

  # Certificate field used as the client identity in audit logs.
  external_identifier = "CN"
}

# ---------------------------------------------------------------------------
# 3. RBAC: grant each pool (principal User:pool-xxxx) access to resources.
# ---------------------------------------------------------------------------

resource "confluent_role_binding" "pool" {
  for_each = local.pool_bindings

  principal   = "User:${confluent_certificate_pool.this[each.value.pool].id}"
  role_name   = each.value.role
  crn_pattern = "${local.cluster.rbac_crn}/kafka=${local.cluster.id}/${each.value.resource}"
}
