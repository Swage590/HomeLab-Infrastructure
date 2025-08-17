#!/usr/bin/env python3
import configparser
import subprocess
import os
import sys
import re

# Path to your Ansible inventory
INVENTORY_FILE = "inventory.ini"
HOST_VARS_DIR = "host_vars"

# Vault info
VAULT_FILE_NAME = "vault.yml"

# Fetch password from 1Password
def fetch_item(item_name, vault_name, field_name):
    try:
        op_path = f"op://{vault_name}/{item_name}/{field_name}"
        result = subprocess.run(
            ["op", "read", op_path],
            capture_output=True, text=True, check=True
        )
        return result.stdout.strip()
    except subprocess.CalledProcessError as e:
        print(f"Error fetching password for {item_name}: {e.stderr}")
        sys.exit(1)

# Parse inventory.ini and return a list of hosts that does not include any groups
def expand_host_range(host):
    """
    Expands patterns like Host[1:3] to Host1, Host2, Host3.
    """
    m = re.match(r"(\w+)\[(\d+):(\d+)\]", host)
    if m:
        prefix, start, end = m.groups()
        return [f"{prefix}{i}" for i in range(int(start), int(end)+1)]
    return [host]

def get_hosts(inventory_file):
    hosts = []
    groups = set()

    # First pass: collect all group names
    with open(inventory_file) as f:
        for line in f:
            line = line.strip()
            if not line or line.startswith("#"):
                continue
            if line.startswith("[") and line.endswith("]"):
                group_name = line[1:-1].split(":")[0]  # remove :children or :vars
                groups.add(group_name)

    # Second pass: collect actual hosts
    with open(inventory_file) as f:
        for line in f:
            line = line.strip()
            if not line or line.startswith("#") or "=" in line:
                continue
            if line.startswith("[") and line.endswith("]"):
                continue  # skip group headers
            candidate_hosts = expand_host_range(line.split()[0])
            # Remove any host that matches a known group
            candidate_hosts = [h for h in candidate_hosts if h not in groups]
            hosts.extend(candidate_hosts)

    return hosts

# Create host_vars directory if it doesn't exist
def ensure_host_vars(hostname):
    path = os.path.join(HOST_VARS_DIR, hostname)
    os.makedirs(path, exist_ok=True)
    return path

# Write and encrypt vault file
def write_encrypted_vault(hostname, vault_password):
    path = ensure_host_vars(hostname)
    vault_file_path = os.path.join(path, VAULT_FILE_NAME)
    username = fetch_item(hostname, "Ansible", "username")
    password = fetch_item(hostname, "Ansible", "password")
    
    # Write plaintext vault
    with open(vault_file_path, "w") as f:
        f.write(f"ansible_user: {username}\n")
        f.write(f"ansible_ssh_private_key_file: /home/swage/private_key\n") # Ansible & 1password are not making it easy to get rid of this
        f.write(f"ansible_become_password: {password}\n")

    # Encrypt with ansible-vault
    process = subprocess.run(
        ["ansible-vault", "encrypt", vault_file_path, "--vault-password-file", vault_password],
        capture_output=True, text=True
    )
    if process.returncode != 0:
        print(f"Failed to encrypt vault for {hostname}: {process.stderr}")
    else:
        print(f"Vault for {hostname} written and encrypted successfully.")

def main():
    vault_password_file = fetch_item("Ansible-Vault", "Home Lab", "password")  # Assumes you have a "vault_password" item
    hosts = get_hosts(INVENTORY_FILE)
    print("Found hosts:", hosts)
    for host in hosts:
        write_encrypted_vault(host, "ansible-vault-password.sh")

if __name__ == "__main__":
    main()

