#!/bin/bash
#
# Data Disk Preparation Script for K3s/Rancher
# Target: SRV22 (srv22.mosca.lan)
#
# Prerequisites:
#   - SSH key authentication configured (run setup-ssh-key.sh first)
#   - Passwordless sudo configured for ssh_user
#
# Usage from macOS:
#   ./prepare-data-disk.sh <server> <ssh_user> [device] [size_gb]
#
# Example:
#   ./prepare-data-disk.sh srv22.mosca.lan administrator /dev/sdb 50
#   ./prepare-data-disk.sh 192.168.11.130 administrator  # Auto-detect blank disk
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
DEVICE="$3"  # Optional: if not provided, auto-detect
MIN_SIZE_GB="${4:-50}"

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
    echo "Usage: $0 <server> <ssh_user> [device] [size_gb]"
    echo
    echo "Arguments:"
    echo "  server       - Target server hostname/IP (e.g., srv22.mosca.lan)"
    echo "  ssh_user     - SSH username (e.g., administrator)"
    echo "  device       - Block device (optional, auto-detected if not specified)"
    echo "  size_gb      - Minimum disk size in GB (default: 50)"
    echo
    echo "Prerequisites:"
    echo "  - SSH key authentication must be configured"
    echo "  - Passwordless sudo must be configured for ssh_user"
    echo "  - Run setup-ssh-key.sh first if not configured"
    echo
    echo "Examples:"
    echo "  # Auto-detect blank disk:"
    echo "  $0 srv22.mosca.lan administrator"
    echo
    echo "  # Specify device explicitly:"
    echo "  $0 192.168.11.130 administrator /dev/sdb 50"
    echo
    echo "Available devices on target server:"
    if [ -n "$SERVER" ] && [ -n "$SSH_USER" ]; then
        ssh_exec "lsblk -d -o NAME,SIZE,TYPE,MOUNTPOINT | grep -E 'disk|nvme'" 2>/dev/null || true
    fi
    exit 1
}

check_args() {
    if [ -z "$SERVER" ] || [ -z "$SSH_USER" ]; then
        log_error "Missing required arguments"
        usage
    fi
}

# Execute command on remote server via SSH
# Uses SSH key authentication and passwordless sudo
ssh_exec() {
    local cmd="$1"
    ssh -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o LogLevel=ERROR \
        "${SSH_USER}@${SERVER}" "sudo bash -c $(printf '%q' "$cmd")" 2>&1
}

# Check SSH connection and prerequisites
check_ssh_prerequisites() {
    # Test SSH connection
    if ! ssh -o PasswordAuthentication=no -o ConnectTimeout=5 -o StrictHostKeyChecking=no \
        -o UserKnownHostsFile=/dev/null -o LogLevel=ERROR \
        "${SSH_USER}@${SERVER}" 'echo "Connection OK"' &>/dev/null; then
        log_error "Cannot connect to ${SSH_USER}@${SERVER}"
        log_info "Please run setup-ssh-key.sh first to configure SSH key authentication"
        exit 1
    fi

    # Test passwordless sudo
    if ! ssh -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o LogLevel=ERROR \
        "${SSH_USER}@${SERVER}" 'sudo -n echo "Sudo OK"' &>/dev/null; then
        log_error "Passwordless sudo not configured for ${SSH_USER}@${SERVER}"
        log_info "Please run setup-ssh-key.sh first to configure passwordless sudo"
        exit 1
    fi

    log_success "SSH and sudo prerequisites verified"
}

find_blank_disk() {
    if [ -n "$DEVICE" ]; then
        log_info "Using specified device: $DEVICE"
        return
    fi

    log_info "Auto-detecting blank disk on remote server..."

    # Find disks without partitions and >= MIN_SIZE_GB
    local blank_disks=$(ssh_exec "
        for disk in /dev/sd[a-z] /dev/nvme[0-9]n[0-9]; do
            [ -b \"\$disk\" ] || continue

            # Check if disk has no partitions
            part_count=\$(lsblk -n -o NAME \"\$disk\" 2>/dev/null | wc -l)
            if [ \"\$part_count\" -eq 1 ]; then
                # Get disk size in GB
                size_bytes=\$(blockdev --getsize64 \"\$disk\" 2>/dev/null)
                size_gb=\$((size_bytes / 1024 / 1024 / 1024))

                if [ \"\$size_gb\" -ge $MIN_SIZE_GB ]; then
                    echo \"\$disk:\$size_gb\"
                fi
            fi
        done
    " | grep -v '^\[sudo\]')

    # Count blank disks found
    local disk_count=$(echo "$blank_disks" | grep -c "^/dev/" || echo "0")

    if [ "$disk_count" -eq 0 ]; then
        log_error "No blank disk >= ${MIN_SIZE_GB}GB found"
        log_info "Available disks:"
        ssh_exec "lsblk -d -o NAME,SIZE,TYPE"
        exit 1
    elif [ "$disk_count" -eq 1 ]; then
        DEVICE=$(echo "$blank_disks" | cut -d':' -f1)
        local disk_size=$(echo "$blank_disks" | cut -d':' -f2)
        log_success "Auto-detected blank disk: $DEVICE (${disk_size}GB)"
    else
        log_warning "Multiple blank disks found:"
        echo "$blank_disks" | while IFS=: read disk size; do
            echo "  $disk - ${size}GB"
        done
        log_error "Please specify which disk to use"
        log_info "Example: $0 $SERVER $SSH_USER <password> /dev/sdb"
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

    # Check disk size using blockdev (more reliable than lsblk)
    local size_bytes=$(ssh_exec "blockdev --getsize64 $DEVICE 2>/dev/null")
    # Extract only numbers, removing any sudo prompts or whitespace
    size_bytes=$(echo "$size_bytes" | tr -d '[:space:]' | grep -oE '[0-9]+' | head -1)

    # Convert bytes to GB
    local size_gb=$((size_bytes / 1024 / 1024 / 1024))

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

set_selinux_context() {
    local selinux_status=$(ssh_exec "getenforce 2>/dev/null || echo 'unknown'")

    if [[ "$selinux_status" != *"Enforcing"* ]]; then
        log_info "SELinux not enforcing - skipping context configuration"
        return
    fi

    log_info "Configuring SELinux context for K3s data directory..."

    # Install policycoreutils-python-utils if not present (contains semanage)
    ssh_exec "rpm -q policycoreutils-python-utils &>/dev/null || dnf install -y policycoreutils-python-utils"

    # Apply container_var_lib_t context - required for K3s with SELinux enforcing
    ssh_exec "semanage fcontext -a -t container_var_lib_t '$MOUNT_POINT(/.*)?'"
    ssh_exec "restorecon -R -v $MOUNT_POINT"

    log_success "SELinux context configured"
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
    check_ssh_prerequisites
    find_blank_disk
    validate_device
    confirm_operation

    create_partition
    create_filesystem
    mount_filesystem
    add_to_fstab
    set_permissions
    set_selinux_context

    print_summary

    log_success "Disk ready for K3s/Rancher installation!"
}

main "$@"
