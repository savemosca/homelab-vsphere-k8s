#!/bin/bash
#
# SSH Key Setup Script
# Configures SSH key authentication and passwordless sudo on remote server
#
# Usage:
#   ./setup-ssh-key.sh <server> <ssh_user> <ssh_password> [ssh_key_path]
#
# Example:
#   ./setup-ssh-key.sh srv22.mosca.lan administrator 'Netribe$1'
#   ./setup-ssh-key.sh 192.168.11.130 administrator 'Netribe$1' ~/.ssh/id_ed25519.pub
#

set -e

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

# Arguments
SERVER="$1"
SSH_USER="$2"
SSH_PASSWORD="$3"
SSH_KEY_PATH="${4:-$HOME/.ssh/id_ed25519.pub}"

# Utility functions
log_info() {
    echo -e "${BLUE}[INFO]${NC} $1"
}

log_success() {
    echo -e "${GREEN}[SUCCESS]${NC} $1"
}

log_error() {
    echo -e "${RED}[ERROR]${NC} $1"
}

usage() {
    echo "Usage: $0 <server> <ssh_user> <ssh_password> [ssh_key_path]"
    echo
    echo "Arguments:"
    echo "  server        - Target server hostname/IP"
    echo "  ssh_user      - SSH username"
    echo "  ssh_password  - SSH password (used only once)"
    echo "  ssh_key_path  - Path to SSH public key (default: ~/.ssh/id_ed25519.pub)"
    echo
    echo "Example:"
    echo "  $0 srv22.mosca.lan administrator 'MyPassword'"
    echo "  $0 192.168.11.130 administrator 'MyPassword' ~/.ssh/id_rsa.pub"
    exit 1
}

check_args() {
    if [ -z "$SERVER" ] || [ -z "$SSH_USER" ] || [ -z "$SSH_PASSWORD" ]; then
        log_error "Missing required arguments"
        usage
    fi
}

check_ssh_key() {
    if [ ! -f "$SSH_KEY_PATH" ]; then
        log_error "SSH public key not found: $SSH_KEY_PATH"
        echo
        echo "Available keys in ~/.ssh/:"
        ls -la ~/.ssh/*.pub 2>/dev/null || echo "  No public keys found"
        exit 1
    fi

    log_info "Using SSH key: $SSH_KEY_PATH"
}

check_sshpass() {
    if ! command -v sshpass &> /dev/null; then
        log_error "sshpass is required but not installed"
        log_info "Install with: brew install sshpass"
        exit 1
    fi
}

copy_ssh_key() {
    log_info "Copying SSH public key to $SSH_USER@$SERVER..."

    local pub_key=$(cat "$SSH_KEY_PATH")

    # Create .ssh directory and authorized_keys file
    sshpass -p "$SSH_PASSWORD" ssh -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o LogLevel=ERROR \
        "${SSH_USER}@${SERVER}" bash <<EOF
mkdir -p ~/.ssh
chmod 700 ~/.ssh
touch ~/.ssh/authorized_keys
chmod 600 ~/.ssh/authorized_keys

# Add key if not already present
if ! grep -q "$pub_key" ~/.ssh/authorized_keys 2>/dev/null; then
    echo "$pub_key" >> ~/.ssh/authorized_keys
    echo "Key added"
else
    echo "Key already present"
fi
EOF

    log_success "SSH key copied successfully"
}

configure_passwordless_sudo() {
    log_info "Configuring passwordless sudo for $SSH_USER..."

    {
        printf '%s\n' "$SSH_PASSWORD"
        cat <<'SCRIPT'
# Create sudoers drop-in file
SUDOERS_FILE="/etc/sudoers.d/90-${USER}-nopasswd"
echo "${USER} ALL=(ALL) NOPASSWD: ALL" > "$SUDOERS_FILE"
chmod 440 "$SUDOERS_FILE"

# Validate sudoers file
if visudo -c -f "$SUDOERS_FILE" >/dev/null 2>&1; then
    echo "Passwordless sudo configured"
else
    echo "ERROR: Invalid sudoers file"
    rm -f "$SUDOERS_FILE"
    exit 1
fi
SCRIPT
    } | sshpass -p "$SSH_PASSWORD" ssh -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o LogLevel=ERROR \
        "${SSH_USER}@${SERVER}" 'sudo -S bash' 2>&1

    log_success "Passwordless sudo configured"
}

test_ssh_key_auth() {
    log_info "Testing SSH key authentication..."

    # Test SSH connection without password
    if ssh -o PasswordAuthentication=no -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o LogLevel=ERROR \
        "${SSH_USER}@${SERVER}" 'echo "SSH key authentication successful"' 2>/dev/null; then
        log_success "SSH key authentication working"
    else
        log_error "SSH key authentication failed"
        exit 1
    fi

    # Test passwordless sudo
    if ssh -o PasswordAuthentication=no -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o LogLevel=ERROR \
        "${SSH_USER}@${SERVER}" 'sudo -n echo "Passwordless sudo working"' 2>/dev/null; then
        log_success "Passwordless sudo working"
    else
        log_error "Passwordless sudo failed"
        exit 1
    fi
}

main() {
    echo
    echo "=================================================="
    echo "SSH KEY SETUP"
    echo "=================================================="
    echo

    check_args
    check_ssh_key
    check_sshpass

    copy_ssh_key
    configure_passwordless_sudo
    test_ssh_key_auth

    echo
    echo "=================================================="
    echo "SETUP COMPLETED SUCCESSFULLY"
    echo "=================================================="
    echo
    echo "You can now use SSH key authentication:"
    echo "  ssh ${SSH_USER}@${SERVER}"
    echo
    echo "And run sudo commands without password:"
    echo "  ssh ${SSH_USER}@${SERVER} 'sudo systemctl status firewalld'"
    echo
    log_success "Server is ready for automated scripts!"
}

main "$@"
