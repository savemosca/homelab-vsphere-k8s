# MetalLB - LoadBalancer per Bare Metal

MetalLB fornisce implementazione LoadBalancer per cluster Kubernetes on-premise.

## Architettura di Rete

```text
┌─────────────────────────────────────────────────────────────────┐
│  Rete K8s                                                       │
│                                                                 │
│  VLAN 35 - net-k8s-management (192.168.11.128/26)              │
│    └── Control Plane, Rancher (srv26)                           │
│                                                                 │
│  VLAN 36 - net-k8s-workload (192.168.13.0/24)                  │
│    └── Worker nodes NIC1 (ens160)                               │
│    └── Pod networking, node-to-node traffic                     │
│                                                                 │
│  VLAN 37 - net-k8s-services (192.168.14.0/25)                  │
│    └── Worker nodes NIC2 (ens192)                               │
│    └── MetalLB LoadBalancer IPs                                 │
│    └── Ingress Controller                                       │
└─────────────────────────────────────────────────────────────────┘

Worker Node (Dual NIC):
┌─────────────────────────────────────┐
│  Ubuntu 24.04                       │
│  ├── ens160 → VLAN 36 (workload)    │
│  └── ens192 → VLAN 37 (services)    │
└─────────────────────────────────────┘
```

## IP Pool Configuration

| Pool | Range | Uso |
|------|-------|-----|
| homelab-pool | 192.168.14.10-100 | Auto-assign |
| homelab-reserved | 192.168.14.101-120 | Manual |

### IP Suggeriti

| IP | Servizio |
|----|----------|
| 192.168.14.10 | nginx-ingress |
| 192.168.14.101 | plex (accesso diretto) |

## Installazione

### 1. Installa MetalLB

```bash
kubectl apply -f https://raw.githubusercontent.com/metallb/metallb/v0.14.9/config/manifests/metallb-native.yaml
```

### 2. Attendi che i pod siano pronti

```bash
kubectl wait --namespace metallb-system \
  --for=condition=ready pod \
  --selector=app=metallb \
  --timeout=90s
```

### 3. Applica la configurazione

```bash
kubectl apply -f metallb-config.yaml
```

## Utilizzo

### LoadBalancer automatico

```yaml
apiVersion: v1
kind: Service
metadata:
  name: my-service
spec:
  type: LoadBalancer
  # IP assegnato automaticamente dal pool homelab-pool
```

### IP specifico

```yaml
apiVersion: v1
kind: Service
metadata:
  name: plex-lb
  annotations:
    metallb.universe.tf/address-pool: homelab-reserved
spec:
  type: LoadBalancer
  loadBalancerIP: 192.168.14.101
```

## Verifica

```bash
# Status MetalLB
kubectl get pods -n metallb-system

# IP pools
kubectl get ipaddresspools -n metallb-system

# Services con LoadBalancer IP
kubectl get svc -A | grep LoadBalancer
```

## Firewall Rules (VLAN 37)

Per accesso esterno ai services:

| Src | Dst | Port | Descrizione |
|-----|-----|------|-------------|
| LAN | 192.168.14.0/25 | 80,443 | HTTP/HTTPS Ingress |
| LAN | 192.168.14.101 | 32400 | Plex |
