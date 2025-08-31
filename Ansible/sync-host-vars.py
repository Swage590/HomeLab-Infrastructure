#!/usr/bin/env python3
import tempfile
import atexit
import subprocess
import os
import sys
import re
from functools import lru_cache
import atexit
# Path to your Ansible inventory
INVENTORY_FILE = "inventory.ini"
HOST_VARS_DIR = "host_vars"

# Vault info
VAULT_FILE_NAME = "vault.yml"

# -------------------------
# Helper functions
# -------------------------

# Fetch item from 1Password
def fetch_item(item_name, vault_name, field_name):
    try:
        op_path = f"op://{vault_name}/{item_name}/{field_name}"
        result = subprocess.run(
            ["op", "read", op_path],
            capture_output=True, text=True, check=True
        )
        return result.stdout.strip()
    except subprocess.CalledProcessError as e:
        print(f"Error fetching {field_name} for {item_name}: {e.stderr}")
        sys.exit(1)

# Expand ranges like Host[1:3] -> Host1, Host2, Host3
def expand_host_range(host):
    m = re.match(r"(\w+)\[(\d+):(\d+)\]", host)
    if m:
        prefix, start, end = m.groups()
        return [f"{prefix}{i}" for i in range(int(start), int(end)+1)]
    return [host]

# Parse inventory.ini and return all hosts (exclude groups)
def get_hosts(inventory_file):
    hosts = []
    groups = set()

    # First pass: collect group names
    with open(inventory_file) as f:
        for line in f:
            line = line.strip()
            if not line or line.startswith("#"):
                continue
            if line.startswith("[") and line.endswith("]"):
                group_name = line[1:-1].split(":")[0]
                groups.add(group_name)

    # Second pass: collect hostnames
    with open(inventory_file) as f:
        for line in f:
            line = line.strip()
            if not line or line.startswith("#") or "=" in line:
                continue
            if line.startswith("[") and line.endswith("]"):
                continue
            candidate_hosts = expand_host_range(line.split()[0])
            candidate_hosts = [h for h in candidate_hosts if h not in groups]
            hosts.extend(candidate_hosts)

    return hosts

# Ensure host_vars/<hostname> directory exists
def ensure_host_vars(hostname):
    path = os.path.join(HOST_VARS_DIR, hostname)
    os.makedirs(path, exist_ok=True)
    return path

import tempfile

# Cache vault password to a temporary file
@lru_cache(maxsize=1)
def get_vault_password_file():
    vault_password = fetch_item("vault", "Ansible", "vault_password")
    tmp = tempfile.NamedTemporaryFile(delete=False, mode="w")
    tmp.write(vault_password)
    tmp.flush()
    tmp.close()
    # Register cleanup on exit
    atexit.register(lambda: os.remove(tmp.name) if os.path.exists(tmp.name) else None)
    return tmp.name

def write_encrypted_vault(hostname):
    path = ensure_host_vars(hostname)
    vault_file_path = os.path.join(path, VAULT_FILE_NAME)

    username = fetch_item(hostname, "Ansible", "username")
    password = fetch_item(hostname, "Ansible", "password")

    with open(vault_file_path, "w") as f:
        f.write(f"ansible_user: {username}\n")
        f.write(f"ansible_ssh_private_key_file: /home/swage/private_key\n")
        f.write(f"ansible_become_password: {password}\n")

    vault_password_file = get_vault_password_file()
    process = subprocess.run(
        ["ansible-vault", "encrypt", vault_file_path, "--vault-password-file", vault_password_file],
        capture_output=True, text=True
    )
    if process.returncode != 0:
        print(f"❌ Failed to encrypt vault for {hostname}: {process.stderr.strip()}")
    else:
        print(f"✅ Vault for {hostname} written and encrypted successfully.")


# -------------------------
# Main
# -------------------------

def main():
    hosts = get_hosts(INVENTORY_FILE)
    print("Found hosts:", hosts)
    for host in hosts:
        write_encrypted_vault(host)

if __name__ == "__main__":
    main()
