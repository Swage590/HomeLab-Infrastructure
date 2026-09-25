variable "vms" {
  type = map(object({
    name         = string
    node_name    = optional(string)
    node         = optional(string)
    cpu          = number
    memory       = number
    mac          = string
    ip           = string
    ha           = optional(bool)
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
  description = "Datastore where the base cloud image is stored"
  type        = string
  default     = "local"
}

variable "domain" {
  description = "TLD of your env"
  type        = string
  default     = "Swage"
}

# --- Storage Defaults ---
variable "default_vm_datastore_id" {
  description = "Shared Ceph pool for HA VM disks and EFI"
  type        = string
  default     = "ceph-vm-pool"
}

variable "local_vm_datastore_id" {
  description = "Host-local storage for pinned VMs"
  type        = string
  default     = "local-lvm"
}

variable "shared_snippets_datastore_id" {
  description = "Cluster-wide shared datastore (CephFS/NFS) for HA cloud-init snippets"
  type        = string
  default     = "cephfs" # Adjust to match your shared snippets-capable storage
}

locals {
  # Flag HA vs Local: explicit flag if defined, otherwise infer from "Shadow-" prefix
  is_ha = {
    for k, vm in var.vms : k => coalesce(
      vm.ha,
      !startswith(coalesce(vm.name, k), "Shadow-")
    )
  }

  # Datastore for VM OS disk and EFI disk
  vm_datastores = {
    for k, vm in var.vms : k => coalesce(
      vm.datastore_id,
      vm.datastore,
      local.is_ha[k] ? var.default_vm_datastore_id : var.local_vm_datastore_id
    )
  }

  # Datastore for cloud-init snippets (Local storage for Shadow VMs, Shared for HA)
  snippet_datastores = {
    for k, vm in var.vms : k => local.is_ha[k] ? var.shared_snippets_datastore_id : "local"
  }

  # Initial host placement
  vm_nodes = {
    for k, vm in var.vms : k => coalesce(vm.node_name, vm.node, "knight")
  }

  unique_nodes = toset(values(local.vm_nodes))
}

# Base OS image cached on each target host's local datastore
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
  name = "Sandbox"
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

# Cloud-Init Snippet
resource "proxmox_virtual_environment_file" "user_data" {
  for_each     = var.vms
  content_type = "snippets"
  datastore_id = local.snippet_datastores[each.key]
  node_name    = local.vm_nodes[each.key]

  source_raw {
    data = templatefile("${path.module}/user-data.yml.tftpl", {
      hostname       = each.value.name
      username       = "swage"
      password_hash  = htpasswd_password.vm_password[each.key].sha512
      fqdn           = "${each.value.name}.${var.domain}"
      ssh_public_key = "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIHNVigjWD/3m7VN4DxPG8nadvsq6eBb/NBNH0iomRVih"
    })
    file_name = "user-data-${each.key}.yml"
  }
}

# Virtual Machines
resource "proxmox_virtual_environment_vm" "ubuntu_vm" {
  for_each = var.vms

  name        = each.value.name
  description = local.is_ha[each.key] ? "[Proxmox HA] Managed by Terraform" : "[Proxmox Pinned] Managed by Terraform"
  node_name   = local.vm_nodes[each.key]
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
    dedicated = each.value.memory * 1024
  }

  efi_disk {
    datastore_id = local.vm_datastores[each.key]
    file_format  = "raw"
    type         = "4m"
  }

  tags = local.is_ha[each.key] ? [
    "ubuntu",
    "ha-enabled",
    "terraform-managed",
  ] : [
    "ubuntu",
    "pinned-host",
    "terraform-managed",
  ]

  disk {
    datastore_id = local.vm_datastores[each.key]
    file_id      = proxmox_virtual_environment_download_file.ubuntu_cloud_image[local.vm_nodes[each.key]].id
    interface    = "scsi0"
    size         = 100
  }

  boot_order    = ["scsi0"]
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
      node_name, # Essential for HA so Proxmox migration doesn't trigger Terraform drift
      disk[0].datastore_id,
      disk[0].file_id,
      disk[0].size,
      initialization[0].user_data_file_id,
      initialization[0].ip_config,
    ]

    replace_triggered_by = [
      proxmox_virtual_environment_file.user_data[each.key]
    ]
  }
}

resource "proxmox_virtual_environment_haresource" "vm_ha" {
  for_each = {
    for k, vm in var.vms : k => vm
    if local.is_ha[k]
  }

  resource_id = "vm:${proxmox_virtual_environment_vm.ubuntu_vm[each.key].vm_id}"
  state       = "started"
  max_relocate = 3
  max_restart  = 3
}

resource "onepassword_item" "_1pass_vm_entry" {
  for_each = var.vms

  vault    = "lqttkuu6qlvnzrcxpemr6w376i"
  category = "login"

  lifecycle {
    ignore_changes = [password]
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

resource "random_password" "vm_salt" {
  for_each = var.vms
  length   = 8
  special  = false
}

resource "htpasswd_password" "vm_password" {
  for_each = var.vms

  password = onepassword_item._1pass_vm_entry[each.key].password
  salt     = random_password.vm_salt[each.key].result
}
