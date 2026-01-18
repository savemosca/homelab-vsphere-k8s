# NVIDIA T4 GPU Passthrough per Kubernetes su vSphere

Configurazione per passare una GPU NVIDIA T4 a un worker node Kubernetes per workload GPU (Plex transcoding, Kasm, AI/ML).

## Architettura

```
┌─────────────────────────────────────────────────────────────┐
│  ESXi Host                                                  │
│  ┌─────────────────────────────────────────────────────────┐│
│  │  NVIDIA T4 (PCIe Passthrough)                           ││
│  └─────────────────────────────────────────────────────────┘│
│                            ↓                                │
│  ┌─────────────────────────────────────────────────────────┐│
│  │  VM Worker Node (GPU)                                   ││
│  │  - NVIDIA Driver                                        ││
│  │  - NVIDIA Container Toolkit                             ││
│  │  - Containerd runtime config                            ││
│  └─────────────────────────────────────────────────────────┘│
└─────────────────────────────────────────────────────────────┘
                            ↓
┌─────────────────────────────────────────────────────────────┐
│  Kubernetes                                                 │
│  ┌─────────────────────────────────────────────────────────┐│
│  │  NVIDIA Device Plugin                                   ││
│  │  - Espone nvidia.com/gpu come risorsa                   ││
│  │  - Schedula pod GPU sul nodo corretto                   ││
│  └─────────────────────────────────────────────────────────┘│
│                            ↓                                │
│  ┌─────────────────────────────────────────────────────────┐│
│  │  Pod con GPU (Plex, Kasm, etc.)                         ││
│  │  resources:                                             ││
│  │    limits:                                              ││
│  │      nvidia.com/gpu: 1                                  ││
│  └─────────────────────────────────────────────────────────┘│
└─────────────────────────────────────────────────────────────┘
```

## Parte 1: Configurazione vSphere

### 1.1 Abilitare Passthrough su ESXi

1. **vSphere Client → Host → Configure → Hardware → PCI Devices**
2. Trova NVIDIA T4 nella lista
3. Click **Toggle Passthrough**
4. **Riavvia l'host ESXi**

### 1.2 Verificare Passthrough attivo

```
# SSH sull'host ESXi
esxcli hardware pci pcipassthru list | grep -i nvidia
```

Output atteso:
```
0000:3b:00.0  true   NVIDIA Corporation  TU104GL [Tesla T4]
```

### 1.3 Creare VM Worker con GPU

**Impostazioni VM:**

| Parametro | Valore |
|-----------|--------|
| Guest OS | Linux (Ubuntu 22.04 o RHEL 9) |
| CPU | 8+ vCPU |
| RAM | 32+ GB |
| Disk | 100+ GB |
| **PCI Device** | NVIDIA T4 (passthrough) |

**VM Options → Advanced → Configuration Parameters:**

```
pciPassthru.use64bitMMIO = TRUE
pciPassthru.64bitMMIOSizeGB = 64
```

**Importante:**
- Memory Reservation: **Reserve all guest memory**
- CPU/MMU Virtualization: **Hardware virtualization**

### 1.4 Configurazione Rancher (RKE2)

Quando crei il cluster da Rancher, assicurati che il nodo GPU abbia:

- **Label:** `nvidia.com/gpu=present`
- **Taint (opzionale):** `nvidia.com/gpu=present:NoSchedule`

---

## Parte 2: Configurazione Worker Node

### 2.1 Installare NVIDIA Driver

**Ubuntu 22.04:**
```bash
sudo apt update
sudo apt install -y nvidia-driver-535-server nvidia-utils-535-server
sudo reboot
```

**RHEL 9:**
```bash
sudo dnf install -y epel-release
sudo dnf config-manager --add-repo https://developer.download.nvidia.com/compute/cuda/repos/rhel9/x86_64/cuda-rhel9.repo
sudo dnf install -y nvidia-driver-535
sudo reboot
```

### 2.2 Verificare Driver

```bash
nvidia-smi
```

Output atteso:
```
+-----------------------------------------------------------------------------+
| NVIDIA-SMI 535.xx.xx    Driver Version: 535.xx.xx    CUDA Version: 12.x     |
|-------------------------------+----------------------+----------------------+
| GPU  Name        Persistence-M| Bus-Id        Disp.A | Volatile Uncorr. ECC |
| Fan  Temp  Perf  Pwr:Usage/Cap|         Memory-Usage | GPU-Util  Compute M. |
|===============================+======================+======================|
|   0  Tesla T4            Off  | 00000000:03:00.0 Off |                    0 |
| N/A   45C    P0    27W /  70W |      0MiB / 15360MiB |      0%      Default |
+-------------------------------+----------------------+----------------------+
```

### 2.3 Installare NVIDIA Container Toolkit

```bash
# Aggiungi repository
curl -fsSL https://nvidia.github.io/libnvidia-container/gpgkey | sudo gpg --dearmor -o /usr/share/keyrings/nvidia-container-toolkit-keyring.gpg
curl -s -L https://nvidia.github.io/libnvidia-container/stable/deb/nvidia-container-toolkit.list | \
  sed 's#deb https://#deb [signed-by=/usr/share/keyrings/nvidia-container-toolkit-keyring.gpg] https://#g' | \
  sudo tee /etc/apt/sources.list.d/nvidia-container-toolkit.list

# Installa
sudo apt update
sudo apt install -y nvidia-container-toolkit

# Configura containerd
sudo nvidia-ctk runtime configure --runtime=containerd
sudo systemctl restart containerd
```

### 2.4 Verificare Container Runtime

```bash
sudo ctr run --rm --gpus 0 -t docker.io/nvidia/cuda:12.0-base-ubuntu22.04 cuda-test nvidia-smi
```

---

## Parte 3: Configurazione Kubernetes

### 3.1 Applicare Label al Nodo GPU

```bash
kubectl label nodes <gpu-worker-node> nvidia.com/gpu=present
```

### 3.2 Deploy NVIDIA Device Plugin

```bash
kubectl create -f https://raw.githubusercontent.com/NVIDIA/k8s-device-plugin/v0.14.3/nvidia-device-plugin.yml
```

Oppure con Helm:
```bash
helm repo add nvdp https://nvidia.github.io/k8s-device-plugin
helm repo update
helm install nvidia-device-plugin nvdp/nvidia-device-plugin \
  --namespace kube-system \
  --set gfd.enabled=true
```

### 3.3 Verificare GPU disponibile

```bash
kubectl describe node <gpu-worker-node> | grep -A5 "Allocatable:"
```

Output atteso:
```
Allocatable:
  cpu:                8
  memory:             32Gi
  nvidia.com/gpu:     1
```

---

## Parte 4: Configurazione Applicazioni

### Plex con GPU Transcoding

Vedi: `kubernetes/apps/media-stack/plex/deployment.yaml`

```yaml
apiVersion: apps/v1
kind: Deployment
metadata:
  name: plex
  namespace: media
spec:
  template:
    spec:
      # Forza scheduling sul nodo GPU
      nodeSelector:
        nvidia.com/gpu: "present"

      containers:
        - name: plex
          image: lscr.io/linuxserver/plex:latest
          env:
            - name: NVIDIA_VISIBLE_DEVICES
              value: "all"
            - name: NVIDIA_DRIVER_CAPABILITIES
              value: "all"
          resources:
            limits:
              nvidia.com/gpu: 1
```

### Kasm Workspaces con GPU

```yaml
resources:
  limits:
    nvidia.com/gpu: 1
env:
  - name: NVIDIA_VISIBLE_DEVICES
    value: "all"
```

---

## RuntimeClass (Opzionale)

Per gestire meglio i workload GPU, crea una RuntimeClass:

```yaml
apiVersion: node.k8s.io/v1
kind: RuntimeClass
metadata:
  name: nvidia
handler: nvidia
scheduling:
  nodeSelector:
    nvidia.com/gpu: "present"
```

Poi nei Pod:
```yaml
spec:
  runtimeClassName: nvidia
```

---

## Troubleshooting

### GPU non visibile nel nodo

```bash
# Sul worker node
nvidia-smi
dmesg | grep -i nvidia
journalctl -u containerd | grep -i nvidia
```

### Device Plugin non funziona

```bash
kubectl logs -n kube-system -l app=nvidia-device-plugin
kubectl describe node <gpu-node> | grep -i nvidia
```

### Container non vede GPU

```bash
# Test diretto
kubectl run gpu-test --rm -it --restart=Never \
  --image=nvidia/cuda:12.0-base-ubuntu22.04 \
  --limits=nvidia.com/gpu=1 \
  -- nvidia-smi
```

### Errore "failed to allocate device"

Verifica che:
1. Solo un pod per volta richieda la GPU (T4 = 1 GPU)
2. Device plugin sia running
3. Nodo abbia label corretto

---

## Note vSphere

### EVC Mode
Se usi EVC (Enhanced vMotion Compatibility), GPU passthrough potrebbe non funzionare. Disabilita EVC per il cluster o escludi il nodo GPU.

### vMotion
VM con GPU passthrough **non possono** usare vMotion. Pianifica maintenance di conseguenza.

### Reservation
La RAM della VM deve essere **completamente riservata** per GPU passthrough.
