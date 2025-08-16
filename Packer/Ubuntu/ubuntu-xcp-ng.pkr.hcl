packer {
  required_plugins {
    xenserver = {
      version = ">= 0.0.1"
      source  = "github.com/ddelnano/xenserver"
    }
  }
}

variable "ssh_public_key" {
  type    = string
  default = "ssh-rsa AAAAB3NzaC1yc2EAAAADAQABAAABAQDZ2Hp3Ahc8IS/jbWFd4cn67f7XLUCh3Ku0TyebNG0/Dn/zdjH5HGUQlDaXRclI8gqX4nTCqZYQBkdklg5axmHQVvJ+GouuOVHKKNiU0HdBpfWWJp3qPuA/EGy8NZG5a/qErY55igcbQ6w0outSU2GcwwZSTnk3vqSTcW99VYxvkZN8b+w+R/OQzs1ADMVqRTkn4OnxpGoLbDU+CeThqplKPjDFyIDw8gRG6EBmaqJUyZ9QfexPBo+PDwtrJckojXXn0oX+JbazQ6GOawKkvmXAJSQsoyWnSmEl1u/fRglD5zSxnYUTRGfG6Atg3pS3dg0GEo7QMXI1oZLzt3+xNC7z" # your public key
}

source "xenserver-iso" "ubuntu" {
  remote_host        = "10.59.20.8"
  remote_username    = "root"
  remote_password    = "EJ2ZP.*Q_RG@9Ca9vksX"

  sr_iso_name        = "ISO Storage"   # SR that contains ISOs
  sr_name            = "LocalSR" # SR for VM disks

  clone_template     = "Other install media"
  vm_name            = "ubuntu-blank-template"

  iso_url            = "https://releases.ubuntu.com/plucky/ubuntu-25.04-live-server-amd64.iso"
  iso_checksum       = "sha256:8b44046211118639c673335a80359f4b3f0d9e52c33fe61c59072b1b61bdecc5"

  ssh_username       = "swage"
  ssh_private_key_file = "/home/swage/Ramen_Riot_rsa"
  ssh_timeout        = "20m"

  disk_size          = 131072
  vm_memory          = 8192
  vcpus_max          = 2

boot_command = [
  "<wait><esc><wait>",  # make sure we're at the menu
  "e<wait>",            # edit default menu entry
  "<down><down><down><end>", # go to the linux kernel line
  " autoinstall ds=nocloud-net;s=http://10.59.20.124:8080/ ---", # add autoinstall params
  "<f10>"               # boot with changes
  ]

  boot_wait = "5s"
  http_directory = "http"
}

build {
  sources = ["source.xenserver-iso.ubuntu"]

  provisioner "shell" {
    inline = [
      "echo 'provisioning complete'"
    ]
  }
}
