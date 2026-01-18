# GPU con Worker Effimeri

Come gestire la GPU NVIDIA T4 con worker node che vengono ricreati frequentemente.

## Strategia Consigliata: Pool Separato

```
┌─────────────────────────────────────────────────────────────┐
│  Rancher Cluster                                            │
│                                                             │
│  Machine Pool: "workers" (effimeri)                         │
│  ┌─────────┐ ┌─────────┐ ┌─────────┐                       │
│  │ Worker1 │ │ Worker2 │ │ Worker3 │  ← Template standard  │
│  │ (no GPU)│ │ (no GPU)│ │ (no GPU)│                       │
│  └─────────┘ └─────────┘ └─────────┘                       │
│                                                             │
│  Machine Pool: "gpu-workers" (semi-persistente)             │
│  ┌─────────────────────────┐                               │
│  │ GPU-Worker              │  ← Template GPU dedicato      │
│  │ (NVIDIA T4 passthrough) │  ← NON effimero              │
│  │ (driver pre-installato) │                               │
│  └─────────────────────────┘                               │
└─────────────────────────────────────────────────────────────┘
```

## Perché il GPU Worker NON dovrebbe essere effimero

1. **GPU Passthrough = VM specifica**
   - La GPU è legata a una VM specifica su un host specifico
   - Ricreare la VM richiede ri-configurare passthrough

2. **Driver installation = tempo**
   - Installare NVIDIA driver richiede 5-10 minuti
   - Richiede reboot

3. **Template diverso**
   - La VM GPU ha configurazioni HW diverse (RAM reserved, PCIe device)

## Configurazione Rancher

### Step 1: Crea Node Template GPU

In Rancher → Cluster Management → RKE2 Cluster → Node Templates:

**Template: gpu-worker-template**
```yaml
cloudConfig:
  runcmd:
    - /usr/local/bin/gpu-bootstrap.sh
```

Oppure usa `infrastructure/vm-templates/gpu-worker-cloud-init.yaml`

### Step 2: Configura Machine Pool GPU

```yaml
machinePools:
  - name: gpu-workers
    quantity: 1
    etcdRole: false
    controlPlaneRole: false
    workerRole: true

    # Template con GPU
    machineConfigRef:
      kind: VmwarevsphereConfig
      name: gpu-worker-template

    # NON effimero
    unhealthyNodeTimeout: 0s
    drainBeforeDelete: true

    # Labels automatici
    labels:
      nvidia.com/gpu: "present"
      node-role.kubernetes.io/gpu: "true"

    # Taint opzionale (solo workload GPU)
    taints:
      - key: nvidia.com/gpu
        value: "present"
        effect: NoSchedule
```

### Step 3: Machine Pool Workers Standard

```yaml
machinePools:
  - name: workers
    quantity: 3
    workerRole: true

    # Effimeri
    unhealthyNodeTimeout: 5m

    # Template standard (no GPU)
    machineConfigRef:
      kind: VmwarevsphereConfig
      name: standard-worker-template
```

## Automazione Driver (se necessario)

Se devi ricreare il worker GPU, usa il bootstrap script:

```bash
# Nel cloud-config del template vSphere
runcmd:
  - curl -sfL https://raw.githubusercontent.com/.../gpu-worker-rke2-bootstrap.sh | bash
```

Oppure copia `infrastructure/vm-templates/gpu-worker-rke2-bootstrap.sh` nel template.

## Alternative

### Opzione A: GPU Operator (Automatico)

NVIDIA GPU Operator installa tutto automaticamente:

```bash
helm repo add nvidia https://helm.ngc.nvidia.com/nvidia
helm install gpu-operator nvidia/gpu-operator \
  --namespace gpu-operator \
  --create-namespace \
  --set driver.enabled=true \
  --set toolkit.enabled=true
```

**Pro:** Completamente automatico
**Contro:** Più complesso, container driver (non nativo)

### Opzione B: Ansible Provisioner

```yaml
# playbook post-provisioning
- name: Configure GPU Worker
  hosts: gpu_workers
  roles:
    - nvidia-driver
    - nvidia-container-toolkit
```

## Best Practice

1. **GPU Worker semi-persistente**
   - Non includerlo nel pool effimero
   - Ricrealo solo quando necessario

2. **Label automatico**
   - Usa `machinePools.labels` in Rancher
   - Oppure cloud-init script

3. **Monitoraggio GPU**
   - Deploy DCGM Exporter per metriche Prometheus
   - Alert se GPU non disponibile

4. **Backup config**
   - Mantieni template VM GPU aggiornato
   - Documenta configurazione passthrough vSphere

## Scheduling Workload GPU

I pod GPU verranno schedulati solo sul nodo GPU:

```yaml
spec:
  nodeSelector:
    nvidia.com/gpu: "present"
  resources:
    limits:
      nvidia.com/gpu: 1
```

Se usi il taint:
```yaml
spec:
  tolerations:
    - key: nvidia.com/gpu
      operator: Exists
      effect: NoSchedule
```
