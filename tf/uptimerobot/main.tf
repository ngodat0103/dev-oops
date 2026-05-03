locals {
  web_tag               = ["production", "web"]
  docker_containter_tag = concat(local.web_tag, ["docker_container"])
  snap_tag              = concat(local.web_tag, ["snap"])
}
# import {
#   to = module.monitors_default.uptimerobot_monitor.default_monitor["vaultwarden"]
#   id = "800604169"
# }
# import {
#   to = module.monitors_default.uptimerobot_monitor.default_monitor["gitlab"]
#   id = "800611041"
# }

# import {
#   to = module.monitors_default.uptimerobot_monitor.default_monitor["nextcloud"]
#   id = "800604827"
# }
module "monitors_default" {
  #human browserable: https://github.com/ngodat0103/terraform-module/tree/d1dd648524d9c4f492c09ac021742654f4184f11
  source              = "git::https://github.com/ngodat0103/terraform-module.git//uptimerobot/monitor?ref=d1dd648524d9c4f492c09ac021742654f4184f11"
  uptimerobot_api_key = var.uptimerobot_api_key
  monitors = {
    vaultwarden = {
      type = "HTTP"
      url  = "https://bitwarden.datrollout.dev/alive"
      tags = local.docker_containter_tag
    },
    nextcloud = {
      type = "HTTP"
      url  = "https://nextcloud.datrollout.dev/index.php/login"
      tags = local.snap_tag
    }
  }
}