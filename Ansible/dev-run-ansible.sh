#!/bin/bash
# Check if the 1Password CLI is already authenticated by trying to list accounts
# Redirecting stderr to dev/null so it stays clean if you aren't signed in
if ! op account list &> /dev/null; then
    echo "🔒 1Password CLI is not authenticated. Starting sign-in..."
    
    # eval $(op signin) requires your input for the master password
    eval "$(op signin)"
    
    # Verify if the sign-in was successful
    if [ $? -eq 0 ]; then
        echo "✅ Successfully authenticated with 1Password!"
    else
        echo "❌ Authentication failed or was cancelled."
        return 1
    fi
else
    echo "✅ Already authenticated with 1Password."
fi

echo "🔄 Running sync-groupall-vars.py..."
./sync-groupall-vars.py

echo "🔄 Running sync-host-vars.py..."
./sync-host-vars.py -i ./inventory-dev.ini

echo "🔑 Setting up SSH key..."
ansible-playbook setup-ssh-key.yml

# Ensure cleanup runs even if the playbook fails or you exit early
trap 'echo "🧹 Cleaning up SSH key..."; ansible-playbook cleanup-ssh-key.yml' EXIT

echo "🚀 Starting Ansible Playbook..."
ansible-playbook main-dev.yml -i ./inventory-dev.ini --vault-password-file ./vault-password.sh --key-file ~/private_key
