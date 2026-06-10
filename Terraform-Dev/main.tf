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
  default     = "Dev-Swage"
}

data "unifi_network" "lan" {
  name = "Sandbox" # this must match the name of your LAN network in the UniFi controller
}

resource "unifi_user" "client" {
  for_each = var.vms

  mac              = each.value.mac
  name             = each.value.name
  fixed_ip         = each.value.ip
  network_id       = data.unifi_network.lan.id
  note             = "[DEV] Created by Terraform"
  local_dns_record = "${each.value.name}.${var.domain}"
}

resource "xenorchestra_vm" "ubuntu_vm" {
  for_each          = var.vms

  name_label        = each.value.name
  name_description  = "[DEV] Created by Terraform"
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
    network_id = "3a9068fc-44bd-b6a7-0377-50cdedda0e34" # Network UUID
    mac_address = unifi_user.client[each.key].mac
  }

  // highlight-start
  # Pass the cloud-init configuration directly
  cloud_config = templatefile("${path.module}/user-data.yml.tftpl", {
    hostname        = each.value.name
    username        = "swage"
    password        = onepassword_item._1pass_vm_entry[each.key].password
    fqdn            = "${each.value.name}.${var.domain}"
  })
}

data "onepassword_item" "vm_temp_creds" {
  vault = "Home Lab"         # name or UUID of the vault
  title = "Packer/Ansible Debian Password"   # title of the item in 1Password
}

resource "onepassword_item" "_1pass_vm_entry" {
  for_each = var.vms

  vault    = "lqttkuu6qlvnzrcxpemr6w376i" # Ansible Vault

  category = "login"
    
  lifecycle {
    ignore_changes = [
      password,
    ]
  }

  title    = each.value.name
  note_value = "[DEV] Created by Terraform"
  url = "${each.value.name}.${var.domain}"

  username = "swage"
  password_recipe {
    length  = 50
    symbols = false
  }

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
      value = each.value.ip
    }
  }
}
