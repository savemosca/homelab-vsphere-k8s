# Flatcar Linux per Worker Node RKE2

Configurazione per usare Flatcar Container Linux come OS per i worker node effimeri (non GPU).

## Perché Flatcar?

| Caratteristica | Beneficio |
|----------------|-----------|
| **Immutable OS** | Nessun drift di configurazione |
| **Auto-update** | Aggiornamenti atomici con rollback |
| **Minimal footprint** | ~300MB RAM overhead |
| **Container-optimized** | Containerd pre-configurato |
| **Ignition config** | Provisioning dichiarativo |

## Architettura Worker Pools

```
┌─────────────────────────────────────────────────────────────────┐
│  Cluster RKE2 su vSphere                                        │
│                                                                 │
│  Pool: "workers" (effimeri)                                     │
│  ┌─────────┐ ┌─────────┐ ┌─────────┐                           │
│  │ Worker1 │ │ Worker2 │ │ Worker3 │  ← Flatcar Linux          │
│  │ (no GPU)│ │ (no GPU)│ │ (no GPU)│  ← Immutable, auto-update │
│  └─────────┘ └─────────┘ └─────────┘                           │
│                                                                 │
│  Pool: "gpu-workers" (semi-persistente)                         │
│  ┌─────────────────────────┐                                   │
│  │ GPU-Worker              │  ← Ubuntu Server 24.04 LTS        │
│  │ (NVIDIA T4 passthrough) │  ← Driver NVIDIA 550              │
│  └─────────────────────────┘                                   │
└─────────────────────────────────────────────────────────────────┘
```

## Setup vSphere

### 1. Download Flatcar OVA

```bash
# Stable channel (raccomandato)
curl -LO https://stable.release.flatcar-linux.net/amd64-usr/current/flatcar_production_vmware_ova.ova

# Oppure Beta/Alpha per testing
curl -LO https://beta.release.flatcar-linux.net/amd64-usr/current/flatcar_production_vmware_ova.ova
```

### 2. Import OVA in vSphere

1. vSphere Client → Datacenter → Deploy OVF Template
2. Seleziona `flatcar_production_vmware_ova.ova`
3. Nome: `flatcar-template`
4. Seleziona datastore e network
5. **Non avviare la VM**
6. Convert to Template

### 3. Genera Ignition Config

```bash
cd infrastructure/vm-templates

# Ottieni il token dal control plane
ssh user@rke2-cp.mosca.lan "sudo cat /var/lib/rancher/rke2/server/node-token"

# Genera Ignition
./generate-ignition.sh \
  "https://rke2-cp.mosca.lan:9345" \
  "K10abc123..." \
  "ssh-rsa AAAA... user@workstation"
```

### 4. Crea VM da Template

**Opzione A: vSphere UI**

1. Clone from Template → `flatcar-template`
2. Customize hardware:
   - CPU: 4+ vCPU
   - RAM: 8+ GB
   - Disk: 50+ GB
3. VM Options → Advanced → Configuration Parameters:
   ```
   guestinfo.ignition.config.data = <base64 del file .ign>
   guestinfo.ignition.config.data.encoding = base64
   ```

**Opzione B: govc CLI**

```bash
# Clone template
govc vm.clone -vm flatcar-template -on=false flatcar-worker-1

# Configura risorse
govc vm.change -vm flatcar-worker-1 \
  -c 4 \
  -m 8192

# Aggiungi Ignition config
govc vm.change -vm flatcar-worker-1 \
  -e "guestinfo.ignition.config.data=$(base64 -w0 flatcar-worker.ign)" \
  -e "guestinfo.ignition.config.data.encoding=base64"

# Avvia
govc vm.power -on flatcar-worker-1
```

**Opzione C: Terraform**

```hcl
resource "vsphere_virtual_machine" "flatcar_worker" {
  count            = 3
  name             = "flatcar-worker-${count.index + 1}"
  resource_pool_id = data.vsphere_compute_cluster.cluster.resource_pool_id
  datastore_id     = data.vsphere_datastore.datastore.id

  num_cpus = 4
  memory   = 8192

  clone {
    template_uuid = data.vsphere_virtual_machine.flatcar_template.id
  }

  disk {
    label            = "disk0"
    size             = 50
    thin_provisioned = true
  }

  network_interface {
    network_id = data.vsphere_network.network.id
  }

  extra_config = {
    "guestinfo.ignition.config.data"          = base64encode(file("flatcar-worker.ign"))
    "guestinfo.ignition.config.data.encoding" = "base64"
  }
}
```

## Configurazione Rancher

Se gestisci il cluster tramite Rancher, configura il Machine Pool:

```yaml
machinePools:
  - name: workers
    quantity: 3
    etcdRole: false
    controlPlaneRole: false
    workerRole: true

    # Template Flatcar
    machineConfigRef:
      kind: VmwarevsphereConfig
      name: flatcar-worker-template

    # Effimeri
    unhealthyNodeTimeout: 5m
    drainBeforeDelete: true

    # Labels
    labels:
      node.kubernetes.io/pool: workers
      kubernetes.io/os: flatcar
```

## Aggiornamenti Automatici

Flatcar supporta aggiornamenti automatici atomici. Per configurarli:

### Disabilitare (raccomandato per worker effimeri)

Se i worker vengono ricreati frequentemente, disabilita gli auto-update:

```yaml
# In Ignition config
systemd:
  units:
    - name: update-engine.service
      mask: true
    - name: locksmithd.service
      mask: true
```

### Abilitare con controllo

Per cluster più stabili:

```yaml
storage:
  files:
    - path: /etc/flatcar/update.conf
      mode: 0644
      contents:
        inline: |
          GROUP=stable
          REBOOT_STRATEGY=etcd-lock
```

## Troubleshooting

### Verificare Ignition

```bash
# Sulla VM Flatcar
sudo journalctl -u ignition-files -u ignition-setup
```

### Verificare RKE2 Agent

```bash
sudo systemctl status rke2-agent
sudo journalctl -u rke2-agent -f
```

### Verificare join al cluster

```bash
# Dal control plane
kubectl get nodes
```

### Errori comuni

**VM non si avvia:**
- Verifica che guestinfo.ignition sia configurato correttamente
- Controlla che il base64 sia valido

**RKE2 non si connette:**
- Verifica URL server e token
- Controlla firewall (porte 9345, 6443)
- Verifica DNS resolution

**Node NotReady:**
- Controlla CNI (Cilium deve essere deployato)
- Verifica kubelet: `sudo journalctl -u rke2-agent`

## File nel Repository

```
infrastructure/vm-templates/
├── flatcar-worker-ignition.yaml   # Butane config (YAML)
├── flatcar-worker.ign.template    # Ignition JSON template
├── generate-ignition.sh           # Script generazione
├── gpu-worker-cloud-init.yaml     # Cloud-init Ubuntu GPU
└── gpu-worker-rke2-bootstrap.sh   # Bootstrap NVIDIA
```
