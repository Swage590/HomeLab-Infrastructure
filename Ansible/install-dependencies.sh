#!/usr/bin/env bash
set -euo pipefail

# Determine target non-root user and home directory
TARGET_USER="${SUDO_USER:-$USER}"
USER_HOME=$(getent passwd "$TARGET_USER" | cut -d: -f6)

# Ansible Collections for Installation
COLLECTION_NAME="kewlfft.aur"

log() {
  echo -e "\033[1;32m[+] $1\033[0m"
}

# 1. Distro Detection
if [ -f /etc/os-release ]; then
  . /etc/os-release
  DISTRO_ID="${ID:-}"
  DISTRO_LIKE="${ID_LIKE:-}"
else
  echo "[-] Cannot identify distribution via /etc/os-release" >&2
  exit 1
fi

# 2. Package Installation
if [[ "$DISTRO_ID" == "ubuntu" || "$DISTRO_ID" == "debian" || "$DISTRO_LIKE" =~ (ubuntu|debian) ]]; then
  log "Configuring 1Password on Debian/Ubuntu..."

  export DEBIAN_FRONTEND=noninteractive
  sudo apt-get update -y
  sudo apt-get install -y curl gpg ca-certificates
  
  # Ensure basic prerequisites are present
  PREREQS=()
  for pkg in curl gpg ca-certificates software-properties-common; do
    if ! dpkg -s "$pkg" >/dev/null 2>&1; then
      PREREQS+=("$pkg")
    fi
  done

  if [ ${#PREREQS[@]} -gt 0 ]; then
    log "Installing prerequisites: ${PREREQS[*]}..."
    sudo apt-get update -y
    sudo DEBIAN_FRONTEND=noninteractive apt-get install -y "${PREREQS[@]}"
  fi

  NEEDS_APT_UPDATE=false

  # 1. Configure 1Password Repository
  if [ ! -f /usr/share/keyrings/1password-archive-keyring.gpg ]; then
    log "Adding 1Password GPG key..."
    curl -sS https://downloads.1password.com/linux/keys/1password.asc \
      | sudo gpg --dearmor --output /usr/share/keyrings/1password-archive-keyring.gpg
  fi

  APT_1P_FILE="/etc/apt/sources.list.d/1password.list"
  if [ ! -f "$APT_1P_FILE" ]; then
    log "Adding 1Password APT repository..."
    echo 'deb [arch=amd64,arm64 signed-by=/usr/share/keyrings/1password-archive-keyring.gpg] https://downloads.1password.com/linux/debian/amd64 stable main' \
      | sudo tee "$APT_1P_FILE" > /dev/null
    NEEDS_APT_UPDATE=true
  fi

  # 2. Configure Ansible PPA
  if ! compgen -G "/etc/apt/sources.list.d/*ansible*.sources" >/dev/null && \
    ! compgen -G "/etc/apt/sources.list.d/*ansible*.list" >/dev/null; then
    log "Adding Ansible PPA..."
    # --update automatically updates apt lists for this PPA
    sudo add-apt-repository --yes --update ppa:ansible/ansible
  fi

  # 3. Refresh Apt cache if 1Password was newly added
  if [ "$NEEDS_APT_UPDATE" = true ]; then
    sudo apt-get update -y
  fi

  # 4. Unified Package Installation Loop
  TARGET_PACKAGES=(1password 1password-cli ansible)

  for pkg in "${TARGET_PACKAGES[@]}"; do
    if ! dpkg -s "$pkg" >/dev/null 2>&1; then
      log "Installing $pkg..."
      sudo DEBIAN_FRONTEND=noninteractive apt-get install -y "$pkg"
    else
      log "$pkg is already installed."
    fi
  done

elif [[ "$DISTRO_ID" == "arch" || "$DISTRO_LIKE" =~ arch ]]; then
  log "Configuring packages on Arch Linux..."

  # Install prerequisites and Ansible from official Arch repositories
  sudo pacman -Sy --needed --noconfirm base-devel git curl ansible

  # 1. Import official 1Password signing key for the target user
  log "Importing 1Password signing key..."
  curl -sS https://downloads.1password.com/linux/keys/1password.asc \
    | sudo -u "$TARGET_USER" gpg --import

  # 2. Function to clone and build AUR packages as per official instructions
  install_aur_pkg() {
    local pkg="$1"
    if pacman -Qi "$pkg" >/dev/null 2>&1; then
      log "$pkg is already installed."
      return 0
    fi

    log "Cloning and installing $pkg from AUR..."
    local build_dir
    build_dir=$(sudo -u "$TARGET_USER" mktemp -d "/tmp/${pkg}-build.XXXXXX")

    sudo -u "$TARGET_USER" git clone "https://aur.archlinux.org/${pkg}.git" "$build_dir"
    (
      cd "$build_dir"
      sudo -u "$TARGET_USER" makepkg -si --noconfirm
    )
    rm -rf "$build_dir"
  }

  # Install 1Password and 1Password CLI
  install_aur_pkg "1password"
  install_aur_pkg "1password-cli"

else
  echo "[-] Unsupported distribution: $DISTRO_ID" >&2
  exit 1
fi

# Install the collections defined in the variable at the top of the script
if sudo -u "$TARGET_USER" ansible-galaxy collection list "$COLLECTION_NAME" >/dev/null 2>&1; then
  log "Ansible collection $COLLECTION_NAME is already installed."
else
  log "Installing Ansible collection $COLLECTION_NAME..."
  sudo -u "$TARGET_USER" ansible-galaxy collection install "$COLLECTION_NAME"
fi

# 3. Write 1Password SSH Agent Config
AGENT_DIR="$USER_HOME/.config/1Password/ssh"
AGENT_FILE="$AGENT_DIR/agent.toml"

log "Ensuring $AGENT_FILE is configured..."
mkdir -p "$AGENT_DIR"
chown "$TARGET_USER":"$TARGET_USER" "$AGENT_DIR"

cat <<'EOF' > "$AGENT_FILE"
[[ssh-keys]]
vault = "Home Lab"
EOF

chown "$TARGET_USER":"$TARGET_USER" "$AGENT_FILE"
chmod 600 "$AGENT_FILE"

# 4. Configure ~/.ssh/config for 1Password Agent Integration
SSH_DIR="$USER_HOME/.ssh"
SSH_CONFIG="$SSH_DIR/config"
mkdir -p "$SSH_DIR"
chown "$TARGET_USER":"$TARGET_USER" "$SSH_DIR"
chmod 700 "$SSH_DIR"
touch "$SSH_CONFIG"

# Append IdentityAgent block only if not already present
AGENT_SOCK='~/.1password/agent.sock'
if ! grep -q "IdentityAgent $AGENT_SOCK" "$SSH_CONFIG"; then
  log "Adding IdentityAgent directive to $SSH_CONFIG..."
  cat <<'EOF' >> "$SSH_CONFIG"

Host *
    IdentityAgent ~/.1password/agent.sock
EOF
fi

chown "$TARGET_USER":"$TARGET_USER" "$SSH_CONFIG"
chmod 600 "$SSH_CONFIG"

log "Setup complete! Open 1Password and ensure 'Use the SSH agent' is enabled under Settings > Developer."


