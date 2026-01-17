# Management Cluster Setup con Rancher (srv26)

Questa guida configura srv26.mosca.lan come management cluster per Cluster API Provider vSphere (CAPV), utilizzando il K3s esistente che ospita Rancher.

## Architettura

```
┌─────────────────────────────────────────────────┐
│   srv26.mosca.lan (192.168.11.130)              │
│   Management Cluster (K3s v1.32.3)              │
│                                                 │
│  ┌──────────────────┐  ┌──────────────────────┐│
│  │  Rancher v2.11.8 │  │  CAPV Controllers    ││
│  │  • Web UI        │  │  • cluster-api       ││
│  │  • Multi-cluster │  │  • capv-controller   ││──────┐
│  │  • RBAC          │  │  • kubeadm-bootstrap ││      │
│  │  • Monitoring    │  │  • control-plane     ││      │
│  └──────────────────┘  └──────────────────────┘│      │
│                                                 │      │
└─────────────────────────────────────────────────┘      │
                                                         │ Manages
                                                         ▼
                          ┌──────────────────────────────────┐
                          │  Workload Cluster (vSphere VMs)  │
                          │  • 1 Control Plane (Flatcar)     │
                          │  • 2-5 Workers (Flatcar)         │
                          │  • Auto-scaling                  │
                          │  • Managed by Rancher            │
                          └──────────────────────────────────┘
```

## Vantaggi di questo Approccio

1. **Riuso Infrastruttura**: Usa il server K3s esistente invece di creare una nuova VM
2. **Rancher Integration**: Gestione centralizzata di tutti i cluster da un'unica UI
3. **Efficienza Risorse**: Nessuna VM aggiuntiva per il management cluster
4. **Backup Unificato**: Un solo cluster da fare backup (srv26)

## Pre-requisiti

- [x] srv26.mosca.lan con K3s v1.32.3 funzionante
- [x] Rancher v2.11.8 installato e accessibile
- [ ] Backup di Rancher completato (vedi [00-rancher-upgrade.md](00-rancher-upgrade.md))
- [ ] Accesso SSH a srv26: `ssh administrator@srv26.mosca.lan`
- [ ] Parametri vSphere disponibili (vCenter URL, datacenter, datastore, etc.)

## 1. Configurare kubectl Locale

Per gestire CAPV dal tuo workstation, configura l'accesso al cluster srv26:

```bash
# Crea directory kubeconfig se non esiste
mkdir -p ~/.kube

# Copia kubeconfig da srv26
scp administrator@srv26.mosca.lan:/etc/rancher/k3s/k3s.yaml ~/.kube/srv26-config

# Aggiorna l'IP del server nel kubeconfig
sed -i '' 's/127.0.0.1/192.168.11.130/g' ~/.kube/srv26-config

# Oppure usa il nome host
sed -i '' 's/127.0.0.1/srv26.mosca.lan/g' ~/.kube/srv26-config

# Test connessione
export KUBECONFIG=~/.kube/srv26-config
kubectl get nodes

# Output atteso:
# NAME              STATUS   ROLES                  AGE    VERSION
# srv26.mosca.lan   Ready    control-plane,master   269d   v1.32.3+k3s1
```

### Configurare Alias (Opzionale)

Aggiungi alias al tuo `~/.bashrc` o `~/.zshrc`:

```bash
# Alias per srv26 management cluster
alias k-mgmt='kubectl --kubeconfig=~/.kube/srv26-config'

# Alias per workload cluster (configureremo dopo)
alias k-work='kubectl --kubeconfig=~/.kube/workload-config'
```

## 2. Installare clusterctl

Installa il CLI di Cluster API sul tuo workstation:

```bash
# macOS con Homebrew
brew install clusterctl

# macOS manuale
curl -L https://github.com/kubernetes-sigs/cluster-api/releases/download/v1.9.5/clusterctl-darwin-amd64 -o clusterctl
chmod +x clusterctl
sudo mv clusterctl /usr/local/bin/

# Linux AMD64
curl -L https://github.com/kubernetes-sigs/cluster-api/releases/download/v1.9.5/clusterctl-linux-amd64 -o clusterctl
chmod +x clusterctl
sudo mv clusterctl /usr/local/bin/

# Verifica installazione
clusterctl version
# Output: clusterctl version: &version.Info{Major:"1", Minor:"9", GitVersion:"v1.9.5"}
```

## 3. Configurare Parametri vSphere

Crea file di configurazione per i parametri del tuo ambiente:

```bash
# Crea directory configurazione
mkdir -p ~/.cluster-api

# Crea file di configurazione
cat > ~/.cluster-api/vsphere-params.env <<'EOF'
# vSphere Connection
export VSPHERE_SERVER="vcenter.example.com"              # Il tuo vCenter hostname/IP
export VSPHERE_USERNAME="administrator@vsphere.local"    # Username vSphere
export VSPHERE_PASSWORD="your-secure-password"           # Password vSphere
export VSPHERE_DATACENTER="Datacenter"                   # Nome del datacenter
export VSPHERE_DATASTORE="datastore1"                    # Nome del datastore
export VSPHERE_NETWORK="VM Network"                      # Nome della rete
export VSPHERE_RESOURCE_POOL="k8s-homelab"               # Resource pool per K8s
export VSPHERE_FOLDER="/Datacenter/vm/k8s-homelab"      # Folder per le VM
export VSPHERE_TEMPLATE="/Datacenter/vm/Templates/flatcar-stable"  # Template Flatcar

# vCenter SSL Thumbprint (ottieni con: govc about.cert -thumbprint -k)
export VSPHERE_THUMBPRINT="AA:BB:CC:DD:EE:FF:..."       # SHA256 fingerprint

# SSH Key per accesso ai nodi (usa la tua chiave pubblica)
export VSPHERE_SSH_AUTHORIZED_KEY="ssh-rsa AAAAB3Nza... user@host"

# Cluster Configuration
export CLUSTER_NAME="homelab-k8s"
export KUBERNETES_VERSION="v1.32.3"
export CONTROL_PLANE_MACHINE_COUNT=1
export WORKER_MACHINE_COUNT=2

# Network Configuration
export CONTROL_PLANE_ENDPOINT_IP="192.168.11.100"       # IP per control plane (DHCP o static)
export POD_CIDR="10.244.0.0/16"
export SERVICE_CIDR="10.96.0.0/12"

# Node Configuration
export VSPHERE_CONTROL_PLANE_DISK_GIB=50
export VSPHERE_CONTROL_PLANE_MEM_MIB=8192
export VSPHERE_CONTROL_PLANE_NUM_CPUS=2

export VSPHERE_WORKER_DISK_GIB=100
export VSPHERE_WORKER_MEM_MIB=16384
export VSPHERE_WORKER_NUM_CPUS=4
EOF

# IMPORTANTE: Edita il file con i tuoi parametri reali
nano ~/.cluster-api/vsphere-params.env

# Carica le variabili
source ~/.cluster-api/vsphere-params.env
```

### Come Ottenere il vCenter SSL Thumbprint

```bash
# Metodo 1: Con govc (se installato)
export GOVC_URL="https://${VSPHERE_SERVER}"
export GOVC_USERNAME="${VSPHERE_USERNAME}"
export GOVC_PASSWORD="${VSPHERE_PASSWORD}"
export GOVC_INSECURE=true
govc about.cert -thumbprint

# Metodo 2: Con openssl
echo | openssl s_client -connect ${VSPHERE_SERVER}:443 2>/dev/null | \
  openssl x509 -fingerprint -sha256 -noout | \
  cut -d= -f2

# Metodo 3: Da vCenter UI
# 1. Accedi a vCenter
# 2. Menu > Administration > Certificate Management
# 3. Copia SHA256 Thumbprint
```

### Come Ottenere la tua SSH Public Key

```bash
# Se hai già una chiave SSH
cat ~/.ssh/id_rsa.pub

# Se non hai una chiave, creala
ssh-keygen -t rsa -b 4096 -C "your-email@example.com"
cat ~/.ssh/id_rsa.pub
```

## 4. Creare clusterctl Configuration File

```bash
cat > ~/.cluster-api/clusterctl.yaml <<EOF
# CAPV Provider Configuration
providers:
  - name: vsphere
    url: https://github.com/kubernetes-sigs/cluster-api-provider-vsphere/releases/v1.11.4/infrastructure-components.yaml
    type: InfrastructureProvider

# Image repository settings
images:
  all:
    repository: ""  # Default registry

# Enable feature flags
CLUSTER_TOPOLOGY: "true"
EOF
```

## 5. Inizializzare CAPV sul Management Cluster

```bash
# Assicurati di puntare al cluster srv26
export KUBECONFIG=~/.kube/srv26-config

# Carica parametri vSphere
source ~/.cluster-api/vsphere-params.env

# Inizializza Cluster API con provider vSphere
clusterctl init --infrastructure vsphere:v1.11.4

# Questo installerà:
# ✅ cluster-api controller
# ✅ cluster-api-provider-vsphere controller
# ✅ kubeadm bootstrap provider
# ✅ kubeadm control plane provider
# ✅ cert-manager (se non già presente)
```

**Output atteso:**

```
Fetching providers
Installing cert-manager Version="v1.15.3"
Waiting for cert-manager to be available...
Installing Provider="cluster-api" Version="v1.9.5" TargetNamespace="capi-system"
Installing Provider="bootstrap-kubeadm" Version="v1.9.5" TargetNamespace="capi-kubeadm-bootstrap-system"
Installing Provider="control-plane-kubeadm" Version="v1.9.5" TargetNamespace="capi-kubeadm-control-plane-system"
Installing Provider="infrastructure-vsphere" Version="v1.11.4" TargetNamespace="capv-system"

Your management cluster has been initialized successfully!

You can now create your first workload cluster by running the following:

  clusterctl generate cluster [name] --kubernetes-version [version] | kubectl apply -f -
```

## 6. Verificare l'Installazione CAPV

```bash
# Verifica che tutti i controller siano running
kubectl get pods -A | grep -E 'capi|capv|cert-manager'

# Output atteso:
# capi-kubeadm-bootstrap-system      capi-kubeadm-bootstrap-controller-manager-xxx      1/1  Running
# capi-kubeadm-control-plane-system  capi-kubeadm-control-plane-controller-manager-xxx  1/1  Running
# capi-system                        capi-controller-manager-xxx                        1/1  Running
# capv-system                        capv-controller-manager-xxx                        1/1  Running
# cert-manager                       cert-manager-xxx                                   1/1  Running
# cert-manager                       cert-manager-cainjector-xxx                        1/1  Running
# cert-manager                       cert-manager-webhook-xxx                           1/1  Running

# Verifica CRDs installate
kubectl get crd | grep cluster.x-k8s.io | wc -l
# Output atteso: ~35 CRDs

# Verifica CRDs vSphere specifiche
kubectl get crd | grep vsphere
# Output atteso:
# vsphereclusters.infrastructure.cluster.x-k8s.io
# vsphereclusteridentities.infrastructure.cluster.x-k8s.io
# vspheredeploymentzones.infrastructure.cluster.x-k8s.io
# vspherefailuredomains.infrastructure.cluster.x-k8s.io
# vspheremachines.infrastructure.cluster.x-k8s.io
# vspheremachinetemplates.infrastructure.cluster.x-k8s.io
# vspherevms.infrastructure.cluster.x-k8s.io
```

## 7. Creare vSphere Credentials Secret

CAPV necessita di credenziali vSphere per creare le VM:

```bash
# Carica parametri se non già fatto
source ~/.cluster-api/vsphere-params.env

# Crea secret con credenziali vSphere
kubectl create secret generic vsphere-credentials \
  --from-literal=username="${VSPHERE_USERNAME}" \
  --from-literal=password="${VSPHERE_PASSWORD}" \
  -n capv-system

# Verifica secret creato
kubectl get secret vsphere-credentials -n capv-system

# Crea Identity per CAPV (nuovo in CAPV v1.10+)
cat <<EOF | kubectl apply -f -
apiVersion: infrastructure.cluster.x-k8s.io/v1beta1
kind: VSphereClusterIdentity
metadata:
  name: vsphere-cluster-identity
  namespace: capv-system
spec:
  secretName: vsphere-credentials
  allowedNamespaces:
    selector:
      matchLabels: {}
EOF

# Verifica VSphereClusterIdentity
kubectl get vsphereclusteridentity -n capv-system
```

## 8. Verificare Risorsa del Management Cluster

```bash
# Verifica risorse disponibili su srv26
kubectl top node

# Output esempio:
# NAME              CPU(cores)   CPU%   MEMORY(bytes)   MEMORY%
# srv26.mosca.lan   800m         40%    2500Mi          19%

# Verifica pod in esecuzione
kubectl get pods -A | wc -l

# Verifica spazio disco
ssh administrator@srv26.mosca.lan "df -h | grep -E 'Filesystem|/var/lib/rancher'"
```

**Risorse Tipiche sul Management Cluster:**
- Rancher (3 replicas): ~1.5GB RAM, ~300m CPU
- CAPV controllers: ~500MB RAM, ~100m CPU
- cert-manager: ~200MB RAM, ~50m CPU
- **Totale**: ~2.2GB RAM, ~450m CPU

Con srv26 che ha 128GB RAM, c'è ampio spazio per CAPV.

## 9. Test Generazione Cluster Manifest (Opzionale)

Prima di creare il cluster reale, testa la generazione del manifest:

```bash
# Carica parametri
source ~/.cluster-api/vsphere-params.env

# Genera manifest di test
clusterctl generate cluster ${CLUSTER_NAME} \
  --infrastructure vsphere \
  --kubernetes-version ${KUBERNETES_VERSION} \
  --control-plane-machine-count ${CONTROL_PLANE_MACHINE_COUNT} \
  --worker-machine-count ${WORKER_MACHINE_COUNT} \
  > /tmp/test-cluster.yaml

# Visualizza il manifest generato
cat /tmp/test-cluster.yaml

# Verifica che contenga i tuoi parametri corretti
grep -E "server:|datacenter:|datastore:|network:" /tmp/test-cluster.yaml

# NON applicare ancora - questo è solo un test
# Creeremo il cluster reale nel prossimo documento
```

## 10. Integrazione con Rancher UI (Opzionale)

Puoi visualizzare i cluster CAPV anche in Rancher:

```bash
# Installa Rancher Cluster API Extension (in sviluppo)
# Questo permetterà di gestire cluster CAPV da Rancher UI

# Per ora, usa kubectl per CAPV e Rancher per management dei cluster importati
```

## 11. Backup del Management Cluster

Configura backup automatici di srv26 che ora include CAPV:

```bash
# SSH a srv26
ssh administrator@srv26.mosca.lan

# Crea script di backup che include CAPV
sudo tee /usr/local/bin/backup-management-cluster.sh >/dev/null <<'SCRIPT'
#!/bin/bash
BACKUP_DIR="/var/backups/k3s-management"
RETENTION_DAYS=7

mkdir -p ${BACKUP_DIR}

# Backup etcd snapshot
/usr/local/bin/k3s etcd-snapshot save \
  --name management-cluster-$(date +%Y%m%d-%H%M)

# Backup CAPV resources
/usr/local/bin/kubectl get -A -o yaml \
  clusters,vsphereclusters,machines,vspheremachines > \
  ${BACKUP_DIR}/capv-resources-$(date +%Y%m%d-%H%M).yaml

# Backup Rancher resources
/usr/local/bin/kubectl get -n cattle-system -o yaml \
  all,secrets,configmaps,ingress > \
  ${BACKUP_DIR}/rancher-resources-$(date +%Y%m%d-%H%M).yaml

# Cleanup old backups
find ${BACKUP_DIR} -name "*.yaml" -mtime +${RETENTION_DAYS} -delete
find /var/lib/rancher/k3s/server/db/snapshots -name "management-cluster-*.zip" -mtime +${RETENTION_DAYS} -delete

echo "Backup completed: $(date)"
SCRIPT

# Rendi eseguibile
sudo chmod +x /usr/local/bin/backup-management-cluster.sh

# Aggiungi a crontab (backup giornaliero alle 2 AM)
(sudo crontab -l 2>/dev/null; echo "0 2 * * * /usr/local/bin/backup-management-cluster.sh >> /var/log/management-backup.log 2>&1") | sudo crontab -

# Test manuale
sudo /usr/local/bin/backup-management-cluster.sh
```

## Troubleshooting

### Problema: clusterctl init fallisce

```bash
# Verifica connettività internet da srv26
ssh administrator@srv26.mosca.lan "curl -I https://github.com"

# Verifica che K3s possa pullare immagini
kubectl get events -A | grep -i "pull"

# Prova con verbosità aumentata
clusterctl init --infrastructure vsphere:v1.11.4 -v 5
```

### Problema: CAPV controller in CrashLoopBackOff

```bash
# Verifica logs del controller
kubectl logs -n capv-system deployment/capv-controller-manager

# Verifica secret credenziali
kubectl get secret vsphere-credentials -n capv-system -o yaml

# Verifica VSphereClusterIdentity
kubectl describe vsphereclusteridentity -n capv-system vsphere-cluster-identity

# Testa connessione a vCenter da srv26
ssh administrator@srv26.mosca.lan "curl -k https://${VSPHERE_SERVER}"
```

### Problema: Conflitto con Rancher

```bash
# Verifica che CAPV e Rancher non siano in conflitto su CRDs
kubectl get crd | grep -E "cattle|cluster"

# Verifica webhook
kubectl get validatingwebhookconfigurations
kubectl get mutatingwebhookconfigurations

# Se necessario, modifica priorità webhook CAPV
kubectl patch validatingwebhookconfiguration capv-validating-webhook-configuration \
  --type='json' -p='[{"op": "add", "path": "/webhooks/0/failurePolicy", "value": "Ignore"}]'
```

### Problema: Insufficient resources su srv26

```bash
# Verifica risorse disponibili
kubectl top nodes
kubectl top pods -A --sort-by=memory
kubectl top pods -A --sort-by=cpu

# Se necessario, scala Rancher a 2 replicas invece di 3
kubectl scale deployment rancher -n cattle-system --replicas=2
```

## Monitoring Management Cluster

```bash
# Crea dashboard di monitoring
cat <<EOF | kubectl apply -f -
apiVersion: v1
kind: ConfigMap
metadata:
  name: capv-monitoring-queries
  namespace: capv-system
data:
  queries.txt: |
    # Verifica stato CAPV
    kubectl get pods -n capv-system
    kubectl get vsphereclusters -A
    kubectl get clusters -A

    # Verifica risorse
    kubectl top node
    kubectl top pods -n capv-system

    # Verifica eventi
    kubectl get events -n capv-system --sort-by='.lastTimestamp'
EOF

# Script di monitoring
tee ~/check-management-cluster.sh >/dev/null <<'SCRIPT'
#!/bin/bash
export KUBECONFIG=~/.kube/srv26-config

echo "=== Management Cluster Status ==="
kubectl get nodes

echo -e "\n=== CAPV Controllers ==="
kubectl get pods -n capv-system

echo -e "\n=== Managed Clusters ==="
kubectl get clusters -A

echo -e "\n=== Resource Usage ==="
kubectl top node 2>/dev/null || echo "Metrics server not available"
SCRIPT

chmod +x ~/check-management-cluster.sh

# Esegui monitoring
~/check-management-cluster.sh
```

## Next Steps

Management cluster configurato! Procedi con:
- [03-workload-cluster.md](03-workload-cluster.md) - Creare il cluster Kubernetes workload con CAPV
- [04-autoscaling.md](04-autoscaling.md) - Configurare cluster autoscaler
- [06-rancher-import.md](06-rancher-import.md) - Importare il workload cluster in Rancher

## Riferimenti

- [Cluster API Quick Start](https://cluster-api.sigs.k8s.io/user/quick-start.html)
- [CAPV Documentation](https://github.com/kubernetes-sigs/cluster-api-provider-vsphere)
- [CAPV vSphere Permissions](https://github.com/kubernetes-sigs/cluster-api-provider-vsphere/blob/main/docs/permission_and_roles.md)
- [Rancher Integration with Cluster API](https://github.com/rancher/cluster-api)
