#!/bin/bash
#
# Rancher on K3s Installation Script for RHEL 10
# Target: SRV22 (srv22.mosca.lan)
# Data disk: /mnt/k3s (50GB minimum recommended)
#
# Usage from macOS:
#   ./install-rancher-k3s.sh <server> <ssh_user> <ssh_password> [rancher_hostname]
#
# Example:
#   ./install-rancher-k3s.sh srv22.mosca.lan administrator 'password' rancher.savemosca.com
#
# Installed versions:
#   - K3s: v1.35.0+k3s1
#   - Rancher: v2.13.1
#   - cert-manager: v1.19.2
#   - Helm: v4.1.0
#

set -e
set -o pipefail

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
RANCHER_HOSTNAME="${4:-rancher.savemosca.com}"

# Configuration
K3S_DATA_DIR="/mnt/k3s"
K3S_VERSION="v1.35.0+k3s1"
RANCHER_VERSION="2.13.1"
CERT_MANAGER_VERSION="v1.19.2"
HELM_VERSION="v4.1.0"

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
    echo "Usage: $0 <server> <ssh_user> <ssh_password> [rancher_hostname]"
    echo
    echo "Arguments:"
    echo "  server            - Target server hostname/IP (e.g., srv22.mosca.lan)"
    echo "  ssh_user          - SSH username (e.g., administrator)"
    echo "  ssh_password      - SSH password"
    echo "  rancher_hostname  - Rancher FQDN (default: rancher.savemosca.com)"
    echo
    echo "Example:"
    echo "  $0 srv22.mosca.lan administrator 'MyPass123' rancher.savemosca.com"
    exit 1
}

check_args() {
    if [ -z "$SERVER" ] || [ -z "$SSH_USER" ] || [ -z "$SSH_PASSWORD" ]; then
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

check_remote_rhel() {
    log_info "Checking remote system..."

    local release=$(ssh_exec "cat /etc/redhat-release 2>/dev/null || echo 'not-rhel'")

    if [[ "$release" == "not-rhel" ]]; then
        log_error "Target system is not RHEL"
        exit 1
    fi

    local version=$(echo "$release" | grep -oE '[0-9]+' | head -1)
    log_info "Detected RHEL version: $version"

    if [ "$version" -lt 9 ]; then
        log_warning "RHEL version < 9 may have compatibility issues"
    fi
}

check_data_disk() {
    log_info "Checking data disk..."

    local disk_check=$(ssh_exec "if [ -d $K3S_DATA_DIR ]; then echo 'exists'; else echo 'missing'; fi")

    if [[ "$disk_check" == *"missing"* ]]; then
        log_error "Directory $K3S_DATA_DIR does not exist on remote server!"
        log_info "Run prepare-data-disk.sh first to setup the data disk"
        exit 1
    fi

    local disk_size=$(ssh_exec "df -BG $K3S_DATA_DIR 2>/dev/null | tail -1 | awk '{print \$2}' | sed 's/G//'")
    disk_size=$(echo "$disk_size" | tr -d '[:space:]' | grep -oE '[0-9]+')

    if [ -n "$disk_size" ]; then
        log_info "Data disk: $K3S_DATA_DIR - ${disk_size}GB available"

        if [ "$disk_size" -lt 50 ]; then
            log_warning "Disk < 50GB - may not be sufficient for production"
        fi
    else
        log_warning "Unable to determine disk size, continuing anyway"
    fi
}

backup_existing_installation() {
    local has_k3s=$(ssh_exec "[ -d $K3S_DATA_DIR/server ] || [ -d $K3S_DATA_DIR/agent ] && echo 'yes' || echo 'no'")

    if [[ "$has_k3s" == *"yes"* ]]; then
        log_warning "Found existing K3s installation in $K3S_DATA_DIR"
        local backup_dir="${K3S_DATA_DIR}_backup_$(date +%Y%m%d_%H%M%S)"

        read -p "Create backup in $backup_dir? (y/n) " -n 1 -r
        echo
        if [[ $REPLY =~ ^[Yy]$ ]]; then
            log_info "Creating backup..."
            ssh_exec "mkdir -p $backup_dir && cp -a $K3S_DATA_DIR/* $backup_dir/ 2>/dev/null || true"
            log_success "Backup created in $backup_dir"
        fi

        read -p "Proceed with uninstalling existing installation? (y/n) " -n 1 -r
        echo
        if [[ $REPLY =~ ^[Yy]$ ]]; then
            uninstall_existing_k3s
        else
            log_error "Installation cancelled"
            exit 1
        fi
    fi
}

uninstall_existing_k3s() {
    log_info "Uninstalling existing K3s..."

    ssh_exec "if [ -f /usr/local/bin/k3s-uninstall.sh ]; then /usr/local/bin/k3s-uninstall.sh; fi || true"
    ssh_exec "systemctl stop k3s 2>/dev/null || true"
    ssh_exec "rm -rf /var/lib/rancher/k3s /etc/rancher/k3s /usr/local/bin/k3s*"
    ssh_exec "if [ -d $K3S_DATA_DIR ]; then find $K3S_DATA_DIR -mindepth 1 -maxdepth 1 ! -name 'lost+found' -exec rm -rf {} + 2>/dev/null || true; fi"

    log_success "Uninstallation completed"
}

configure_firewall() {
    log_info "Configuring firewall for K3s and Rancher..."

    local fw_active=$(ssh_exec "systemctl is-active firewalld 2>/dev/null || echo 'inactive'")

    if [[ "$fw_active" != *"active"* ]]; then
        log_warning "Firewalld not active - skipping firewall configuration"
        return
    fi

    ssh_exec "firewall-cmd --permanent --add-port=6443/tcp"   # Kubernetes API
    ssh_exec "firewall-cmd --permanent --add-port=10250/tcp"  # Kubelet
    ssh_exec "firewall-cmd --permanent --add-port=8472/udp"   # Flannel VXLAN
    ssh_exec "firewall-cmd --permanent --add-port=80/tcp"     # HTTP
    ssh_exec "firewall-cmd --permanent --add-port=443/tcp"    # HTTPS
    ssh_exec "firewall-cmd --reload"

    log_success "Firewall configured"
}

configure_selinux() {
    log_info "Checking SELinux configuration..."

    local selinux_status=$(ssh_exec "getenforce 2>/dev/null || echo 'unknown'")
    log_info "SELinux status: $selinux_status"

    if [[ "$selinux_status" == *"Enforcing"* ]]; then
        log_warning "SELinux is in Enforcing mode"
        log_warning "If you encounter issues, consider switching to Permissive for troubleshooting"
    fi
}

install_dependencies() {
    log_info "Installing dependencies..."

    ssh_exec "dnf install -y curl wget tar jq git container-selinux iptables conntrack-tools"

    log_success "Dependencies installed"
}

install_k3s() {
    log_info "Installing K3s $K3S_VERSION with data dir: $K3S_DATA_DIR..."

    ssh_exec "mkdir -p $K3S_DATA_DIR/{server,agent}"

    ssh_exec "curl -sfL https://get.k3s.io | INSTALL_K3S_VERSION='$K3S_VERSION' INSTALL_K3S_EXEC='server --data-dir=$K3S_DATA_DIR' sh -"

    log_info "Waiting for K3s to be ready..."
    local max_wait=60
    local count=0
    while [ $count -lt $max_wait ]; do
        local node_check=$(ssh_exec "/usr/local/bin/k3s kubectl get nodes 2>/dev/null" || echo "not-ready")
        if [[ "$node_check" != *"not-ready"* ]] && [[ "$node_check" == *"Ready"* ]]; then
            break
        fi
        sleep 2
        count=$((count + 2))
    done

    if [ $count -ge $max_wait ]; then
        log_error "Timeout: K3s not ready after ${max_wait}s"
        exit 1
    fi

    log_success "K3s installed and running"
    ssh_exec "/usr/local/bin/k3s kubectl get nodes"
}

install_helm() {
    log_info "Installing Helm $HELM_VERSION..."

    ssh_exec "curl -fsSL https://get.helm.sh/helm-${HELM_VERSION}-linux-amd64.tar.gz | tar -xzv -C /tmp && mv /tmp/linux-amd64/helm /usr/local/bin/helm && chmod +x /usr/local/bin/helm && rm -rf /tmp/linux-amd64"

    local helm_version=$(ssh_exec "/usr/local/bin/helm version --short")
    log_success "Helm installed: $helm_version"
}

install_cert_manager() {
    log_info "Installing cert-manager $CERT_MANAGER_VERSION..."

    ssh_exec "export KUBECONFIG=/etc/rancher/k3s/k3s.yaml && /usr/local/bin/helm repo add jetstack https://charts.jetstack.io"
    ssh_exec "export KUBECONFIG=/etc/rancher/k3s/k3s.yaml && /usr/local/bin/helm repo update"

    ssh_exec "export KUBECONFIG=/etc/rancher/k3s/k3s.yaml && /usr/local/bin/helm install cert-manager jetstack/cert-manager --namespace cert-manager --create-namespace --version $CERT_MANAGER_VERSION --set crds.enabled=true --wait --timeout 5m"

    log_info "Verifying cert-manager..."
    ssh_exec "export KUBECONFIG=/etc/rancher/k3s/k3s.yaml && /usr/local/bin/k3s kubectl wait --for=condition=ready pod -l app.kubernetes.io/instance=cert-manager -n cert-manager --timeout=300s"

    log_success "cert-manager installed and ready"
}

install_rancher() {
    log_info "Installing Rancher $RANCHER_VERSION with hostname: $RANCHER_HOSTNAME..."

    ssh_exec "export KUBECONFIG=/etc/rancher/k3s/k3s.yaml && /usr/local/bin/helm repo add rancher-stable https://releases.rancher.com/server-charts/stable"
    ssh_exec "export KUBECONFIG=/etc/rancher/k3s/k3s.yaml && /usr/local/bin/helm repo update"
    ssh_exec "export KUBECONFIG=/etc/rancher/k3s/k3s.yaml && /usr/local/bin/k3s kubectl create namespace cattle-system || true"

    local bootstrap_password=$(openssl rand -base64 32 | tr -d "=+/" | cut -c1-25)

    ssh_exec "export KUBECONFIG=/etc/rancher/k3s/k3s.yaml && /usr/local/bin/helm install rancher rancher-stable/rancher --namespace cattle-system --set hostname='$RANCHER_HOSTNAME' --set replicas=1 --set bootstrapPassword='$bootstrap_password' --version $RANCHER_VERSION --wait --timeout 10m"

    ssh_exec "echo '$bootstrap_password' > /root/.rancher-bootstrap-password && chmod 600 /root/.rancher-bootstrap-password"

    log_success "Rancher installed"

    log_info "Waiting for Rancher to be fully ready..."
    ssh_exec "export KUBECONFIG=/etc/rancher/k3s/k3s.yaml && /usr/local/bin/k3s kubectl -n cattle-system wait --for=condition=ready pod -l app=rancher --timeout=600s"

    log_success "Rancher is ready!"
    echo
    echo "=================================================="
    echo "RANCHER ACCESS INFORMATION"
    echo "=================================================="
    echo "URL:      https://$RANCHER_HOSTNAME"
    echo "Username: admin"
    echo "Password: $bootstrap_password"
    echo
    echo "Password also saved in: /root/.rancher-bootstrap-password"
    echo "=================================================="
    echo
}

configure_kubeconfig_access() {
    log_info "Configuring kubectl access for non-root users..."

    ssh_exec "groupadd -f k3s-access"
    ssh_exec "mkdir -p /etc/rancher/k3s-access && cp /etc/rancher/k3s/k3s.yaml /etc/rancher/k3s-access/kubeconfig && chgrp k3s-access /etc/rancher/k3s-access/kubeconfig && chmod 640 /etc/rancher/k3s-access/kubeconfig"

    log_info "To grant access to a user:"
    log_info "  usermod -a -G k3s-access <username>"
    log_info "  echo 'export KUBECONFIG=/etc/rancher/k3s-access/kubeconfig' >> /home/<username>/.bashrc"
}

print_summary() {
    local hostname=$(ssh_exec "hostname -f")
    local disk_info=$(ssh_exec "df -h $K3S_DATA_DIR")
    local namespaces=$(ssh_exec "export KUBECONFIG=/etc/rancher/k3s/k3s.yaml && /usr/local/bin/k3s kubectl get ns")
    local pods=$(ssh_exec "export KUBECONFIG=/etc/rancher/k3s/k3s.yaml && /usr/local/bin/k3s kubectl get pods -A")

    echo
    echo "=================================================="
    echo "INSTALLATION COMPLETED SUCCESSFULLY!"
    echo "=================================================="
    echo
    echo "Server:    $hostname"
    echo "K3s:       $K3S_VERSION"
    echo "Data Dir:  $K3S_DATA_DIR"
    echo "Rancher:   $RANCHER_VERSION"
    echo "Hostname:  $RANCHER_HOSTNAME"
    echo
    echo "Disk structure:"
    echo "$disk_info"
    echo
    echo "Active namespaces:"
    echo "$namespaces"
    echo
    echo "System pods:"
    echo "$pods"
    echo
    echo "=================================================="
    echo "NEXT STEPS:"
    echo "=================================================="
    echo "1. Configure DNS to point $RANCHER_HOSTNAME to this server"
    echo "2. Access Rancher: https://$RANCHER_HOSTNAME"
    echo "3. Configure vSphere credentials in Rancher"
    echo "4. Proceed with workload cluster creation"
    echo
    echo "Useful commands (run on server):"
    echo "  k3s kubectl get all -A              # Status of all resources"
    echo "  k3s kubectl logs -n cattle-system -l app=rancher  # Rancher logs"
    echo "  systemctl status k3s                # K3s service status"
    echo "  journalctl -u k3s -f                # K3s logs in real-time"
    echo
}

# =============================================================================
# MAIN
# =============================================================================

main() {
    echo
    echo "=================================================="
    echo "RANCHER ON K3S INSTALLATION - REMOTE EXECUTION"
    echo "=================================================="
    echo

    log_info "Starting installation..."
    log_info "Target server: $SERVER"
    log_info "SSH user: $SSH_USER"
    log_info "Rancher hostname: $RANCHER_HOSTNAME"
    log_info "K3s data directory: $K3S_DATA_DIR"
    echo

    # Prerequisites
    check_args
    check_sshpass

    # Remote system checks
    check_remote_rhel
    check_data_disk
    backup_existing_installation

    # System configuration
    configure_firewall
    configure_selinux
    install_dependencies

    # Install stack
    install_k3s
    install_helm
    install_cert_manager
    install_rancher

    # Post-installation configuration
    configure_kubeconfig_access

    # Summary
    print_summary

    log_success "Installation completed!"
}

# Execute main
main "$@"
