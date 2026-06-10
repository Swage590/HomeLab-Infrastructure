terraform {
  required_providers {
    xenorchestra = {
      source = "terra-farm/xenorchestra"
    }
    onepassword = {
      source = "1Password/onepassword"
    }
    unifi = {
      source = "ubiquiti-community/unifi"
      version = "0.41.3"
    }
  }
}
