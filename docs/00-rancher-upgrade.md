# Rancher Upgrade Guide

Guide per aggiornare Rancher da v2.11.0-hotfix-42a5.1 a v2.11.8 sul server srv26.mosca.lan.

## Stato Attuale

- **Server**: srv26.mosca.lan (192.168.11.130)
- **OS**: Red Hat Enterprise Linux 9.7
- **Kubernetes**: K3s v1.32.3+k3s1
- **Rancher**: v2.11.0-hotfix-42a5.1
- **URL**: https://rancher.savemosca.com
- **Deployment**: HA (3 replicas)
- **Uptime**: 269 giorni

## Versioni Disponibili

- **v2.11.8** - Ultima patch release della serie 2.11 (CONSIGLIATO per primo upgrade)
- **v2.12.0** - Versione minor più recente
- **v2.13.1** - Ultima versione disponibile

## Pre-requisiti

- [x] K3s v1.32.3 è compatibile con Rancher v2.11.8
- [ ] Backup di Rancher completato
- [ ] Accesso SSH a srv26.mosca.lan
- [ ] Credenziali admin di Rancher

## Fase 1: Backup Completo

### 1.1 Backup dello Stato di Rancher

```bash
# SSH al server
ssh administrator@srv26.mosca.lan

# Creare directory backup
mkdir -p ~/rancher-backups/$(date +%Y%m%d)
cd ~/rancher-backups/$(date +%Y%m%d)

# Backup di tutti i namespace Rancher
sudo /usr/local/bin/kubectl get all -A -o yaml > all-resources-backup.yaml

# Backup specifico namespace cattle-system
sudo /usr/local/bin/kubectl get all,secrets,configmaps,ingress -n cattle-system -o yaml > cattle-system-backup.yaml

# Backup CRDs di Rancher
sudo /usr/local/bin/kubectl get crd -o yaml | grep cattle > rancher-crds-backup.yaml

# Backup etcd di K3s (importante!)
sudo /usr/local/bin/k3s etcd-snapshot save --name rancher-pre-upgrade-$(date +%Y%m%d-%H%M)
```

### 1.2 Backup usando Rancher Backup Operator (CONSIGLIATO)

Se hai già installato il Rancher Backup Operator, usa questo metodo:

```bash
# Verificare se Rancher Backup è installato
sudo /usr/local/bin/kubectl get deployment -n cattle-resources-system rancher-backup

# Se installato, creare backup
cat <<EOF | sudo /usr/local/bin/kubectl apply -f -
apiVersion: resources.cattle.io/v1
kind: Backup
metadata:
  name: rancher-upgrade-backup
  namespace: cattle-resources-system
spec:
  resourceSetName: rancher-resource-set
  schedule: ""
  retentionCount: 3
EOF

# Verificare lo stato del backup
sudo /usr/local/bin/kubectl get backup -n cattle-resources-system
sudo /usr/local/bin/kubectl describe backup rancher-upgrade-backup -n cattle-resources-system
```

### 1.3 Installare Rancher Backup Operator (se non presente)

```bash
# Aggiungere repository Helm di Rancher
helm repo add rancher-charts https://charts.rancher.io
helm repo update

# Installare Rancher Backup Operator
helm install rancher-backup-crd rancher-charts/rancher-backup-crd \
  --namespace cattle-resources-system \
  --create-namespace

helm install rancher-backup rancher-charts/rancher-backup \
  --namespace cattle-resources-system

# Verificare installazione
sudo /usr/local/bin/kubectl get pods -n cattle-resources-system
```

### 1.4 Backup del Database K3s

```bash
# Lista snapshot etcd disponibili
sudo /usr/local/bin/k3s etcd-snapshot list

# Copia snapshot in location sicura
sudo cp /var/lib/rancher/k3s/server/db/snapshots/* ~/rancher-backups/$(date +%Y%m%d)/

# Backup completo directory K3s
sudo tar -czf ~/rancher-backups/$(date +%Y%m%d)/k3s-complete-backup.tar.gz \
  /etc/rancher/k3s \
  /var/lib/rancher/k3s/server/db/snapshots
```

### 1.5 Documentare Configurazione Attuale

```bash
# Salvare versione attuale
sudo /usr/local/bin/kubectl get deployment -n cattle-system rancher \
  -o jsonpath='{.spec.template.spec.containers[0].image}' > current-version.txt

# Salvare configurazione Helm (se installato con Helm)
helm get values rancher -n cattle-system > rancher-helm-values.yaml 2>/dev/null || echo "Not installed with Helm"

# Salvare configurazione Ingress
sudo /usr/local/bin/kubectl get ingress -n cattle-system -o yaml > rancher-ingress.yaml

# Salvare secrets importanti (ATTENZIONE: contiene dati sensibili)
sudo /usr/local/bin/kubectl get secret -n cattle-system bootstrap-secret -o yaml > bootstrap-secret.yaml 2>/dev/null
```

## Fase 2: Pre-upgrade Checks

### 2.1 Verificare Salute del Cluster

```bash
# Status dei nodi
sudo /usr/local/bin/kubectl get nodes

# Status dei pod Rancher
sudo /usr/local/bin/kubectl get pods -n cattle-system -l app=rancher

# Verificare risorse disponibili
sudo /usr/local/bin/kubectl top node 2>/dev/null || free -h

# Verificare certificati
sudo /usr/local/bin/kubectl get secret -n cattle-system tls-rancher-ingress -o jsonpath='{.data.tls\.crt}' | base64 -d | openssl x509 -noout -dates
```

### 2.2 Verificare Compatibilità

```bash
# Versione K3s
sudo /usr/local/bin/k3s --version

# Versione Helm (se usato)
helm version

# Cluster Kubernetes supportato da Rancher v2.11.8?
# K3s v1.32.3 ✅ Supportato
```

### 2.3 Test di Rollback (Opzionale)

```bash
# Verificare che possiamo fare rollback in caso di problemi
sudo /usr/local/bin/kubectl rollout history deployment/rancher -n cattle-system
```

## Fase 3: Upgrade Rancher

### Metodo A: Upgrade con Helm (Se installato con Helm)

```bash
# Aggiungere/aggiornare repository Rancher
helm repo add rancher-latest https://releases.rancher.com/server-charts/latest
helm repo update

# Verificare la chart disponibile
helm search repo rancher-latest/rancher --versions | head

# Upgrade a v2.11.8
helm upgrade rancher rancher-latest/rancher \
  --namespace cattle-system \
  --version 2.11.8 \
  --set hostname=rancher.savemosca.com \
  --set replicas=3 \
  --reuse-values

# Monitorare il rolling update
sudo /usr/local/bin/kubectl rollout status deployment/rancher -n cattle-system
```

### Metodo B: Upgrade Manuale del Deployment

Se Rancher non è stato installato con Helm:

```bash
# Aggiornare l'immagine del deployment
sudo /usr/local/bin/kubectl set image deployment/rancher \
  rancher=rancher/rancher:v2.11.8 \
  -n cattle-system

# Monitorare il rolling update
sudo /usr/local/bin/kubectl rollout status deployment/rancher -n cattle-system

# Verificare che i pod si riavviino correttamente
watch sudo /usr/local/bin/kubectl get pods -n cattle-system -l app=rancher
```

## Fase 4: Post-upgrade Verification

### 4.1 Verificare Deployment

```bash
# Verificare versione aggiornata
sudo /usr/local/bin/kubectl get deployment -n cattle-system rancher \
  -o jsonpath='{.spec.template.spec.containers[0].image}'
# Output atteso: rancher/rancher:v2.11.8

# Verificare che tutti i pod siano running
sudo /usr/local/bin/kubectl get pods -n cattle-system -l app=rancher

# Verificare logs per errori
sudo /usr/local/bin/kubectl logs -n cattle-system -l app=rancher --tail=50
```

### 4.2 Verificare Accesso Web UI

```bash
# Testare accesso HTTP
curl -k -I https://rancher.savemosca.com

# Verificare API
curl -k https://rancher.savemosca.com/v3
# Output atteso: {"type":"error","status":"401","message":"Unauthorized 401: must authenticate"}
```

Accedere a https://rancher.savemosca.com e verificare:
- [x] Login funziona
- [x] Dashboard carica correttamente
- [x] Cluster esistenti sono visibili
- [x] Nessun errore nel banner superiore

### 4.3 Verificare Funzionalità

```bash
# Verificare server-version setting
sudo /usr/local/bin/kubectl get setting server-version -o jsonpath='{.value}'
# Output atteso: v2.11.8

# Verificare fleet (se usato)
sudo /usr/local/bin/kubectl get pods -n cattle-fleet-system

# Verificare webhook
sudo /usr/local/bin/kubectl get validatingwebhookconfigurations | grep rancher
```

## Fase 5: Cleanup

```bash
# Rimuovere vecchi ReplicaSets
sudo /usr/local/bin/kubectl delete replicaset -n cattle-system \
  $(sudo /usr/local/bin/kubectl get rs -n cattle-system -o jsonpath='{.items[?(@.spec.replicas==0)].metadata.name}')

# Verificare spazio disco
df -h /var/lib/rancher
```

## Rollback Procedure (In caso di problemi)

### Rollback con Helm

```bash
# Verificare history
helm history rancher -n cattle-system

# Rollback all'ultima versione funzionante
helm rollback rancher -n cattle-system
```

### Rollback Manuale

```bash
# Rollback del deployment
sudo /usr/local/bin/kubectl rollout undo deployment/rancher -n cattle-system

# Oppure ripristina versione specifica
sudo /usr/local/bin/kubectl set image deployment/rancher \
  rancher=rancher/rancher:v2.11.0-hotfix-42a5.1 \
  -n cattle-system
```

### Rollback Completo da Backup

```bash
# Ripristinare snapshot etcd
sudo /usr/local/bin/k3s server \
  --cluster-reset \
  --cluster-reset-restore-path=/var/lib/rancher/k3s/server/db/snapshots/rancher-pre-upgrade-XXXXXX

# Riavviare K3s
sudo systemctl restart k3s
```

## Troubleshooting

### Problema: Pod in CrashLoopBackOff

```bash
# Controllare logs
sudo /usr/local/bin/kubectl logs -n cattle-system -l app=rancher --previous

# Verificare risorse
sudo /usr/local/bin/kubectl describe pod -n cattle-system -l app=rancher

# Verificare secret e configmap
sudo /usr/local/bin/kubectl get secrets,configmaps -n cattle-system
```

### Problema: Web UI non accessibile

```bash
# Verificare ingress
sudo /usr/local/bin/kubectl get ingress -n cattle-system
sudo /usr/local/bin/kubectl describe ingress -n cattle-system

# Verificare certificati
sudo /usr/local/bin/kubectl get secret -n cattle-system tls-rancher-ingress

# Testare servizio direttamente
sudo /usr/local/bin/kubectl port-forward -n cattle-system svc/rancher 8443:443
# Poi accedere a https://localhost:8443
```

### Problema: Database migration failed

```bash
# Verificare logs dettagliati
sudo /usr/local/bin/kubectl logs -n cattle-system deployment/rancher | grep -i migration

# Se necessario, ripristinare backup
# Seguire "Rollback Completo da Backup"
```

## Post-Upgrade: Upgrade a v2.12 o v2.13 (Opzionale)

Dopo aver verificato che v2.11.8 funziona correttamente, puoi procedere con upgrade a versioni successive:

```bash
# Creare nuovo backup prima di ogni upgrade
sudo /usr/local/bin/k3s etcd-snapshot save --name rancher-pre-v2.12-$(date +%Y%m%d-%H%M)

# Upgrade a v2.12.0
helm upgrade rancher rancher-latest/rancher \
  --namespace cattle-system \
  --version 2.12.0 \
  --reuse-values

# Verificare e poi procedere a v2.13.1
helm upgrade rancher rancher-latest/rancher \
  --namespace cattle-system \
  --version 2.13.1 \
  --reuse-values
```

## Riferimenti

- [Rancher v2.11.8 Release Notes](https://github.com/rancher/rancher/releases/tag/v2.11.8)
- [Rancher Upgrade Documentation](https://ranchermanager.docs.rancher.com/getting-started/installation-and-upgrade/install-upgrade-on-a-kubernetes-cluster/upgrades)
- [Rancher Backup Documentation](https://ranchermanager.docs.rancher.com/how-to-guides/new-user-guides/backup-restore-and-disaster-recovery)

## Next Steps

Dopo l'upgrade di Rancher, procedi con:
- [02-management-cluster-rancher.md](02-management-cluster-rancher.md) - Configurare CAPV su srv26 con Rancher
- [03-workload-cluster.md](03-workload-cluster.md) - Deploy del cluster Kubernetes workload
- [06-rancher-import.md](06-rancher-import.md) - Importare il cluster workload in Rancher
