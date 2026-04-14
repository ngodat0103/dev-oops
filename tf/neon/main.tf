resource "neon_project" "metadata" {
  name                      = "metadata"
  region_id                 = "aws-us-east-2"
  pg_version=16
  history_retention_seconds = 21600
  enable_logical_replication = "yes"
}

resource "neon_project" "production" {
  name                      = "production"
  region_id                 = "aws-ap-southeast-1"
  pg_version=16
  history_retention_seconds = 21600
}

resource "neon_role" "vaultwarden" {
  project_id = neon_project.production.id
  branch_id  = neon_project.production.default_branch_id
  name       = "vaultwarden"
}
resource "neon_database" "vaultwarden" {
  project_id = neon_project.production.id
  branch_id  = neon_project.production.default_branch_id
  name       = "vaultwarden"
  owner_name = neon_role.vaultwarden.name
}