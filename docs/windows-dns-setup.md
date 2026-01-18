# Configurazione DNS Windows Server per Kubernetes

Guida per configurare Windows Server DNS per risolvere i servizi Kubernetes esposti via Ingress.

## Architettura

```
Client → Windows DNS Server → Record A → IP MetalLB (Nginx Ingress)
                                              ↓
                                         Nginx Ingress
                                              ↓
                                         Service K8s
```

## Prerequisiti

- Windows Server con ruolo DNS installato
- IP statico per Nginx Ingress (via MetalLB)
- Accesso amministrativo al DNS Server

## Configurazione Manuale

### 1. Ottenere IP del Nginx Ingress

```bash
kubectl get svc -n ingress-nginx
# Nota l'EXTERNAL-IP del servizio ingress-nginx-controller
```

### 2. Creare Zona DNS (se non esiste)

```powershell
# PowerShell come Amministratore
Add-DnsServerPrimaryZone -Name "savemosca.com" -ZoneFile "savemosca.com.dns"
```

### 3. Aggiungere Record A per ogni servizio

```powershell
# Sostituisci 192.168.1.100 con l'IP del tuo Nginx Ingress
$IngressIP = "192.168.1.100"

# Media Stack
Add-DnsServerResourceRecordA -ZoneName "savemosca.com" -Name "sonarr" -IPv4Address $IngressIP
Add-DnsServerResourceRecordA -ZoneName "savemosca.com" -Name "radarr" -IPv4Address $IngressIP
Add-DnsServerResourceRecordA -ZoneName "savemosca.com" -Name "lidarr" -IPv4Address $IngressIP
Add-DnsServerResourceRecordA -ZoneName "savemosca.com" -Name "prowlarr" -IPv4Address $IngressIP
Add-DnsServerResourceRecordA -ZoneName "savemosca.com" -Name "bazarr" -IPv4Address $IngressIP
Add-DnsServerResourceRecordA -ZoneName "savemosca.com" -Name "readarr" -IPv4Address $IngressIP
Add-DnsServerResourceRecordA -ZoneName "savemosca.com" -Name "overseerr" -IPv4Address $IngressIP
Add-DnsServerResourceRecordA -ZoneName "savemosca.com" -Name "tautulli" -IPv4Address $IngressIP
Add-DnsServerResourceRecordA -ZoneName "savemosca.com" -Name "qbittorrent" -IPv4Address $IngressIP
Add-DnsServerResourceRecordA -ZoneName "savemosca.com" -Name "sabnzbd" -IPv4Address $IngressIP
Add-DnsServerResourceRecordA -ZoneName "savemosca.com" -Name "homarr" -IPv4Address $IngressIP
Add-DnsServerResourceRecordA -ZoneName "savemosca.com" -Name "huntarr" -IPv4Address $IngressIP
Add-DnsServerResourceRecordA -ZoneName "savemosca.com" -Name "romm" -IPv4Address $IngressIP

# AdGuard (se usi dominio diverso)
Add-DnsServerResourceRecordA -ZoneName "savemosca.com" -Name "adguard" -IPv4Address $IngressIP
```

### 4. Verificare i Record

```powershell
Get-DnsServerResourceRecord -ZoneName "savemosca.com" -RRType A
```

---

## Automazione

### Opzione 1: ExternalDNS (Consigliata)

ExternalDNS sincronizza automaticamente gli Ingress Kubernetes con Windows DNS.

**Requisiti:**
- Windows Server 2016+ con DNS
- Credenziali per RFC2136 (Dynamic DNS) o accesso WMI

**Nota:** ExternalDNS supporta Windows DNS tramite provider `rfc2136`. Richiede configurazione TSIG sul server DNS.

### Opzione 2: Script PowerShell Schedulato

Script che legge gli Ingress e aggiorna DNS automaticamente.

Vedi: `scripts/sync-dns-windows.ps1`

### Opzione 3: Webhook + PowerShell

Kubernetes Ingress event → Webhook → Script PowerShell → DNS Update

---

## Script di Sincronizzazione

Salva come `sync-dns-windows.ps1` sul Windows DNS Server:

```powershell
# sync-dns-windows.ps1
# Sincronizza record DNS da Kubernetes Ingress
# Eseguire come Task Schedulato ogni 5-10 minuti

param(
    [string]$KubeconfigPath = "$env:USERPROFILE\.kube\config",
    [string]$ZoneName = "savemosca.com",
    [string]$IngressIP = "192.168.1.100"
)

# Richiede kubectl installato
$Ingresses = kubectl get ingress -A -o json | ConvertFrom-Json

foreach ($ing in $Ingresses.items) {
    foreach ($rule in $ing.spec.rules) {
        $hostname = $rule.host

        if ($hostname -like "*.$ZoneName") {
            $recordName = $hostname.Replace(".$ZoneName", "")

            # Verifica se il record esiste
            $existing = Get-DnsServerResourceRecord -ZoneName $ZoneName -Name $recordName -ErrorAction SilentlyContinue

            if (-not $existing) {
                Write-Host "Adding DNS record: $recordName -> $IngressIP"
                Add-DnsServerResourceRecordA -ZoneName $ZoneName -Name $recordName -IPv4Address $IngressIP
            }
        }
    }
}

Write-Host "DNS sync completed at $(Get-Date)"
```

### Configurare Task Schedulato

```powershell
# Crea task schedulato per eseguire ogni 10 minuti
$Action = New-ScheduledTaskAction -Execute "PowerShell.exe" -Argument "-File C:\Scripts\sync-dns-windows.ps1"
$Trigger = New-ScheduledTaskTrigger -RepetitionInterval (New-TimeSpan -Minutes 10) -At "00:00" -Daily
$Principal = New-ScheduledTaskPrincipal -UserId "SYSTEM" -LogonType ServiceAccount -RunLevel Highest

Register-ScheduledTask -TaskName "K8s-DNS-Sync" -Action $Action -Trigger $Trigger -Principal $Principal
```

---

## Split-Brain DNS (Interno vs Esterno)

Se usi lo stesso dominio internamente ed esternamente:

### Scenario
- **Esterno (Internet):** savemosca.com → IP Pubblico (Cloudflare)
- **Interno (LAN):** savemosca.com → IP MetalLB (Windows DNS)

### Configurazione

1. **Windows DNS:** Crea zona autoritativa per `savemosca.com`
2. **Conditional Forwarder:** Per tutto il resto, inoltra a Cloudflare/pubblico
3. **Client LAN:** Usano Windows DNS come resolver

```powershell
# Imposta forwarder per domini non locali
Add-DnsServerForwarder -IPAddress 1.1.1.1, 8.8.8.8
```

---

## Troubleshooting

### Verificare risoluzione

```powershell
# Dal client
nslookup sonarr.savemosca.com <IP-DNS-SERVER>

# Dal DNS server
Resolve-DnsName sonarr.savemosca.com -Server localhost
```

### Pulire cache DNS

```powershell
# Sul DNS Server
Clear-DnsServerCache

# Sul client
ipconfig /flushdns
```

### Verificare zone

```powershell
Get-DnsServerZone
Get-DnsServerResourceRecord -ZoneName "savemosca.com"
```
