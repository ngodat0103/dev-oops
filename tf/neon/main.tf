resource "neon_project" "metadata" {
  name                      = "metadata"
  region_id                 = "aws-us-east-2"
  pg_version=16
  history_retention_seconds = 21600
}

resource "neon_role" "juicefs" {
  project_id = neon_project.metadata.id
  branch_id  = neon_project.metadata.default_branch_id
  name       = "juicefs"
}
resource "neon_database" "juicefs" {
  project_id = neon_project.metadata.id
  branch_id  = neon_project.metadata.default_branch_id
  name       = "juicefs"
  owner_name = neon_role.juicefs.name
}