terraform {
  required_version = ">= 1.9"

  required_providers {
    proxmox = {
      source  = "bpg/proxmox"
      version = "~> 0.112"
    }
    opnsense = {
      source  = "browningluke/opnsense"
      version = "~> 0.26"
    }
    restapi = {
      source  = "Mastercard/restapi"
      version = "~> 3.0"
    }
  }

  backend "local" {
    path = "../.private/opnsense.tfstate"
  }
}
