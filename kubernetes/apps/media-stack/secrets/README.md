# Secrets Management

Questa directory contiene i template per i Secret Kubernetes necessari al media stack.

## File Template Disponibili

- `mullvad-vpn-secret.yaml.template` - Credenziali VPN Mullvad
- `smb-credentials-secret.yaml.template` - Credenziali SMB Windows Server

## Come Usare i Template

### 1. Copia il Template

```bash
# Per Mullvad VPN
cp mullvad-vpn-secret.yaml.template mullvad-vpn-secret.yaml

# Per SMB credentials
cp smb-credentials-secret.yaml.template smb-credentials-secret.yaml
```

### 2. Modifica con le Tue Credenziali

Apri i file copiati e sostituisci i placeholder:

```yaml
# mullvad-vpn-secret.yaml
stringData:
  account-number: "1234567890123456"  # Il tuo account number Mullvad

# smb-credentials-secret.yaml
stringData:
  username: "media-user"
  password: "YourSecurePassword123!"
```

### 3. Applica i Secret

```bash
# Crea il namespace se non esiste
kubectl create namespace media

# Applica i secret
kubectl apply -f mullvad-vpn-secret.yaml
kubectl apply -f smb-credentials-secret.yaml

# Verifica
kubectl get secrets -n media
```

## Sicurezza

⚠️ **IMPORTANTE**: I file con credenziali reali (`*-secret.yaml` senza `.template`) sono automaticamente ignorati da Git tramite `.gitignore`.

**NON committare mai file con credenziali reali!**

## Alternative: Creazione Diretta via kubectl

Se preferisci non creare file YAML con credenziali:

### Mullvad VPN Secret

```bash
kubectl create secret generic mullvad-vpn \
  --from-literal=account-number=YOUR_MULLVAD_ACCOUNT_NUMBER \
  -n media
```

### SMB Credentials Secret

```bash
kubectl create secret generic smb-credentials \
  --from-literal=username=media-user \
  --from-literal=password=YourSecurePassword123! \
  -n media
```

## Rotazione Secrets

Per aggiornare un secret esistente:

```bash
# Metodo 1: Elimina e ricrea
kubectl delete secret mullvad-vpn -n media
kubectl create secret generic mullvad-vpn \
  --from-literal=account-number=NEW_ACCOUNT_NUMBER \
  -n media

# Metodo 2: Usa kubectl edit
kubectl edit secret mullvad-vpn -n media
```

Dopo aver aggiornato un secret, riavvia i pod che lo usano:

```bash
# Riavvia qBittorrent (usa Mullvad VPN)
kubectl rollout restart deployment/qbittorrent -n media

# Riavvia SABnzbd (usa Mullvad VPN)
kubectl rollout restart deployment/sabnzbd -n media

# Riavvia tutti i pod che usano SMB storage
kubectl rollout restart deployment -n media
```

## Backup Secrets (Encrypted)

Per backup sicuri, usa strumenti come:

- **Sealed Secrets** (Bitnami)
- **SOPS** (Mozilla)
- **External Secrets Operator**
- **Vault** (HashiCorp)

Esempio con SOPS:

```bash
# Installa SOPS
brew install sops

# Encrypt secret
sops -e mullvad-vpn-secret.yaml > mullvad-vpn-secret.enc.yaml

# Il file .enc.yaml può essere committato in Git
```

## Troubleshooting

### Secret non trovato

```bash
# Lista tutti i secret nel namespace
kubectl get secrets -n media

# Descrivi un secret specifico
kubectl describe secret mullvad-vpn -n media

# Visualizza il contenuto (decodificato)
kubectl get secret mullvad-vpn -n media -o jsonpath='{.data.account-number}' | base64 -d
```

### Pod non monta il secret

```bash
# Verifica eventi del pod
kubectl describe pod <pod-name> -n media

# Controlla i log
kubectl logs <pod-name> -n media
```
