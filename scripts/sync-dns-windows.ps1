<#
.SYNOPSIS
    Sincronizza record DNS Windows Server con Kubernetes Ingress
.DESCRIPTION
    Legge tutti gli Ingress dal cluster Kubernetes e crea/aggiorna
    i record DNS A corrispondenti su Windows DNS Server.
.PARAMETER ZoneName
    Nome della zona DNS (es. savemosca.com)
.PARAMETER IngressIP
    IP del LoadBalancer Nginx Ingress
.PARAMETER KubeconfigPath
    Path al file kubeconfig (default: ~/.kube/config)
.PARAMETER DryRun
    Se specificato, mostra cosa farebbe senza applicare modifiche
.EXAMPLE
    .\sync-dns-windows.ps1 -ZoneName "savemosca.com" -IngressIP "192.168.1.100"
.EXAMPLE
    .\sync-dns-windows.ps1 -ZoneName "savemosca.com" -IngressIP "192.168.1.100" -DryRun
.NOTES
    Richiede:
    - PowerShell 5.1+
    - Modulo DnsServer (RSAT o Windows Server)
    - kubectl configurato con accesso al cluster
#>

param(
    [Parameter(Mandatory=$true)]
    [string]$ZoneName,

    [Parameter(Mandatory=$true)]
    [string]$IngressIP,

    [string]$KubeconfigPath = "$env:USERPROFILE\.kube\config",

    [switch]$DryRun,

    [switch]$RemoveStale
)

$ErrorActionPreference = "Stop"
$LogFile = "$PSScriptRoot\dns-sync.log"

function Write-Log {
    param([string]$Message)
    $timestamp = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
    $logMessage = "[$timestamp] $Message"
    Write-Host $logMessage
    Add-Content -Path $LogFile -Value $logMessage
}

function Get-KubernetesIngresses {
    try {
        $env:KUBECONFIG = $KubeconfigPath
        $json = kubectl get ingress -A -o json 2>&1
        if ($LASTEXITCODE -ne 0) {
            throw "kubectl failed: $json"
        }
        return ($json | ConvertFrom-Json).items
    }
    catch {
        Write-Log "ERROR: Failed to get Ingresses: $_"
        throw
    }
}

function Get-CurrentDnsRecords {
    param([string]$Zone)
    try {
        return Get-DnsServerResourceRecord -ZoneName $Zone -RRType A -ErrorAction SilentlyContinue
    }
    catch {
        Write-Log "ERROR: Failed to get DNS records: $_"
        return @()
    }
}

function Add-IngressDnsRecord {
    param(
        [string]$Zone,
        [string]$Name,
        [string]$IP
    )

    if ($DryRun) {
        Write-Log "DRY-RUN: Would add $Name.$Zone -> $IP"
        return
    }

    try {
        Add-DnsServerResourceRecordA -ZoneName $Zone -Name $Name -IPv4Address $IP -ErrorAction Stop
        Write-Log "ADDED: $Name.$Zone -> $IP"
    }
    catch {
        if ($_.Exception.Message -like "*already exists*") {
            Write-Log "EXISTS: $Name.$Zone (skipping)"
        }
        else {
            Write-Log "ERROR: Failed to add $Name.$Zone - $_"
        }
    }
}

function Update-IngressDnsRecord {
    param(
        [string]$Zone,
        [string]$Name,
        [string]$NewIP,
        [string]$OldIP
    )

    if ($DryRun) {
        Write-Log "DRY-RUN: Would update $Name.$Zone from $OldIP to $NewIP"
        return
    }

    try {
        $old = Get-DnsServerResourceRecord -ZoneName $Zone -Name $Name -RRType A
        $new = $old.Clone()
        $new.RecordData.IPv4Address = [System.Net.IPAddress]::Parse($NewIP)
        Set-DnsServerResourceRecord -ZoneName $Zone -OldInputObject $old -NewInputObject $new
        Write-Log "UPDATED: $Name.$Zone from $OldIP to $NewIP"
    }
    catch {
        Write-Log "ERROR: Failed to update $Name.$Zone - $_"
    }
}

function Remove-StaleDnsRecord {
    param(
        [string]$Zone,
        [string]$Name
    )

    if ($DryRun) {
        Write-Log "DRY-RUN: Would remove stale record $Name.$Zone"
        return
    }

    try {
        Remove-DnsServerResourceRecord -ZoneName $Zone -Name $Name -RRType A -Force
        Write-Log "REMOVED: $Name.$Zone (stale)"
    }
    catch {
        Write-Log "ERROR: Failed to remove $Name.$Zone - $_"
    }
}

# Main
Write-Log "========== DNS Sync Started =========="
Write-Log "Zone: $ZoneName, Ingress IP: $IngressIP"

# Get Ingresses from Kubernetes
$ingresses = Get-KubernetesIngresses
$ingressHosts = @{}

foreach ($ing in $ingresses) {
    foreach ($rule in $ing.spec.rules) {
        $hostname = $rule.host
        if ($hostname -like "*.$ZoneName") {
            $recordName = $hostname.Replace(".$ZoneName", "")
            $ingressHosts[$recordName] = $true
            Write-Log "Found Ingress: $hostname"
        }
    }
}

Write-Log "Total Ingress hosts for $ZoneName`: $($ingressHosts.Count)"

# Get current DNS records
$currentRecords = Get-CurrentDnsRecords -Zone $ZoneName
$currentNames = @{}
foreach ($rec in $currentRecords) {
    if ($rec.HostName -ne "@" -and $rec.HostName -ne $ZoneName) {
        $currentNames[$rec.HostName] = $rec.RecordData.IPv4Address.ToString()
    }
}

# Add/Update records
foreach ($name in $ingressHosts.Keys) {
    if ($currentNames.ContainsKey($name)) {
        $currentIP = $currentNames[$name]
        if ($currentIP -ne $IngressIP) {
            Update-IngressDnsRecord -Zone $ZoneName -Name $name -NewIP $IngressIP -OldIP $currentIP
        }
        else {
            Write-Log "OK: $name.$ZoneName -> $IngressIP"
        }
    }
    else {
        Add-IngressDnsRecord -Zone $ZoneName -Name $name -IP $IngressIP
    }
}

# Remove stale records (optional)
if ($RemoveStale) {
    foreach ($name in $currentNames.Keys) {
        if (-not $ingressHosts.ContainsKey($name)) {
            # Solo se l'IP corrisponde a IngressIP (per non toccare altri record)
            if ($currentNames[$name] -eq $IngressIP) {
                Remove-StaleDnsRecord -Zone $ZoneName -Name $name
            }
        }
    }
}

Write-Log "========== DNS Sync Completed =========="
