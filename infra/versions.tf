terraform {
  required_version = ">= 1.9"

  required_providers {
    proxmox = {
      source  = "bpg/proxmox"
      version = "~> 0.101"
    }
    opnsense = {
      source  = "browningluke/opnsense"
      version = "~> 0.18"
    }
    restapi = {
      source  = "Mastercard/restapi"
      version = "~> 1.20"
    }
  }

  backend "local" {
    path = "../.private/opnsense.tfstate"
  }
}
