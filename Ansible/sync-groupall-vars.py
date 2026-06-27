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
        print(f"✅ Fetched {item_name}/{field_name} successfully.")
        return result.stdout.strip()
    except subprocess.CalledProcessError as e:
        print(f"❌ Error fetching {item_name}/{field_name}: {e.stderr}")
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
            ["ansible-vault", "encrypt", tmp_yaml_path, "--output", str(filepath), "--vault-password-file", tmp_pass_path, "--encrypt-vault-id", "default"],
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
        MARIADB_ROOT_PASSWORD=fetch_item("MARIADB_ROOT_PASSWORD", "Home Lab", "password"),
        DISCORD_CHANNEL_ID_TOKEN=fetch_item("Watchtower_Discord_Webhook_Token", "Home Lab", "password"),
        k3s_datastore_endpoint=fetch_item("K3s", "Home Lab", "password"),
        k3s_token=fetch_item("K3s Node Token", "Home Lab", "password"),
        k3s_tls_san=fetch_item("k3s", "Home Lab", "url"),
        discord_webhook_url=fetch_item("SMTP_discord_webhook_url", "Home Lab", "password"),
        COUCHDB_USER=fetch_item("CouchDB", "Home Lab", "username"),
        COUCHDB_USER_PASSWORD=fetch_item("CouchDB", "Home Lab", "password"),
        n8n_postgres_password=fetch_item("n8n PostgreSQL password", "Home Lab", "password"),
        n8n_runner_password=fetch_item("n8n runner password", "Home Lab", "password")
    )

if __name__ == "__main__":
    main()
