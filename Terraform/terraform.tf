terraform {
  backend "local" {
    path = "/mnt/sharedrive/terraform/terraform.tfstate"
  }
  required_providers {
    proxmox = {
      source  = "bpg/proxmox"
      version = "0.61.1"
    }
    onepassword = {
      source = "1Password/onepassword"
    }
    unifi = {
      source  = "ubiquiti-community/unifi"
      version = "0.41.3"
    }
    htpasswd = {
      source  = "loafoe/htpasswd"
      version = "~> 1.2"
    }
  }
}
