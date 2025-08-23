variable "vms" {
  type = map(object({
    name   = string
    cpu    = number
    memory = number
    mac    = string
    ip     = string
  }))
}

variable "domain" {
  description = "TLD of your env"
  type        = string
  default     = "Swage"
}

data "unifi_network" "lan" {
  name = "Main" # this must match the name of your LAN network in the UniFi controller
}

resource "unifi_user" "client" {
  for_each = var.vms

  mac              = each.value.mac
  name             = each.value.name
  fixed_ip         = each.value.ip
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
  template = "9b60187e-5bf1-ccb8-9c2d-bd58b275248b"

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
      value = each.value.mac
    }

    field {
      label = "IP Address"
      type  = "URL"
      value = unifi_user.client[each.key].ip
    }
  }
}
