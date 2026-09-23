#!/bin/bash

# 1Password secret reference for the service account token
OP_TOKEN_URI="op://Home Lab/co5dtojebigtletvoh2wwpsyl4/credential"

# Detect environment and resolve the appropriate 1Password CLI binary
if grep -qi "microsoft" /proc/version 2>/dev/null; then
    # Running inside WSL: Locate Windows op.exe via WinGet package path
    WIN_OP_BASE="/mnt/c/Users/$(cmd.exe /c echo %USERNAME% | tr -d '\r')/AppData/Local/Microsoft/WinGet/Packages"
    OP_DIR=$(ls -td "$WIN_OP_BASE"/AgileBits.1Password.CLI* 2>/dev/null | head -n1)

    if [ -z "$OP_DIR" ]; then
        echo "[ERROR] Could not find 1Password CLI folder in $WIN_OP_BASE" >&2
        return 1 2>/dev/null || exit 1
    fi

    # Forward any OP_* environment variables across the WSL boundary
    mapfile -d '' op_env_vars < <(env -0 | grep -z ^OP_ | cut -z -d= -f1)
    export WSLENV="${WSLENV:-}:$(IFS=:; echo "${op_env_vars[*]}")"

    OP_BIN="$OP_DIR/op.exe"
else
    # Running in native Linux
    if ! command -v op >/dev/null 2>&1; then
        echo "[ERROR] 'op' command not found in PATH" >&2
        return 1 2>/dev/null || exit 1
    fi

    OP_BIN="op"
fi

# 1. Wrapper Mode: If arguments were supplied, execute op directly
if [ $# -gt 0 ]; then
    exec "$OP_BIN" "$@"
fi

# 2. Injector Mode: If no arguments, fetch and export the service account token
OP_SERVICE_ACCOUNT_TOKEN=$("$OP_BIN" read "$OP_TOKEN_URI")
export OP_SERVICE_ACCOUNT_TOKEN

