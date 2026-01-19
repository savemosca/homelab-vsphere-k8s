# Homelab vSphere 8 + Kubernetes Infrastructure

Production-grade Kubernetes homelab running on vSphere 8 with Rancher, ephemeral workers, and GitOps.

## Architecture Overview

- **Infrastructure**: VMware vSphere 8 (2 ESXi hosts in cluster)
- **Management**: Rancher v2.13.1 on K3s (srv26.mosca.lan)
- **Kubernetes**: RKE2 v1.31.4 provisioned by Rancher
- **Node OS**:
  - Flatcar Container Linux (standard workers - ephemeral)
  - Ubuntu 24.04 LTS (GPU workers - semi-persistent)
- **Networking**:
  - Cilium CNI with Hubble observability
  - MetalLB for LoadBalancer services
  - 3 dedicated VLANs (management, workload, services)
- **Storage**: vSphere CSI Driver with dynamic provisioning
- **Secrets**: Sealed Secrets for GitOps-safe secret management
- **GPU**: NVIDIA T4 with driver 550 + Container Toolkit

## Network Architecture

| VLAN | Name | Subnet | Purpose |
|------|------|--------|---------|
| 35 | net-k8s-management | 192.168.11.128/26 | Control plane, Rancher |
| 36 | net-k8s-workload | 192.168.13.0/24 | Worker nodes (DHCP) |
| 37 | net-k8s-services | 192.168.14.0/25 | MetalLB LoadBalancer IPs |

Workers have dual-NIC configuration (ens160 on VLAN 36, ens192 on VLAN 37).

## Repository Structure

```text
homelab-vsphere-k8s/
├── docs/                              # Documentation
│   ├── 00-rancher-upgrade.md          # Rancher upgrade guide
│   ├── 01-vsphere-setup.md            # vSphere prerequisites
│   ├── 02-management-cluster-rancher.md
│   ├── 03-workload-cluster.md
│   └── ...
│
├── infrastructure/
│   ├── rancher-cluster/               # RKE2 cluster definition
│   │   ├── cluster.yaml               # Cluster CRD for Rancher
│   │   ├── vsphere-machine-config.yaml # VM configs per node type
│   │   └── cloud-credential.yaml.template
│   │
│   ├── sealed-secrets/                # Sealed Secrets controller
│   │   └── kustomization.yaml
│   │
│   ├── metallb/                       # MetalLB L2 configuration
│   │   └── metallb-config.yaml
│   │
│   ├── vsphere-csi/                   # vSphere CSI driver
│   │   └── ...
│   │
│   ├── gpu-worker/                    # GPU node configuration
│   │   ├── cloud-init-gpu.yaml        # Ubuntu cloud-init with NVIDIA
│   │   └── nvidia-device-plugin.yaml
│   │
│   └── flatcar-ignition/              # Flatcar node config
│       └── worker-node.bu
│
├── kubernetes/
│   ├── core/                          # Core cluster services
│   │   ├── cert-manager/
│   │   ├── nginx-ingress/
│   │   └── sealed-secrets/
│   │
│   └── apps/                          # Homelab applications
│       └── media-stack/               # Radarr, Sonarr, etc.
│
├── scripts/
│   ├── import-vm-templates.ps1        # PowerCLI template import
│   ├── import-vm-templates.sh         # govc template import
│   └── deploy-cluster.sh
│
└── ci-cd/
    └── github-actions/
```

## Quick Start

### Prerequisites

- vSphere 8 with vCenter
- Rancher v2.13+ installed
- Content Libraries with VM templates:
  - `flatcar-stable-4459.2.2` (Flatcar Stable)
  - `ubuntu-24.04-lts-cloudimg` (Ubuntu Server LTS)
- Network configured (VLANs 35, 36, 37)

### 1. Import VM Templates

```bash
# Using PowerCLI (macOS/Windows)
./scripts/import-vm-templates.ps1

# Or using govc (Linux/macOS)
./scripts/import-vm-templates.sh
```

### 2. Create Cloud Credential in Rancher

```bash
# Via Rancher API
curl -sk -X POST "https://rancher.savemosca.com/v3/cloudcredentials" \
  -H "Authorization: Bearer $RANCHER_TOKEN" \
  -H "Content-Type: application/json" \
  -d '{
    "name": "vsphere-homelab",
    "vmwarevspherecredentialConfig": {
      "vcenter": "srv02.mosca.lan",
      "vcenterPort": "443",
      "username": "rancher.user@vsphere.local",
      "password": "YOUR_PASSWORD"
    }
  }'
```

### 3. Deploy RKE2 Cluster

```bash
# Get Rancher kubeconfig
export KUBECONFIG=~/.kube/rancher-local.yaml

# Apply cluster and machine configs
kubectl apply -f infrastructure/rancher-cluster/vsphere-machine-config.yaml
kubectl apply -f infrastructure/rancher-cluster/cluster.yaml

# Watch provisioning
watch kubectl get clusters,machines -n fleet-default
```

### 4. Install Infrastructure Components

```bash
# Switch to workload cluster
export KUBECONFIG=~/.kube/homelab-k8s.yaml

# Install Sealed Secrets
kubectl apply -k infrastructure/sealed-secrets/

# Install MetalLB
kubectl apply -f infrastructure/metallb/metallb-config.yaml

# Install NGINX Ingress
kubectl apply -f kubernetes/core/nginx-ingress/
```

### 5. Seal Your Secrets

```bash
# Install kubeseal CLI
brew install kubeseal

# Create a secret
kubectl create secret generic my-secret \
  --from-literal=password=supersecret \
  --dry-run=client -o yaml > secret.yaml

# Seal it (can be committed to git)
kubeseal --controller-namespace kube-system \
  --controller-name sealed-secrets-controller \
  < secret.yaml > sealed-secret.yaml

# Apply sealed secret
kubectl apply -f sealed-secret.yaml
```

## Node Pools

| Pool | OS | Quantity | Purpose | Ephemeral |
|------|-----|----------|---------|-----------|
| control-plane | Ubuntu 24.04 | 1 | K8s control plane + etcd | No |
| workers | Flatcar 4459.2.2 | 2 | Standard workloads | Yes (5m timeout) |
| gpu-workers | Ubuntu 24.04 | 0* | GPU workloads (NVIDIA T4) | No |

*GPU workers added after vSphere GPU passthrough configured.

## Resource Allocation

| Component | vCPU | RAM | Storage |
|-----------|------|-----|---------|
| Control Plane | 2 | 4GB | 40GB |
| Worker (x2) | 4 | 8GB | 40GB |
| GPU Worker | 8 | 32GB | 100GB |

## Content Libraries

| Library | Datastore | Location |
|---------|-----------|----------|
| cnt-lbr-k8s-esxi01 | datastore06-local-jbod | esxi01 |
| cnt-lbr-k8s-esxi02 | datastore01-esxi02-local | esxi02 |

Both contain: `flatcar-stable-4459.2.2`, `ubuntu-24.04-lts-cloudimg`

## Sealed Secrets

This project uses [Sealed Secrets](https://github.com/bitnami-labs/sealed-secrets) for GitOps-safe secret management:

- Secrets are encrypted with a cluster-specific key
- Encrypted secrets (SealedSecrets) can be safely committed to Git
- Only the cluster can decrypt them

```bash
# Backup the sealing key (IMPORTANT - store securely!)
kubectl get secret -n kube-system -l sealedsecrets.bitnami.com/sealed-secrets-key -o yaml > sealed-secrets-key-backup.yaml
```

## Monitoring

- **Rancher UI**: https://rancher.savemosca.com
- **Hubble UI**: Cilium network observability (via port-forward)
- **Grafana**: Via Rancher Monitoring stack

## Maintenance

- **Flatcar updates**: Automatic (Stable channel)
- **Ubuntu updates**: Via cloud-init on boot
- **K8s upgrades**: Managed via Rancher UI or cluster.yaml
- **Secret rotation**: Re-seal and apply new SealedSecrets

## Troubleshooting

```bash
# Check cluster status
kubectl get clusters -n fleet-default

# Check machine provisioning
kubectl get machines -n fleet-default

# Check Rancher logs
kubectl logs -n cattle-system -l app=rancher

# Check Sealed Secrets controller
kubectl logs -n kube-system -l app.kubernetes.io/name=sealed-secrets
```

## License

MIT License

---

**Status**: In Progress | **Last Updated**: 2026-01-19
