# Importare Workload Cluster in Rancher

Guida per importare il cluster Kubernetes workload (gestito da CAPV) in Rancher per management centralizzato.

## Overview

Dopo aver creato il cluster workload con CAPV, lo importeremo in Rancher per ottenere:
- **UI Centralizzata**: Gestisci tutti i cluster da https://rancher.savemosca.com
- **RBAC Avanzato**: Controllo accessi granulare tramite Rancher
- **App Catalog**: Deploy applicazioni dal catalogo Rancher
- **Monitoring**: Prometheus/Grafana integrati
- **Backup**: Gestione backup cluster da Rancher UI

## Architettura Finale

```
┌───────────────────────────────────────────────────┐
│   srv26.mosca.lan (Management Cluster)            │
│   • Rancher v2.11.8 (management UI)               │
│   • CAPV controllers (provision/manage VMs)       │
│   • K3s v1.32.3                                   │
└───────────────────┬───────────────────────────────┘
                    │
       ┌────────────┼────────────┐
       │ Manages    │  Imported  │
       ▼            ▼            │
┌─────────────────────────┐     │
│  Workload Cluster       │     │
│  (vSphere VMs)          │◄────┘
│  • Control Plane        │
│  • Worker Nodes         │
│  • Auto-scaling         │
│  • Apps running here    │
└─────────────────────────┘
```

## Pre-requisiti

- [x] Cluster workload deployato e funzionante
- [x] Rancher v2.11.8 accessibile
- [x] kubectl con accesso a entrambi i cluster
- [ ] Kubeconfig del workload cluster

## 1. Ottenere Kubeconfig del Workload Cluster

```bash
# Assicurati di puntare al management cluster (srv26)
export KUBECONFIG=~/.kube/srv26-config

# Ottieni kubeconfig del workload cluster
clusterctl get kubeconfig homelab-k8s > ~/.kube/homelab-k8s-config

# Verifica connessione al workload cluster
export KUBECONFIG=~/.kube/homelab-k8s-config
kubectl get nodes

# Output atteso:
# NAME                                   STATUS   ROLES           AGE   VERSION
# homelab-k8s-control-plane-xxxxx        Ready    control-plane   10m   v1.32.3
# homelab-k8s-workers-xxxxx-xxxxx        Ready    <none>          8m    v1.32.3
# homelab-k8s-workers-xxxxx-yyyyy        Ready    <none>          8m    v1.32.3
```

### Configurare Alias per Switchare tra Cluster

```bash
# Aggiungi al tuo ~/.bashrc o ~/.zshrc
alias k-mgmt='kubectl --kubeconfig=~/.kube/srv26-config'
alias k-work='kubectl --kubeconfig=~/.kube/homelab-k8s-config'

# Oppure usa kubectx (consigliato)
# Merge dei kubeconfig
export KUBECONFIG=~/.kube/srv26-config:~/.kube/homelab-k8s-config
kubectl config view --flatten > ~/.kube/config

# Installa kubectx
brew install kubectx  # macOS

# Switch tra cluster
kubectx srv26-mosca-lan  # management cluster
kubectx homelab-k8s      # workload cluster
```

## 2. Importare Cluster via Rancher UI

### Metodo A: Import tramite Web UI (Consigliato)

1. **Accedi a Rancher**
   - Vai a https://rancher.savemosca.com
   - Login con le tue credenziali admin

2. **Avvia Import Cluster**
   - Click su "☰" (hamburger menu) in alto a sinistra
   - Seleziona "Cluster Management"
   - Click su "Import Existing" button

3. **Configura Import**
   - **Cluster Name**: `homelab-k8s-workload`
   - **Description**: `Production Kubernetes cluster managed by CAPV on vSphere`
   - **Member Roles**: Configura gli utenti che possono accedere
   - **Labels** (opzionale):
     - `environment=production`
     - `provider=vsphere`
     - `management=capv`
   - Click "Create"

4. **Applica Manifest al Workload Cluster**

   Rancher genererà un comando da eseguire. Sarà simile a:

   ```bash
   # Copia il comando mostrato dalla UI di Rancher
   # Esempio:
   curl --insecure -sfL https://rancher.savemosca.com/v3/import/abc123xyz.yaml | kubectl apply -f -
   ```

   Esegui sul workload cluster:
   ```bash
   # Switch al workload cluster
   export KUBECONFIG=~/.kube/homelab-k8s-config

   # Applica il manifest di import (usa il comando dalla UI Rancher)
   curl --insecure -sfL https://rancher.savemosca.com/v3/import/TOKEN.yaml | kubectl apply -f -

   # Oppure scarica e applica
   curl --insecure -sfL https://rancher.savemosca.com/v3/import/TOKEN.yaml -o rancher-import.yaml
   kubectl apply -f rancher-import.yaml
   ```

5. **Verifica Import**

   ```bash
   # Verifica che i pod di cattle-system siano running
   kubectl get pods -n cattle-system

   # Output atteso:
   # NAME                               READY   STATUS    RESTARTS   AGE
   # cattle-cluster-agent-xxx           1/1     Running   0          2m
   # cattle-node-agent-xxx              1/1     Running   0          2m
   ```

6. **Attendi Sincronizzazione**
   - Torna alla UI di Rancher
   - Il cluster dovrebbe apparire come "Active" dopo 1-2 minuti
   - Verifica che tutte le informazioni del cluster siano visibili (nodi, pods, etc.)

### Metodo B: Import tramite CLI

```bash
# Torna al management cluster
export KUBECONFIG=~/.kube/srv26-config

# Crea Cluster Registration in Rancher
cat <<EOF | kubectl apply -f -
apiVersion: provisioning.cattle.io/v1
kind: Cluster
metadata:
  name: homelab-k8s-workload
  namespace: fleet-default
spec:
  clusterAPIConfig:
    clusterName: homelab-k8s
EOF

# Ottieni il registration token
TOKEN=$(kubectl get secret -n fleet-default \
  $(kubectl get cluster homelab-k8s-workload -n fleet-default -o jsonpath='{.status.clusterName}')-registration \
  -o jsonpath='{.data.values}' | base64 -d)

# Switch al workload cluster
export KUBECONFIG=~/.kube/homelab-k8s-config

# Applica registration manifest
echo "${TOKEN}" | kubectl apply -f -
```

## 3. Configurare Monitoring

Dopo l'import, abilita monitoring dal Rancher UI:

1. **Vai al Cluster Importato**
   - Rancher UI → Cluster Management → homelab-k8s-workload

2. **Abilita Monitoring**
   - Tab "Apps & Marketplace"
   - Click "Charts"
   - Cerca "Monitoring" (Rancher Monitoring v2)
   - Click "Install"
   - Configurazione:
     ```yaml
     # Valori personalizzati
     prometheus:
       retention: 7d
       persistentVolume:
         enabled: true
         size: 50Gi
         storageClass: vsphere-storage

     grafana:
       persistence:
         enabled: true
         size: 10Gi
         storageClass: vsphere-storage
       adminPassword: "your-secure-password"  # Cambia!

     alertmanager:
       enabled: true
       persistence:
         enabled: true
         size: 10Gi
     ```
   - Click "Install"

3. **Verifica Monitoring**
   ```bash
   # Switch al workload cluster
   export KUBECONFIG=~/.kube/homelab-k8s-config

   # Verifica pod monitoring
   kubectl get pods -n cattle-monitoring-system

   # Accedi a Grafana via port-forward (temporaneo)
   kubectl port-forward -n cattle-monitoring-system \
     svc/rancher-monitoring-grafana 3000:80

   # Poi vai a http://localhost:3000
   # Username: admin
   # Password: (quella configurata sopra)
   ```

4. **Configurare Ingress per Grafana** (Opzionale)
   ```yaml
   # grafana-ingress.yaml
   apiVersion: networking.k8s.io/v1
   kind: Ingress
   metadata:
     name: grafana
     namespace: cattle-monitoring-system
     annotations:
       cert-manager.io/cluster-issuer: letsencrypt-prod
   spec:
     ingressClassName: nginx
     tls:
       - hosts:
           - grafana.savemosca.com
         secretName: grafana-tls
     rules:
       - host: grafana.savemosca.com
         http:
           paths:
             - path: /
               pathType: Prefix
               backend:
                 service:
                   name: rancher-monitoring-grafana
                   port:
                     number: 80
   ```

   ```bash
   kubectl apply -f grafana-ingress.yaml
   ```

## 4. Configurare Backup (Opzionale ma Consigliato)

Abilita backup automatici del workload cluster:

1. **Installa Rancher Backup dal Catalog**
   - Rancher UI → Apps & Marketplace → Charts
   - Cerca "Rancher Backup"
   - Click "Install"
   - Namespace: `cattle-resources-system`
   - Click "Install"

2. **Configura S3/NFS Storage per Backup**

   Esempio con NFS:
   ```yaml
   # backup-storage.yaml
   apiVersion: v1
   kind: PersistentVolume
   metadata:
     name: rancher-backup-pv
   spec:
     capacity:
       storage: 100Gi
     accessModes:
       - ReadWriteMany
     nfs:
       server: nas.homelab.local
       path: /backups/rancher
     persistentVolumeReclaimPolicy: Retain
   ---
   apiVersion: v1
   kind: PersistentVolumeClaim
   metadata:
     name: rancher-backup-pvc
     namespace: cattle-resources-system
   spec:
     accessModes:
       - ReadWriteMany
     resources:
       requests:
         storage: 100Gi
   ```

3. **Crea Backup Schedule**
   ```yaml
   # backup-schedule.yaml
   apiVersion: resources.cattle.io/v1
   kind: Backup
   metadata:
     name: daily-backup
     namespace: cattle-resources-system
   spec:
     resourceSetName: rancher-resource-set
     schedule: "0 2 * * *"  # Daily at 2 AM
     retentionCount: 7
     storageLocation:
       s3:
         # Configura S3 se disponibile
         bucketName: homelab-backups
         region: us-east-1
         endpoint: s3.amazonaws.com
         credentialSecretName: s3-creds
         # Oppure usa persistentVolumeClaim
       # persistentVolumeClaim:
       #   name: rancher-backup-pvc
   ```

## 5. Verifiche Post-Import

```bash
# Switch al workload cluster
export KUBECONFIG=~/.kube/homelab-k8s-config

# 1. Verifica namespace Rancher
kubectl get namespaces | grep cattle

# Output atteso:
# cattle-fleet-local-system
# cattle-fleet-system
# cattle-monitoring-system (se monitoring installato)
# cattle-system

# 2. Verifica connessione cluster agent a Rancher
kubectl logs -n cattle-system deployment/cattle-cluster-agent --tail=50

# Deve mostrare: "Successfully connected to Rancher"

# 3. Verifica da Rancher UI
# - Vai a https://rancher.savemosca.com
# - Cluster Management → homelab-k8s-workload
# - Verifica che:
#   ✅ Stato = Active
#   ✅ Nodi visibili (control plane + workers)
#   ✅ Pod count corretto
#   ✅ CPU/Memory metrics visibili

# 4. Testa gestione da Rancher
# - Prova a fare kubectl via Rancher UI
# - Lancia un pod di test
# - Verifica logs/exec funzionano
```

## 6. Deploy Applicazioni dal Catalog Rancher

Ora puoi deployare apps direttamente da Rancher:

```bash
# Esempio: Deploy di un app dal catalog
# 1. Rancher UI → homelab-k8s-workload
# 2. Apps & Marketplace → Charts
# 3. Cerca "nginx" o qualsiasi app
# 4. Click Install
# 5. Configura namespace e valori
# 6. Click Install

# Oppure via kubectl
export KUBECONFIG=~/.kube/homelab-k8s-config

# Deploy applicazione di test
kubectl create deployment nginx --image=nginx:latest
kubectl expose deployment nginx --port=80 --type=ClusterIP
kubectl get pods,svc
```

## 7. Integrare CAPV Autoscaling con Rancher

Rancher può visualizzare lo stato dell'autoscaling CAPV:

```bash
# Torna al management cluster
export KUBECONFIG=~/.kube/srv26-config

# Verifica MachineDeployment
kubectl get machinedeployments -n default

# Scala manualmente (test)
kubectl scale machinedeployment homelab-k8s-workers --replicas=3

# Torna al workload cluster e verifica nuovi nodi
export KUBECONFIG=~/.kube/homelab-k8s-config
watch kubectl get nodes

# Da Rancher UI:
# - Vai a Cluster → Nodes
# - Vedrai i nuovi nodi apparire mentre CAPV li provisiona
```

## 8. RBAC e Multi-Tenancy

Configura accessi granulari tramite Rancher:

```bash
# Rancher UI → Cluster Management → homelab-k8s-workload
# → Users & Roles

# 1. Crea Project (namespace logico)
#    - Name: "Production Apps"
#    - Namespaces: default, media-stack, monitoring

# 2. Aggiungi Members al Project
#    - User: developer@example.com
#    - Role: Project Member (can deploy apps, view logs)

# 3. Crea Custom Roles (opzionale)
#    - Role: "App Deployer"
#    - Permissions: create/edit deployments, services
#    - No permission to: delete namespaces, edit RBAC
```

## Troubleshooting

### Problema: Cluster rimane "Pending"

```bash
# Verifica cattle-cluster-agent
export KUBECONFIG=~/.kube/homelab-k8s-config
kubectl logs -n cattle-system deployment/cattle-cluster-agent

# Verifica connectivity a Rancher
kubectl exec -n cattle-system deployment/cattle-cluster-agent -- \
  curl -k https://rancher.savemosca.com/v3

# Se timeout, verifica DNS e routing
kubectl run -it --rm debug --image=nicolaka/netshoot --restart=Never -- \
  nslookup rancher.savemosca.com
```

### Problema: Monitoring non installa

```bash
# Verifica storage class disponibile
kubectl get storageclass

# Se manca, crea vSphere CSI storageclass
# Vedi infrastructure/storage/storageclass.yaml

# Verifica PVC pending
kubectl get pvc -n cattle-monitoring-system

# Descrivi PVC per vedere errori
kubectl describe pvc -n cattle-monitoring-system
```

### Problema: Conflitto tra CAPV e Rancher

```bash
# CAPV e Rancher gestiscono il cluster in modo diverso
# CAPV = provisioning infra (VMs, nodes)
# Rancher = management layer (apps, monitoring, RBAC)

# NON usare Rancher per:
# - Provisionare nuovi nodi (usa CAPV)
# - Modificare control plane (usa CAPV)

# USA Rancher per:
# - Deploy apps
# - Monitoring
# - RBAC
# - Backup
# - Catalog apps
```

### Problema: Import token scaduto

```bash
# Genera nuovo token di import
# Rancher UI → Cluster Management → homelab-k8s-workload
# → ⋮ (menu) → "Registration Command"
# Copia e esegui il nuovo comando sul workload cluster
```

## Next Steps

Cluster importato in Rancher! Ora puoi:
- [kubernetes/apps/](../kubernetes/apps/) - Deployare le applicazioni del homelab
- [docs/04-autoscaling.md](04-autoscaling.md) - Configurare cluster autoscaler
- [docs/05-cicd-setup.md](05-cicd-setup.md) - Setup GitHub Actions per CI/CD

## Riferimenti

- [Rancher Import Cluster Documentation](https://ranchermanager.docs.rancher.com/how-to-guides/new-user-guides/kubernetes-clusters-in-rancher-setup/import-existing-clusters)
- [Rancher Monitoring](https://ranchermanager.docs.rancher.com/integrations-in-rancher/monitoring-and-alerting)
- [Rancher Backup & Restore](https://ranchermanager.docs.rancher.com/how-to-guides/new-user-guides/backup-restore-and-disaster-recovery)
- [CAPV + Rancher Integration](https://github.com/rancher/cluster-api)
