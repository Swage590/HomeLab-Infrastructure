#!/bin/bash
# ansible-vault-password.sh

VAULT_NAME="Home Lab"
ITEM_NAME="Ansible-Vault"
FIELD_NAME="password"

op read "op://${VAULT_NAME}/${ITEM_NAME}/${FIELD_NAME}"
