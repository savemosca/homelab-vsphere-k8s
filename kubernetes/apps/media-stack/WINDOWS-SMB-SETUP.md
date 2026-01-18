# Configurazione Windows Server 2025 per SMB Media Storage

Guida per configurare le share SMB su **srv05.mosca.lan** (Windows Server 2025) per il media stack Kubernetes.

## Prerequisiti

- Windows Server 2025 installato su srv05.mosca.lan
- Accesso amministratore al server
- SMB abilitato (di default su Windows Server)

## 1. Creazione Utente Dedicato

Crea un utente Windows dedicato per Kubernetes:

```powershell
# Apri PowerShell come Amministratore

# Crea utente locale
$Password = ConvertTo-SecureString "YOUR_SECURE_PASSWORD" -AsPlainText -Force
New-LocalUser -Name "media-user" -Password $Password -FullName "Media Stack User" -Description "Kubernetes media stack service account"

# Imposta password che non scade mai
Set-LocalUser -Name "media-user" -PasswordNeverExpires $true
```

**IMPORTANTE**: Salva la password in un posto sicuro, ti servirà per il Secret Kubernetes.

## 2. Creazione Directory e Share SMB

### Opzione A: Drive Dedicato (Consigliato)

```powershell
# Crea directory sul drive dedicato (es. D:, E:, etc.)
New-Item -Path "D:\Media" -ItemType Directory -Force
New-Item -Path "D:\Media\Movies" -ItemType Directory -Force
New-Item -Path "D:\Media\TVShows" -ItemType Directory -Force
New-Item -Path "D:\Media\Music" -ItemType Directory -Force
New-Item -Path "D:\Media\Downloads" -ItemType Directory -Force

# Imposta permessi NTFS
$Acl = Get-Acl "D:\Media"
$AccessRule = New-Object System.Security.AccessControl.FileSystemAccessRule("media-user","FullControl","ContainerInherit,ObjectInherit","None","Allow")
$Acl.SetAccessRule($AccessRule)
Set-Acl "D:\Media" $Acl

# Crea SMB shares
New-SmbShare -Name "media-movies" -Path "D:\Media\Movies" -FullAccess "media-user" -Description "Kubernetes Movies Storage"
New-SmbShare -Name "media-tvshows" -Path "D:\Media\TVShows" -FullAccess "media-user" -Description "Kubernetes TV Shows Storage"
New-SmbShare -Name "media-music" -Path "D:\Media\Music" -FullAccess "media-user" -Description "Kubernetes Music Storage"
New-SmbShare -Name "media-downloads" -Path "D:\Media\Downloads" -FullAccess "media-user" -Description "Kubernetes Downloads Storage"
```

### Opzione B: Directory su C: (Solo per test)

```powershell
# Crea directory su C:
New-Item -Path "C:\Data\Media" -ItemType Directory -Force
New-Item -Path "C:\Data\Media\Movies" -ItemType Directory -Force
New-Item -Path "C:\Data\Media\TVShows" -ItemType Directory -Force
New-Item -Path "C:\Data\Media\Music" -ItemType Directory -Force
New-Item -Path "C:\Data\Media\Downloads" -ItemType Directory -Force

# Imposta permessi e crea share (come sopra, sostituendo il path)
```

## 3. Configurazione SMB per Performance

Abilita SMB 3.1.1 e ottimizzazioni:

```powershell
# Verifica versione SMB (deve essere 3.1.1)
Get-SmbServerConfiguration | Select EnableSMB1Protocol,EnableSMB2Protocol

# Disabilita SMB 1.0 (sicurezza)
Set-SmbServerConfiguration -EnableSMB1Protocol $false -Force

# Abilita SMB 3.1.1 features
Set-SmbServerConfiguration -EnableSMB2Protocol $true -Force
Set-SmbServerConfiguration -EncryptData $true -Force

# Ottimizzazioni performance
Set-SmbServerConfiguration -MaxChannelPerSession 32 -Force
Set-SmbServerConfiguration -MaxSessionPerConnection 32 -Force
Set-SmbServerConfiguration -MaxWorkItems 8192 -Force

# Abilita SMB Multichannel
Set-SmbServerConfiguration -EnableMultiChannel $true -Force
```

## 4. Configurazione Firewall

```powershell
# Verifica regole firewall SMB esistenti
Get-NetFirewallRule -DisplayGroup "File and Printer Sharing" | Select DisplayName,Enabled

# Abilita File and Printer Sharing se necessario
Enable-NetFirewallRule -DisplayGroup "File and Printer Sharing"

# Aggiungi regola specifica per subnet Kubernetes (es. 10.0.0.0/8)
New-NetFirewallRule -DisplayName "SMB for Kubernetes" `
    -Direction Inbound `
    -Protocol TCP `
    -LocalPort 445 `
    -RemoteAddress 10.0.0.0/8 `
    -Action Allow
```

## 5. Verifica Configurazione

```powershell
# Lista le share
Get-SmbShare | Where-Object Name -like "media-*" | Format-Table Name,Path,Description

# Verifica permessi
Get-SmbShareAccess -Name "media-movies"

# Testa connessione SMB da un client
# (Da un altro computer o dal cluster)
Test-NetConnection -ComputerName srv05.mosca.lan -Port 445

# Verifica sessioni SMB attive
Get-SmbSession
```

## 6. Monitoring e Performance

### Event Viewer
Monitora eventi SMB:
```
Applications and Services Logs → Microsoft → Windows → SMBServer
```

### Performance Counters
```powershell
# Monitora performance SMB
Get-Counter "\SMB Server Shares(*)\*"
```

### Ottimizzazioni Avanzate (Opzionale)

```powershell
# Abilita RDMA se hai hardware supportato (NIC con RDMA)
# Get-NetAdapterRdma
# Enable-NetAdapterRdma -Name "Ethernet"

# Disabilita caching lato server per dati streaming
Set-SmbShare -Name "media-movies" -CachingMode None
Set-SmbShare -Name "media-tvshows" -CachingMode None
Set-SmbShare -Name "media-music" -CachingMode None

# Downloads può beneficiare di caching
Set-SmbShare -Name "media-downloads" -CachingMode Manual
```

## 7. Backup e Disaster Recovery

### Shadow Copies (VSS)

```powershell
# Abilita shadow copies sul volume
vssadmin add shadowstorage /for=D: /on=D: /maxsize=50GB

# Crea snapshot schedule
$Action = New-ScheduledTaskAction -Execute "vssadmin" -Argument "create shadow /for=D:"
$Trigger = New-ScheduledTaskTrigger -Daily -At 2am
Register-ScheduledTask -TaskName "Media Shadow Copy" -Action $Action -Trigger $Trigger
```

## 8. Security Best Practices

```powershell
# Disabilita accesso guest
Set-SmbServerConfiguration -EnableGuestAccess $false -Force

# Richiedi signing SMB
Set-SmbServerConfiguration -RequireSecuritySignature $true -Force

# Abilita encryption per share sensibili
Set-SmbShare -Name "media-movies" -EncryptData $true
Set-SmbShare -Name "media-tvshows" -EncryptData $true
Set-SmbShare -Name "media-music" -EncryptData $true
Set-SmbShare -Name "media-downloads" -EncryptData $true
```

## 9. Troubleshooting

### Share non accessibili

```powershell
# Verifica share
Get-SmbShare -Name "media-*"

# Verifica permessi
Get-SmbShareAccess -Name "media-movies"

# Reset permessi
Grant-SmbShareAccess -Name "media-movies" -AccountName "media-user" -AccessRight Full -Force
```

### Performance Issues

```powershell
# Aumenta buffer SMB
Set-SmbServerConfiguration -MaxMpxCount 125 -Force

# Disabilita oplocks se hai problemi di lock
Set-SmbShare -Name "media-downloads" -FolderEnumerationMode Unrestricted
```

### Network Issues

```powershell
# Testa connettività
Test-NetConnection -ComputerName srv05.mosca.lan -Port 445

# Verifica DNS
Resolve-DnsName srv05.mosca.lan

# Flush SMB cache
Get-SmbConnection | Where-Object ServerName -eq "srv05.mosca.lan" | Close-SmbSession
```

## 10. Kubernetes Integration

Dopo aver configurato Windows Server, crea il Secret Kubernetes:

```bash
kubectl create secret generic smb-credentials \
  --from-literal=username=media-user \
  --from-literal=password=YOUR_SECURE_PASSWORD \
  -n media
```

Oppure modifica il file `shared-storage.yaml` con le credenziali corrette.

## Riepilogo Configurazione

| Share Name | Path | UNC Path | Permissions |
|------------|------|----------|-------------|
| media-movies | D:\Media\Movies | \\\\srv05.mosca.lan\media-movies | media-user: Full |
| media-tvshows | D:\Media\TVShows | \\\\srv05.mosca.lan\media-tvshows | media-user: Full |
| media-music | D:\Media\Music | \\\\srv05.mosca.lan\media-music | media-user: Full |
| media-downloads | D:\Media\Downloads | \\\\srv05.mosca.lan\media-downloads | media-user: Full |

## Note Importanti

1. **Encryption**: SMB 3.1.1 con encryption è abilitato per sicurezza
2. **Performance**: SMB Multichannel migliora throughput su reti multiple
3. **Permissions**: L'utente `media-user` ha Full Control su tutte le share
4. **UID/GID**: I container Linux usano UID 1000, i mount options gestiscono la mappatura
5. **Backup**: Considera di abilitare Windows Server Backup o Veeam per proteggere i dati

## Prossimi Passi

1. ✅ Configurare Windows Server 2025 (questa guida)
2. ⬜ Installare CSI driver SMB su Kubernetes
3. ⬜ Deploy dei manifest storage
4. ⬜ Deploy dello stack media
