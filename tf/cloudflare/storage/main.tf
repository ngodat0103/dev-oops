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

resource "cloudflare_r2_bucket" "veleroStorageBackupProd" {
  account_id    = "4c8ad4e9fa8213af3fd284bb97b68b5e"
  name          = "velero-storage-prod"
  location      = "apac"
  storage_class = "Standard"
}