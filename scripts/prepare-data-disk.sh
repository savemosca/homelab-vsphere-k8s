#!/bin/bash
#
# Data Disk Preparation Script for K3s/Rancher
# Target: SRV22 (srv22.mosca.lan)
#
# Usage from macOS:
#   ./prepare-data-disk.sh <server> <ssh_user> <ssh_password> <device> [size_gb]
#
# Example:
#   ./prepare-data-disk.sh srv22.mosca.lan administrator 'password' /dev/sdb 50
#
# WARNING: This script will completely format the specified disk!
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
DEVICE="$4"
MIN_SIZE_GB="${5:-50}"

MOUNT_POINT="/mnt/k3s"

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
    echo "Usage: $0 <server> <ssh_user> <ssh_password> <device> [size_gb]"
    echo
    echo "Arguments:"
    echo "  server       - Target server hostname/IP (e.g., srv22.mosca.lan)"
    echo "  ssh_user     - SSH username (e.g., administrator)"
    echo "  ssh_password - SSH password"
    echo "  device       - Block device (e.g., /dev/sdb, /dev/nvme0n1)"
    echo "  size_gb      - Minimum disk size in GB (default: 50)"
    echo
    echo "Example:"
    echo "  $0 srv22.mosca.lan administrator 'MyPass123' /dev/sdb 50"
    echo
    echo "Available devices on target server:"
    if [ -n "$SERVER" ] && [ -n "$SSH_USER" ] && [ -n "$SSH_PASSWORD" ]; then
        ssh_exec "lsblk -d -o NAME,SIZE,TYPE,MOUNTPOINT | grep -E 'disk|nvme'" 2>/dev/null || true
    fi
    exit 1
}

check_args() {
    if [ -z "$SERVER" ] || [ -z "$SSH_USER" ] || [ -z "$SSH_PASSWORD" ] || [ -z "$DEVICE" ]; then
        log_error "Missing required arguments"
        usage
    fi
}

# Execute command on remote server via SSH
ssh_exec() {
    local cmd="$1"
    sshpass -p "$SSH_PASSWORD" ssh -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o LogLevel=ERROR \
        "${SSH_USER}@${SERVER}" "sudo -S bash -c \"$cmd\" <<< '$SSH_PASSWORD'" 2>&1
}

# Check if sshpass is installed
check_sshpass() {
    if ! command -v sshpass &> /dev/null; then
        log_error "sshpass is required but not installed"
        log_info "Install with: brew install sshpass"
        exit 1
    fi
}

validate_device() {
    log_info "Validating device $DEVICE on remote server..."

    local device_check=$(ssh_exec "[ -b $DEVICE ] && echo 'exists' || echo 'missing'")

    if [[ "$device_check" == *"missing"* ]]; then
        log_error "Device $DEVICE does not exist or is not a block device"
        log_info "Available devices:"
        ssh_exec "lsblk -d"
        exit 1
    fi

    # Check disk size
    local size_gb=$(ssh_exec "lsblk -b -d -n -o SIZE $DEVICE 2>/dev/null | awk '{print int(\$1/1024/1024/1024)}'")
    # Remove sudo prompt and extract only the number
    size_gb=$(echo "$size_gb" | grep -v '^\[sudo\]' | tr -d '[:space:]' | grep -oE '[0-9]+' | head -1)

    if [ -z "$size_gb" ] || [ "$size_gb" -eq 0 ]; then
        log_error "Unable to determine disk size"
        exit 1
    fi

    log_info "Disk size: ${size_gb}GB"

    if [ "$size_gb" -lt "$MIN_SIZE_GB" ]; then
        log_error "Disk too small: ${size_gb}GB (minimum: ${MIN_SIZE_GB}GB)"
        exit 1
    fi

    # Check if disk is in use
    local mount_check=$(ssh_exec "mount | grep '^$DEVICE' || echo 'not-mounted'")
    if [[ "$mount_check" != *"not-mounted"* ]]; then
        log_error "Device $DEVICE is already mounted:"
        echo "$mount_check"
        exit 1
    fi
}

confirm_operation() {
    echo
    log_warning "WARNING: This operation will erase ALL DATA on $DEVICE"
    echo
    ssh_exec "lsblk $DEVICE"
    echo
    read -p "Are you sure you want to continue? Type 'YES' to confirm: " confirm

    if [ "$confirm" != "YES" ]; then
        log_info "Operation cancelled"
        exit 0
    fi
}

create_partition() {
    log_info "Creating partition on $DEVICE..."

    # Wipe existing signatures
    ssh_exec "wipefs -a $DEVICE 2>/dev/null || true" >/dev/null 2>&1

    # Create new GPT partition table and single partition
    ssh_exec "parted -s $DEVICE mklabel gpt" >/dev/null 2>&1
    ssh_exec "parted -s $DEVICE mkpart primary xfs 0% 100%" >/dev/null 2>&1

    # Wait for kernel to recognize partition
    ssh_exec "sleep 2 && partprobe $DEVICE && sleep 2" >/dev/null 2>&1

    # Determine partition name (sdb1 or nvme0n1p1)
    PARTITION=""
    if [[ "$DEVICE" =~ "nvme" ]]; then
        PARTITION="${DEVICE}p1"
    else
        PARTITION="${DEVICE}1"
    fi

    local part_check=$(ssh_exec "[ -b $PARTITION ] && echo 'exists' || echo 'missing'")
    if [[ "$part_check" == *"missing"* ]]; then
        log_error "Partition $PARTITION not created correctly"
        exit 1
    fi

    log_success "Partition created: $PARTITION"
}

create_filesystem() {
    log_info "Creating XFS filesystem on $PARTITION..."

    ssh_exec "mkfs.xfs -f -L 'k3s-data' $PARTITION" >/dev/null 2>&1

    log_success "XFS filesystem created"
}

mount_filesystem() {
    log_info "Mounting filesystem on $MOUNT_POINT..."

    ssh_exec "mkdir -p $MOUNT_POINT" >/dev/null 2>&1
    ssh_exec "mount $PARTITION $MOUNT_POINT" >/dev/null 2>&1

    # Verify mount
    local mount_verify=$(ssh_exec "mount | grep $MOUNT_POINT || echo 'not-mounted'")
    if [[ "$mount_verify" == *"not-mounted"* ]]; then
        log_error "Mount failed"
        exit 1
    fi

    log_success "Filesystem mounted on $MOUNT_POINT"
    ssh_exec "df -h $MOUNT_POINT"
}

add_to_fstab() {
    log_info "Adding entry to /etc/fstab for automatic mount..."

    # Get partition UUID
    local uuid=$(ssh_exec "blkid -s UUID -o value $PARTITION 2>/dev/null" | tr -d '[:space:]')

    if [ -z "$uuid" ]; then
        log_error "Unable to get UUID of $PARTITION"
        exit 1
    fi

    # Remove existing entries for this mount point
    ssh_exec "sed -i '\\|$MOUNT_POINT|d' /etc/fstab" >/dev/null 2>&1

    # Add new entry
    ssh_exec "echo 'UUID=$uuid $MOUNT_POINT xfs defaults,noatime 0 2' >> /etc/fstab" >/dev/null 2>&1

    log_success "Entry added to /etc/fstab"
    log_info "UUID: $uuid"

    # Test fstab
    log_info "Testing mount from fstab..."
    ssh_exec "umount $MOUNT_POINT && mount $MOUNT_POINT" >/dev/null 2>&1

    local mount_verify=$(ssh_exec "mount | grep $MOUNT_POINT || echo 'not-mounted'")
    if [[ "$mount_verify" == *"not-mounted"* ]]; then
        log_error "Mount from fstab failed!"
        exit 1
    fi

    log_success "Mount from fstab working"
}

set_permissions() {
    log_info "Configuring permissions..."

    ssh_exec "chown root:root $MOUNT_POINT && chmod 755 $MOUNT_POINT"

    log_success "Permissions configured"
}

print_summary() {
    local disk_info=$(ssh_exec "df -h $MOUNT_POINT")
    local lsblk_info=$(ssh_exec "lsblk $DEVICE")

    echo
    echo "=================================================="
    echo "DISK PREPARATION COMPLETED"
    echo "=================================================="
    echo
    echo "Device:      $DEVICE"
    echo "Partition:   $PARTITION"
    echo "Mount Point: $MOUNT_POINT"
    echo "Filesystem:  XFS"
    echo
    echo "$disk_info"
    echo
    echo "$lsblk_info"
    echo
    echo "=================================================="
    echo "NEXT STEPS:"
    echo "=================================================="
    echo "1. Verify persistent mount:"
    echo "   ssh $SSH_USER@$SERVER 'mount | grep $MOUNT_POINT'"
    echo
    echo "2. Run Rancher installation script:"
    echo "   ./install-rancher-k3s.sh $SERVER $SSH_USER <password> [hostname]"
    echo
}

# =============================================================================
# MAIN
# =============================================================================

main() {
    echo
    echo "=================================================="
    echo "K3S/RANCHER DATA DISK PREPARATION - REMOTE"
    echo "=================================================="
    echo

    check_args
    check_sshpass
    validate_device
    confirm_operation

    create_partition
    create_filesystem
    mount_filesystem
    add_to_fstab
    set_permissions

    print_summary

    log_success "Disk ready for K3s/Rancher installation!"
}

main "$@"
