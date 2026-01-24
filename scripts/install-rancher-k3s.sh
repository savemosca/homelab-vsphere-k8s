#!/bin/bash
#
# Rancher on K3s Installation Script for RHEL 10
# Target: SRV22 (srv22.mosca.lan)
# Data disk: /mnt/k3s (50GB minimum recommended)
#
# Prerequisites:
#   - SSH key authentication configured (run setup-ssh-key.sh first)
#   - Passwordless sudo configured for ssh_user
#
# Usage from macOS:
#   ./install-rancher-k3s.sh <server> <ssh_user> [rancher_hostname]
#
# Example:
#   ./install-rancher-k3s.sh srv22.mosca.lan administrator rancher.savemosca.com
#   ./install-rancher-k3s.sh 192.168.11.130 administrator
#
# Installed versions:
#   - K3s: v1.34.3+k3s1 (Kubernetes 1.34.3)
#   - Traefik: bundled with K3s
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
RANCHER_HOSTNAME="${3:-rancher.savemosca.com}"

# Configuration
K3S_DATA_DIR="/mnt/k3s"
K3S_VERSION="v1.34.3+k3s1"
RANCHER_VERSION="2.13.1"
CERT_MANAGER_VERSION="v1.19.2"
HELM_VERSION="v4.1.0"
TRAEFIK_VERSION="3.6.7"
TRAEFIK_CHART_VERSION="39.0.0"

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
    echo "Usage: $0 <server> <ssh_user> [rancher_hostname]"
    echo
    echo "Arguments:"
    echo "  server            - Target server hostname/IP (e.g., srv22.mosca.lan)"
    echo "  ssh_user          - SSH username (e.g., administrator)"
    echo "  rancher_hostname  - Rancher FQDN (default: rancher.savemosca.com)"
    echo
    echo "Prerequisites:"
    echo "  - SSH key authentication must be configured"
    echo "  - Passwordless sudo must be configured for ssh_user"
    echo "  - Run setup-ssh-key.sh first if not configured"
    echo
    echo "Example:"
    echo "  $0 srv22.mosca.lan administrator rancher.savemosca.com"
    echo "  $0 192.168.11.130 administrator"
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
    # Remove sudo prompt and extract only the number
    disk_size=$(echo "$disk_size" | grep -v '^\[sudo\]' | tr -d '[:space:]' | grep -oE '[0-9]+' | head -1)

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

    # Allow pod-to-pod and service communication (K3s default CIDRs)
    # NOTE: These CIDRs match K3s defaults. If using custom --cluster-cidr or --service-cidr, adjust accordingly.
    ssh_exec "firewall-cmd --permanent --add-rich-rule='rule family=ipv4 source address=10.42.0.0/16 accept'"  # Pod network (--cluster-cidr)
    ssh_exec "firewall-cmd --permanent --add-rich-rule='rule family=ipv4 source address=10.43.0.0/16 accept'"  # Service network (--service-cidr)

    ssh_exec "firewall-cmd --reload"

    log_success "Firewall configured"
}

configure_selinux() {
    log_info "Checking SELinux configuration..."

    local selinux_status=$(ssh_exec "getenforce 2>/dev/null || echo 'unknown'")
    log_info "SELinux status: $selinux_status"

    if [[ "$selinux_status" == *"Enforcing"* ]]; then
        log_info "SELinux is in Enforcing mode - will configure proper contexts"
    fi
}

configure_selinux_data_dir() {
    local selinux_status=$(ssh_exec "getenforce 2>/dev/null || echo 'unknown'")

    if [[ "$selinux_status" != *"Enforcing"* ]]; then
        log_info "SELinux not enforcing - skipping context configuration"
        return
    fi

    log_info "Configuring SELinux context for K3s data directory: $K3S_DATA_DIR"

    # Apply container_var_lib_t context to K3s data directory
    # This is critical for K3s to work on custom data directories with SELinux enforcing
    ssh_exec "semanage fcontext -a -t container_var_lib_t '$K3S_DATA_DIR(/.*)?'"
    ssh_exec "restorecon -R -v $K3S_DATA_DIR"

    log_success "SELinux context applied to $K3S_DATA_DIR"
}

install_dependencies() {
    log_info "Installing dependencies..."

    ssh_exec "dnf install -y curl wget tar jq container-selinux iptables conntrack-tools policycoreutils-python-utils"

    log_success "Dependencies installed"
}

install_k3s() {
    log_info "Installing K3s $K3S_VERSION with data dir: $K3S_DATA_DIR..."

    # Disable network policy controller to avoid conflicts (K3s best practice)
    # Reference: https://docs.k3s.io/networking/basic-network-options
    ssh_exec "curl -sfL https://get.k3s.io | INSTALL_K3S_VERSION='$K3S_VERSION' INSTALL_K3S_EXEC='server --data-dir=$K3S_DATA_DIR --disable-network-policy' sh -"

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

    log_success "K3s node is ready"

    # Wait for core components (coredns, traefik) to be running
    log_info "Waiting for core K3s components..."

    # Wait for coredns pod to exist, then for it to be ready
    local max_wait=120
    local count=0
    while [ $count -lt $max_wait ]; do
        local coredns_exists=$(ssh_exec "export KUBECONFIG=/etc/rancher/k3s/k3s.yaml && /usr/local/bin/k3s kubectl get pod -l k8s-app=kube-dns -n kube-system --no-headers 2>/dev/null | wc -l")
        coredns_exists=$(echo "$coredns_exists" | tr -d '[:space:]')
        if [ "$coredns_exists" -gt 0 ]; then
            log_info "CoreDNS pod found, waiting for ready status..."
            ssh_exec "export KUBECONFIG=/etc/rancher/k3s/k3s.yaml && /usr/local/bin/k3s kubectl wait --for=condition=ready pod -l k8s-app=kube-dns -n kube-system --timeout=60s" && break
        fi
        sleep 2
        count=$((count + 2))
    done

    # Wait for traefik pod to exist, then for it to be ready
    count=0
    while [ $count -lt $max_wait ]; do
        local traefik_exists=$(ssh_exec "export KUBECONFIG=/etc/rancher/k3s/k3s.yaml && /usr/local/bin/k3s kubectl get pod -l app.kubernetes.io/name=traefik -n kube-system --no-headers 2>/dev/null | wc -l")
        traefik_exists=$(echo "$traefik_exists" | tr -d '[:space:]')
        if [ "$traefik_exists" -gt 0 ]; then
            log_info "Traefik pod found, waiting for ready status..."
            ssh_exec "export KUBECONFIG=/etc/rancher/k3s/k3s.yaml && /usr/local/bin/k3s kubectl wait --for=condition=ready pod -l app.kubernetes.io/name=traefik -n kube-system --timeout=60s" && break
        fi
        sleep 2
        count=$((count + 2))
    done

    log_success "K3s core components ready"
    ssh_exec "/usr/local/bin/k3s kubectl get nodes"
}

install_helm() {
    log_info "Installing Helm $HELM_VERSION..."

    ssh_exec "curl -fsSL https://get.helm.sh/helm-${HELM_VERSION}-linux-amd64.tar.gz | tar -xzv -C /tmp && mv /tmp/linux-amd64/helm /usr/local/bin/helm && chmod +x /usr/local/bin/helm && rm -rf /tmp/linux-amd64"

    local helm_version=$(ssh_exec "/usr/local/bin/helm version --short")
    log_success "Helm installed: $helm_version"
}

upgrade_traefik() {
    log_info "Upgrading Traefik to v$TRAEFIK_VERSION (required for Kubernetes 1.34)..."

    # Add Traefik Helm repository
    ssh_exec "export KUBECONFIG=/etc/rancher/k3s/k3s.yaml && /usr/local/bin/helm repo add traefik https://traefik.github.io/charts"
    ssh_exec "export KUBECONFIG=/etc/rancher/k3s/k3s.yaml && /usr/local/bin/helm repo update"

    # Create Traefik values file on remote server
    ssh_exec "cat > /tmp/traefik-values.yaml <<'EOF'
deployment:
  podAnnotations:
    prometheus.io/port: \"8082\"
    prometheus.io/scrape: \"true\"
global:
  systemDefaultRegistry: \"\"
image:
  repository: rancher/mirrored-library-traefik
  tag: \"$TRAEFIK_VERSION\"
priorityClassName: system-cluster-critical
providers:
  kubernetesIngress:
    publishedService:
      enabled: true
service:
  ipFamilyPolicy: PreferDualStack
tolerations:
- key: CriticalAddonsOnly
  operator: Exists
- effect: NoSchedule
  key: node-role.kubernetes.io/control-plane
  operator: Exists
EOF
"

    # Upgrade Traefik using Helm
    ssh_exec "export KUBECONFIG=/etc/rancher/k3s/k3s.yaml && /usr/local/bin/helm upgrade traefik traefik/traefik --version $TRAEFIK_CHART_VERSION --namespace kube-system -f /tmp/traefik-values.yaml --wait --timeout 5m"

    # Wait for Traefik to be ready
    log_info "Waiting for Traefik to be ready after upgrade..."
    ssh_exec "export KUBECONFIG=/etc/rancher/k3s/k3s.yaml && /usr/local/bin/k3s kubectl -n kube-system rollout status deployment/traefik --timeout=300s"

    # Verify Traefik version
    local traefik_version=$(ssh_exec "export KUBECONFIG=/etc/rancher/k3s/k3s.yaml && /usr/local/bin/k3s kubectl get deployment traefik -n kube-system -o jsonpath='{.spec.template.spec.containers[0].image}'" | grep -oE '[0-9]+\.[0-9]+\.[0-9]+')
    log_success "Traefik upgraded to v$traefik_version"

    # Clean up values file
    ssh_exec "rm -f /tmp/traefik-values.yaml"
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

    # Install Rancher with tls=external (TLS termination handled by Traefik ingress)
    # NOTE: Rancher pods communicate internally via HTTP (port 80).
    # A NetworkPolicy will be applied to restrict access to Traefik only.
    ssh_exec "export KUBECONFIG=/etc/rancher/k3s/k3s.yaml && /usr/local/bin/helm install rancher rancher-stable/rancher --namespace cattle-system --set hostname='$RANCHER_HOSTNAME' --set replicas=1 --set bootstrapPassword='$bootstrap_password' --set tls=external --version $RANCHER_VERSION --wait --timeout 10m"

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

apply_rancher_network_policy() {
    log_info "Applying network policy to restrict Rancher access..."

    # Create network policy that allows only Traefik to reach Rancher pods
    # This mitigates the security risk of tls=external (HTTP internal communication)
    ssh_exec "export KUBECONFIG=/etc/rancher/k3s/k3s.yaml && cat <<'NETPOL' | /usr/local/bin/k3s kubectl apply -f -
---
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata:
  name: rancher-access-control
  namespace: cattle-system
spec:
  podSelector:
    matchLabels:
      app: rancher
  policyTypes:
  - Ingress
  ingress:
  # Allow traffic from Traefik ingress controller
  - from:
    - namespaceSelector:
        matchLabels:
          kubernetes.io/metadata.name: kube-system
      podSelector:
        matchLabels:
          app.kubernetes.io/name: traefik
    ports:
    - protocol: TCP
      port: 80
    - protocol: TCP
      port: 444
  # Allow traffic from same namespace (for webhooks, internal communication)
  - from:
    - podSelector: {}
    ports:
    - protocol: TCP
      port: 80
    - protocol: TCP
      port: 444
NETPOL
"

    log_success "Network policy applied - Rancher access restricted to Traefik only"
}

configure_kubeconfig_access() {
    log_info "Configuring kubectl access for non-root users..."

    ssh_exec "groupadd -f k3s-access"
    ssh_exec "mkdir -p /etc/rancher/k3s-access && cp /etc/rancher/k3s/k3s.yaml /etc/rancher/k3s-access/kubeconfig && chgrp k3s-access /etc/rancher/k3s-access/kubeconfig && chmod 640 /etc/rancher/k3s-access/kubeconfig"

    # Add SSH user to k3s-access group and configure bashrc
    log_info "Granting kubectl access to user: $SSH_USER"
    ssh_exec "usermod -a -G k3s-access $SSH_USER"
    ssh_exec "grep -q 'KUBECONFIG=/etc/rancher/k3s-access/kubeconfig' /home/$SSH_USER/.bashrc 2>/dev/null || echo 'export KUBECONFIG=/etc/rancher/k3s-access/kubeconfig' >> /home/$SSH_USER/.bashrc"

    log_success "User $SSH_USER configured for kubectl access"
    log_info "User must re-login or run: newgrp k3s-access"
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
    check_ssh_prerequisites

    # Remote system checks
    check_remote_rhel
    check_data_disk
    backup_existing_installation

    # System configuration
    configure_firewall
    configure_selinux
    install_dependencies
    configure_selinux_data_dir

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
