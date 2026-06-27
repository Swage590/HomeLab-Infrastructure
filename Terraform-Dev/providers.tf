provider "onepassword" {
}

data "onepassword_item" "unifi_creds" {
  vault = "Home Lab"         # name or UUID of the vault
  title = "Terraform Unifi"   # title of the item in 1Password
}

data "onepassword_item" "proxmox_creds" {
  vault = "Home Lab"         # name or UUID of the vault
  title = "Terraform Proxmox"   # title of the item in 1Password
}

data "onepassword_item" "proxmox_ssh_creds" {
  vault = "Home Lab"         # name or UUID of the vault
  title = "Proxmox"          # title of the item in 1Password
}

locals {
  proxmox_token_id = [for s in data.onepassword_item.proxmox_creds.section : [for f in s.field : f.value if f.label == "Token ID"]][0][0]
  proxmox_secret   = [for s in data.onepassword_item.proxmox_creds.section : [for f in s.field : f.value if f.label == "Secret"]][0][0]
}

provider "proxmox" {
  endpoint  = "https://10.59.99.8:8006/"
  api_token = "${local.proxmox_token_id}=${local.proxmox_secret}"
  insecure  = true

  ssh {
    agent    = false
    username = data.onepassword_item.proxmox_ssh_creds.username
    password = data.onepassword_item.proxmox_ssh_creds.password
  }
}

provider "unifi" {
  username       = data.onepassword_item.unifi_creds.username
  password       = data.onepassword_item.unifi_creds.password
  api_url        = data.onepassword_item.unifi_creds.url

  allow_insecure = true
}
