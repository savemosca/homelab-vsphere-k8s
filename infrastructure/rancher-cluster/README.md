# Cluster RKE2 su vSphere gestito da Rancher

Configurazione dichiarativa per creare e gestire il cluster Kubernetes workload su vSphere tramite Rancher.

## Architettura

```
┌─────────────────────────────────────────────────────────────────┐
│  Management Cluster (srv26.mosca.lan)                           │
│  K3s + Rancher                                                  │
│                                                                 │
│  ┌─────────────────────────────────────────────────────────┐   │
│  │  Rancher Provisioning                                    │   │
│  │  - Cloud Credential (vSphere)                            │   │
│  │  - Machine Config (VM templates)                         │   │
│  │  - Cluster Resource (RKE2)                               │   │
│  └─────────────────────────────────────────────────────────┘   │
└─────────────────────────────────────────────────────────────────┘
                              │
                              ▼
┌─────────────────────────────────────────────────────────────────┐
│  Workload Cluster (homelab-k8s)                                 │
│  RKE2 su vSphere                                                │
│                                                                 │
│  ┌─────────────┐  ┌─────────────────────────────────────────┐  │
│  │ Control     │  │ Worker Pool (Flatcar)                   │  │
│  │ Plane       │  │ ┌───────┐ ┌───────┐ ┌───────┐          │  │
│  │ (Ubuntu)    │  │ │ W1    │ │ W2    │ │ W3    │          │  │
│  └─────────────┘  │ └───────┘ └───────┘ └───────┘          │  │
│                   └─────────────────────────────────────────┘  │
│                   ┌─────────────────────────────────────────┐  │
│                   │ GPU Pool (Ubuntu 24.04)                 │  │
│                   │ ┌───────────────────┐                   │  │
│                   │ │ GPU-W1 (NVIDIA T4)│                   │  │
│                   │ └───────────────────┘                   │  │
│                   └─────────────────────────────────────────┘  │
└─────────────────────────────────────────────────────────────────┘
```

## Prerequisiti

1. **Rancher installato** su srv26.mosca.lan
2. **vSphere credentials** configurate
3. **Template VM** in vSphere:
   - Ubuntu 24.04 (control plane + GPU workers)
   - Flatcar Linux (standard workers)
4. **Network** configurata in vSphere

## File di Configurazione

| File | Descrizione |
|------|-------------|
| `cloud-credential.yaml` | Credenziali vSphere (da applicare con secret) |
| `vsphere-machine-config.yaml` | Template configurazione VM |
| `cluster.yaml` | Definizione cluster RKE2 |
| `machine-pools.yaml` | Pool di worker nodes |

## Deployment

### 1. Creare il Secret con credenziali vSphere

```bash
# Creare il secret (NON committare su git!)
kubectl create secret generic vsphere-credentials \
  --namespace=fleet-default \
  --from-literal=username='rancher.user@vsphere.local' \
  --from-literal=password='YOUR_PASSWORD'
```

### 2. Applicare la Cloud Credential

```bash
kubectl apply -f cloud-credential.yaml
```

### 3. Applicare la Machine Config

```bash
kubectl apply -f vsphere-machine-config.yaml
```

### 4. Creare il Cluster

```bash
kubectl apply -f cluster.yaml
kubectl apply -f machine-pools.yaml
```

### 5. Monitorare il provisioning

```bash
# Status cluster
kubectl get clusters.provisioning.cattle.io -n fleet-default

# Status macchine
kubectl get machines.cluster.x-k8s.io -n fleet-default

# Log provisioning
kubectl logs -n cattle-system -l app=rancher -f
```

## Ottenere Kubeconfig

```bash
# Una volta che il cluster è Active
kubectl get secret -n fleet-default homelab-k8s-kubeconfig -o jsonpath='{.data.value}' | base64 -d > ~/.kube/homelab-k8s.yaml

# Usare il cluster
export KUBECONFIG=~/.kube/homelab-k8s.yaml
kubectl get nodes
```

## vSphere CSI Integration

Dopo la creazione del cluster, verrà automaticamente deployato il vSphere CSI Driver per:
- Provisioning dinamico di PersistentVolumes
- StorageClass `vsphere-thin` per dischi thin provisioned

## Troubleshooting

### Cluster bloccato in Provisioning

```bash
# Controllare i log del controller
kubectl logs -n cattle-system -l app=rancher --tail=100

# Controllare lo stato delle macchine
kubectl describe machines.cluster.x-k8s.io -n fleet-default
```

### VM non si avviano

Verificare in vSphere:
- Permessi utente rancher.user
- Template VM esistente
- Risorse disponibili (CPU, RAM, storage)
- Network configurata correttamente
