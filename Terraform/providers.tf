provider "onepassword" {
}

data "onepassword_item" "unifi_creds" {
  vault = "Home Lab"         # name or UUID of the vault
  title = "Terraform Unifi"   # title of the item in 1Password
}

data "onepassword_item" "xo_creds" {
  vault = "Home Lab"         # name or UUID of the vault
  title = "Terraform XO-CE"   # title of the item in 1Password
}

provider "xenorchestra" {
  url      = data.onepassword_item.xo_creds.url
  username = data.onepassword_item.xo_creds.username
  password = data.onepassword_item.xo_creds.password

  insecure = true
}

provider "unifi" {
  username       = data.onepassword_item.unifi_creds.username
  password       = data.onepassword_item.unifi_creds.password
  api_url        = data.onepassword_item.unifi_creds.url

  allow_insecure = true
}
