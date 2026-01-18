# vSphere CSI Driver Integration

Il vSphere Container Storage Interface (CSI) driver permette il provisioning dinamico di PersistentVolumes su vSphere.

## Architettura

```
┌─────────────────────────────────────────────────────────────────┐
│  Kubernetes Cluster                                             │
│                                                                 │
│  ┌─────────────────────────────────────────────────────────┐   │
│  │  vSphere CSI Driver                                      │   │
│  │  - Controller (Deployment)                               │   │
│  │  - Node (DaemonSet)                                      │   │
│  └─────────────────────────────────────────────────────────┘   │
│                              │                                  │
│                              ▼                                  │
│  ┌─────────────────────────────────────────────────────────┐   │
│  │  StorageClasses                                          │   │
│  │  - vsphere-thin (default)                                │   │
│  │  - vsphere-thick-eager                                   │   │
│  └─────────────────────────────────────────────────────────┘   │
└─────────────────────────────────────────────────────────────────┘
                              │
                              ▼
┌─────────────────────────────────────────────────────────────────┐
│  vSphere                                                        │
│  ┌─────────────────────────────────────────────────────────┐   │
│  │  Datastores                                              │   │
│  │  - datastore02-local-raid (primary)                      │   │
│  │  - datastore03-local-raid (secondary)                    │   │
│  └─────────────────────────────────────────────────────────┘   │
└─────────────────────────────────────────────────────────────────┘
```

## Prerequisiti

1. **vSphere 7.0+** con vCenter
2. **VM Hardware Version 15+**
3. **Utente vSphere** con permessi:
   - `Cns.Searchable`
   - `Datastore.*` (subset necessario)
   - `VirtualMachine.Config.*` (per attach dischi)

## Deployment

Il vSphere CSI Driver viene deployato automaticamente da Rancher per cluster RKE2 su vSphere.

Per deployment manuale:

```bash
kubectl apply -f vsphere-csi-secret.yaml
kubectl apply -f vsphere-csi-driver.yaml
kubectl apply -f storage-classes.yaml
```

## StorageClasses

| Nome | Provisioner | Disk Type | Reclaim Policy |
|------|-------------|-----------|----------------|
| vsphere-thin | csi.vsphere.vmware.com | Thin | Delete |
| vsphere-thick-eager | csi.vsphere.vmware.com | Thick Eager Zeroed | Retain |

## Utilizzo

```yaml
apiVersion: v1
kind: PersistentVolumeClaim
metadata:
  name: my-pvc
spec:
  accessModes:
    - ReadWriteOnce
  storageClassName: vsphere-thin
  resources:
    requests:
      storage: 10Gi
```

## Troubleshooting

```bash
# Verificare CSI pods
kubectl get pods -n vmware-system-csi

# Logs controller
kubectl logs -n vmware-system-csi -l app=vsphere-csi-controller

# Logs node driver
kubectl logs -n vmware-system-csi -l app=vsphere-csi-node

# Verificare StorageClass
kubectl get sc

# Verificare PV/PVC
kubectl get pv,pvc -A
```
