#!/bin/bash
#
# Import VM Templates (Flatcar Stable + Ubuntu 24.04 LTS) to vSphere Content Library
#
# Prerequisiti:
#   - govc installato (https://github.com/vmware/govmomi/releases)
#   - Variabili ambiente GOVC_* configurate
#
# Uso:
#   export GOVC_URL=srv02.mosca.lan
#   export GOVC_USERNAME=administrator@vsphere.local
#   export GOVC_PASSWORD=xxx
#   export GOVC_INSECURE=true
#   ./import-vm-templates.sh cnt-lbr-esxi01

set -e

# Configurazione
CONTENT_LIBRARY="${1:-cnt-lbr-esxi01}"
DOWNLOAD_DIR="${2:-/tmp/vm-templates}"
FLATCAR_CHANNEL="stable"

# URLs
FLATCAR_BASE_URL="https://stable.release.flatcar-linux.net/amd64-usr/current"
FLATCAR_OVA="flatcar_production_vmware_ova.ova"

UBUNTU_BASE_URL="https://cloud-images.ubuntu.com/noble/current"
UBUNTU_OVA="noble-server-cloudimg-amd64.ova"

# Colori
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

log_info() { echo -e "${NC}[INFO] $1"; }
log_success() { echo -e "${GREEN}[OK] $1${NC}"; }
log_warn() { echo -e "${YELLOW}[WARN] $1${NC}"; }
log_error() { echo -e "${RED}[ERROR] $1${NC}"; }

check_prerequisites() {
    log_info "Verifica prerequisiti..."

    if ! command -v govc &> /dev/null; then
        log_error "govc non trovato. Installalo da https://github.com/vmware/govmomi/releases"
        exit 1
    fi

    if [ -z "$GOVC_URL" ]; then
        log_error "GOVC_URL non configurato"
        echo "Esporta le variabili:"
        echo "  export GOVC_URL=vcenter.example.com"
        echo "  export GOVC_USERNAME=user@vsphere.local"
        echo "  export GOVC_PASSWORD=password"
        echo "  export GOVC_INSECURE=true"
        exit 1
    fi

    # Test connessione
    if ! govc about &> /dev/null; then
        log_error "Impossibile connettersi a vCenter"
        exit 1
    fi

    log_success "Prerequisiti OK"
}

get_flatcar_version() {
    log_info "Recupero versione Flatcar Stable..."
    VERSION=$(curl -sfL "$FLATCAR_BASE_URL/version.txt" | grep FLATCAR_VERSION | cut -d= -f2)
    echo "$VERSION"
}

download_template() {
    local url="$1"
    local output="$2"
    local name="$3"

    if [ -f "$output" ]; then
        log_warn "$name già in cache: $output"
        return 0
    fi

    log_info "Download $name..."
    log_info "URL: $url"
    log_info "Questo potrebbe richiedere diversi minuti..."

    curl -L --progress-bar -o "$output" "$url"
    log_success "Download completato: $output"
}

import_to_library() {
    local ova_path="$1"
    local item_name="$2"
    local library="$3"

    log_info "Importazione $item_name in Content Library '$library'..."

    # Verifica se esiste già
    if govc library.info "/$library/$item_name" &> /dev/null; then
        log_warn "Item '$item_name' già presente, rimuovo..."
        govc library.rm "/$library/$item_name"
    fi

    # Importa
    govc library.import -n "$item_name" "/$library" "$ova_path"
    log_success "Importazione completata: $item_name"
}

# Main
echo "======================================"
echo " Import VM Templates to vSphere"
echo "======================================"
echo ""

check_prerequisites

# Crea directory download
mkdir -p "$DOWNLOAD_DIR"

# Verifica Content Library
log_info "Verifica Content Library: $CONTENT_LIBRARY"
if ! govc library.info "/$CONTENT_LIBRARY" &> /dev/null; then
    log_error "Content Library '$CONTENT_LIBRARY' non trovata!"
    exit 1
fi
log_success "Content Library trovata"

echo ""
echo "=== Flatcar Container Linux (Stable) ==="

FLATCAR_VERSION=$(get_flatcar_version)
log_success "Versione: $FLATCAR_VERSION"

FLATCAR_LOCAL="$DOWNLOAD_DIR/flatcar-stable-$FLATCAR_VERSION.ova"
download_template "$FLATCAR_BASE_URL/$FLATCAR_OVA" "$FLATCAR_LOCAL" "Flatcar $FLATCAR_VERSION"
import_to_library "$FLATCAR_LOCAL" "flatcar-stable-$FLATCAR_VERSION" "$CONTENT_LIBRARY"

echo ""
echo "=== Ubuntu Server 24.04 LTS (Noble) ==="

UBUNTU_LOCAL="$DOWNLOAD_DIR/ubuntu-24.04-lts.ova"
download_template "$UBUNTU_BASE_URL/$UBUNTU_OVA" "$UBUNTU_LOCAL" "Ubuntu 24.04 LTS"
import_to_library "$UBUNTU_LOCAL" "ubuntu-24.04-lts-cloudimg" "$CONTENT_LIBRARY"

echo ""
echo "======================================"
log_success "Import completato!"
echo "======================================"
echo ""
echo "Template disponibili:"
govc library.ls "/$CONTENT_LIBRARY"
