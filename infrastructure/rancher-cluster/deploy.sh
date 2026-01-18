#!/bin/bash
# Script per deployare il cluster RKE2 su vSphere tramite Rancher
#
# Prerequisiti:
#   - kubectl configurato per accedere al management cluster (srv26)
#   - File cloud-credential.yaml creato dal template con credenziali reali
#
# Uso: ./deploy.sh [create|delete|status]

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
NAMESPACE="fleet-default"
CLUSTER_NAME="homelab-k8s"

# Colori per output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

log_info() { echo -e "${GREEN}[INFO]${NC} $1"; }
log_warn() { echo -e "${YELLOW}[WARN]${NC} $1"; }
log_error() { echo -e "${RED}[ERROR]${NC} $1"; }

check_prerequisites() {
    log_info "Verifica prerequisiti..."

    # Verifica kubectl
    if ! command -v kubectl &> /dev/null; then
        log_error "kubectl non trovato"
        exit 1
    fi

    # Verifica connessione al management cluster
    if ! kubectl cluster-info &> /dev/null; then
        log_error "Impossibile connettersi al cluster Kubernetes"
        log_info "Assicurati che KUBECONFIG punti al management cluster (srv26)"
        exit 1
    fi

    # Verifica Rancher
    if ! kubectl get deployment -n cattle-system rancher &> /dev/null; then
        log_error "Rancher non trovato nel cluster"
        exit 1
    fi

    # Verifica file credential
    if [ ! -f "${SCRIPT_DIR}/cloud-credential.yaml" ]; then
        log_error "File cloud-credential.yaml non trovato"
        log_info "Crea il file dal template:"
        log_info "  cp cloud-credential.yaml.template cloud-credential.yaml"
        log_info "  # Modifica con le credenziali reali"
        exit 1
    fi

    log_info "Prerequisiti OK"
}

create_cluster() {
    log_info "=== Creazione Cluster ${CLUSTER_NAME} ==="

    # 1. Crea namespace se non esiste
    kubectl create namespace ${NAMESPACE} --dry-run=client -o yaml | kubectl apply -f -

    # 2. Applica cloud credentials
    log_info "Applicazione cloud credentials..."
    kubectl apply -f "${SCRIPT_DIR}/cloud-credential.yaml"

    # 3. Applica machine configs
    log_info "Applicazione machine configs..."
    kubectl apply -f "${SCRIPT_DIR}/vsphere-machine-config.yaml"

    # 4. Crea il cluster
    log_info "Creazione cluster..."
    kubectl apply -f "${SCRIPT_DIR}/cluster.yaml"

    log_info "=== Cluster creato ==="
    log_info "Monitora il provisioning con:"
    log_info "  kubectl get clusters.provisioning.cattle.io -n ${NAMESPACE} -w"
    log_info "  kubectl get machines.cluster.x-k8s.io -n ${NAMESPACE} -w"
}

delete_cluster() {
    log_warn "=== Eliminazione Cluster ${CLUSTER_NAME} ==="
    read -p "Sei sicuro di voler eliminare il cluster? [y/N] " -n 1 -r
    echo
    if [[ $REPLY =~ ^[Yy]$ ]]; then
        kubectl delete -f "${SCRIPT_DIR}/cluster.yaml" --ignore-not-found
        log_info "Cluster in fase di eliminazione..."
        log_info "Le VM su vSphere verranno eliminate automaticamente"
    else
        log_info "Operazione annullata"
    fi
}

show_status() {
    log_info "=== Status Cluster ${CLUSTER_NAME} ==="

    echo ""
    echo "--- Cluster ---"
    kubectl get clusters.provisioning.cattle.io -n ${NAMESPACE} -o wide 2>/dev/null || echo "Nessun cluster trovato"

    echo ""
    echo "--- Machine Pools ---"
    kubectl get machinepools.rke-machine.cattle.io -n ${NAMESPACE} 2>/dev/null || echo "Nessun machine pool trovato"

    echo ""
    echo "--- Machines ---"
    kubectl get machines.cluster.x-k8s.io -n ${NAMESPACE} -o wide 2>/dev/null || echo "Nessuna macchina trovata"

    echo ""
    echo "--- Cloud Credentials ---"
    kubectl get secrets -n cattle-global-data -l cattle.io/creator=norman 2>/dev/null | head -10

    # Se cluster è attivo, mostra kubeconfig
    CLUSTER_STATUS=$(kubectl get clusters.provisioning.cattle.io -n ${NAMESPACE} ${CLUSTER_NAME} -o jsonpath='{.status.ready}' 2>/dev/null || echo "false")
    if [ "$CLUSTER_STATUS" == "true" ]; then
        echo ""
        log_info "Cluster READY! Per ottenere il kubeconfig:"
        log_info "  kubectl get secret -n ${NAMESPACE} ${CLUSTER_NAME}-kubeconfig -o jsonpath='{.data.value}' | base64 -d > ~/.kube/${CLUSTER_NAME}.yaml"
    fi
}

get_kubeconfig() {
    log_info "Recupero kubeconfig per ${CLUSTER_NAME}..."

    KUBECONFIG_SECRET="${CLUSTER_NAME}-kubeconfig"
    KUBECONFIG_FILE="${HOME}/.kube/${CLUSTER_NAME}.yaml"

    if kubectl get secret -n ${NAMESPACE} ${KUBECONFIG_SECRET} &> /dev/null; then
        kubectl get secret -n ${NAMESPACE} ${KUBECONFIG_SECRET} -o jsonpath='{.data.value}' | base64 -d > "${KUBECONFIG_FILE}"
        log_info "Kubeconfig salvato in: ${KUBECONFIG_FILE}"
        log_info "Usa con: export KUBECONFIG=${KUBECONFIG_FILE}"
    else
        log_error "Kubeconfig non ancora disponibile. Il cluster potrebbe essere ancora in provisioning."
    fi
}

# Main
case "${1:-status}" in
    create)
        check_prerequisites
        create_cluster
        ;;
    delete)
        delete_cluster
        ;;
    status)
        show_status
        ;;
    kubeconfig)
        get_kubeconfig
        ;;
    *)
        echo "Uso: $0 [create|delete|status|kubeconfig]"
        echo ""
        echo "Comandi:"
        echo "  create     - Crea il cluster RKE2 su vSphere"
        echo "  delete     - Elimina il cluster"
        echo "  status     - Mostra lo stato del cluster"
        echo "  kubeconfig - Recupera il kubeconfig del cluster"
        exit 1
        ;;
esac
