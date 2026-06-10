#!/usr/bin/env python3
import argparse
import tempfile
import atexit
import subprocess
import os
import sys
import re
from functools import lru_cache
import configparser

# -------------------------
# Configuration & Defaults
# -------------------------

def get_default_inventory():
    """Determine the default inventory path from ansible.cfg or use the standard fallback."""
    ansible_cfg = os.environ.get("ANSIBLE_CONFIG", "ansible.cfg")
    fallback_inventory = "inventory.ini"

    if os.path.exists(ansible_cfg):
        config = configparser.ConfigParser()
        config.read(ansible_cfg)
        if "defaults" in config and "inventory" in config["defaults"]:
            return config["defaults"]["inventory"]
            
    return fallback_inventory

HOST_VARS_DIR = "host_vars"
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
import re

def expand_host_range(host):
    # The regex now captures 4 groups: Prefix, Start, End, and Suffix
    m = re.match(r"(.*?)\[(\d+):(\d+)\](.*)", host)
    if m:
        prefix, start, end, suffix = m.groups()
        
        # Preserves leading zeros if your range is [01:03]
        pad = len(start) if start.startswith('0') else 0
        
        # Rebuild the string including the suffix
        return [f"{prefix}{str(i).zfill(pad)}{suffix}" for i in range(int(start), int(end)+1)]
        
    return [host]

# Parse inventory file and return all hosts (exclude groups)
def get_hosts(inventory_file):
    if not os.path.exists(inventory_file):
        print(f"❌ Error: Inventory file '{inventory_file}' not found.")
        sys.exit(1)

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

# Cache vault password to a temporary file
@lru_cache(maxsize=1)
def get_vault_password_file():
    vault_password = fetch_item("Ansible-Vault", "Home Lab", "password")
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
        ["ansible-vault", "encrypt", vault_file_path, "--vault-password-file", vault_password_file, "--encrypt-vault-id", "default"],
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
    # Setup CLI argument parsing
    parser = argparse.ArgumentParser(description="Generate encrypted Ansible vault files from a 1Password backend.")
    parser.add_argument(
        "-i", "--inventory", 
        type=str, 
        default=get_default_inventory(),
        help="Path to the custom inventory file. Defaults to ansible.cfg selection or inventory.ini."
    )
    args = parser.parse_args()

    print(f"📋 Using inventory file: {args.inventory}")
    
    hosts = get_hosts(args.inventory)
    print("Found hosts:", hosts)
    
    for host in hosts:
        write_encrypted_vault(host)

if __name__ == "__main__":
    main()
