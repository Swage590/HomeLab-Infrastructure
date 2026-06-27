#!/bin/bash
# Parse arguments
SKIP_SYNC=0
ENVIRONMENT="dev"
ANSIBLE_ARGS=()

LIMIT_ARG=""

while [[ "$#" -gt 0 ]]; do
    case $1 in
        --skip-sync) SKIP_SYNC=1; shift ;;
        --dev) ENVIRONMENT="dev"; shift ;;
        --prod) ENVIRONMENT="prod"; shift ;;
        --env) ENVIRONMENT="$2"; shift 2 ;;
        --limit|-l) LIMIT_ARG="$2"; ANSIBLE_ARGS+=("$1" "$2"); shift 2 ;;
        --limit=*) LIMIT_ARG="${1#*=}"; ANSIBLE_ARGS+=("$1"); shift ;;
        -l=*) LIMIT_ARG="${1#*=}"; ANSIBLE_ARGS+=("$1"); shift ;;
        *) ANSIBLE_ARGS+=("$1"); shift ;;
    esac
done

if [ "$ENVIRONMENT" == "dev" ]; then
    INVENTORY="./inventory-dev.ini"
    PLAYBOOK="main-dev.yml"
elif [ "$ENVIRONMENT" == "prod" ]; then
    INVENTORY="./inventory.ini"
    PLAYBOOK="main.yml"
else
    echo "❌ Unknown environment: $ENVIRONMENT. Use --dev or --prod."
    exit 1
fi

echo "🌍 Running for environment: $ENVIRONMENT"

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
        exit 1
    fi
else
    echo "✅ Already authenticated with 1Password."
fi

if [ "$SKIP_SYNC" -eq 0 ]; then
    echo "🔄 Running sync-groupall-vars.py..."
    ./sync-groupall-vars.py

    if [ -n "$LIMIT_ARG" ]; then
        echo "🔄 Running sync-host-vars.py with limit: $LIMIT_ARG..."
        ./sync-host-vars.py -i "$INVENTORY" --limit "$LIMIT_ARG"
    else
        echo "🔄 Running sync-host-vars.py..."
        ./sync-host-vars.py -i "$INVENTORY"
    fi
else
    echo "⏭️  Skipping python sync scripts (--skip-sync provided)..."
fi

echo "🔑 Setting up SSH key..."
ansible-playbook setup-ssh-key.yml

# Ensure cleanup runs even if the playbook fails or you exit early
trap 'echo "🧹 Cleaning up SSH key..."; ansible-playbook cleanup-ssh-key.yml' EXIT

echo "🚀 Starting Ansible Playbook..."
ansible-playbook "$PLAYBOOK" -i "$INVENTORY" --vault-password-file ./vault-password.sh --key-file ~/private_key "${ANSIBLE_ARGS[@]}"
