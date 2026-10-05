<#
.SYNOPSIS
    Phase 1: create the DC01 VM and install Windows Server 2025 with no clicking.

.DESCRIPTION
    1. Finds the Server ISO and picks the "Standard Evaluation (Desktop Experience)" edition.
    2. Builds an answer file (autounattend.xml) with DC01's name and Administrator password.
    3. Creates the VM (4 GB cap, 2 CPUs, 60 GB disk, internal LabSwitch, no auto-start).
    4. Boots the installer and waits until Windows is installed and PowerShell Direct answers.
    5. Removes the install media and answer file, then takes checkpoint "01-OS-installed".
#>
. "$PSScriptRoot\lab-common.ps1"
$Name = 'DC01'

# 1. Installer ISO and edition
$iso = Find-LabIso '*SERVER*EVAL*'
$editions = Get-LabIsoEditions -IsoPath $iso
$editions | Format-Table -AutoSize | Out-String | Write-Host
# Standard with the full desktop: names ending in "SERVERSTANDARD" (the "...CORE" ones have no GUI).
$edition = $editions | Where-Object { $_.Name -match 'SERVERSTANDARD$' -or ($_.Name -match 'Standard' -and $_.Name -match 'Desktop Experience') } | Select-Object -First 1
if (-not $edition) { throw 'Could not find a Standard (Desktop Experience) edition on the ISO' }
Write-Host "[info] Installing: $($edition.Name) (index $($edition.Index))"

# 2. Answer file ISO, stored next to the VM and deleted after setup
$vmDir = Join-Path $LabVMPath $Name
New-Item -ItemType Directory -Path $vmDir -Force | Out-Null
$unattendIso = New-LabUnattendIso -VMName $Name -Template 'server-autounattend.xml' -IsoPath (Join-Path $vmDir "$Name-unattend.iso") -Values @{
    IMAGE_INDEX    = $edition.Index
    COMPUTER_NAME  = $Name
    ADMIN_PASSWORD = Get-LabSecret 'DC_LOCAL_ADMIN'
}

# 3. VM
New-LabVM -Name $Name -InstallIso $iso -UnattendIso $unattendIso | Format-Table Name, State, MemoryMaximum -AutoSize | Out-String | Write-Host

# 4. Install (about 10-20 minutes)
Write-Host '[info] Starting DC01 and booting the installer...'
Start-LabVMFromDvd -Name $Name
Wait-LabVMReady -Name $Name -Credential (Get-LabCredential 'Administrator' 'DC_LOCAL_ADMIN')

# 5. Clean up and checkpoint
Remove-LabUnattendMedia -VMName $Name
Checkpoint-VM -Name $Name -SnapshotName '01-OS-installed'
Write-Host "[done] DC01 installed. Checkpoint '01-OS-installed' taken. Lab disk usage: $(Get-LabDiskUsage) GB"
