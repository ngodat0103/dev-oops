terraform {
  required_providers {
    neon = {
      source  = "kislerdm/neon"
    }
  }
}

provider "neon" {
        # api_key = var.neon_api_token
}