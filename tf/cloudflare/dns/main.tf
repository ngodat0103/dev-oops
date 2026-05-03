terraform {
  required_providers {
    cloudflare = {
      source  = "cloudflare/cloudflare"
      version = "~> 5"
    }
  }
}
locals {
  cloudflare_api_token = var.cloudflare_api_token
  zone_id              = "ab6606e8b3aad0b66008eb26f2dd3660"
  share_comment        = "Managed by Terraform"
  account_id           = "4c8ad4e9fa8213af3fd284bb97b68b5e"
  traefik_k8s_lan_ip= "192.168.1.232"
  traefik_docker_ip = "192.168.1.121"
}
module "ddns_records" {
  source               = "git::https://github.com/ngodat0103/terraform-module.git//cloudflare/dns-records?ref=9efc538229c94814818587dccad17a7ccf878310"
  cloudflare_api_token = local.cloudflare_api_token
  zone_id              = local.zone_id
  share_comment        = local.share_comment
  ddns_content         = var.ddns_content
  dns_records = {
    nextcloud = {
      type    = "CNAME"
      proxied = true
      ttl     = 1
    }
    bitwarden = {
      type    = "CNAME"
      proxied = true
    }
    // Internal services
    core-harbor = {
      type    = "A"
      proxied = false
      content = local.traefik_k8s_lan_ip
      ttl     = 1
    }
    kafka-ui = {
      type    = "A"
      proxied = false
      content = local.traefik_k8s_lan_ip
      ttl     = 1
    }
    pgadmin4 = {
      type    = "A"
      proxied = false
      content = local.traefik_k8s_lan_ip
      ttl     = 1
    }
    argocd = {
      type    = "A"
      proxied = false
      content = local.traefik_k8s_lan_ip
      ttl     = 1
    }
    sonarqube = {
      type    = "A"
      proxied = false
      content = local.traefik_k8s_lan_ip
      ttl     = 1
    }
    jellyfin = {
      type    = "A"
      proxied = false
      content = local.traefik_k8s_lan_ip
      ttl     = 1
    }
    gitlab = {
      type    = "A"
      proxied = false
      content = local.traefik_docker_ip
      ttl     = 1
    }
  }
}

## Firewall

import {
  to = module.personal_firewall.cloudflare_ruleset.default
  id = "zones/${local.zone_id}/1036fedd818d45d78dbad2f5dcf4cb17"
}

module "personal_firewall" {
  source               = "git::https://github.com/ngodat0103/terraform-module.git//cloudflare/personal-firewall?ref=0.0.1"
  cloudflare_api_token = local.cloudflare_api_token
  zone_id              = local.zone_id
  firewall_rules = [
    {
      description = "Allow healthcheck from UptimeRobot IP addresses"
      expression  = "(http.request.method eq \"HEAD\" and ip.src in {${file("${path.root}/uptimerobot-ips.txt")}})"
      enable      = true
      action      = "skip",
      action_parameters = {
        ruleset = "current"
      }
      logging = {
        enabled = false
      }
    },
    {
      action      = "block"
      description = "Block requests originating from outside Vietnam"
      enabled     = true
      expression  = "(ip.src.country ne \"VN\")"
    },
    {
      action      = "block"
      description = "Block external access to /admin Vaultwarden"
      enabled     = true
      expression  = "(http.request.full_uri eq \"https://bitwarden.datrollout.dev/admin\")"
    }
  ]
}