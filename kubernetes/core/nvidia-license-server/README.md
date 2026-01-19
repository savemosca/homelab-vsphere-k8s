# NVIDIA vGPU License Server (FastAPI-DLS)

Server di licenze open-source per NVIDIA vGPU/GRID.

## Configurazione GPU

- **Host ESXi**: esxi01.mosca.lan
- **GPU**: Tesla P4
- **Profilo vGPU**: grid_p4-4q (4GB VRAM, max 2 vGPU)

## Setup

### 1. Genera certificati

Il license server richiede certificati SSL. Genera con:

```bash
# Crea directory temporanea
mkdir -p /tmp/dls-certs && cd /tmp/dls-certs

# Genera CA
openssl genrsa -out ca.key 2048
openssl req -x509 -new -nodes -key ca.key -sha256 -days 3650 \
  -out ca.crt -subj "/CN=FastAPI-DLS CA"

# Genera certificato server
openssl genrsa -out server.key 2048
openssl req -new -key server.key -out server.csr \
  -subj "/CN=nvidia-dls.mosca.lan"

# Firma il certificato
openssl x509 -req -in server.csr -CA ca.crt -CAkey ca.key \
  -CAcreateserial -out server.crt -days 3650 -sha256

# Crea secret Kubernetes
kubectl create secret generic fastapi-dls-certs \
  --from-file=webserver.key=server.key \
  --from-file=webserver.crt=server.crt \
  -n nvidia-license
```

### 2. DNS

Aggiungi record DNS per il license server:

**Windows DNS (interno):**
```
nvidia-dls.mosca.lan  A  → [IP LoadBalancer MetalLB]
```

### 3. Deploy

```bash
kubectl apply -k kubernetes/core/nvidia-license-server/
```

### 4. Configura i client vGPU

Sui GPU workers, configura il client per puntare al license server:

```bash
# File: /etc/nvidia/gridd.conf
ServerAddress=nvidia-dls.mosca.lan
ServerPort=443
FeatureType=1
EnableUI=FALSE
```

Oppure tramite cloud-init nel template GPU worker.

## Verifica

```bash
# Controlla licenze attive
curl -k https://nvidia-dls.mosca.lan/

# Logs
kubectl logs -n nvidia-license -l app=fastapi-dls
```

## GPU Worker VM Configuration

Per assegnare il profilo vGPU alla VM:

1. vSphere → Edit VM Settings
2. Add New Device → Shared PCI Device
3. Seleziona: NVIDIA GRID vGPU (grid_p4-4q)
4. Reserve all memory

Il profilo `grid_p4-4q` permette 2 VM con 4GB VRAM ciascuna.
