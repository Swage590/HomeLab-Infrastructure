variable "vm_count" {
  description = "Number of Ubuntu VMs to create"
  type        = number
  default     = 3
}

variable "domain" {
  description = "TLD of your env"
  type        = string
  default     = "Swage"
}

# Pre define VM mac, then declare the 1pass thing for a oneliner lookup
locals {
  vm_macs = [
    for i in range(var.vm_count) :
    format("02:00:00:%02x:%02x:%02x", 10, 20, i)
  ]
}

data "unifi_network" "lan" {
  name = "Main" # this must match the name of your LAN network in the UniFi controller
}

resource "unifi_user" "ubuntu_vm" {
  count      = var.vm_count

  mac        = local.vm_macs[count.index]
  name       = "Ubuntu-25-Template${count.index + 1}"
  fixed_ip   = cidrhost("10.59.20.0/24", 200 + count.index) # example: 192.168.1.50, .51, etc.
  network_id = data.unifi_network.lan.id
  note       = "Managed by Terraform"
  local_dns_record = "Ubuntu-25-Template${count.index + 1}.${var.domain}"
}

resource "xenorchestra_vm" "ubuntu_vm" {
  count             = var.vm_count
  name_label        = "Ubuntu-25-Template${count.index + 1}"
  name_description  = "Managed by Terraform"
  memory_max        = 17179869184 # 16 GB in bytes
  cpus              = 2
  auto_poweron      = true
  hvm_boot_firmware = "uefi"

  # Template (find the template UUID with `terraform import` or `xo-cli`)
  template = "c1a205ca-04f9-3161-26a8-371b5aec9a6f"

  tags = [
      "Ubuntu",
  ]

  disk {
    sr_id      = "32add21e-26ca-7eb7-c309-1c3f3df995d2" # Storage repository UUID
    name_label = "ubuntu-disk"
    size       = 107374182400 # 100 GB in bytes
  }

  network {
    network_id = "6545157d-63ee-92e2-8748-ca5db513ac3b" # Network UUID
    mac_address = local.vm_macs[count.index]
  }

  cloud_config = <<EOF
#cloud-config
hostname: Ubuntu-25-Template${count.index + 1}
ssh_pwauth: true
users:
  - name: swage
    sudo: ALL=(ALL) NOPASSWD:ALL
    groups: users, admin
    home: /home/swage
    shell: /bin/bash
    ssh-authorized-keys:
      - "ssh-rsa AAAAB3NzaC1yc2EAAAADAQABAAABAQDZ2Hp3Ahc8IS/jbWFd4cn67f7XLUCh3Ku0TyebNG0/Dn/zdjH5HGUQlDaXRclI8gqX4nTCqZYQBkdklg5axmHQVvJ+GouuOVHKKNiU0HdBpfWWJp3qPuA/EGy8NZG5a/qErY55igcbQ6w0outSU2GcwwZSTnk3vqSTcW99VYxvkZN8b+w+R/OQzs1ADMVqRTkn4OnxpGoLbDU+CeThqplKPjDFyIDw8gRG6EBmaqJUyZ9QfexPBo+PDwtrJckojXXn0oX+JbazQ6GOawKkvmXAJSQsoyWnSmEl1u/fRglD5zSxnYUTRGfG6Atg3pS3dg0GEo7QMXI1oZLzt3+xNC7z"
runcmd:
  # Stop networking to safely remove lease
  - systemctl stop systemd-networkd || true
  - dhclient -r || true                   # release lease if dhclient is in use
  - rm -f /var/lib/dhcp/*.leases || true  # remove old lease files
  - systemctl start systemd-networkd || true
EOF
}
