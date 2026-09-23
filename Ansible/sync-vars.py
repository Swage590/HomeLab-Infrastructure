#!/usr/bin/env python3
"""
sync-vars.py: Unified synchronization of Ansible Vault variables from 1Password.

Reads group variable mappings from vault-manifest.yml, discovers hosts from the
inventory, queries 1Password concurrently, and writes encrypted Ansible Vault files.
"""

import argparse
import configparser
import os
import re
import subprocess
import sys
import tempfile
from concurrent.futures import ThreadPoolExecutor, as_completed
from contextlib import contextmanager
from pathlib import Path
import yaml

ANSIBLE_DIR = Path(__file__).resolve().parent

# -----------------------------------------------------------------------------
# Configuration & Defaults
# -----------------------------------------------------------------------------

def get_default_inventory() -> str:
    """Determine default inventory path from ANSIBLE_CONFIG, ansible.cfg, or fallback."""
    ansible_cfg = os.environ.get("ANSIBLE_CONFIG", str(ANSIBLE_DIR / "ansible.cfg"))
    fallback = str(ANSIBLE_DIR / "inventory.ini")

    if os.path.exists(ansible_cfg):
        config = configparser.ConfigParser()
        config.read(ansible_cfg)
        if "defaults" in config and "inventory" in config["defaults"]:
            inv = config["defaults"]["inventory"]
            # Resolve relative to ANSIBLE_DIR if needed
            return str((ANSIBLE_DIR / inv).resolve()) if not os.path.isabs(inv) else inv

    return fallback


def load_manifest(manifest_path: Path) -> dict:
    """Load the vault manifest YAML file."""
    if not manifest_path.exists():
        print(f"❌ Error: Manifest file '{manifest_path}' not found.", file=sys.stderr)
        sys.exit(1)
    with open(manifest_path, "r") as f:
        return yaml.safe_load(f)


# -----------------------------------------------------------------------------
# 1Password Fetching
# -----------------------------------------------------------------------------

def fetch_op_item(uri: str) -> str:
    """Fetch a single secret field from 1Password using `op read`."""
    try:
        result = subprocess.run(
            ["op", "read", uri],
            capture_output=True,
            text=True,
            check=True
        )
        return result.stdout.strip()
    except subprocess.CalledProcessError as e:
        print(f"❌ Error fetching '{uri}': {e.stderr.strip()}", file=sys.stderr)
        raise


def fetch_mapping_parallel(var_to_uri: dict[str, str], max_workers: int = 8) -> dict[str, str]:
    """Concurrently fetch multiple secrets from 1Password given a {var_name: uri} mapping."""
    results = {}
    with ThreadPoolExecutor(max_workers=max_workers) as executor:
        future_to_var = {
            executor.submit(fetch_op_item, uri): var_name
            for var_name, uri in var_to_uri.items()
        }
        for future in as_completed(future_to_var):
            var_name = future_to_var[future]
            try:
                results[var_name] = future.result()
            except Exception:
                print(f"❌ Failed to fetch secret for variable: {var_name}", file=sys.stderr)
                sys.exit(1)
    return results


# -----------------------------------------------------------------------------
# Vault Encryption Helpers
# -----------------------------------------------------------------------------

@contextmanager
def temp_vault_password_file(vault_password: str):
    """Context manager creating a secured temporary file containing the vault password."""
    tmp = tempfile.NamedTemporaryFile(mode="w", delete=False)
    try:
        os.chmod(tmp.name, 0o600)
        tmp.write(vault_password)
        tmp.flush()
        tmp.close()
        yield tmp.name
    finally:
        Path(tmp.name).unlink(missing_ok=True)


def write_encrypted_vault_yaml(filepath: Path, data: dict, vault_password_file: str):
    """Safely write YAML to a temporary file and encrypt into target location using ansible-vault."""
    filepath.parent.mkdir(parents=True, exist_ok=True)
    yaml_content = yaml.dump(data, default_flow_style=False, sort_keys=False)

    with tempfile.NamedTemporaryFile("w", delete=False) as tmp_yaml:
        tmp_yaml.write(yaml_content)
        tmp_yaml_path = tmp_yaml.name

    try:
        subprocess.run(
            [
                "ansible-vault", "encrypt", tmp_yaml_path,
                "--output", str(filepath.resolve()),
                "--vault-password-file", vault_password_file,
                "--encrypt-vault-id", "default"
            ],
            capture_output=True,
            text=True,
            check=True
        )
        print(f"✅ Encrypted vault written to {filepath}")
    except subprocess.CalledProcessError as e:
        print(f"❌ Failed to encrypt vault at {filepath}: {e.stderr.strip()}", file=sys.stderr)
        sys.exit(1)
    finally:
        Path(tmp_yaml_path).unlink(missing_ok=True)


# -----------------------------------------------------------------------------
# Inventory & Host Parsing
# -----------------------------------------------------------------------------

def expand_host_range(host: str) -> list[str]:
    """Expand host ranges like host[1:3] or host[01:03]."""
    m = re.match(r"(.*?)\[(\d+):(\d+)\](.*)", host)
    if m:
        prefix, start, end, suffix = m.groups()
        pad = len(start) if start.startswith('0') else 0
        return [f"{prefix}{str(i).zfill(pad)}{suffix}" for i in range(int(start), int(end) + 1)]
    return [host]


def get_hosts_from_inventory(inventory_file: str) -> list[str]:
    """Parse hosts from an INI inventory file, excluding group headers and vars sections."""
    if not os.path.exists(inventory_file):
        print(f"❌ Error: Inventory file '{inventory_file}' not found.", file=sys.stderr)
        sys.exit(1)

    groups = set()
    with open(inventory_file) as f:
        for line in f:
            line = line.strip()
            if not line or line.startswith("#"):
                continue
            if line.startswith("[") and line.endswith("]"):
                group_name = line[1:-1].split(":")[0]
                groups.add(group_name)

    hosts = []
    with open(inventory_file) as f:
        in_vars_section = False
        for line in f:
            line = line.strip()
            if not line or line.startswith("#"):
                continue
            if line.startswith("[") and line.endswith("]"):
                in_vars_section = line.endswith(":vars]")
                continue
            if in_vars_section:
                continue

            first_token = line.split()[0]
            if "=" in first_token:
                continue

            candidate_hosts = expand_host_range(first_token)
            candidate_hosts = [h for h in candidate_hosts if h not in groups]
            hosts.extend(candidate_hosts)

    return list(dict.fromkeys(hosts))


# -----------------------------------------------------------------------------
# Synchronization Tasks
# -----------------------------------------------------------------------------

def sync_group_vars(manifest: dict, vault_password_file: str, max_workers: int):
    """Synchronize group variables defined in the manifest."""
    groups_config = manifest.get("groups", {})
    if not groups_config:
        print("ℹ️  No group variables configured in manifest.")
        return

    for group_name, var_mappings in groups_config.items():
        print(f"\n📦 Fetching secrets for group: {group_name} ({len(var_mappings)} variables)...")
        fetched_vars = fetch_mapping_parallel(var_mappings, max_workers=max_workers)
        output_path = ANSIBLE_DIR / "group_vars" / group_name / "vault.yml"
        write_encrypted_vault_yaml(output_path, fetched_vars, vault_password_file)


def sync_host_vars(hosts: list[str], manifest: dict, vault_password_file: str, max_workers: int):
    """Synchronize host variables for discovered inventory hosts."""
    if not hosts:
        print("ℹ️  No hosts to sync.")
        return

    hosts_config = manifest.get("hosts", {})
    vault_name = hosts_config.get("vault", "Ansible")
    static_vars = hosts_config.get("static_vars", {})
    dynamic_vars = hosts_config.get("dynamic_vars", {})

    print(f"\n🖥️  Syncing vault variables for {len(hosts)} host(s)...")

    # Build all URIs across all hosts to fetch concurrently
    # Key format: (hostname, var_name) -> URI
    lookup_map = {}
    for hostname in hosts:
        short_hostname = hostname.split('.')[0]
        for var_name, field_name in dynamic_vars.items():
            uri = f"op://{vault_name}/{short_hostname}/{field_name}"
            lookup_map[f"{hostname}:{var_name}"] = uri

    fetched_all = fetch_mapping_parallel(lookup_map, max_workers=max_workers)

    for hostname in hosts:
        host_data = dict(static_vars)
        for var_name in dynamic_vars:
            key = f"{hostname}:{var_name}"
            host_data[var_name] = fetched_all[key]

        output_path = ANSIBLE_DIR / "host_vars" / hostname / "vault.yml"
        write_encrypted_vault_yaml(output_path, host_data, vault_password_file)


# -----------------------------------------------------------------------------
# Main CLI Entrypoint
# -----------------------------------------------------------------------------

def main():
    parser = argparse.ArgumentParser(
        description="Unified synchronization of Ansible Vault variables from 1Password backend."
    )
    parser.add_argument(
        "-i", "--inventory",
        type=str,
        default=get_default_inventory(),
        help="Path to the inventory file (defaults to ansible.cfg or inventory.ini)."
    )
    parser.add_argument(
        "-l", "--limit",
        type=str,
        default=None,
        help="Limit host synchronization to comma-separated hosts."
    )
    parser.add_argument(
        "-c", "--config",
        type=str,
        default=str(ANSIBLE_DIR / "vault-manifest.yml"),
        help="Path to vault-manifest.yml configuration."
    )
    parser.add_argument(
        "--groups-only",
        action="store_true",
        help="Only sync group variables (skip host variables)."
    )
    parser.add_argument(
        "--hosts-only",
        action="store_true",
        help="Only sync host variables (skip group variables)."
    )
    parser.add_argument(
        "-w", "--workers",
        type=int,
        default=8,
        help="Number of concurrent worker threads for 1Password lookups (default: 8)."
    )

    args = parser.parse_args()

    manifest_path = Path(args.config).resolve()
    manifest = load_manifest(manifest_path)

    # 1. Fetch Master Ansible Vault Password once
    vault_pw_uri = manifest.get("vault_password", {}).get("uri", "op://Home Lab/Ansible-Vault/password")
    print(f"🔑 Fetching master Ansible Vault password from {vault_pw_uri}...")
    vault_password = fetch_op_item(vault_pw_uri)

    with temp_vault_password_file(vault_password) as vault_pw_file:
        # 2. Sync Group Variables (unless --hosts-only is passed)
        if not args.hosts_only:
            sync_group_vars(manifest, vault_pw_file, max_workers=args.workers)

        # 3. Sync Host Variables (unless --groups-only is passed)
        if not args.groups_only:
            hosts = get_hosts_from_inventory(args.inventory)
            if args.limit:
                limit_list = [h.strip() for h in args.limit.split(",") if h.strip()]
                hosts = [h for h in hosts if h in limit_list]
                print(f"🎯 Filtered hosts with limit '{args.limit}': {hosts}")
            sync_host_vars(hosts, manifest, vault_pw_file, max_workers=args.workers)

    print("\n✨ All vault variables synchronized successfully.")


if __name__ == "__main__":
    main()
