# ExternalDNS con Windows DNS Server

Sincronizzazione automatica dei record DNS da Kubernetes Ingress a Windows DNS Server usando RFC2136 (Dynamic DNS).

## Come funziona

```
Ingress creato/modificato
        ↓
ExternalDNS (in cluster)
        ↓
RFC2136 update (TSIG auth)
        ↓
Windows DNS Server
        ↓
Record A creato/aggiornato
```

## Prerequisiti

- Windows Server 2016+ con ruolo DNS
- Kubernetes cluster con Ingress controller
- Connettività TCP/53 dal cluster al DNS server

## Configurazione Windows DNS Server

### 1. Abilita Dynamic Updates

```powershell
# PowerShell come Administrator
Set-DnsServerPrimaryZone -Name "savemosca.com" -DynamicUpdate "Secure"
```

### 2. Genera chiave TSIG

```powershell
# Genera chiave random
$tsigKey = [Convert]::ToBase64String((1..32 | ForEach-Object { Get-Random -Maximum 256 }))
Write-Host "Salva questa chiave: $tsigKey"

# Registra la chiave sul DNS server
dnscmd /TsigAdd externaldns-key hmac-sha256. $tsigKey
```

### 3. Configura Firewall

```powershell
New-NetFirewallRule -DisplayName "DNS Dynamic Update (TCP)" `
    -Direction Inbound -Protocol TCP -LocalPort 53 -Action Allow
```

## Configurazione Kubernetes

### 1. Modifica external-dns.yaml

Aggiorna questi valori:

| Parametro | Valore | Descrizione |
|-----------|--------|-------------|
| `--rfc2136-host` | IP del DNS Server | Es. 192.168.1.10 |
| `--rfc2136-zone` | Nome zona | Es. savemosca.com |
| `--domain-filter` | Dominio da gestire | Es. savemosca.com |
| `tsig-secret` | Chiave TSIG | Da Step 2 sopra |

### 2. Deploy

```bash
kubectl apply -f external-dns.yaml
```

### 3. Verifica

```bash
# Log ExternalDNS
kubectl logs -n external-dns -l app=external-dns -f

# Verifica record creati su Windows
Get-DnsServerResourceRecord -ZoneName "savemosca.com" -RRType A
```

## Come usare

Aggiungi annotation agli Ingress per controllare il comportamento:

```yaml
apiVersion: networking.k8s.io/v1
kind: Ingress
metadata:
  name: myapp
  annotations:
    # ExternalDNS legge automaticamente spec.rules[].host
    # Opzionale: forza TTL specifico
    external-dns.alpha.kubernetes.io/ttl: "300"
spec:
  rules:
    - host: myapp.savemosca.com  # Record A creato automaticamente
```

## Record TXT di ownership

ExternalDNS crea record TXT per tracciare quali record gestisce:

```
externaldns-myapp.savemosca.com TXT "heritage=external-dns,external-dns/owner=k8s-cluster"
```

Questo previene conflitti se gestisci anche record manuali.

## Troubleshooting

### ExternalDNS non crea record

```bash
# Verifica logs
kubectl logs -n external-dns deployment/external-dns

# Errori comuni:
# - "TSIG error" → chiave non corrisponde
# - "connection refused" → firewall blocca TCP/53
# - "not authorized" → Dynamic Updates non abilitato sulla zona
```

### Test connettività

```bash
# Dal cluster, verifica raggiungibilità DNS server
kubectl run -it --rm debug --image=busybox -- nslookup savemosca.com 192.168.1.10
```

### Test TSIG manuale

```bash
# Installa nsupdate per test
kubectl run -it --rm debug --image=alpine -- sh
apk add bind-tools

# Test update
nsupdate -v << EOF
server 192.168.1.10
zone savemosca.com
update add test.savemosca.com 300 A 1.2.3.4
send
EOF
```

## Alternativa: Active Directory Integrated DNS

Se il DNS è AD-integrated, puoi usare Kerberos invece di TSIG:

1. Crea un service account in AD per ExternalDNS
2. Genera keytab
3. Usa `--rfc2136-gss-tsig` invece di TSIG

Questo è più complesso ma si integra meglio con AD.

## Policy

| Policy | Comportamento |
|--------|---------------|
| `sync` | Crea e rimuove record (default) |
| `upsert-only` | Solo crea/aggiorna, non rimuove |

Per sicurezza iniziale, usa `--policy=upsert-only` e passa a `sync` dopo aver verificato il funzionamento.
