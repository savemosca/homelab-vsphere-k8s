# vSphere 8 Environment Setup

This guide covers preparing your vSphere environment for Kubernetes deployment with Cluster API.

## Prerequisites

- vSphere 8.0 or later with vCenter Server
- Administrator credentials or user with sufficient permissions
- Network with DHCP (or static IP pool)
- Datastore with minimum 500GB free space
- ESXi host with minimum 32GB RAM available for K8s cluster

## 1. vCenter Permissions

Create a dedicated service account for Cluster API operations.

### Required vCenter Roles

Create a custom role "k8s-cluster-admin" with these privileges:

**Virtual Machine Permissions:**
- ✅ Inventory → Create new
- ✅ Inventory → Remove
- ✅ Configuration → Change configuration
- ✅ Configuration → Add new disk
- ✅ Configuration → Change resource
- ✅ Interaction → Power on/off
- ✅ Snapshot management → Create snapshot
- ✅ Provisioning → Clone virtual machine
- ✅ Provisioning → Deploy template

**Datastore Permissions:**
- ✅ Datastore → Allocate space
- ✅ Datastore → Browse datastore
- ✅ Datastore → Low-level file operations

**Network Permissions:**
- ✅ Network → Assign network

**Resource Pool Permissions:**
- ✅ All privileges

### Create Service Account

```bash
# Create user in vCenter (via UI or govmomi)
# Username: k8s-capv@vsphere.local
# Grant "k8s-cluster-admin" role at datacenter level
```

## 2. Network Configuration

### Option A: DHCP (Recommended for Homelab)

Configure DHCP server to reserve IP range for K8s nodes:

```
DHCP Pool: 192.168.1.100-192.168.1.150
Gateway: 192.168.1.1
DNS: 192.168.1.53 (Pihole) or 1.1.1.1
Domain: homelab.local
```

### Option B: Static IPs

Create IP pool file for manual assignment:

```yaml
# infrastructure/networking/ip-pool.yaml
apiVersion: ipam.cluster.x-k8s.io/v1alpha1
kind: InClusterIPPool
metadata:
  name: homelab-pool
spec:
  addresses:
    - 192.168.1.100-192.168.1.150
  prefix: 24
  gateway: 192.168.1.1
```

### Port Group Configuration

Ensure your network port group allows:
- ✅ Promiscuous Mode: Reject (not needed for standard CNI)
- ✅ MAC Address Changes: Accept
- ✅ Forged Transmits: Accept

```bash
# Verify via govc CLI
govc host.portgroup.info -json "VM Network" | jq .
```

## 3. Resource Pool Setup

Create dedicated resource pool for Kubernetes cluster:

**Via vCenter UI:**
1. Navigate to Host → Configure → Resource Allocation
2. Right-click → New Resource Pool
3. Settings:
   - Name: `k8s-homelab`
   - CPU Shares: Normal (4000)
   - CPU Reservation: 0 MHz
   - CPU Limit: Unlimited
   - Memory Shares: Normal (40960)
   - Memory Reservation: 0 MB
   - Memory Limit: 40960 MB (40GB)

**Via govc CLI:**

```bash
export GOVC_URL="vcenter.homelab.local"
export GOVC_USERNAME="administrator@vsphere.local"
export GOVC_PASSWORD="your-password"
export GOVC_INSECURE=true

govc pool.create \
  -cpu.limit=-1 \
  -cpu.reservation=0 \
  -cpu.shares=normal \
  -mem.limit=40960 \
  -mem.reservation=0 \
  -mem.shares=normal \
  /Datacenter/host/Cluster/Resources/k8s-homelab
```

## 4. Content Library Setup

Create content library for OS templates (Flatcar, Ubuntu).

### Create Library

```bash
# Via govc
govc library.create -json k8s-images

# Get library ID
export LIBRARY_ID=$(govc library.info -json k8s-images | jq -r .id)
```

### Import Flatcar Container Linux OVA

Download latest stable Flatcar release:

```bash
# Download Flatcar OVA
FLATCAR_VERSION="3975.2.0"
curl -LO https://stable.release.flatcar-linux.net/amd64-usr/${FLATCAR_VERSION}/flatcar_production_vmware_ova.ova

# Import to content library
govc library.import \
  k8s-images \
  flatcar_production_vmware_ova.ova
```

**Manual import via UI:**
1. vCenter → Content Libraries → k8s-images
2. Actions → Import Item
3. Upload `flatcar_production_vmware_ova.ova`
4. Wait for upload completion (~500MB)

### Import Ubuntu 22.04 Template (for Control Plane)

```bash
# Download Ubuntu cloud image
curl -LO https://cloud-images.ubuntu.com/releases/22.04/release/ubuntu-22.04-server-cloudimg-amd64.ova

# Import to content library
govc library.import \
  k8s-images \
  ubuntu-22.04-server-cloudimg-amd64.ova
```

## 5. Datastore Configuration

Verify available space:

```bash
govc datastore.info datastore1
# Ensure minimum 500GB free capacity
```

Create folder structure for cluster VMs:

```bash
govc folder.create /Datacenter/vm/k8s-homelab
```

## 6. vSphere CSI Driver Prerequisites

Enable disk UUID for all Kubernetes VMs (required for CSI):

**Via govc (applied to template):**

```bash
govc vm.change \
  -vm /Datacenter/vm/Templates/flatcar-stable \
  -e disk.enableUUID=TRUE
```

**Via cluster manifest (automatic for CAPV):**

Already included in `infrastructure/workload-cluster/cluster.yaml`:

```yaml
spec:
  template:
    spec:
      diskGiB: 50
      numCPUs: 2
      memoryMiB: 8192
      network:
        devices:
          - networkName: "VM Network"
            dhcp4: true
      cloneMode: linkedClone
      datacenter: "Datacenter"
      datastore: "datastore1"
      folder: "/Datacenter/vm/k8s-homelab"
      resourcePool: "k8s-homelab"
      server: "vcenter.homelab.local"
      template: "/Datacenter/vm/Templates/flatcar-stable"
      thumbprint: "<vcenter-ssl-thumbprint>"
```

## 7. Get vCenter SSL Thumbprint

Required for secure CAPV connection:

```bash
# Method 1: Using govc
govc about.cert -thumbprint -k

# Method 2: Using openssl
echo | openssl s_client -connect vcenter.homelab.local:443 2>/dev/null | \
  openssl x509 -fingerprint -sha256 -noout | \
  cut -d= -f2

# Example output:
# 6E:C4:...:A2:F3 (SHA256 fingerprint)
```

Save this thumbprint for cluster configuration.

## 8. Verify Setup

Run pre-flight checks:

```bash
# Check vCenter connectivity
govc about

# List datastores
govc datastore.info

# List networks
govc network.info

# List resource pools
govc pool.info k8s-homelab

# List content library items
govc library.info k8s-images

# Expected output:
# ✅ vCenter reachable
# ✅ Datastore has >500GB free
# ✅ Resource pool exists with 40GB RAM limit
# ✅ Content library contains Flatcar OVA
```

## 9. DNS Configuration (Optional but Recommended)

Add DNS records for cluster endpoints:

```
# /etc/hosts or DNS server
192.168.1.100   k8s-api.homelab.local           # Control plane API
192.168.1.200   *.homelab.local                 # Wildcard for ingress
192.168.1.53    pihole.homelab.local            # Pihole DNS
192.168.1.201   grafana.homelab.local           # Grafana dashboard
```

## 10. Environment Variables Template

Create `.envrc` file (use with direnv):

```bash
# vSphere credentials
export VSPHERE_SERVER="vcenter.homelab.local"
export VSPHERE_USERNAME="k8s-capv@vsphere.local"
export VSPHERE_PASSWORD="your-secure-password"
export VSPHERE_DATACENTER="Datacenter"
export VSPHERE_DATASTORE="datastore1"
export VSPHERE_NETWORK="VM Network"
export VSPHERE_RESOURCE_POOL="k8s-homelab"
export VSPHERE_FOLDER="/Datacenter/vm/k8s-homelab"
export VSPHERE_TEMPLATE="/Datacenter/vm/Templates/flatcar-stable"
export VSPHERE_THUMBPRINT="6E:C4:...:A2:F3"

# Cluster configuration
export CLUSTER_NAME="homelab-k8s"
export KUBERNETES_VERSION="v1.28.5"
export CONTROL_PLANE_MACHINE_COUNT=1
export WORKER_MACHINE_COUNT=2

# Network settings
export CONTROL_PLANE_ENDPOINT_IP="192.168.1.100"
export POD_CIDR="10.244.0.0/16"
export SERVICE_CIDR="10.96.0.0/12"

# clusterctl settings
export CLUSTERCTL_DISABLE_VERSIONCHECK=true
```

## Troubleshooting

### Issue: "Cannot find template in content library"

**Solution:** Ensure OVA is fully imported and synced:

```bash
govc library.info k8s-images
# Wait for "synced: true" status
```

### Issue: "Insufficient resources"

**Solution:** Verify resource pool limits:

```bash
govc pool.info -json k8s-homelab | jq .config.memoryAllocation
# Increase memory limit if needed
```

### Issue: "Network not found"

**Solution:** List available networks:

```bash
govc network.info -json | jq -r '.[].name'
# Use exact network name from output
```

## Next Steps

Once vSphere environment is ready, proceed to:
- [02-management-cluster.md](02-management-cluster.md) - Deploy K3s management cluster
- [03-workload-cluster.md](03-workload-cluster.md) - Create production K8s cluster

## References

- [vSphere CSI Driver Requirements](https://docs.vmware.com/en/VMware-vSphere-Container-Storage-Plug-in/)
- [CAPV vSphere Permissions](https://github.com/kubernetes-sigs/cluster-api-provider-vsphere/blob/main/docs/permission_and_roles.md)
- [Flatcar on VMware](https://www.flatcar.org/docs/latest/installing/cloud/vmware/)
