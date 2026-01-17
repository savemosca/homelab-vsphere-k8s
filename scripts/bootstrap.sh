#!/bin/bash
# Bootstrap script for homelab Kubernetes cluster on vSphere
# This script automates the entire cluster setup process

set -euo pipefail

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# Configuration
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(dirname "${SCRIPT_DIR}")"
MGMT_KUBECONFIG="${HOME}/.kube/management-config"
WORKLOAD_KUBECONFIG="${HOME}/.kube/homelab-config"

# Logging functions
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

# Check prerequisites
check_prerequisites() {
    log_info "Checking prerequisites..."

    local missing_tools=()

    # Check required tools
    for tool in kubectl clusterctl helm govc; do
        if ! command -v "$tool" &> /dev/null; then
            missing_tools+=("$tool")
        fi
    done

    if [ ${#missing_tools[@]} -gt 0 ]; then
        log_error "Missing required tools: ${missing_tools[*]}"
        log_info "Install them with:"
        log_info "  macOS: brew install kubectl clusterctl helm govmomi"
        log_info "  Linux: See respective tool documentation"
        exit 1
    fi

    log_success "All prerequisites met"
}

# Load environment variables
load_environment() {
    log_info "Loading environment variables..."

    if [ -f "${REPO_ROOT}/.env" ]; then
        # shellcheck disable=SC1091
        source "${REPO_ROOT}/.env"
        log_success "Environment loaded from .env"
    else
        log_warning ".env file not found. Using environment variables."
    fi

    # Verify required variables
    local required_vars=(
        "VSPHERE_SERVER"
        "VSPHERE_USERNAME"
        "VSPHERE_PASSWORD"
        "VSPHERE_DATACENTER"
        "VSPHERE_DATASTORE"
        "VSPHERE_NETWORK"
        "VSPHERE_THUMBPRINT"
    )

    local missing_vars=()
    for var in "${required_vars[@]}"; do
        if [ -z "${!var:-}" ]; then
            missing_vars+=("$var")
        fi
    done

    if [ ${#missing_vars[@]} -gt 0 ]; then
        log_error "Missing required environment variables: ${missing_vars[*]}"
        exit 1
    fi
}

# Step 1: Initialize management cluster
init_management_cluster() {
    log_info "Step 1: Initializing management cluster (K3s + CAPV)..."

    # Check if management cluster is accessible
    if kubectl --kubeconfig="${MGMT_KUBECONFIG}" cluster-info &> /dev/null; then
        log_success "Management cluster already accessible"
        return 0
    fi

    log_warning "Management cluster not found. Please create it manually:"
    log_info "  1. Deploy Ubuntu VM on vSphere"
    log_info "  2. Run infrastructure/management-cluster/k3s-install.sh"
    log_info "  3. Copy kubeconfig to ${MGMT_KUBECONFIG}"
    log_info "  4. Re-run this script"
    exit 1
}

# Step 2: Install Cluster API providers
install_capv() {
    log_info "Step 2: Installing Cluster API providers..."

    export KUBECONFIG="${MGMT_KUBECONFIG}"

    # Check if CAPV is already installed
    if kubectl get namespace capv-system &> /dev/null; then
        log_success "CAPV already installed"
        return 0
    fi

    log_info "Installing CAPV v1.10.0..."
    clusterctl init --infrastructure vsphere:v1.10.0

    log_info "Waiting for CAPV controllers to be ready..."
    kubectl wait --for=condition=available --timeout=300s \
        deployment/capv-controller-manager -n capv-system

    log_success "CAPV installed successfully"
}

# Step 3: Create workload cluster
create_workload_cluster() {
    log_info "Step 3: Creating workload cluster..."

    export KUBECONFIG="${MGMT_KUBECONFIG}"

    # Check if cluster already exists
    if kubectl get cluster homelab-k8s &> /dev/null; then
        log_success "Workload cluster already exists"
        return 0
    fi

    log_info "Applying cluster manifests..."
    kubectl apply -f "${REPO_ROOT}/infrastructure/workload-cluster/cluster.yaml"
    kubectl apply -f "${REPO_ROOT}/infrastructure/workload-cluster/control-plane.yaml"
    kubectl apply -f "${REPO_ROOT}/infrastructure/workload-cluster/worker-pool.yaml"

    log_info "Waiting for cluster to be ready (this may take 10-15 minutes)..."
    kubectl wait --for=condition=ready --timeout=900s cluster/homelab-k8s

    log_success "Workload cluster created"
}

# Step 4: Get workload cluster kubeconfig
get_workload_kubeconfig() {
    log_info "Step 4: Retrieving workload cluster kubeconfig..."

    export KUBECONFIG="${MGMT_KUBECONFIG}"

    clusterctl get kubeconfig homelab-k8s > "${WORKLOAD_KUBECONFIG}"
    chmod 600 "${WORKLOAD_KUBECONFIG}"

    log_success "Kubeconfig saved to ${WORKLOAD_KUBECONFIG}"
}

# Step 5: Install CNI (Cilium)
install_cni() {
    log_info "Step 5: Installing Cilium CNI..."

    export KUBECONFIG="${WORKLOAD_KUBECONFIG}"

    # Check if Cilium is already installed
    if kubectl get namespace cilium &> /dev/null; then
        log_success "Cilium already installed"
        return 0
    fi

    log_info "Adding Cilium Helm repo..."
    helm repo add cilium https://helm.cilium.io/
    helm repo update

    log_info "Installing Cilium..."
    helm install cilium cilium/cilium --version 1.14.5 \
        --namespace kube-system \
        -f "${REPO_ROOT}/infrastructure/networking/cilium-values.yaml"

    log_info "Waiting for Cilium to be ready..."
    kubectl wait --for=condition=ready --timeout=300s \
        pod -l k8s-app=cilium -n kube-system

    log_success "Cilium installed successfully"
}

# Step 6: Install storage (vSphere CSI)
install_storage() {
    log_info "Step 6: Installing vSphere CSI driver..."

    export KUBECONFIG="${WORKLOAD_KUBECONFIG}"

    # Check if CSI driver is already installed
    if kubectl get namespace vmware-system-csi &> /dev/null; then
        log_success "vSphere CSI already installed"
        return 0
    fi

    log_info "Installing vSphere CSI driver..."
    kubectl apply -f "${REPO_ROOT}/infrastructure/storage/vsphere-csi-driver.yaml"
    kubectl apply -f "${REPO_ROOT}/infrastructure/storage/storageclass.yaml"

    log_success "vSphere CSI installed successfully"
}

# Step 7: Install networking components
install_networking() {
    log_info "Step 7: Installing networking components..."

    export KUBECONFIG="${WORKLOAD_KUBECONFIG}"

    # Install MetalLB
    log_info "Installing MetalLB..."
    kubectl apply -f https://raw.githubusercontent.com/metallb/metallb/v0.14.3/config/manifests/metallb-native.yaml
    sleep 30  # Wait for MetalLB CRDs
    kubectl apply -f "${REPO_ROOT}/infrastructure/networking/metallb-config.yaml"

    # Install NGINX Ingress
    log_info "Installing NGINX Ingress Controller..."
    helm repo add ingress-nginx https://kubernetes.github.io/ingress-nginx
    helm repo update
    helm upgrade --install ingress-nginx ingress-nginx/ingress-nginx \
        --namespace ingress-nginx --create-namespace

    log_success "Networking components installed"
}

# Step 8: Deploy applications
deploy_applications() {
    log_info "Step 8: Deploying homelab applications..."

    export KUBECONFIG="${WORKLOAD_KUBECONFIG}"

    log_info "Deploying media stack..."
    kubectl apply -f "${REPO_ROOT}/kubernetes/apps/media-stack/namespace.yaml"
    kubectl apply -f "${REPO_ROOT}/kubernetes/apps/media-stack/shared-storage.yaml"
    kubectl apply -f "${REPO_ROOT}/kubernetes/apps/media-stack/radarr/deployment.yaml"

    log_info "Deploying Pihole + Cloudflared..."
    kubectl apply -f "${REPO_ROOT}/kubernetes/apps/pihole-cloudflared/pihole-deployment.yaml"

    log_success "Applications deployed"
}

# Step 9: Install autoscaler
install_autoscaler() {
    log_info "Step 9: Installing Cluster Autoscaler..."

    export KUBECONFIG="${WORKLOAD_KUBECONFIG}"

    # First, add annotations to MachineDeployment
    kubectl annotate machinedeployment homelab-k8s-workers \
        cluster.x-k8s.io/cluster-api-autoscaler-node-group-min-size=2 \
        cluster.x-k8s.io/cluster-api-autoscaler-node-group-max-size=5 \
        --overwrite

    # Apply autoscaler manifest
    kubectl apply -f "${REPO_ROOT}/infrastructure/workload-cluster/autoscaler.yaml"

    log_success "Cluster Autoscaler installed"
}

# Main bootstrap flow
main() {
    echo -e "${GREEN}"
    echo "╔═══════════════════════════════════════════════════════╗"
    echo "║  Homelab vSphere Kubernetes Bootstrap                ║"
    echo "║  Automated cluster setup for production-grade K8s    ║"
    echo "╚═══════════════════════════════════════════════════════╝"
    echo -e "${NC}"

    check_prerequisites
    load_environment

    log_info "Starting bootstrap process..."
    echo ""

    init_management_cluster
    install_capv
    create_workload_cluster
    get_workload_kubeconfig
    install_cni
    install_storage
    install_networking
    deploy_applications
    install_autoscaler

    echo ""
    log_success "╔═══════════════════════════════════════════════════════╗"
    log_success "║  Bootstrap completed successfully!                    ║"
    log_success "╚═══════════════════════════════════════════════════════╝"
    echo ""
    log_info "Cluster details:"
    log_info "  Management kubeconfig: ${MGMT_KUBECONFIG}"
    log_info "  Workload kubeconfig:   ${WORKLOAD_KUBECONFIG}"
    echo ""
    log_info "Access your applications:"
    log_info "  Radarr:  https://radarr.homelab.local"
    log_info "  Pihole:  https://pihole.homelab.local"
    echo ""
    log_info "Switch to workload cluster:"
    log_info "  export KUBECONFIG=${WORKLOAD_KUBECONFIG}"
    echo ""
}

main "$@"
