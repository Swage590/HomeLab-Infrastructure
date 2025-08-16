terraform {
  required_providers {
    xenorchestra = {
      source = "terra-farm/xenorchestra"
    }
    onepassword = {
      source = "1Password/onepassword"
    }
  }
}

provider "onepassword" {
  op_cli_path = "/mnt/c/Users/Swage/AppData/Local/Microsoft/WinGet/Packages/AgileBits.1Password.CLI_Microsoft.Winget.Source_8wekyb3d8bbwe/./terraform-op.sh"
}

data "onepassword_item" "xo_creds" {
  vault = "Home Lab"         # name or UUID of the vault
  title = "Xen Orchestra 5 XO-CE"   # title of the item in 1Password
}

# This allows me to do the oneliner lookup for the url in the provider section
locals {
  sections = {
    for section in data.onepassword_item.xo_creds.section :
    section.label => {
      id     = section.id
      fields = {
        for field_block in section.field :
        field_block.label => {
          id      = field_block.id
          purpose = field_block.purpose
          type    = field_block.type
          value   = field_block.value
        }
      }
    }
  }
}

provider "xenorchestra" {
  url      = local.sections["Terraform"].fields["url"].value
  username = data.onepassword_item.xo_creds.username
  password = data.onepassword_item.xo_creds.password

  insecure = true
}

resource "xenorchestra_vm" "ubuntu_vm" {
  count             = 3
  name_label        = "Ubuntu-25-Template${count.index + 1}"
  memory_max        = 17179869184 # 16 GB in bytes
  cpus              = 2
  auto_poweron      = true
  hvm_boot_firmware = "uefi"

  # Template (find the template UUID with `terraform import` or `xo-cli`)
  template = "c1a205ca-04f9-3161-26a8-371b5aec9a6f"

  disk {
    sr_id      = "32add21e-26ca-7eb7-c309-1c3f3df995d2" # Storage repository UUID
    name_label = "ubuntu-disk"
    size       = 107374182400 # 100 GB in bytes
  }

  network {
    network_id = "6545157d-63ee-92e2-8748-ca5db513ac3b" # Network UUID
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
