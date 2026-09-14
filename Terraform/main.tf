variable "vms" {
  type = map(object({
    name         = string
    node_name    = optional(string)
    node         = optional(string)
    cpu          = number
    memory       = number
    mac          = string
    ip           = string
    datastore_id = optional(string)
    datastore    = optional(string)
  }))
}

variable "cloud_image_url" {
  description = "URL of the cloud image to download and use for VMs"
  type        = string
  default     = "https://cloud-images.ubuntu.com/resolute/current/resolute-server-cloudimg-amd64.img"
}

variable "cloud_image_file_name" {
  description = "The file name for the downloaded cloud image in the datastore"
  type        = string
  default     = "resolute-server-cloudimg-amd64.img"
}

variable "cloud_image_datastore_id" {
  description = "The datastore where cloud images will be stored (must support ISO/image content type)"
  type        = string
  default     = "local"
}

variable "domain" {
  description = "TLD of your env"
  type        = string
  default     = "Swage"
}

variable "default_vm_datastore_id" {
  description = "Default datastore for VM disks (used by default for new VMs)"
  type        = string
  default     = "ceph-vm-pool"
}

variable "local_vm_datastore_id" {
  description = "Datastore for local storage VMs (e.g. Shadow VMs)"
  type        = string
  default     = "local-lvm"
}

locals {
  unique_nodes = toset([for vm in var.vms : coalesce(vm.node_name, vm.node, "knight")])

  vm_datastores = {
    for k, vm in var.vms : k => coalesce(
      vm.datastore_id,
      vm.datastore,
      startswith(coalesce(vm.name, k), "Shadow-") ? var.local_vm_datastore_id : var.default_vm_datastore_id
    )
  }
}

resource "proxmox_virtual_environment_download_file" "ubuntu_cloud_image" {
  for_each = local.unique_nodes

  content_type        = "iso"
  datastore_id        = var.cloud_image_datastore_id
  node_name           = each.key
  url                 = var.cloud_image_url
  file_name           = var.cloud_image_file_name
  overwrite           = false
  overwrite_unmanaged = true
  upload_timeout      = 1800
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
  note             = "[Proxmox] Created by Terraform"
  local_dns_record = "${each.value.name}.${var.domain}"
}

resource "proxmox_virtual_environment_file" "user_data" {
  for_each     = var.vms
  content_type = "snippets"
  datastore_id = "local"
  node_name    = coalesce(each.value.node_name, each.value.node, "knight")

  source_raw {
    data = templatefile("${path.module}/user-data.yml.tftpl", {
      hostname       = each.value.name
      username       = "swage"
      password       = onepassword_item._1pass_vm_entry[each.key].password
      fqdn           = "${each.value.name}.${var.domain}"
      ssh_public_key = "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIHNVigjWD/3m7VN4DxPG8nadvsq6eBb/NBNH0iomRVih"
    })
    file_name = "user-data-${each.key}.yml"
  }
}

resource "proxmox_virtual_environment_vm" "ubuntu_vm" {
  for_each = var.vms

  name        = each.value.name
  description = "[Proxmox] Created by Terraform"
  node_name   = coalesce(each.value.node_name, each.value.node, "knight")
  bios        = "ovmf"

  agent {
    enabled = true
    timeout = "10s"
  }

  started = true

  cpu {
    cores = each.value.cpu
    type  = "host"
  }

  memory {
    dedicated = each.value.memory * 1024 # Convert GB to MB
  }

  efi_disk {
    datastore_id = local.vm_datastores[each.key]
    file_format  = "raw"
    type         = "4m"
  }

  tags = [
    "ubuntu",
    "terraform-managed",
  ]

  disk {
    datastore_id = local.vm_datastores[each.key]
    file_id      = proxmox_virtual_environment_download_file.ubuntu_cloud_image[coalesce(each.value.node_name, each.value.node, "knight")].id
    interface    = "scsi0"
    size         = 100
  }

  boot_order = ["scsi0"]

  scsi_hardware = "virtio-scsi-pci"

  operating_system {
    type = "l26"
  }

  serial_device {}

  network_device {
    bridge      = "vmbr0"
    mac_address = upper(unifi_user.client[each.key].mac)
  }

  initialization {
    datastore_id      = local.vm_datastores[each.key]
    interface         = "scsi1"
    user_data_file_id = proxmox_virtual_environment_file.user_data[each.key].id
    ip_config {
      ipv4 {
        address = "dhcp"
      }
    }
  }

  lifecycle {
    ignore_changes = [
      node_name,
    ]
  }
}

data "onepassword_item" "vm_temp_creds" {
  vault = "Home Lab"                       # name or UUID of the vault
  title = "Packer/Ansible Debian Password" # title of the item in 1Password
}

resource "onepassword_item" "_1pass_vm_entry" {
  for_each = var.vms

  vault = "lqttkuu6qlvnzrcxpemr6w376i" # Ansible Vault

  category = "login"

  lifecycle {
    ignore_changes = [
      password,
    ]
  }

  title      = each.value.name
  note_value = "[Proxmox] Created by Terraform"
  url        = "${each.value.name}.${var.domain}"

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
