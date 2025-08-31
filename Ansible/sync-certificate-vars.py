#!/usr/bin/env python3
import subprocess
import sys
import tempfile
import yaml
from pathlib import Path

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

def write_ansible_vault_yaml(filepath: str, vault_password: str, **data):
    filepath = Path(filepath)

    # Dump dictionary to YAML
    yaml_content = yaml.dump(data, default_flow_style=False, sort_keys=False)

    # Write YAML to a temporary file
    with tempfile.NamedTemporaryFile("w", delete=False) as tmp_yaml:
        tmp_yaml.write(yaml_content)
        tmp_yaml_path = tmp_yaml.name

    # Write vault password to a temporary file
    with tempfile.NamedTemporaryFile("w", delete=False) as tmp_pass:
        tmp_pass.write(vault_password)
        tmp_pass_path = tmp_pass.name

    try:
        # Encrypt using ansible-vault
        process = subprocess.run(
            ["ansible-vault", "encrypt", tmp_yaml_path, "--output", str(filepath), "--vault-password-file", tmp_pass_path],
            check=True
        )
        if process.returncode != 0:
            print(f"❌ Failed to encrypt vault at {filepath}: {process.stderr.strip()}")
        else:
            print(f"✅ Vault at {filepath} written and encrypted successfully.")
    finally:
        # Clean up temp files
        Path(tmp_yaml_path).unlink(missing_ok=True)
        Path(tmp_pass_path).unlink(missing_ok=True)

def main():
    vault_password = fetch_item("Ansible-Vault", "Home Lab", "password")

    write_ansible_vault_yaml(
        "group_vars/all/vault.yml",
        vault_password,
        certificates_ca_address_or_ip=fetch_item("Step-CA", "Home Lab", "url"),
        certificates_fingerprint=fetch_item("Step-CA", "Home Lab", "SmallStep Info/X.509 Root Fingerprint"),
    )

if __name__ == "__main__":
    main()
