terraform {
  required_providers {
    proxmox = {
      source  = "bpg/proxmox"
      version = "0.61.1"
    }
    onepassword = {
      source = "1Password/onepassword"
    }
    unifi = {
      source = "ubiquiti-community/unifi"
      version = "0.41.3"
    }
  }
}
