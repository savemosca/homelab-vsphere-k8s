# NVIDIA Device Plugin per Kubernetes

Espone le GPU NVIDIA come risorse Kubernetes (`nvidia.com/gpu`).

## Prerequisiti sul Worker Node GPU

1. **GPU passthrough configurato** (vedi `docs/nvidia-gpu-passthrough.md`)
2. **NVIDIA Driver installato**
3. **NVIDIA Container Toolkit configurato**
4. **Label applicato al nodo:**
   ```bash
   kubectl label nodes <gpu-node> nvidia.com/gpu=present
   ```

## Deploy

```bash
kubectl apply -f nvidia-device-plugin.yaml
```

## Verifica

```bash
# Device Plugin running
kubectl get pods -n gpu-operator

# GPU visibile come risorsa
kubectl describe node <gpu-node> | grep nvidia.com/gpu

# Output atteso:
#   nvidia.com/gpu:     1
```

## Utilizzo nei Pod

```yaml
spec:
  containers:
    - name: gpu-app
      resources:
        limits:
          nvidia.com/gpu: 1
      env:
        - name: NVIDIA_VISIBLE_DEVICES
          value: "all"
        - name: NVIDIA_DRIVER_CAPABILITIES
          value: "all"
```

## RuntimeClass (opzionale)

Per scheduling automatico sul nodo GPU:

```yaml
spec:
  runtimeClassName: nvidia
```

## Applicazioni GPU nel repo

| App | Path | GPU Usage |
|-----|------|-----------|
| Plex | `kubernetes/apps/media-stack/plex/` | Hardware transcoding |
| Kasm | `kubernetes/apps/kasm/` (futuro) | Desktop acceleration |

## Troubleshooting

```bash
# Log device plugin
kubectl logs -n gpu-operator -l name=nvidia-device-plugin-ds

# Test GPU
kubectl run gpu-test --rm -it --restart=Never \
  --image=nvidia/cuda:12.0-base-ubuntu22.04 \
  --limits=nvidia.com/gpu=1 \
  -- nvidia-smi
```
