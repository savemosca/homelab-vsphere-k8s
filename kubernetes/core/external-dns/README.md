# ExternalDNS + DDNS Configuration

Gestione automatica DNS split-horizon per savemosca.com:
- **Interno** (Windows DNS): risolve a IP MetalLB
- **Esterno** (Cloudflare): risolve a IP pubblico dinamico

## Architettura

```
┌─────────────────────────────────────────────────────────────────────┐
│                         CLOUDFLARE                                   │
│                                                                      │
│   home.savemosca.com        A     →  IP Pubblico (DDNS Updater)     │
│   radarr.savemosca.com    CNAME  →  home.savemosca.com (ExternalDNS)│
│   sonarr.savemosca.com    CNAME  →  home.savemosca.com (ExternalDNS)│
│   *.savemosca.com         CNAME  →  home.savemosca.com (ExternalDNS)│
└─────────────────────────────────────────────────────────────────────┘

┌─────────────────────────────────────────────────────────────────────┐
│                       WINDOWS DNS (AD)                               │
│                                                                      │
│   ingress.savemosca.com     A     →  192.168.14.10 (MetalLB, fisso) │
│   radarr.savemosca.com    CNAME  →  ingress.savemosca.com (ExtDNS)  │
│   sonarr.savemosca.com    CNAME  →  ingress.savemosca.com (ExtDNS)  │
└─────────────────────────────────────────────────────────────────────┘
```

## Componenti

### 1. DDNS Updater
Container che rileva l'IP pubblico e aggiorna il record A `home.savemosca.com` su Cloudflare.

- **Immagine**: `qmcgaw/ddns-updater`
- **Frequenza**: ogni 5 minuti
- **Configurazione**: API Token Cloudflare

### 2. ExternalDNS (Cloudflare)
Sincronizza gli Ingress Kubernetes con Cloudflare, creando CNAME verso `home.savemosca.com`.

- **Immagine**: `registry.k8s.io/external-dns/external-dns`
- **Provider**: Cloudflare
- **Policy**: sync (crea e rimuove record)

### 3. ExternalDNS (Windows DNS)
Sincronizza gli Ingress Kubernetes con Windows DNS via RFC2136/GSS-TSIG.

- **Provider**: rfc2136
- **Autenticazione**: GSS-TSIG (Kerberos) o TSIG key
- **Target**: CNAME verso `ingress.savemosca.com`

## Flusso di Risoluzione

### Client Interno (LAN)
```
radarr.savemosca.com
    → Windows DNS
    → CNAME ingress.savemosca.com
    → A 192.168.14.10
    → NGINX Ingress
    → Pod Radarr
```

### Client Esterno (Internet)
```
radarr.savemosca.com
    → Cloudflare
    → CNAME home.savemosca.com
    → A [IP Pubblico]
    → Router NAT
    → 192.168.14.10
    → NGINX Ingress
    → Pod Radarr
```

## Prerequisiti

### Cloudflare
1. API Token con permessi:
   - Zone:DNS:Edit
   - Zone:Zone:Read
2. Zone ID di savemosca.com

### Windows DNS
1. Zona savemosca.com configurata
2. Record A fisso: `ingress.savemosca.com → [IP MetalLB Ingress]`
3. Dynamic Updates abilitati (Secure only per AD-integrated)
4. Account AD con permessi di modifica sulla zona, oppure TSIG key

### Router
1. Port forwarding 80/443 verso IP MetalLB Ingress (192.168.14.x)

## Configurazione

### Secrets richiesti

```bash
# Cloudflare
kubectl create secret generic cloudflare-credentials \
  --from-literal=api-token=YOUR_CLOUDFLARE_API_TOKEN \
  -n external-dns

# Windows DNS (se usi TSIG invece di GSS-TSIG)
kubectl create secret generic windows-dns-credentials \
  --from-literal=tsig-secret=YOUR_TSIG_SECRET \
  -n external-dns
```

### Deploy

```bash
kubectl apply -k kubernetes/core/external-dns/
```

## File Structure

```
external-dns/
├── README.md                      # Questa documentazione
├── kustomization.yaml
├── namespace.yaml
├── ddns-updater/
│   ├── deployment.yaml
│   ├── configmap.yaml
│   └── secret.yaml.template
├── cloudflare/
│   ├── deployment.yaml
│   ├── clusterrole.yaml
│   └── secret.yaml.template
└── windows-dns/
    ├── deployment.yaml
    ├── clusterrole.yaml
    └── secret.yaml.template
```

## Annotazioni Ingress

Per far gestire un Ingress da ExternalDNS, aggiungi:

```yaml
metadata:
  annotations:
    external-dns.alpha.kubernetes.io/hostname: radarr.savemosca.com
    # Opzionale: escludere da un provider
    # external-dns.alpha.kubernetes.io/exclude: "true"
```

## Troubleshooting

```bash
# Logs DDNS Updater
kubectl logs -n external-dns -l app=ddns-updater

# Logs ExternalDNS Cloudflare
kubectl logs -n external-dns -l app=external-dns-cloudflare

# Logs ExternalDNS Windows DNS
kubectl logs -n external-dns -l app=external-dns-windows

# Verifica record Cloudflare
curl -X GET "https://api.cloudflare.com/client/v4/zones/ZONE_ID/dns_records" \
  -H "Authorization: Bearer API_TOKEN"

# Verifica record Windows DNS
nslookup radarr.savemosca.com [WINDOWS_DNS_IP]
```

## Credenziali Richieste

Prima di deployare, fornire:

| Credenziale | Uso | Dove ottenerla |
|-------------|-----|----------------|
| Cloudflare API Token | DDNS + ExternalDNS | Cloudflare Dashboard → API Tokens |
| Cloudflare Zone ID | Identificare la zona | Cloudflare Dashboard → savemosca.com → Overview |
| Windows DNS Server IP | ExternalDNS RFC2136 | IP del Domain Controller |
| Account AD / TSIG Key | Autenticazione DNS update | AD o configurazione manuale |
