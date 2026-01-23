#!/bin/bash
#
# Enable Passwordless Sudo for User
# Target: SRV22 (srv22.mosca.lan)
#
# Usage from macOS:
#   ./enable-passwordless-sudo.sh <server> <ssh_user> <ssh_password> [target_user]
#
# Example:
#   ./enable-passwordless-sudo.sh 192.168.11.130 administrator 'Netribe$1' administrator
#
# This will allow the target user to run sudo without password prompt
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
TARGET_USER="${4:-$SSH_USER}"

# Utility functions
log_info() {
    echo -e "${BLUE}[INFO]${NC} $1"
}

log_success() {
    echo -e "${GREEN}[SUCCESS]${NC} $1"
}

log_warning() {
    echo -e "${YELLOW}[WARNING]${NC} $1"
}

log_error() {
    echo -e "${RED}[ERROR]${NC} $1"
}

usage() {
    echo "Usage: $0 <server> <ssh_user> <ssh_password> [target_user]"
    echo
    echo "Arguments:"
    echo "  server       - Target server hostname/IP"
    echo "  ssh_user     - SSH username with sudo access"
    echo "  ssh_password - SSH password"
    echo "  target_user  - User to grant passwordless sudo (default: same as ssh_user)"
    echo
    echo "Example:"
    echo "  $0 192.168.11.130 administrator 'MyPass123'"
    echo "  $0 srv22.mosca.lan administrator 'MyPass123' administrator"
    exit 1
}

check_args() {
    if [ -z "$SERVER" ] || [ -z "$SSH_USER" ] || [ -z "$SSH_PASSWORD" ]; then
        log_error "Missing required arguments"
        usage
    fi
}

check_sshpass() {
    if ! command -v sshpass &> /dev/null; then
        log_error "sshpass is required but not installed"
        log_info "Install with: brew install sshpass"
        exit 1
    fi
}

enable_passwordless_sudo() {
    log_info "Enabling passwordless sudo for user: $TARGET_USER"

    # Create sudoers.d entry
    local sudoers_file="/etc/sudoers.d/99-$TARGET_USER-nopasswd"

    sshpass -p "$SSH_PASSWORD" ssh -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o LogLevel=ERROR \
        "${SSH_USER}@${SERVER}" "echo '$SSH_PASSWORD' | sudo -S bash -c \"
            echo '# Allow $TARGET_USER to run sudo without password' > $sudoers_file
            echo '$TARGET_USER ALL=(ALL) NOPASSWD: ALL' >> $sudoers_file
            chmod 0440 $sudoers_file
            visudo -c -f $sudoers_file
        \"" 2>&1 | grep -v '^\[sudo\]'

    if [ ${PIPESTATUS[0]} -eq 0 ]; then
        log_success "Passwordless sudo enabled for $TARGET_USER"
    else
        log_error "Failed to enable passwordless sudo"
        exit 1
    fi
}

test_passwordless_sudo() {
    log_info "Testing passwordless sudo..."

    local test_result=$(sshpass -p "$SSH_PASSWORD" ssh -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o LogLevel=ERROR \
        "${SSH_USER}@${SERVER}" "sudo -n whoami 2>&1")

    if [[ "$test_result" == "root" ]]; then
        log_success "Passwordless sudo is working correctly"
        return 0
    else
        log_error "Passwordless sudo test failed"
        log_error "Output: $test_result"
        return 1
    fi
}

print_summary() {
    echo
    echo "=================================================="
    echo "PASSWORDLESS SUDO CONFIGURATION COMPLETED"
    echo "=================================================="
    echo
    echo "Server:      $SERVER"
    echo "User:        $TARGET_USER"
    echo "Config file: /etc/sudoers.d/99-$TARGET_USER-nopasswd"
    echo
    echo "The user '$TARGET_USER' can now run sudo commands"
    echo "without being prompted for a password."
    echo
    echo "=================================================="
    echo "SECURITY NOTE:"
    echo "=================================================="
    echo "This configuration allows the user to execute ANY"
    echo "command with root privileges without authentication."
    echo
    echo "Only use this in trusted environments or for"
    echo "automation purposes on non-production systems."
    echo
    echo "To revert this change, run on the server:"
    echo "  sudo rm /etc/sudoers.d/99-$TARGET_USER-nopasswd"
    echo
}

# =============================================================================
# MAIN
# =============================================================================

main() {
    echo
    echo "=================================================="
    echo "ENABLE PASSWORDLESS SUDO - REMOTE CONFIGURATION"
    echo "=================================================="
    echo

    check_args
    check_sshpass

    log_info "Target: $TARGET_USER@$SERVER"
    echo

    log_warning "This will allow '$TARGET_USER' to run sudo without password"
    read -p "Are you sure you want to continue? (y/n) " -n 1 -r
    echo
    if [[ ! $REPLY =~ ^[Yy]$ ]]; then
        log_info "Operation cancelled"
        exit 0
    fi

    enable_passwordless_sudo
    sleep 1
    test_passwordless_sudo

    print_summary

    log_success "Configuration completed!"
}

main "$@"
