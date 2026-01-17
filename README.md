# Homelab vSphere 8 + Kubernetes Infrastructure

Production-grade Kubernetes homelab running on vSphere 8 with ephemeral nodes, autoscaling, and GitOps CI/CD.

## Architecture Overview

- **Infrastructure**: VMware vSphere 8 (single host: 10 cores/128GB RAM)
- **Management**: Rancher v2.11.8 on K3s (srv26.mosca.lan) for centralized cluster management
- **Kubernetes**: Vanilla K8s managed by Cluster API Provider vSphere (CAPV)
- **Node OS**: Flatcar Container Linux (ephemeral, immutable)
- **Networking**: Cilium CNI with eBPF dataplane
- **Storage**: vSphere CSI Driver with dynamic provisioning
- **CI/CD**: GitHub Actions with automated deployments
- **Autoscaling**: Cluster Autoscaler (2-5 worker nodes)

## Repository Structure

```text
homelab-vsphere-k8s/
├── docs/                              # Documentation
│   ├── 00-rancher-upgrade.md          # Rancher upgrade guide (v2.11.0 → v2.11.8)
│   ├── 01-vsphere-setup.md            # vSphere prerequisites and configuration
│   ├── 02-management-cluster-rancher.md # CAPV setup on existing Rancher K3s
│   ├── 03-workload-cluster.md         # Production K8s cluster deployment
│   ├── 04-autoscaling.md              # Cluster Autoscaler configuration
│   ├── 05-cicd-setup.md               # GitHub Actions integration
│   └── 06-rancher-import.md           # Import workload cluster into Rancher
│
├── infrastructure/
│   ├── management-cluster/         # K3s + CAPV controller
│   │   ├── k3s-install.sh
│   │   ├── capv-init.yaml
│   │   └── clusterctl-config.yaml
│   │
│   ├── workload-cluster/           # Main K8s cluster manifests
│   │   ├── cluster.yaml            # Cluster API cluster definition
│   │   ├── control-plane.yaml      # Control plane config
│   │   ├── worker-pool.yaml        # Worker MachineDeployment
│   │   └── autoscaler.yaml         # Cluster Autoscaler
│   │
│   ├── flatcar-ignition/           # Flatcar node configuration
│   │   ├── worker-node.bu          # Butane YAML config
│   │   └── convert.sh              # Butane → Ignition converter
│   │
│   ├── storage/                    # Persistent storage
│   │   ├── vsphere-csi-driver.yaml
│   │   ├── storageclass.yaml
│   │   └── velero-backup.yaml
│   │
│   └── networking/                 # Network infrastructure
│       ├── cilium-values.yaml
│       ├── metallb-config.yaml
│       └── nginx-ingress.yaml
│
├── kubernetes/
│   ├── core/                       # Core cluster services
│   │   ├── cert-manager/
│   │   ├── external-dns/
│   │   └── sealed-secrets/
│   │
│   ├── apps/                       # Homelab applications
│   │   ├── media-stack/            # Radarr, Sonarr, Bazarr, Qbittorrent
│   │   │   ├── namespace.yaml
│   │   │   ├── radarr/
│   │   │   ├── sonarr/
│   │   │   ├── bazarr/
│   │   │   └── qbittorrent/
│   │   │
│   │   └── pihole-cloudflared/     # DNS + Cloudflare tunnel
│   │       ├── pihole-deployment.yaml
│   │       └── cloudflared-deployment.yaml
│   │
│   └── monitoring/                 # Observability stack
│       ├── kube-prometheus-stack/
│       └── grafana-dashboards/
│
├── ci-cd/
│   ├── github-actions/             # CI/CD workflows
│   │   ├── build-push.yaml         # Container build & push
│   │   └── deploy.yaml             # Kubernetes deployment
│   │
│   └── helm-charts/                # Custom Helm charts
│       └── homelab-apps/
│
└── scripts/                        # Automation scripts
    ├── bootstrap.sh                # Full cluster bootstrap
    ├── backup.sh                   # Velero backup automation
    └── destroy.sh                  # Cleanup script
```

## Quick Start

### Prerequisites

- vSphere 8 with vCenter credentials
- Existing Rancher installation (srv26.mosca.lan) or fresh K3s install
- vSphere namespace/resource pool configured
- DHCP or static IP pool for VMs
- ~500GB free datastore space
- GitHub account for CI/CD

### 1. Upgrade Rancher (if existing installation)

```bash
# Backup and upgrade Rancher from v2.11.0 to v2.11.8
# See detailed guide: docs/00-rancher-upgrade.md

ssh administrator@srv26.mosca.lan
# Follow backup and upgrade procedures
```

### 2. Prepare vSphere Environment

```bash
# Follow detailed guide
cat docs/01-vsphere-setup.md

# Upload Flatcar OVA to Content Library
# Configure network and resource pool
# Get vCenter SSL thumbprint
```

### 3. Setup CAPV on Management Cluster (srv26)

```bash
# Configure parameters
cp infrastructure/vsphere-params.env.template ~/.cluster-api/vsphere-params.env
nano ~/.cluster-api/vsphere-params.env  # Edit with your vSphere details

# Install clusterctl and initialize CAPV
# Follow: docs/02-management-cluster-rancher.md
clusterctl init --infrastructure vsphere
```

### 4. Create Workload Cluster

```bash
# Load vSphere parameters
source ~/.cluster-api/vsphere-params.env

# Generate cluster manifest
./scripts/generate-cluster-manifest.sh

# Deploy cluster
export KUBECONFIG=~/.kube/srv26-config
kubectl apply -f generated/cluster-full.yaml

# Wait for cluster ready
watch kubectl get clusters,machines,vspheremachines
```

### 5. Import Cluster into Rancher

```bash
# Get workload cluster kubeconfig
clusterctl get kubeconfig homelab-k8s > ~/.kube/homelab-k8s-config

# Import via Rancher UI
# Follow: docs/06-rancher-import.md
# Rancher URL: https://rancher.savemosca.com
```

### 6. Install Core Components

```bash
# Switch to workload cluster
export KUBECONFIG=~/.kube/homelab-k8s-config

# Install Cilium CNI
helm repo add cilium https://helm.cilium.io/
helm install cilium cilium/cilium --version 1.14.5 \
  -f infrastructure/networking/cilium-values.yaml

# Install vSphere CSI Driver
kubectl apply -f infrastructure/storage/vsphere-csi-driver.yaml

# Install MetalLB
kubectl apply -f infrastructure/networking/metallb-config.yaml

# Install NGINX Ingress
kubectl apply -f infrastructure/networking/nginx-ingress.yaml
```

### 7. Deploy Applications

```bash
# Media stack
kubectl apply -k kubernetes/apps/media-stack/

# Pihole + Cloudflared
kubectl apply -k kubernetes/apps/pihole-cloudflared/
```

### 8. Setup CI/CD

Follow [docs/05-cicd-setup.md](docs/05-cicd-setup.md) to configure GitHub Actions.

## Resource Allocation

| Component | vCPU | RAM | Storage | Purpose |
|-----------|------|-----|---------|---------|
| srv26 (Management + Rancher) | 2+ | 4-6GB | 50GB | K3s + Rancher + CAPV controllers |
| Control Plane | 2 | 8GB | 50GB | K8s control plane (etcd, API server) |
| Worker 1 | 4 | 16GB | 100GB | Primary workloads |
| Worker 2 | 4 | 16GB | 100GB | Workload HA |
| **Total** | **12-14** | **44-54GB** | **300-350GB** | **~35-40% host capacity** |

## Autoscaling Configuration

- **Min workers**: 2 nodes
- **Max workers**: 4-5 nodes (limited by host resources)
- **Scale-up trigger**: Pending pods for >30s
- **Scale-down delay**: 10 minutes idle
- **VM startup time**: ~2-3 minutes (Flatcar + K8s join)

## Architecture Diagram

```text
┌──────────────────────────────────────────────────────────┐
│           srv26.mosca.lan (Management Cluster)           │
│                                                          │
│  ┌───────────────┐         ┌──────────────────────┐    │
│  │ Rancher v2.11 │         │  CAPV Controllers    │    │
│  │ • Web UI      │         │  • cluster-api       │    │
│  │ • Multi-mgmt  │◄────────┤  • capv-controller   │────┼────┐
│  │ • Monitoring  │         │  • kubeadm-bootstrap │    │    │
│  └───────────────┘         └──────────────────────┘    │    │
│                    K3s v1.32.3                          │    │
└──────────────────────────────────────────────────────────┘    │
                                                                │
        Manages Infrastructure          Imports for Management  │
                │                                               │
                ▼                                               │
┌────────────────────────────────────────────────────┐         │
│       Workload Cluster (vSphere VMs)               │         │
│  ┌──────────────┐  ┌────────────────────────────┐ │         │
│  │ Control Plane│  │  Worker Nodes (2-5)        │ │◄────────┘
│  │ • etcd       │  │  • Flatcar Linux           │ │
│  │ • API Server │  │  • Auto-scaling (CAPV)     │ │
│  │ • Scheduler  │  │  • Apps running here       │ │
│  └──────────────┘  └────────────────────────────┘ │
│              Kubernetes v1.32.3                    │
└────────────────────────────────────────────────────┘
```

## CI/CD Pipeline

```text
┌─────────────┐     ┌──────────────┐     ┌─────────────┐
│  Git Push   │────▶│GitHub Actions│────▶│   Deploy    │
│             │     │              │     │             │
│ • Code      │     │ • Build img  │     │ • kubectl   │
│ • Manifests │     │ • Push GHCR  │     │ • Helm      │
└─────────────┘     └──────────────┘     └─────────────┘
```

See [ci-cd/github-actions/](ci-cd/github-actions/) for workflow definitions.

## Monitoring

Access monitoring dashboards:
- **Rancher UI**: https://rancher.savemosca.com (cluster overview, resources)
- **Grafana**: Deployed via Rancher Monitoring (cluster metrics, node stats, application performance)
- **Prometheus**: Metrics collection and alerting
- **Alerts**: Configured via Rancher for critical events

## Backup Strategy

- **Velero**: Automated PV backups to NFS/S3
- **Etcd snapshots**: Daily control plane backups
- **GitOps**: All configs version-controlled in this repo

## Cost Breakdown

- **vSphere licensing**: Already owned
- **Hardware**: Existing homelab server
- **GitHub Actions**: Free (2000 min/month for private repos)
- **Total monthly cost**: $0

## Maintenance

- **OS updates**: Flatcar auto-updates (stable channel)
- **K8s upgrades**: Managed via CAPV cluster updates
- **Application updates**: Automated via Renovate bot
- **Time commitment**: ~30 min/month

## Troubleshooting

Common issues and solutions in [docs/troubleshooting.md](docs/troubleshooting.md).

## Contributing

This is a personal homelab project, but feel free to:
- Open issues for questions
- Submit PRs for improvements
- Fork for your own homelab

## License

MIT License - see [LICENSE](LICENSE)

## Acknowledgments

- [Cluster API Provider vSphere](https://github.com/kubernetes-sigs/cluster-api-provider-vsphere)
- [Flatcar Container Linux](https://www.flatcar.org/)
- [Cilium CNI](https://cilium.io/)
- Homelab community at r/homelab

---

**Status**: 🚧 In Progress | **Last Updated**: 2026-01-17
