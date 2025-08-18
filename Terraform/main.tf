variable "vms" {
  type = map(object({
    name   = string
    cpu    = number
    memory = number
  }))
}

variable "domain" {
  description = "TLD of your env"
  type        = string
  default     = "Swage"
}

# Sequential MAC Generation to allow Unifi Entry to be created before VM
locals {
  # list of VM keys to map to indices
  vm_keys = keys(var.vms)

  # generate sequential MACs: 02:00:00:0a:14:00, 02:00:00:0a:14:01, ...
  vm_macs = [
    for i in range(length(local.vm_keys)) :
    format("02:00:00:%02x:%02x:%02x", 10, 20, i)
  ]

  # map keys to MACs for easy lookup by VM key
  mac_addresses = {
    for idx, key in local.vm_keys :
    key => local.vm_macs[idx]
  }
}

data "unifi_network" "lan" {
  name = "Main" # this must match the name of your LAN network in the UniFi controller
}

resource "unifi_user" "client" {
  for_each = var.vms

  mac              = local.mac_addresses[each.key]
  name             = each.value.name
  fixed_ip         = cidrhost("10.59.20.0/24", 200 + index(local.vm_keys, each.key)) # Starts assigning at .200
  network_id       = data.unifi_network.lan.id
  note             = "Managed by Terraform"
  local_dns_record = "${each.value.name}.${var.domain}"
}

resource "xenorchestra_vm" "ubuntu_vm" {
  for_each          = var.vms

  name_label        = each.value.name
  name_description  = "Managed by Terraform"
  memory_max        = each.value.memory * 1024 * 1024 * 1024 # Convert GB to bytes
  cpus              = each.value.cpu
  auto_poweron      = true
  hvm_boot_firmware = "uefi"

  # Template (find the template UUID with `terraform import` or `xo-cli`)
  template = "c1a205ca-04f9-3161-26a8-371b5aec9a6f"

  tags = [
      "Ubuntu",
      "Terraform Managed",
  ]

  disk {
    sr_id      = "32add21e-26ca-7eb7-c309-1c3f3df995d2" # Storage repository UUID
    name_label = "ubuntu-disk"
    size       = 107374182400 # 100 GB in bytes
  }

  network {
    network_id = "6545157d-63ee-92e2-8748-ca5db513ac3b" # Network UUID
    mac_address = unifi_user.client[each.key].mac
  }
}

data "onepassword_item" "vm_temp_creds" {
  vault = "Home Lab"         # name or UUID of the vault
  title = "Packer/Ansible Debian Password"   # title of the item in 1Password
}

resource "onepassword_item" "_1pass_vm_entry" {
  for_each = var.vms

  vault    = "lqttkuu6qlvnzrcxpemr6w376i" # Ansible Vault

  category = "login"

  title    = each.value.name
  note_value = "Managed by Terraform"
  url = "${each.value.name}.${var.domain}"

  username = "swage"
  password = data.onepassword_item.vm_temp_creds.password

  section {
    label = "Networking"

    field {
      label = "MAC Address"
      type  = "STRING"
      value = local.mac_addresses[each.key]
    }

    field {
      label = "IP Address"
      type  = "URL"
      value = unifi_user.client[each.key].ip
    }
  }
}
