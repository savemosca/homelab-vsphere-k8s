# Riepilogo Post-Pulizia Sistema

Documento generato: 2026-01-17

## Stato Corrente del Sistema

### Server Management Cluster (srv26.mosca.lan)
- **IP**: 192.168.11.130
- **OS**: RHEL 9.7
- **K3s**: v1.32.11+k3s1 ✅
- **Rancher**: v2.13.1 ✅ (installazione fresca)
- **Accesso Rancher**: https://rancher.savemosca.com
- **Bootstrap Password**: `cmnlndb298kp48mtbskq6mqqzljqlmp8xvkcp9km8dk2whkphgwgml`

### Disk Usage
```
Filesystem                 Size  Used Avail Use%
/dev/mapper/rhel_srv26-root 35G   14G   22G  41%
```

## Operazioni di Pulizia Completate

### ✅ 1. Database Corrotto Rimosso
- **Percorso**: `/var/lib/rancher/k3s/server/db-v1.32.11-corrupted`
- **Dimensione**: 11MB
- **Status**: Già rimosso in precedenza

### ✅ 2. Job Helm Completati
Rimossi dalla namespace `cattle-system`:
- `helm-operation-bgzj5`
- `helm-operation-dtxwj`
- `helm-operation-hmvg8`
- `helm-operation-l4jxz`
- `helm-operation-p9jvn`
- `helm-operation-s5xtc`

### ✅ 3. Pod Completati/Falliti
- Nessun pod in stato `Succeeded` o `Failed` trovato
- Sistema pulito

### ✅ 4. ReplicaSet Vecchi (0 replicas)
Rimossi:
- `capi-kubeadm-bootstrap-system/capi-kubeadm-bootstrap-controller-manager-6f9cfbdb68`
- `kube-system/traefik-67bfb46dcb`

### ✅ 5. Container Images Inutilizzati
Immagini rimosse:
- `docker.io/rancher/mirrored-metrics-server:v0.7.2`
- `docker.io/rancher/mirrored-pause:3.6`
- `docker.io/rancher/local-path-provisioner:v0.0.31`
- `docker.io/rancher/mirrored-coredns-coredns:1.12.0`
- `docker.io/rancher/klipper-helm:v0.9.4-build20250113`
- `quay.io/jetstack/cert-manager-startupapicheck:v1.16.2`
- `docker.io/rancher/mirrored-library-traefik:3.3.2`

**Totale spazio liberato da immagini**: ~500MB

## ⚠️ Backup Directory - Azione Manuale Consigliata

### Backup da Mantenere
```bash
~/k3s-backups/pre-upgrade-attempt2-20260117-1824/
├── k3s-database-backup.tar.gz (15MB)
└── k3s-server-full-backup.tar.gz (18MB)
```
**DA MANTENERE** - Questo è il backup valido del secondo tentativo di upgrade (successo)

### Backup da Rimuovere (Opzionale)
```bash
# Primo tentativo fallito - sicuro da rimuovere
~/k3s-backups/20260117-1809/

# Backup vecchi di Rancher prima del reset - sicuro da rimuovere
~/rancher-backups/20260117-1754/
~/rancher-backups/20260117-1755/
```

### Comando per Rimozione Manuale
```bash
ssh administrator@srv26.mosca.lan "rm -rf ~/k3s-backups/20260117-1809 ~/rancher-backups/20260117-175*"
```

**Spazio che verrà liberato**: ~40MB

## Namespace Kubernetes Correnti (22 totali)

### Namespace di Sistema
- `default`
- `kube-system`
- `kube-public`
- `kube-node-lease`

### Namespace Rancher
- `cattle-system` (Rancher server)
- `cattle-fleet-system` (Fleet GitOps)
- `cattle-fleet-local-system` (Local cluster management)
- `cattle-global-data` (Global configuration)
- `cattle-global-nt` (Node templates)
- `cattle-impersonation-system` (User impersonation)
- `cattle-provisioning-capi-system` (Cluster API provisioning)
- `cattle-resources-system` (Resource management)
- `fleet-default` (Default Fleet namespace)
- `fleet-local` (Local Fleet workspace)
- `local` (Local cluster alias)

### Namespace Infrastructure
- `cert-manager` (Certificate management)
- `capi-kubeadm-bootstrap-system` (Cluster API Kubeadm Bootstrap)
- `capi-kubeadm-control-plane-system` (Cluster API Kubeadm Control Plane)
- `capi-system` (Cluster API core)
- `capv-system` (Cluster API Provider vSphere)

### Namespace Networking/Storage
- `tigera-operator` (Calico operator)
- `kube-system` (include anche Traefik ingress, CoreDNS, local-path provisioner)

## Risorse Orfane - Verifica Completata

Nessuna risorsa orfana trovata relativa a:
- Old Rancher v2.11.x
- Old cluster `c-m-wvxsns7q`
- Old NodeTemplate `nt-zhxpf`
- RKE1 resources

Tutte le risorse orfane sono state rimosse durante l'upgrade.

## Cronologia Upgrade

### Timeline degli Eventi

**17 Gennaio 2026 - 17:54**: Backup pre-upgrade Rancher
- Rancher v2.11.0-hotfix-42a5.1 su K3s v1.32.3

**17 Gennaio 2026 - 17:55**: Upgrade Rancher riuscito
- Rancher v2.11.0 → v2.13.1
- Risolto problema RKE1 NodeTemplate

**17 Gennaio 2026 - 18:09**: Primo tentativo upgrade K3s - FALLITO
- K3s v1.32.3 → v1.32.11
- Database reset/corrotto
- Perdita di tutti i namespace Rancher

**17 Gennaio 2026 - 18:15**: Reinstallazione Rancher
- Rancher v2.13.1 da zero
- Configurazione fresca

**17 Gennaio 2026 - 18:24**: Secondo tentativo upgrade K3s - SUCCESSO
- Backup completo database (K3s fermo)
- K3s v1.32.3 → v1.32.11
- Database preservato
- Tutti i 22 namespace intatti

**17 Gennaio 2026 - 18:45**: Sistema di pulizia completato
- Rimossi job completati
- Rimossi ReplicaSet vecchi
- Rimossi container images inutilizzati
- Identificati backup da rimuovere manualmente

## Lezioni Apprese - Best Practices per Futuri Upgrade

### ✅ Backup K3s - Procedura Corretta
```bash
# 1. FERMA K3s prima del backup del database
sudo systemctl stop k3s

# 2. Backup database (15MB)
sudo tar -czf ~/k3s-backups/$(date +%Y%m%d-%H%M)/k3s-database-backup.tar.gz \
  -C /var/lib/rancher/k3s/server db/

# 3. Backup completo server (18MB)
sudo tar -czf ~/k3s-backups/$(date +%Y%m%d-%H%M)/k3s-server-full-backup.tar.gz \
  -C /var/lib/rancher/k3s server/

# 4. RIAVVIA K3s
sudo systemctl start k3s

# 5. Verifica che tutto funzioni
sudo /usr/local/bin/kubectl get nodes
sudo /usr/local/bin/kubectl get namespaces

# 6. Procedi con l'upgrade
curl -sfL https://get.k3s.io | INSTALL_K3S_VERSION=v1.32.11+k3s1 sh -s - server
```

### ❌ Errori da Evitare
1. **NON** fare backup del database con K3s in esecuzione
2. **NON** fare solo backup delle risorse Kubernetes (kubectl get all)
3. **NON** upgradare senza backup del database SQLite
4. **NON** rimuovere backup fino a verifica completa del sistema

### ✅ Pulizia Periodica Consigliata
```bash
# Job Helm completati
sudo /usr/local/bin/kubectl delete jobs -n cattle-system --field-selector status.successful=1

# Pod completati/falliti
sudo /usr/local/bin/kubectl delete pods -A --field-selector status.phase=Succeeded
sudo /usr/local/bin/kubectl delete pods -A --field-selector status.phase=Failed

# ReplicaSet vecchi (0 replicas)
sudo /usr/local/bin/kubectl get rs -A -o json | \
  jq -r '.items[] | select(.spec.replicas == 0) | "\(.metadata.namespace) \(.metadata.name)"' | \
  while read ns name; do
    sudo /usr/local/bin/kubectl delete rs -n "$ns" "$name"
  done

# Container images inutilizzati
sudo /usr/local/bin/k3s crictl rmi --prune
```

## Stato Health Check

### K3s Service
```bash
ssh administrator@srv26.mosca.lan "sudo systemctl status k3s"
```
**Expected**: `Active: active (running)`

### Rancher Pods
```bash
ssh administrator@srv26.mosca.lan "sudo /usr/local/bin/kubectl get pods -n cattle-system"
```
**Expected**: Tutti i pod `rancher-*` in stato `Running` (3 replicas)

### Certificate Manager
```bash
ssh administrator@srv26.mosca.lan "sudo /usr/local/bin/kubectl get pods -n cert-manager"
```
**Expected**: Tutti i pod `cert-manager-*` in stato `Running`

### CAPV Controllers
```bash
ssh administrator@srv26.mosca.lan "sudo /usr/local/bin/kubectl get pods -n capv-system"
```
**Expected**: Pod `capv-controller-manager-*` in stato `Running`

## Next Steps - Configurazione Rancher

### 1. Setup Iniziale Rancher (TODO)
```bash
# Accedi a https://rancher.savemosca.com
# Bootstrap password: cmnlndb298kp48mtbskq6mqqzljqlmp8xvkcp9km8dk2whkphgwgml

# - Crea nuovo utente admin permanente
# - Imposta password sicura
# - Accetta i termini di servizio
# - Il cluster local (srv26) dovrebbe essere già presente
```

### 2. Deploy Workload Cluster con CAPV (TODO)
- Configura `vsphere-params.env` con credenziali vSphere
- Genera manifest del cluster workload
- Deploy del cluster su vSphere
- Verifica nodi control plane e worker

### 3. Import Workload Cluster in Rancher (TODO)
- Usa la UI Rancher per importare il cluster
- Abilita monitoring (Prometheus/Grafana)
- Configura backup automatici
- Setup RBAC e multi-tenancy

## File di Riferimento

### Documentazione
- [docs/00-rancher-upgrade.md](00-rancher-upgrade.md) - Guida upgrade Rancher
- [docs/02-management-cluster-rancher.md](02-management-cluster-rancher.md) - Setup management cluster
- [docs/06-rancher-import.md](06-rancher-import.md) - Import workload cluster in Rancher
- [README.md](../README.md) - Overview completo del progetto

### Script e Template
- [scripts/generate-cluster-manifest.sh](../scripts/generate-cluster-manifest.sh) - Generatore manifest CAPV
- [infrastructure/vsphere-params.env.template](../infrastructure/vsphere-params.env.template) - Template parametri vSphere
- [infrastructure/workload-cluster/cluster.yaml](../infrastructure/workload-cluster/cluster.yaml) - Manifest cluster base
- [infrastructure/workload-cluster/control-plane.yaml](../infrastructure/workload-cluster/control-plane.yaml) - Control plane config
- [infrastructure/workload-cluster/worker-pool.yaml](../infrastructure/workload-cluster/worker-pool.yaml) - Worker nodes config

## Contatti e Supporto

### Issue Tracking
- Per problemi con Rancher: https://github.com/rancher/rancher/issues
- Per problemi con CAPV: https://github.com/kubernetes-sigs/cluster-api-provider-vsphere/issues
- Per problemi con K3s: https://github.com/k3s-io/k3s/issues

### Versioni Software Installate
- **K3s**: v1.32.11+k3s1
- **Rancher**: v2.13.1
- **Helm**: (verifica con `helm version`)
- **cert-manager**: v1.16.2
- **Cluster API**: (verifica con `kubectl get pods -n capi-system`)
- **CAPV**: (verifica con `kubectl get pods -n capv-system`)

---

**Documento generato automaticamente durante la pulizia post-upgrade del sistema**
