terraform {
  required_providers {
    cloudflare = {
      source  = "cloudflare/cloudflare"
      version = "~> 5"
    }
  }
}

resource "cloudflare_r2_bucket" "backupStorageProd" {
  account_id    = "4c8ad4e9fa8213af3fd284bb97b68b5e"
  name          = "backup-storage-prod"
  location      = "apac"
  storage_class = "Standard"
}
resource "cloudflare_r2_bucket" "juicefs" {
  account_id    = "4c8ad4e9fa8213af3fd284bb97b68b5e"
  name          = "juicefs-prod"
  location      = "apac"
  storage_class = "Standard"
}

resource "cloudflare_r2_bucket" "cnpg_postgresql" {
  account_id    = "4c8ad4e9fa8213af3fd284bb97b68b5e"
  name          = "cnpg-postgresql"
  location      = "apac"
  storage_class = "Standard"
}

