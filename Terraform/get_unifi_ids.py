import subprocess
import json
import re
import os
import requests
import urllib3
import time

# Suppress insecure HTTPS request warnings for self-signed UniFi certs
urllib3.disable_warnings(urllib3.exceptions.InsecureRequestWarning)

TFVARS_FILE = "virtual-machines.auto.tfvars"
OP_UNIFI_ITEM_NAME = "Terraform Unifi"
OP_UNIFI_VAULT_NAME = "Home Lab"
OP_ANSIBLE_VAULT_ID = "lqttkuu6qlvnzrcxpemr6w376i" # From your Terraform code

def get_op_credentials():
    print(f"Fetching UniFi credentials from 1Password ('{OP_UNIFI_ITEM_NAME}')...")
    try:
        cmd = ["op", "item", "get", OP_UNIFI_ITEM_NAME, "--vault", OP_UNIFI_VAULT_NAME, "--format", "json"]
        result = subprocess.run(cmd, capture_output=True, text=True, check=True)
        item_data = json.loads(result.stdout)
        
        username, password, url = None, None, None
        
        for field in item_data.get("fields", []):
            if field.get("id") == "username":
                username = field.get("value")
            elif field.get("id") == "password":
                password = field.get("value")
                
        if item_data.get("urls"):
            url = item_data["urls"][0].get("href").rstrip('/')
            
        if not all([username, password, url]):
            raise ValueError("Could not find username, password, or URL in the UniFi 1Password item.")
            
        return username, password, url
    except subprocess.CalledProcessError as e:
        print(f"Error fetching UniFi creds from 1Password: {e.stderr}")
        exit(1)

def parse_tfvars():
    print(f"Parsing {TFVARS_FILE} for VMs and MAC addresses...")
    if not os.path.exists(TFVARS_FILE):
        print(f"Error: {TFVARS_FILE} not found in the current directory.")
        exit(1)
        
    with open(TFVARS_FILE, 'r') as f:
        content = f.read()
        
    pattern = re.compile(r'(\w+)\s*=\s*\{[^{]*?mac\s*=\s*"([a-fA-F0-9:]+)"', re.DOTALL)
    
    vms = {}
    for match in pattern.finditer(content):
        vm_name = match.group(1)
        mac_addr = match.group(2).lower()
        vms[vm_name] = mac_addr
        
    print(f"Found {len(vms)} VMs in tfvars file.")
    return vms

def get_terraform_state():
    print("Checking current Terraform state...")
    try:
        result = subprocess.run(["terraform", "state", "list"], capture_output=True, text=True, check=True)
        return set(result.stdout.splitlines())
    except subprocess.CalledProcessError as e:
        print(f"Warning: Could not read Terraform state ({e}). Defaulting to empty state.")
        return set()

def run_terraform_import(resource_address, import_id):
    """Helper function to execute terraform import with rate limit protection."""
    print(f"[IMPORTING] {resource_address} with ID {import_id}...")
    cmd = ["terraform", "import", resource_address, import_id]
    
    max_retries = 3
    for attempt in range(max_retries):
        try:
            subprocess.run(cmd, capture_output=True, text=True, check=True)
            print("  -> Success!")
            return True
        except subprocess.CalledProcessError as e:
            stderr = e.stderr or ""
            if "429" in stderr or "Too Many Requests" in stderr:
                wait_time = 15 * (attempt + 1)
                print(f"  -> RATE LIMITED (429). Waiting {wait_time}s before retrying (Attempt {attempt+1}/{max_retries})...")
                time.sleep(wait_time)
            else:
                print(f"  -> ERROR: Failed to import {resource_address}")
                print(f"     {stderr.strip().splitlines()[-1] if stderr else 'Unknown error'}")
                return False
    return False

def execute_unifi_imports(username, password, base_url, vms, existing_state):
    print(f"\nAuthenticating to UniFi Controller at {base_url}...")
    session = requests.Session()
    session.verify = False 
    
    auth_url = f"{base_url}/api/auth/login"
    auth_resp = session.post(auth_url, json={"username": username, "password": password})
    
    if not auth_resp.ok:
        print(f"Failed to authenticate: {auth_resp.status_code} - {auth_resp.text}")
        exit(1)
        
    print("Fetching client data from UniFi API...")
    users_url = f"{base_url}/proxy/network/api/s/default/stat/alluser"
    users_resp = session.get(users_url)
    
    if not users_resp.ok:
        print(f"Failed to fetch users: {users_resp.status_code} - {users_resp.text}")
        exit(1)
        
    client_data = users_resp.json().get('data', [])
    mac_to_id = {client.get('mac'): client.get('_id') for client in client_data if 'mac' in client}
    
    print("\n--- Starting UniFi Terraform Imports ---\n")
    for vm_name, mac in vms.items():
        resource_address = f'unifi_user.client["{vm_name}"]'
        
        if resource_address in existing_state:
            print(f"[SKIP] {resource_address} is already in the Terraform state.")
            continue
            
        unifi_id = mac_to_id.get(mac)
        if unifi_id:
            run_terraform_import(resource_address, unifi_id)
        else:
            print(f"[WARNING] Could not find UniFi ID for {vm_name} (MAC: {mac}) in the UniFi controller.")

def get_op_item_id(item_name, vault_id):
    """Fetches the 1Password item ID by name and vault ID."""
    try:
        cmd = ["op", "item", "get", item_name, "--vault", vault_id, "--format", "json"]
        result = subprocess.run(cmd, capture_output=True, text=True, check=True)
        item_data = json.loads(result.stdout)
        return item_data.get("id")
    except subprocess.CalledProcessError:
        return None

def execute_1password_imports(vms, existing_state):
    print("\n--- Starting 1Password Terraform Imports ---\n")
    for vm_name in vms.keys():
        resource_address = f'onepassword_item._1pass_vm_entry["{vm_name}"]'
        
        if resource_address in existing_state:
            print(f"[SKIP] {resource_address} is already in the Terraform state.")
            continue
            
        # The 1Password item title matches the VM name
        item_id = get_op_item_id(vm_name, OP_ANSIBLE_VAULT_ID)
        
        if item_id:
            # Terraform 1Password provider requires vaults/<vault_id>/items/<item_id>
            import_id = f"vaults/{OP_ANSIBLE_VAULT_ID}/items/{item_id}"
            run_terraform_import(resource_address, import_id)
        else:
            print(f"[WARNING] Could not find 1Password item named '{vm_name}' in vault {OP_ANSIBLE_VAULT_ID}.")

if __name__ == "__main__":
    vms = parse_tfvars()
    existing_state = get_terraform_state()
    
    # 1. Handle UniFi Imports
    unifi_user, unifi_pass, unifi_url = get_op_credentials()
    execute_unifi_imports(unifi_user, unifi_pass, unifi_url, vms, existing_state)
    
    # 2. Handle 1Password Imports
    execute_1password_imports(vms, existing_state)
