# Management Cluster Setup (K3s + CAPV)

The management cluster runs Cluster API controllers that manage the lifecycle of your workload Kubernetes cluster.

## Why K3s for Management?

- **Lightweight**: ~500MB RAM footprint vs 2-4GB for full K8s
- **Single binary**: Easy to install and upgrade
- **Built-in storage**: sqlite instead of etcd for simple use case
- **Perfect for CAPV**: Only needs to run controller pods

## Architecture

```
┌─────────────────────────────────────┐
│   Management Cluster (K3s)          │
│                                     │
│  ┌──────────────────────────────┐  │
│  │  Cluster API Controllers     │  │
│  │  • cluster-api-controller    │  │
│  │  • capv-controller           │  │──────┐
│  │  • kubeadm-bootstrap         │  │      │
│  │  • kubeadm-control-plane     │  │      │
│  └──────────────────────────────┘  │      │
│                                     │      │
└─────────────────────────────────────┘      │
                                             │ Manages
                                             ▼
                          ┌───────────────────────────────┐
                          │  Workload Cluster (Full K8s)  │
                          │  • 1 Control Plane Node       │
                          │  • 2-5 Worker Nodes           │
                          │  • Your applications run here │
                          └───────────────────────────────┘
```

## 1. Deploy K3s VM on vSphere

### Create Ubuntu VM for K3s

**Specs:**
- OS: Ubuntu 22.04 LTS Server
- vCPU: 2 cores
- RAM: 4GB
- Disk: 50GB (thin provisioned)
- Network: VM Network (DHCP or static IP)

**Via vCenter UI:**
1. Deploy from Ubuntu template in content library
2. Power on and get IP address from vCenter console
3. SSH into VM: `ssh ubuntu@<management-vm-ip>`

**Via govc:**

```bash
# Clone from template
govc vm.clone \
  -vm /Datacenter/vm/Templates/ubuntu-22.04 \
  -on=true \
  -ds=datastore1 \
  -pool=k8s-homelab \
  -folder=/Datacenter/vm/k8s-homelab \
  k3s-management

# Wait for VM to boot
govc vm.ip k3s-management

# Get IP and SSH
MGMT_IP=$(govc vm.ip k3s-management)
ssh ubuntu@${MGMT_IP}
```

## 2. Install K3s

SSH into the management VM and run:

```bash
# Install K3s (single-node, no workload scheduling)
curl -sfL https://get.k3s.io | sh -s - server \
  --disable traefik \
  --disable servicelb \
  --disable local-storage \
  --write-kubeconfig-mode 644 \
  --node-taint CriticalAddonsOnly=true:NoExecute

# Wait for K3s to be ready
sudo k3s kubectl wait --for=condition=ready node --all --timeout=300s

# Verify
sudo k3s kubectl get nodes
# NAME             STATUS   ROLES                  AGE   VERSION
# k3s-management   Ready    control-plane,master   1m    v1.28.5+k3s1
```

## 3. Copy Kubeconfig to Local Machine

From your local workstation:

```bash
# Copy kubeconfig from management VM
scp ubuntu@<management-vm-ip>:/etc/rancher/k3s/k3s.yaml ~/.kube/management-config

# Update server IP in kubeconfig
sed -i '' "s/127.0.0.1/<management-vm-ip>/g" ~/.kube/management-config

# Test connection
export KUBECONFIG=~/.kube/management-config
kubectl get nodes
```

## 4. Install clusterctl

Install Cluster API CLI on your local machine:

```bash
# macOS
brew install clusterctl

# Linux
curl -L https://github.com/kubernetes-sigs/cluster-api/releases/download/v1.6.1/clusterctl-darwin-amd64 -o clusterctl
chmod +x clusterctl
sudo mv clusterctl /usr/local/bin/

# Verify
clusterctl version
# clusterctl version: &version.Info{Major:"1", Minor:"6", GitVersion:"v1.6.1"}
```

## 5. Create clusterctl Configuration

Create `~/.cluster-api/clusterctl.yaml`:

```yaml
# vSphere provider credentials
providers:
  - name: vsphere
    url: https://github.com/kubernetes-sigs/cluster-api-provider-vsphere/releases/v1.10.0/infrastructure-components.yaml
    type: InfrastructureProvider

# Variables for template expansion
VSPHERE_USERNAME: "k8s-capv@vsphere.local"
VSPHERE_PASSWORD: "your-password-here"
VSPHERE_SERVER: "vcenter.homelab.local"
VSPHERE_DATACENTER: "Datacenter"
VSPHERE_DATASTORE: "datastore1"
VSPHERE_NETWORK: "VM Network"
VSPHERE_RESOURCE_POOL: "k8s-homelab"
VSPHERE_FOLDER: "/Datacenter/vm/k8s-homelab"
VSPHERE_TEMPLATE: "/Datacenter/vm/Templates/flatcar-stable"
VSPHERE_THUMBPRINT: "6E:C4:...:A2:F3"  # From step 7 of vSphere setup
VSPHERE_SSH_AUTHORIZED_KEY: "ssh-rsa AAAA... your-public-key"

# Cluster defaults
CLUSTER_CIDR: "10.244.0.0/16"
SERVICE_CIDR: "10.96.0.0/12"
KUBERNETES_VERSION: "v1.28.5"

# Image repository override (optional, for air-gapped)
# EXP_CLUSTER_RESOURCE_SET: "true"
```

**Security note:** Store sensitive values in environment variables instead:

```bash
export VSPHERE_PASSWORD="your-password"
export VSPHERE_USERNAME="k8s-capv@vsphere.local"
# Remove VSPHERE_PASSWORD from clusterctl.yaml
```

## 6. Initialize Cluster API Providers

```bash
# Initialize CAPV on management cluster
export KUBECONFIG=~/.kube/management-config

clusterctl init --infrastructure vsphere:v1.10.0

# This installs:
# ✅ cluster-api controller
# ✅ cluster-api-provider-vsphere controller
# ✅ kubeadm bootstrap provider
# ✅ kubeadm control plane provider
```

**Expected output:**

```
Fetching providers
Installing cert-manager Version="v1.13.2"
Waiting for cert-manager to be available...
Installing Provider="cluster-api" Version="v1.6.1" TargetNamespace="capi-system"
Installing Provider="bootstrap-kubeadm" Version="v1.6.1" TargetNamespace="capi-kubeadm-bootstrap-system"
Installing Provider="control-plane-kubeadm" Version="v1.6.1" TargetNamespace="capi-kubeadm-control-plane-system"
Installing Provider="infrastructure-vsphere" Version="v1.10.0" TargetNamespace="capv-system"

Your management cluster has been initialized successfully!
```

## 7. Verify CAPV Installation

```bash
# Check all controllers are running
kubectl get pods -A | grep -E 'capi|capv'

# Expected output:
# capi-kubeadm-bootstrap-system      capi-kubeadm-bootstrap-controller-manager-xxx      1/1  Running
# capi-kubeadm-control-plane-system  capi-kubeadm-control-plane-controller-manager-xxx  1/1  Running
# capi-system                        capi-controller-manager-xxx                         1/1  Running
# capv-system                        capv-controller-manager-xxx                         1/1  Running
# cert-manager                       cert-manager-xxx                                    1/1  Running
# cert-manager                       cert-manager-cainjector-xxx                         1/1  Running
# cert-manager                       cert-manager-webhook-xxx                            1/1  Running

# Check CRDs installed
kubectl get crd | grep cluster.x-k8s.io
# Should show ~30 CRDs including:
# clusters.cluster.x-k8s.io
# machinedeployments.cluster.x-k8s.io
# vsphereclusters.infrastructure.cluster.x-k8s.io
# vspheremachines.infrastructure.cluster.x-k8s.io
```

## 8. Create vSphere Credentials Secret

CAPV needs vCenter credentials to provision VMs:

```bash
# Create cloud-provider credentials secret
kubectl create secret generic vsphere-creds \
  --from-literal=username="${VSPHERE_USERNAME}" \
  --from-literal=password="${VSPHERE_PASSWORD}" \
  -n capv-system

# Verify secret
kubectl get secret vsphere-creds -n capv-system
```

## 9. Test CAPV with Sample Cluster (Optional)

Generate a test cluster manifest:

```bash
clusterctl generate cluster test-cluster \
  --infrastructure vsphere \
  --kubernetes-version v1.28.5 \
  --control-plane-machine-count 1 \
  --worker-machine-count 1 \
  > test-cluster.yaml

# Review manifest
cat test-cluster.yaml

# DON'T apply yet - this is just for validation
# We'll create the real cluster in the next step
```

## 10. Management Cluster Backup

Backup K3s configuration for disaster recovery:

```bash
# On management VM
sudo tar -czf k3s-backup-$(date +%Y%m%d).tar.gz \
  /etc/rancher/k3s \
  /var/lib/rancher/k3s

# Copy to safe location
scp ubuntu@<management-vm-ip>:~/k3s-backup-*.tar.gz ~/backups/
```

**Automated backup script** (save as `/usr/local/bin/backup-k3s.sh`):

```bash
#!/bin/bash
BACKUP_DIR="/var/backups/k3s"
RETENTION_DAYS=7

mkdir -p ${BACKUP_DIR}

# Backup K3s state
tar -czf ${BACKUP_DIR}/k3s-$(date +%Y%m%d-%H%M).tar.gz \
  /etc/rancher/k3s \
  /var/lib/rancher/k3s/server/db

# Cleanup old backups
find ${BACKUP_DIR} -name "k3s-*.tar.gz" -mtime +${RETENTION_DAYS} -delete

# Backup to NAS (optional)
# rsync -av ${BACKUP_DIR}/ nas.homelab.local:/backups/k3s/
```

**Create cron job:**

```bash
sudo crontab -e
# Add:
0 2 * * * /usr/local/bin/backup-k3s.sh
```

## 11. Resource Usage Monitoring

Check management cluster resource usage:

```bash
# Node resources
kubectl top node

# Pod resources
kubectl top pods -A

# Expected usage:
# CPU: ~200-500m (0.2-0.5 cores)
# Memory: ~1.5-2GB
# Storage: ~5GB
```

## Troubleshooting

### Issue: "Connection refused to management cluster"

**Solution:** Check K3s service status:

```bash
ssh ubuntu@<management-vm-ip>
sudo systemctl status k3s
sudo journalctl -u k3s -f
```

### Issue: "clusterctl init fails with timeout"

**Solution:** Check internet connectivity from management VM:

```bash
# Test outbound HTTPS
curl -I https://github.com

# Check DNS resolution
nslookup github.com

# Verify K3s can pull images
sudo k3s crictl images
```

### Issue: "CAPV controller crash loop"

**Solution:** Check vSphere credentials:

```bash
kubectl logs -n capv-system deployment/capv-controller-manager

# Recreate secret with correct credentials
kubectl delete secret vsphere-creds -n capv-system
kubectl create secret generic vsphere-creds \
  --from-literal=username="${VSPHERE_USERNAME}" \
  --from-literal=password="${VSPHERE_PASSWORD}" \
  -n capv-system

# Restart controller
kubectl rollout restart deployment capv-controller-manager -n capv-system
```

## Upgrading Management Cluster

### K3s Upgrade

```bash
# SSH to management VM
ssh ubuntu@<management-vm-ip>

# Upgrade K3s
curl -sfL https://get.k3s.io | sh -

# Verify new version
sudo k3s kubectl version
```

### CAPV Upgrade

```bash
# From local machine
export KUBECONFIG=~/.kube/management-config

# Upgrade to latest CAPV version
clusterctl upgrade apply --infrastructure vsphere:v1.11.0

# Verify
clusterctl upgrade plan
```

## Next Steps

Management cluster is now ready! Proceed to:
- [03-workload-cluster.md](03-workload-cluster.md) - Create production Kubernetes cluster

## References

- [K3s Documentation](https://docs.k3s.io/)
- [Cluster API Quick Start](https://cluster-api.sigs.k8s.io/user/quick-start.html)
- [CAPV Provider Documentation](https://github.com/kubernetes-sigs/cluster-api-provider-vsphere/tree/main/docs)
