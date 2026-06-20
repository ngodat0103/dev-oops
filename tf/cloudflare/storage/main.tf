terraform {
  required_providers {
    cloudflare = {
      source  = "cloudflare/cloudflare"
      version = "~> 5"
    }
  }
}
locals {
  account_id = "4c8ad4e9fa8213af3fd284bb97b68b5e"
  email      = "ngovuminhdat@gmail.com"
}

resource "cloudflare_r2_bucket" "backupStorageProd" {
  account_id    = local.account_id
  name          = "backup-storage-prod"
  location      = "apac"
  storage_class = "Standard"
}

resource "cloudflare_r2_bucket" "veleroStorageBackupProd" {
  account_id    = local.account_id
  name          = "velero-storage-prod"
  location      = "apac"
  storage_class = "Standard"
}

resource "cloudflare_r2_bucket" "juicefs" {
  account_id    = local.account_id
  name          = "juicefs-prod"
  location      = "apac"
  storage_class = "Standard"
}

resource "cloudflare_r2_bucket" "cnpg_postgresql" {
  account_id    = local.account_id
  name          = "cnpg-postgresql"
  location      = "apac"
  storage_class = "Standard"
}
resource "cloudflare_notification_policy" "r2_storage_alert" {
  account_id  = local.account_id
  name        = "R2 Storage > 100GB"
  description = "Alert when total R2 storage exceeds 100GB (~$1.50/mo at $0.015/GB-month)"
  enabled     = true
  alert_type  = "billing_usage_alert"
  mechanisms = {
    email = [{
      id = local.email
    }]
  }

  filters = {
    product = ["r2_storage"]
    limit   = ["107374182400"] # 100 GB in bytes
  }
}

