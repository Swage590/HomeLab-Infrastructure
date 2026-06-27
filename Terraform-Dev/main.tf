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

resource "proxmox_virtual_environment_file" "user_data" {
  for_each     = var.vms
  content_type = "snippets"
  datastore_id = "local"
  node_name    = "proxmox"

  source_raw {
    data = templatefile("${path.module}/user-data.yml.tftpl", {
      hostname        = each.value.name
      username        = "swage"
      password        = onepassword_item._1pass_vm_entry[each.key].password
      fqdn            = "${each.value.name}.${var.domain}"
    })
    file_name = "user-data-${each.key}.yml"
  }
}

resource "proxmox_virtual_environment_vm" "ubuntu_vm" {
  for_each    = var.vms

  name        = each.value.name
  description = "[DEV] Created by Terraform"
  node_name   = "proxmox"
  
  cpu {
    cores = each.value.cpu
  }

  memory {
    dedicated = each.value.memory * 1024 # Convert GB to MB
  }

  clone {
    vm_id = 100
  }

  tags = [
      "ubuntu",
      "terraform-managed",
  ]

  disk {
    datastore_id = "local-lvm"
    interface    = "scsi0"
    size         = 100
  }

  network_device {
    bridge      = "vmbr0"
    mac_address = upper(unifi_user.client[each.key].mac)
  }

  initialization {
    user_data_file_id = proxmox_virtual_environment_file.user_data[each.key].id
    ip_config {
      ipv4 {
        address = "dhcp"
      }
    }
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
