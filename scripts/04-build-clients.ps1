<#
.SYNOPSIS
    Phase 4: build the Windows 11 clients (CL01, CL02) and join them to the domain.

.DESCRIPTION
    For each client:
      1. Answer file with the computer name and a local admin "labadmin" account.
      2. VM with a virtual TPM (Windows 11 requires TPM 2.0), 4 GB cap, no auto-start.
      3. Unattended install, then remove the media and take checkpoint "01-OS-installed".
      4. The client gets its IP from DC01's DHCP, joins corp.roscoe.internal, and restarts.
         It lands in OU=Workstations because of the redircmp setting from phase 3.
      5. Checkpoint "02-domain-joined".
    Both clients install at the same time to save time (DC 4 GB + 2 x 4 GB = 12 GB max).

.EXAMPLE
    .\04-build-clients.ps1              # both
    .\04-build-clients.ps1 -Names CL01  # just one
#>
param([string[]]$Names = @('CL01', 'CL02'))
. "$PSScriptRoot\lab-common.ps1"

$iso = Find-LabIso '*CLIENTENTERPRISEEVAL*'
$edition = Get-LabIsoEditions -IsoPath $iso | Where-Object Name -match 'Enterprise' | Select-Object -First 1
Write-Host "[info] Installing: $($edition.Name) (index $($edition.Index))"
$domainCred = Get-LabCredential "$DomainNetBIOS\labadmin" 'DOMAIN_ADMIN_labadmin'

# 1-2. Create and start every client that doesn't exist yet
$new = @()
foreach ($Name in $Names) {
    if (Get-VM -Name $Name -ErrorAction SilentlyContinue) { Write-Host "[skip] $Name already exists"; continue }
    $vmDir = Join-Path $LabVMPath $Name
    New-Item -ItemType Directory -Path $vmDir -Force | Out-Null
    $unattendIso = New-LabUnattendIso -VMName $Name -Template 'client-autounattend.xml' -IsoPath (Join-Path $vmDir "$Name-unattend.iso") -Values @{
        IMAGE_INDEX    = $edition.Index
        COMPUTER_NAME  = $Name
        ADMIN_PASSWORD = Get-LabSecret 'CLIENT_LOCAL_ADMIN'
    }
    New-LabVM -Name $Name -InstallIso $iso -UnattendIso $unattendIso | Out-Null
    Write-Host "[info] Starting $Name and booting the installer..."
    Start-LabVMFromDvd -Name $Name
    $new += $Name
}

# 3. Wait for each install, clean up, checkpoint
foreach ($Name in $new) {
    Wait-LabVMReady -Name $Name -Credential (Get-LabCredential "$Name\labadmin" 'CLIENT_LOCAL_ADMIN') -TimeoutMinutes 60
    Remove-LabUnattendMedia -VMName $Name
    Checkpoint-VM -Name $Name -SnapshotName '01-OS-installed'
    Write-Host "[done] $Name installed, checkpoint '01-OS-installed'"
}

# 4-5. Domain join
foreach ($Name in $Names) {
    $joined = $false
    try { $joined = Invoke-Command -VMName $Name -Credential $domainCred -ErrorAction Stop -ScriptBlock { (Get-CimInstance Win32_ComputerSystem).PartOfDomain } } catch {}
    if ($joined) { Write-Host "[skip] $Name is already on the domain"; continue }

    Invoke-Command -VMName $Name -Credential (Get-LabCredential "$Name\labadmin" 'CLIENT_LOCAL_ADMIN') -ArgumentList $DomainName, $domainCred -ScriptBlock {
        param($domain, $cred)
        $ErrorActionPreference = 'Stop'
        # Wait for a DHCP lease from DC01 (10.10.10.100-200), then make sure the domain name resolves.
        for ($i = 0; $i -lt 30; $i++) {
            $ip = (Get-NetIPAddress -AddressFamily IPv4 | Where-Object IPAddress -like '10.10.10.*').IPAddress
            if ($ip) { break }
            ipconfig /renew | Out-Null; Start-Sleep 5
        }
        if (-not $ip) { throw 'No DHCP lease from DC01' }
        Write-Host "[info] $env:COMPUTERNAME got $ip from DHCP"
        Resolve-DnsName $domain -ErrorAction Stop | Out-Null

        # Join the domain. This creates a computer account in AD and a trust between the PC and the domain.
        Add-Computer -DomainName $domain -Credential $cred -Force
        Write-Host "[done] $env:COMPUTERNAME joined $domain"
        Restart-Computer -Force
    }
    Start-Sleep -Seconds 30
    Wait-LabVMReady -Name $Name -Credential $domainCred
    Checkpoint-VM -Name $Name -SnapshotName '02-domain-joined'
    Write-Host "[done] $Name on the domain, checkpoint '02-domain-joined'"
}
Write-Host "[done] Clients ready. Lab disk usage: $(Get-LabDiskUsage) GB"
