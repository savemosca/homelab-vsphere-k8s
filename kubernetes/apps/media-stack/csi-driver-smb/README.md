# SMB CSI Driver Installation

Il **SMB CSI driver** permette a Kubernetes di montare share SMB/CIFS come PersistentVolumes.

## Installazione

### Metodo 1: Helm (Raccomandato)

```bash
# Aggiungi il repo Helm
helm repo add csi-driver-smb https://raw.githubusercontent.com/kubernetes-csi/csi-driver-smb/master/charts
helm repo update

# Installa il driver
helm install csi-driver-smb csi-driver-smb/csi-driver-smb \
  --namespace kube-system \
  --version v1.15.0

# Verifica installazione
kubectl get pods -n kube-system -l app=csi-smb-controller
kubectl get pods -n kube-system -l app=csi-smb-node
```

### Metodo 2: Manifest YAML

```bash
# Versione del driver
VERSION=v1.15.0

# Installa tutti i componenti
kubectl apply -f https://raw.githubusercontent.com/kubernetes-csi/csi-driver-smb/master/deploy/${VERSION}/rbac-csi-smb-controller.yaml
kubectl apply -f https://raw.githubusercontent.com/kubernetes-csi/csi-driver-smb/master/deploy/${VERSION}/csi-smb-driverinfo.yaml
kubectl apply -f https://raw.githubusercontent.com/kubernetes-csi/csi-driver-smb/master/deploy/${VERSION}/csi-smb-controller.yaml
kubectl apply -f https://raw.githubusercontent.com/kubernetes-csi/csi-driver-smb/master/deploy/${VERSION}/csi-smb-node.yaml
```

## Verifica Installazione

```bash
# Verifica che il CSI driver sia registrato
kubectl get csidriver smb.csi.k8s.io

# Output atteso:
# NAME              ATTACHREQUIRED   PODINFOONMOUNT   STORAGECAPACITY   TOKENREQUESTS   REQUIRESREPUBLISH   MODES        AGE
# smb.csi.k8s.io    false            true             false             <unset>         false               Persistent   30s

# Verifica pods del controller
kubectl get pods -n kube-system | grep csi-smb

# Output atteso:
# csi-smb-controller-xxx    3/3     Running   0          1m
# csi-smb-node-xxx          3/3     Running   0          1m
# csi-smb-node-yyy          3/3     Running   0          1m
```

## Test Funzionamento

Dopo l'installazione, testa con un volume temporaneo:

```bash
# Crea un secret di test
kubectl create secret generic smb-test \
  --from-literal=username=media-user \
  --from-literal=password=yourpassword \
  -n default

# Crea un PV di test
cat <<EOF | kubectl apply -f -
apiVersion: v1
kind: PersistentVolume
metadata:
  name: smb-test-pv
spec:
  capacity:
    storage: 1Gi
  accessModes:
    - ReadWriteMany
  persistentVolumeReclaimPolicy: Retain
  mountOptions:
    - dir_mode=0777
    - file_mode=0777
  csi:
    driver: smb.csi.k8s.io
    readOnly: false
    volumeHandle: smb-test-handle
    volumeAttributes:
      source: "//srv05.mosca.lan/media-downloads"
    nodeStageSecretRef:
      name: smb-test
      namespace: default
EOF

# Crea un PVC
cat <<EOF | kubectl apply -f -
apiVersion: v1
kind: PersistentVolumeClaim
metadata:
  name: smb-test-pvc
  namespace: default
spec:
  accessModes:
    - ReadWriteMany
  resources:
    requests:
      storage: 1Gi
  volumeName: smb-test-pv
  storageClassName: ""
EOF

# Crea un pod di test
cat <<EOF | kubectl apply -f -
apiVersion: v1
kind: Pod
metadata:
  name: smb-test-pod
  namespace: default
spec:
  containers:
  - name: test
    image: busybox
    command: ["sh", "-c", "echo 'SMB mount test' > /mnt/test.txt && cat /mnt/test.txt && sleep 3600"]
    volumeMounts:
    - name: smb
      mountPath: /mnt
  volumes:
  - name: smb
    persistentVolumeClaim:
      claimName: smb-test-pvc
EOF

# Verifica che funzioni
kubectl logs smb-test-pod
# Output atteso: SMB mount test

# Cleanup
kubectl delete pod smb-test-pod
kubectl delete pvc smb-test-pvc
kubectl delete pv smb-test-pv
kubectl delete secret smb-test
```

## Troubleshooting

### Driver non si avvia

```bash
# Controlla logs del controller
kubectl logs -n kube-system -l app=csi-smb-controller -c smb

# Controlla logs dei nodi
kubectl logs -n kube-system -l app=csi-smb-node -c smb
```

### Mount fallisce

```bash
# Verifica il secret
kubectl get secret smb-credentials -n media -o yaml

# Verifica eventi del PVC
kubectl describe pvc media-movies -n media

# Verifica eventi del pod
kubectl describe pod <pod-name> -n media

# Testa connettività SMB da un nodo
kubectl run -it --rm smb-test --image=alpine -- sh
apk add samba-client
smbclient -L //srv05.mosca.lan -U media-user
```

### Permessi non corretti

```bash
# Verifica mount options nel PV
kubectl get pv smb-media-movies -o yaml

# Le opzioni devono includere:
# - dir_mode=0777
# - file_mode=0777
# - uid=1000
# - gid=1000
```

## Disinstallazione

### Con Helm

```bash
helm uninstall csi-driver-smb -n kube-system
```

### Con kubectl

```bash
VERSION=v1.15.0
kubectl delete -f https://raw.githubusercontent.com/kubernetes-csi/csi-driver-smb/master/deploy/${VERSION}/csi-smb-node.yaml
kubectl delete -f https://raw.githubusercontent.com/kubernetes-csi/csi-driver-smb/master/deploy/${VERSION}/csi-smb-controller.yaml
kubectl delete -f https://raw.githubusercontent.com/kubernetes-csi/csi-driver-smb/master/deploy/${VERSION}/csi-smb-driverinfo.yaml
kubectl delete -f https://raw.githubusercontent.com/kubernetes-csi/csi-driver-smb/master/deploy/${VERSION}/rbac-csi-smb-controller.yaml
```

## Risorse

- [GitHub Repository](https://github.com/kubernetes-csi/csi-driver-smb)
- [Documentazione Ufficiale](https://github.com/kubernetes-csi/csi-driver-smb/tree/master/docs)
- [Release Notes](https://github.com/kubernetes-csi/csi-driver-smb/releases)
