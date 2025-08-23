#!/bin/bash
# ansible-vault-password.sh

VAULT_NAME="Home Lab"
ITEM_NAME="Ansible-Vault"
FIELD_NAME="password"

# Sneakily load in the private key to home while this is fetching the vault password
# Ansible & 1Password aren't making it easy to get rid of these hard coded creds
op read "op://Home Lab/Github SSH Key/private key?ssh-format=openssh" > /home/swage/private_key
chmod 600 /home/swage/private_key

op read "op://${VAULT_NAME}/${ITEM_NAME}/${FIELD_NAME}"
