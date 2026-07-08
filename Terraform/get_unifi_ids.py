import subprocess
import json
import re
import os
import requests
import urllib3
import time
import ssl
from urllib.parse import urlparse

try:
    import websocket
except ImportError:
    print("\n[ERROR] The 'websocket-client' library is missing.")
    print("Xen Orchestra requires a WebSocket connection for its API.")
    print("Run this command and try again:\n  pip install websocket-client\n")
    exit(1)

# Suppress insecure HTTPS request warnings
urllib3.disable_warnings(urllib3.exceptions.InsecureRequestWarning)

TFVARS_FILE = "virtual-machines.auto.tfvars"
OP_VAULT_NAME = "Home Lab"
OP_ANSIBLE_VAULT_ID = "lqttkuu6qlvnzrcxpemr6w376i" # From your Terraform code

# Update these to match your exact 1Password item titles!
OP_UNIFI_ITEM_NAME = "Terraform Unifi"
OP_XO_ITEM_NAME = "Xen Orchestra 5 XO-CE"

def get_op_credentials(item_name):
    print(f"Fetching credentials from 1Password ('{item_name}')...")
    try:
        cmd = ["op", "item", "get", item_name, "--vault", OP_VAULT_NAME, "--format", "json"]
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
            raise ValueError(f"Could not find username, password, or URL in 1Password item: {item_name}")
            
        return username, password, url
    except subprocess.CalledProcessError as e:
        print(f"Error fetching '{item_name}' from 1Password: {e.stderr}")
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
    print(f"[IMPORTING] {resource_address} with ID {import_id}...")
    cmd = ["terraform", "import", resource_address, import_id]
    
    max_retries = 3
    for attempt in range(max_retries):
        try:
            subprocess.run(cmd, capture_output=True, text=True, check=True)
            print("  -> Success!")
            time.sleep(5) 
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
        return
        
    print("Fetching client data from UniFi API...")
    users_url = f"{base_url}/proxy/network/api/s/default/stat/alluser"
    users_resp = session.get(users_url)
    
    if not users_resp.ok:
        print(f"Failed to fetch users: {users_resp.status_code} - {users_resp.text}")
        return
        
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
            print(f"[WARNING] Could not find UniFi ID for {vm_name} (MAC: {mac}).")

def get_op_item_id(item_name, vault_id):
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
            
        item_id = get_op_item_id(vm_name, OP_ANSIBLE_VAULT_ID)
        
        if item_id:
            import_id = f"vaults/{OP_ANSIBLE_VAULT_ID}/items/{item_id}"
            run_terraform_import(resource_address, import_id)
        else:
            print(f"[WARNING] Could not find 1Password item named '{vm_name}' in vault {OP_ANSIBLE_VAULT_ID}.")

def execute_xo_imports(username, password, base_url, vms, existing_state):
    print(f"\nAuthenticating to Xen Orchestra via WebSocket at {base_url}...")
    
    # Translate HTTP/HTTPS to WS/WSS
    parsed_url = urlparse(base_url)
    ws_scheme = "wss" if parsed_url.scheme == "https" else "ws"
    ws_url = f"{ws_scheme}://{parsed_url.netloc}/api/"
    
    print(f"Using WebSocket endpoint: {ws_url}")
    
    try:
        # Ignore SSL verification for self-signed homelab certs
        ws = websocket.create_connection(ws_url, sslopt={"cert_reqs": ssl.CERT_NONE})
    except Exception as e:
        print(f"ERROR: Failed to connect to WebSocket: {e}")
        return

    # 1. Authenticate via JSON-RPC
    auth_payload = {
        "jsonrpc": "2.0",
        "method": "session.signIn",
        "params": {"email": username, "password": password},
        "id": 1
    }
    ws.send(json.dumps(auth_payload))
    auth_resp = json.loads(ws.recv())
    
    if 'error' in auth_resp:
        print(f"Failed to authenticate to XO: {auth_resp['error']}")
        ws.close()
        return

    # 2. Get all VMs via JSON-RPC
    print("Fetching VM data from Xen Orchestra WebSocket API...")
    vms_payload = {
        "jsonrpc": "2.0",
        "method": "xo.getAllObjects",
        "params": {"filter": {"type": "VM"}},
        "id": 2
    }
    ws.send(json.dumps(vms_payload))
    vms_resp = json.loads(ws.recv())
    ws.close()

    if 'error' in vms_resp:
         print(f"XO API Error: {vms_resp['error']}")
         return

    xo_objects = vms_resp.get('result', {})
    
    name_to_uuid = {}
    for obj_id, obj_data in xo_objects.items():
        if obj_data.get('type') == 'VM':
            name_to_uuid[obj_data.get('name_label')] = obj_id

    print("\n--- Starting Xen Orchestra Terraform Imports ---\n")
    for vm_name in vms.keys():
        resource_address = f'xenorchestra_vm.ubuntu_vm["{vm_name}"]'
        
        if resource_address in existing_state:
            print(f"[SKIP] {resource_address} is already in the Terraform state.")
            continue
            
        vm_uuid = name_to_uuid.get(vm_name)
        if vm_uuid:
            run_terraform_import(resource_address, vm_uuid)
        else:
            print(f"[WARNING] Could not find Xen Orchestra VM named '{vm_name}'.")

if __name__ == "__main__":
    vms = parse_tfvars()
    existing_state = get_terraform_state()
    
    # 1. Handle UniFi Imports
    unifi_user, unifi_pass, unifi_url = get_op_credentials(OP_UNIFI_ITEM_NAME)
    execute_unifi_imports(unifi_user, unifi_pass, unifi_url, vms, existing_state)
    
    # 2. Handle Xen Orchestra Imports
    xo_user, xo_pass, xo_url = get_op_credentials(OP_XO_ITEM_NAME)
    execute_xo_imports(xo_user, xo_pass, xo_url, vms, existing_state)

    # 3. Handle 1Password Imports
    execute_1password_imports(vms, existing_state)
    
    print("\nAll import routines completed.")
