#Requires -Modules VMware.PowerCLI

<#
.SYNOPSIS
    Importa automaticamente i template VM (Flatcar Stable e Ubuntu Server LTS) in vSphere Content Library

.DESCRIPTION
    - Scarica l'ultima versione stabile di Flatcar Container Linux OVA
    - Scarica l'ultima versione LTS di Ubuntu Server Cloud Image OVA
    - Importa entrambi nella Content Library specificata

.PARAMETER vCenterServer
    Hostname o IP del vCenter Server

.PARAMETER ContentLibrary
    Nome della Content Library dove importare i template

.PARAMETER Credential
    PSCredential per l'autenticazione a vCenter (opzionale, richiede interattivo se non fornito)

.EXAMPLE
    ./import-vm-templates.ps1 -vCenterServer srv02.mosca.lan -ContentLibrary cnt-lbr-esxi01

.EXAMPLE
    $cred = Get-Credential
    ./import-vm-templates.ps1 -vCenterServer srv02.mosca.lan -ContentLibrary cnt-lbr-esxi01 -Credential $cred
#>

param(
    [Parameter(Mandatory = $true)]
    [string]$vCenterServer,

    [Parameter(Mandatory = $true)]
    [string]$ContentLibrary,

    [Parameter(Mandatory = $false)]
    [PSCredential]$Credential,

    [Parameter(Mandatory = $false)]
    [string]$DownloadPath = "",

    [Parameter(Mandatory = $false)]
    [switch]$FlatcarOnly,

    [Parameter(Mandatory = $false)]
    [switch]$UbuntuOnly,

    [Parameter(Mandatory = $false)]
    [switch]$PhotonOnly
)

$ErrorActionPreference = "Stop"

# URLs per i template
$FlatcarBaseUrl = "https://stable.release.flatcar-linux.net/amd64-usr/current"
$FlatcarOvaName = "flatcar_production_vmware_ova.ova"

# Ubuntu Cloud Images - 24.04 LTS (Noble Numbat)
$UbuntuBaseUrl = "https://cloud-images.ubuntu.com/noble/current"
$UbuntuOvaName = "noble-server-cloudimg-amd64.ova"

# VMware Photon OS 5.0 (Hardware Version 15)
$PhotonUrl = "https://packages.vmware.com/photon/5.0/GA/ova/photon-hw15-5.0-dde71ec57.x86_64.ova"
$PhotonOvaName = "photon-hw15-5.0-dde71ec57.x86_64.ova"

function Write-Log {
    param([string]$Message, [string]$Level = "INFO")
    $timestamp = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
    $color = switch ($Level) {
        "INFO" { "White" }
        "SUCCESS" { "Green" }
        "WARN" { "Yellow" }
        "ERROR" { "Red" }
    }
    Write-Host "[$timestamp] [$Level] $Message" -ForegroundColor $color
}

function Get-LatestFlatcarVersion {
    Write-Log "Recupero versione Flatcar Stable..."
    $versionUrl = "$FlatcarBaseUrl/version.txt"
    try {
        $versionContent = Invoke-WebRequest -Uri $versionUrl -UseBasicParsing
        $version = ($versionContent.Content -split "`n" | Where-Object { $_ -match "FLATCAR_VERSION=" }) -replace "FLATCAR_VERSION=", ""
        Write-Log "Flatcar Stable version: $version" -Level SUCCESS
        return $version.Trim()
    }
    catch {
        Write-Log "Impossibile recuperare versione Flatcar: $_" -Level ERROR
        return "unknown"
    }
}

function Download-Template {
    param(
        [string]$Url,
        [string]$OutputPath,
        [string]$Name
    )

    if (Test-Path $OutputPath) {
        Write-Log "$Name già presente in cache: $OutputPath" -Level WARN
        return $OutputPath
    }

    Write-Log "Download $Name da $Url..."
    Write-Log "Questo potrebbe richiedere diversi minuti..."

    try {
        # Usa BITS se disponibile (Windows), altrimenti Invoke-WebRequest
        if ($PSVersionTable.PSEdition -eq "Desktop" -or $IsWindows) {
            Start-BitsTransfer -Source $Url -Destination $OutputPath -Description "Downloading $Name"
        }
        else {
            Invoke-WebRequest -Uri $Url -OutFile $OutputPath -UseBasicParsing
        }
        Write-Log "Download completato: $OutputPath" -Level SUCCESS
        return $OutputPath
    }
    catch {
        Write-Log "Errore download: $_" -Level ERROR
        throw
    }
}

function Import-ToContentLibrary {
    param(
        [string]$OvaPath,
        [string]$LibraryName,
        [string]$ItemName
    )

    Write-Log "Importazione $ItemName in Content Library '$LibraryName'..."

    # Verifica se l'item esiste già
    $library = Get-ContentLibrary -Name $LibraryName
    $existingItem = Get-ContentLibraryItem -ContentLibrary $library -Name $ItemName -ErrorAction SilentlyContinue

    if ($existingItem) {
        Write-Log "Item '$ItemName' già presente. Rimuovo per aggiornare..." -Level WARN
        Remove-ContentLibraryItem -ContentLibraryItem $existingItem -Confirm:$false
    }

    # Importa OVA
    try {
        $item = New-ContentLibraryItem -ContentLibrary $library -Name $ItemName -Files $OvaPath
        Write-Log "Importazione completata: $ItemName" -Level SUCCESS
        return $item
    }
    catch {
        Write-Log "Errore importazione: $_" -Level ERROR
        throw
    }
}

# Main
Write-Log "=== Import VM Templates to vSphere ===" -Level INFO
Write-Log ""

# Imposta directory download
if ([string]::IsNullOrEmpty($DownloadPath)) {
    if ($IsWindows -or $PSVersionTable.PSEdition -eq "Desktop") {
        $DownloadPath = Join-Path $env:TEMP "vm-templates"
    } else {
        # macOS/Linux
        $DownloadPath = Join-Path $HOME ".cache/vm-templates"
    }
}

# Crea directory download
if (-not (Test-Path $DownloadPath)) {
    New-Item -ItemType Directory -Path $DownloadPath -Force | Out-Null
    Write-Log "Directory download creata: $DownloadPath" -Level INFO
}

# Connessione a vCenter
Write-Log "Connessione a vCenter: $vCenterServer"
Set-PowerCLIConfiguration -InvalidCertificateAction Ignore -Confirm:$false | Out-Null

if ($Credential) {
    Connect-VIServer -Server $vCenterServer -Credential $Credential | Out-Null
}
else {
    Connect-VIServer -Server $vCenterServer | Out-Null
}
Write-Log "Connesso a vCenter" -Level SUCCESS

# Verifica Content Library
$library = Get-ContentLibrary -Name $ContentLibrary -ErrorAction SilentlyContinue
if (-not $library) {
    Write-Log "Content Library '$ContentLibrary' non trovata!" -Level ERROR
    Disconnect-VIServer -Confirm:$false
    exit 1
}
Write-Log "Content Library trovata: $ContentLibrary" -Level SUCCESS

try {
    # Import Flatcar
    if (-not $UbuntuOnly -and -not $PhotonOnly) {
        Write-Log ""
        Write-Log "=== Flatcar Container Linux (Stable) ===" -Level INFO

        $flatcarVersion = Get-LatestFlatcarVersion
        $flatcarUrl = "$FlatcarBaseUrl/$FlatcarOvaName"
        $flatcarLocalPath = Join-Path $DownloadPath "flatcar-stable-$flatcarVersion.ova"

        Download-Template -Url $flatcarUrl -OutputPath $flatcarLocalPath -Name "Flatcar $flatcarVersion"
        Import-ToContentLibrary -OvaPath $flatcarLocalPath -LibraryName $ContentLibrary -ItemName "flatcar-stable-$flatcarVersion"
    }

    # Import Ubuntu
    if (-not $FlatcarOnly -and -not $PhotonOnly) {
        Write-Log ""
        Write-Log "=== Ubuntu Server 24.04 LTS (Noble) ===" -Level INFO

        $ubuntuUrl = "$UbuntuBaseUrl/$UbuntuOvaName"
        $ubuntuLocalPath = Join-Path $DownloadPath "ubuntu-24.04-lts.ova"

        Download-Template -Url $ubuntuUrl -OutputPath $ubuntuLocalPath -Name "Ubuntu 24.04 LTS"
        Import-ToContentLibrary -OvaPath $ubuntuLocalPath -LibraryName $ContentLibrary -ItemName "ubuntu-24.04-lts-cloudimg"
    }

    # Import Photon OS
    if (-not $FlatcarOnly -and -not $UbuntuOnly) {
        Write-Log ""
        Write-Log "=== VMware Photon OS 5.0 ===" -Level INFO

        $photonLocalPath = Join-Path $DownloadPath $PhotonOvaName

        Download-Template -Url $PhotonUrl -OutputPath $photonLocalPath -Name "Photon OS 5.0"
        Import-ToContentLibrary -OvaPath $photonLocalPath -LibraryName $ContentLibrary -ItemName "photon-5.0-ova"
    }

    Write-Log ""
    Write-Log "=== Import completato ===" -Level SUCCESS
    Write-Log ""
    Write-Log "Template disponibili:"
    Get-ContentLibraryItem -ContentLibrary $library | Format-Table Name, ItemType, @{N = "SizeGB"; E = { [math]::Round($_.SizeGB, 2) } }

}
finally {
    Disconnect-VIServer -Confirm:$false -ErrorAction SilentlyContinue
}
