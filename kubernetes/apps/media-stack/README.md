# Media Stack con Mullvad VPN

Stack completo per automazione media con protezione VPN Mullvad su Kubernetes.

## Componenti

### Download Clients (con VPN Mullvad)
- **qBittorrent** (porta 8080) - Client torrent con VPN
- **SABnzbd** (porta 8081) - Client Usenet con VPN

### Media Management (*arr stack)
- **Prowlarr** (porta 9696) - Indexer manager
- **Radarr** (porta 7878) - Gestione film
- **Sonarr** (porta 8989) - Gestione serie TV
- **Lidarr** (porta 8686) - Gestione musica
- **Readarr** (porta 8787) - Gestione ebook/audiolibri
- **Bazarr** (porta 6767) - Gestione sottotitoli

### Media Request & Monitoring
- **Overseerr** (porta 5055) - Sistema richieste media
- **Tautulli** (porta 8181) - Monitoring Plex/Jellyfin
- **Homarr** (porta 7575) - Dashboard centralizzata

### Retrogaming
- **Romm** (porta 8080) - ROM manager per retrogaming

## Prerequisiti

### 1. NFS Server (srv05.mosca.lan)

Creare le seguenti directory NFS sul server:

```bash
# Su srv05.mosca.lan
mkdir -p /mnt/data/media/{movies,tvshows,music,downloads}
chown -R 1000:1000 /mnt/data/media
chmod -R 755 /mnt/data/media

# Configurare /etc/exports
echo "/mnt/data/media/movies    *(rw,sync,no_subtree_check,no_root_squash)" >> /etc/exports
echo "/mnt/data/media/tvshows   *(rw,sync,no_subtree_check,no_root_squash)" >> /etc/exports
echo "/mnt/data/media/music     *(rw,sync,no_subtree_check,no_root_squash)" >> /etc/exports
echo "/mnt/data/media/downloads *(rw,sync,no_subtree_check,no_root_squash)" >> /etc/exports

exportfs -ra
```

### 2. Mullvad VPN Account

1. Crea un account su [https://mullvad.net](https://mullvad.net)
2. Ottieni il tuo **account number** (formato: 1234567890123456)
3. Il container Gluetun utilizzerà l'account number per generare automaticamente le chiavi Wireguard

## Installazione

### 0. Gestione Secrets (IMPORTANTE)

⚠️ **I file con credenziali reali NON devono essere committati su Git!**

Questo repository usa file template per i secret. Devi creare le tue copie locali:

```bash
cd kubernetes/apps/media-stack

# Copia i template
cp secrets/mullvad-vpn-secret.yaml.template secrets/mullvad-vpn-secret.yaml
cp secrets/smb-credentials-secret.yaml.template secrets/smb-credentials-secret.yaml
cp shared-storage.yaml.template shared-storage.yaml

# Modifica i file copiati con le tue credenziali
# I file *-secret.yaml e shared-storage.yaml sono in .gitignore
```

Oppure crea i secret direttamente con kubectl (raccomandato):

```bash
# Mullvad VPN secret
kubectl create secret generic mullvad-vpn \
  --from-literal=account-number=YOUR_MULLVAD_ACCOUNT_NUMBER \
  -n media

# SMB credentials secret
kubectl create secret generic smb-credentials \
  --from-literal=username=media-user \
  --from-literal=password=YourSecurePassword123! \
  -n media
```

Vedi [secrets/README.md](secrets/README.md) per maggiori dettagli.

### 1. Installa CSI Driver SMB

```bash
helm repo add csi-driver-smb https://raw.githubusercontent.com/kubernetes-csi/csi-driver-smb/master/charts
helm install csi-driver-smb csi-driver-smb/csi-driver-smb \
  --namespace kube-system \
  --version v1.15.0
```

### 2. Deploy dei Manifesti

```bash
# Deploy namespace e storage
kubectl apply -f namespace.yaml
kubectl apply -f shared-storage.yaml

# Verifica che i PV siano creati
kubectl get pv | grep nfs-media

# Deploy download clients con VPN
kubectl apply -f qbittorrent/deployment.yaml
kubectl apply -f sabnzbd/deployment.yaml

# Deploy *arr stack
kubectl apply -f prowlarr/deployment.yaml
kubectl apply -f radarr/deployment.yaml
kubectl apply -f sonarr/deployment.yaml
kubectl apply -f lidarr/deployment.yaml
kubectl apply -f readarr/deployment.yaml
kubectl apply -f bazarr/deployment.yaml

# Deploy media request & monitoring
kubectl apply -f overseerr/deployment.yaml
kubectl apply -f tautulli/deployment.yaml

# Deploy dashboard
kubectl apply -f homarr/deployment.yaml

# Deploy retrogaming
kubectl apply -f romm/deployment.yaml
```

### 3. Verifica Deployment

```bash
# Controlla tutti i pod
kubectl get pods -n media

# Verifica lo stato VPN di qBittorrent
kubectl logs -n media -l app=qbittorrent -c gluetun

# Verifica lo stato VPN di SABnzbd
kubectl logs -n media -l app=sabnzbd -c gluetun

# Controlla gli ingress
kubectl get ingress -n media
```

## Configurazione Post-Deploy

### 1. Verifica Connessione VPN

Accedi a qBittorrent e verifica che l'IP pubblico sia quello di Mullvad:

```bash
# Shell nel container qBittorrent
kubectl exec -n media -it deployment/qbittorrent -c gluetun -- sh

# Verifica IP pubblico
wget -qO- https://api.ipify.org
# Dovrebbe mostrare un IP svedese/olandese/italiano di Mullvad
```

### 2. Configurazione Prowlarr (Indexer Manager)

1. Accedi a [https://prowlarr.savemosca.com](https://prowlarr.savemosca.com)
2. Aggiungi indexer torrent e Usenet
3. Collega Prowlarr a Radarr, Sonarr, Lidarr, Readarr:
   - Settings → Apps → Add Application
   - Usa gli URL interni: `http://radarr:7878`, `http://sonarr:8989`, `http://lidarr:8686`, `http://readarr:8787`

### 3. Configurazione Download Clients

#### qBittorrent
1. Accedi a [https://qbittorrent.savemosca.com](https://qbittorrent.savemosca.com)
2. Credenziali default: `admin` / `adminadmin`
3. Cambia password in: Tools → Options → Web UI

#### SABnzbd
1. Accedi a [https://sabnzbd.savemosca.com](https://sabnzbd.savemosca.com)
2. Segui il wizard di configurazione
3. Aggiungi il tuo provider Usenet in Config → Servers

### 4. Configurazione *arr Apps

Per ogni app (Radarr, Sonarr, Lidarr, Readarr):

1. Settings → Download Clients → Add
   - **Torrent**: qBittorrent
     - Host: `qbittorrent`
     - Port: `8080`
     - Category: `movies` / `tv` / `music` / `books`
   - **Usenet**: SABnzbd
     - Host: `sabnzbd`
     - Port: `8081`
     - API Key: (dalla configurazione SABnzbd)

2. Settings → Media Management
   - Root Folder: `/movies` o `/tv` o `/music` o `/books`
   - Abilita "Rename Movies/Episodes" (o "Rename Books" per Readarr)

### 5. Configurazione Overseerr

1. Accedi a [https://overseerr.savemosca.com](https://overseerr.savemosca.com)
2. Collega a Plex o Jellyfin
3. Collega Radarr:
   - URL: `http://radarr:7878`
   - API Key: (da Radarr Settings → General)
4. Collega Sonarr:
   - URL: `http://sonarr:8989`
   - API Key: (da Sonarr Settings → General)

### 6. Configurazione Tautulli

1. Accedi a [https://tautulli.savemosca.com](https://tautulli.savemosca.com)
2. Collega al server Plex/Jellyfin
3. Configura notifiche e statistiche

### 7. Configurazione Homarr Dashboard

1. Accedi a [https://homarr.savemosca.com](https://homarr.savemosca.com)
2. Aggiungi widget per tutti i servizi:
   - qBittorrent: `http://qbittorrent:8080`
   - SABnzbd: `http://sabnzbd:8081`
   - Prowlarr: `http://prowlarr:9696`
   - Radarr: `http://radarr:7878`
   - Sonarr: `http://sonarr:8989`
   - Lidarr: `http://lidarr:8686`
   - Readarr: `http://readarr:8787`
   - Bazarr: `http://bazarr:6767`
   - Overseerr: `http://overseerr:5055`
   - Tautulli: `http://tautulli:8181`
   - Romm: `http://romm:8080`

### 8. Configurazione Romm

1. Accedi a [https://romm.savemosca.com](https://romm.savemosca.com)
2. Crea account amministratore al primo accesso
3. Organizza le ROM per piattaforma nella directory `/roms`:
   - `/roms/Nintendo/NES`
   - `/roms/Nintendo/SNES`
   - `/roms/Sega/Genesis`
   - `/roms/Sony/PlayStation`
4. Configura IGDB (opzionale) per metadata automatico:
   - Ottieni API key da [https://api.igdb.com](https://api.igdb.com)
   - Aggiungi Client ID e Secret nel ConfigMap `romm-config`

## URLs dei Servizi

Tutti i servizi sono esposti su **porta 443** tramite Traefik:

| Servizio | URL |
|----------|-----|
| Homarr Dashboard | https://homarr.savemosca.com |
| qBittorrent | https://qbittorrent.savemosca.com |
| SABnzbd | https://sabnzbd.savemosca.com |
| Prowlarr | https://prowlarr.savemosca.com |
| Radarr | https://radarr.savemosca.com |
| Sonarr | https://sonarr.savemosca.com |
| Lidarr | https://lidarr.savemosca.com |
| Readarr | https://readarr.savemosca.com |
| Bazarr | https://bazarr.savemosca.com |
| Overseerr | https://overseerr.savemosca.com |
| Tautulli | https://tautulli.savemosca.com |
| Romm | https://romm.savemosca.com |

## Troubleshooting

### VPN non si connette

```bash
# Verifica il secret
kubectl get secret mullvad-vpn -n media -o yaml

# Controlla i log di gluetun
kubectl logs -n media -l app=qbittorrent -c gluetun --tail=100

# Verifica che il firewall permetta traffico VPN
kubectl exec -n media deployment/qbittorrent -c gluetun -- ping 1.1.1.1
```

### Download non partono

1. Verifica connessione VPN
2. Controlla che qBittorrent/SABnzbd vedano la directory `/downloads`
3. Verifica permessi NFS (deve essere scrivibile da UID 1000)

### PVC non si binda

```bash
# Verifica che il server NFS sia raggiungibile
ping srv05.mosca.lan

# Testa mount NFS manualmente
showmount -e srv05.mosca.lan

# Verifica eventi PVC
kubectl describe pvc media-downloads -n media
```

### Prowlarr non comunica con le *arr apps

Usa sempre gli URL interni del cluster:
- `http://radarr:7878`
- `http://sonarr:8989`
- `http://lidarr:8686`

NON usare gli URL ingress esterni.

## Ottimizzazione

### Cambiare Server VPN Mullvad

Modifica il ConfigMap in `qbittorrent/deployment.yaml` e `sabnzbd/deployment.yaml`:

```yaml
SERVER_CITIES: "Milan"  # o Amsterdam, Stockholm, Frankfurt, etc.
```

Applica le modifiche:
```bash
kubectl apply -f qbittorrent/deployment.yaml
kubectl apply -f sabnzbd/deployment.yaml
kubectl rollout restart deployment/qbittorrent -n media
kubectl rollout restart deployment/sabnzbd -n media
```

### Aumentare Risorse

Modifica `resources` nei deployment per dare più CPU/memoria ai servizi che ne hanno bisogno.

### Backup Configurazioni

```bash
# Backup di tutte le config
kubectl get pvc -n media
# Crea snapshot o backup dei PVC config di ogni servizio
```

## Sicurezza

- Le credenziali VPN sono salvate in un Kubernetes Secret
- Tutto il traffico torrent/usenet passa attraverso la VPN Mullvad
- Gli ingress usano TLS con certificati Let's Encrypt
- Network Policy limita traffico in/out dal namespace media

## Note

- **Kill Switch**: Gluetun ha un kill switch integrato. Se la VPN si disconnette, qBittorrent e SABnzbd non avranno accesso a Internet
- **Port Forwarding**: Mullvad non supporta port forwarding. Per massimizzare velocità torrent, considera altri provider VPN se necessario
- **Split Tunneling**: Solo qBittorrent e SABnzbd usano la VPN. Le altre app accedono direttamente a Internet
