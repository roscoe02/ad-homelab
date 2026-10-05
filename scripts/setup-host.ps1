#Requires -RunAsAdministrator
<#
.SYNOPSIS
    One-time host setup for the AD home lab. Run once from an elevated (admin) terminal.

.DESCRIPTION
    1. Adds your Windows account to the local "Hyper-V Administrators" group, so the lab
       can be managed (and started/stopped) without an admin terminal from now on.
    2. Creates the folder that holds every lab VM file (one place = easy to measure and delete).
    3. Creates an INTERNAL Hyper-V switch called "LabSwitch". Internal means it connects the
       VMs to each other and to this PC only. It is NOT attached to the physical network card,
       so the domain controller's DHCP server can never hand out addresses on the home LAN.
    4. Gives this PC the address 10.10.10.1 on that switch and turns on Windows NAT for
       10.10.10.0/24, so lab VMs can reach the internet (for updates) through this PC,
       while nothing on the internet or the home LAN can reach in.

    Safe to run more than once: each step checks whether it is already done.
#>

$ErrorActionPreference = 'Stop'

# ----- Settings (change here if needed) -----
$LabRoot      = 'E:\Labs\ad-homelab-vms'   # all VM disks/configs live under here
$SwitchName   = 'LabSwitch'
$HostLabIP    = '10.10.10.1'               # this PC's address inside the lab = the lab's default gateway
$LabPrefix    = '10.10.10.0/24'            # home LAN is 192.168.1.0/24, so no overlap
$NatName      = 'LabNAT'

# The account that ran "Terminal (Admin)" is the same account you log in with.
$LabUser = [Security.Principal.WindowsIdentity]::GetCurrent().Name

# ----- 1. Hyper-V Administrators membership -----
# S-1-5-32-578 is the well-known ID of the built-in "Hyper-V Administrators" group.
$hvAdmins = Get-LocalGroup -SID 'S-1-5-32-578'
$isMember = Get-LocalGroupMember -Group $hvAdmins | Where-Object Name -eq $LabUser
if ($isMember) {
    Write-Host "[skip] $LabUser is already in $($hvAdmins.Name)"
} else {
    Add-LocalGroupMember -Group $hvAdmins -Member $LabUser
    Write-Host "[done] Added $LabUser to $($hvAdmins.Name) (takes effect after you sign out and back in)"
}

# ----- 2. Lab folder -----
foreach ($dir in $LabRoot, "$LabRoot\VMs", "$LabRoot\ISOs") {
    if (-not (Test-Path $dir)) { New-Item -ItemType Directory -Path $dir | Out-Null; Write-Host "[done] Created $dir" }
    else { Write-Host "[skip] $dir exists" }
}

# ----- 3. Internal virtual switch -----
if (Get-VMSwitch -Name $SwitchName -ErrorAction SilentlyContinue) {
    Write-Host "[skip] Switch $SwitchName exists"
} else {
    New-VMSwitch -Name $SwitchName -SwitchType Internal | Out-Null
    Write-Host "[done] Created internal switch $SwitchName"
}

# ----- 4. Host gateway IP + NAT -----
$ifAlias = "vEthernet ($SwitchName)"
if (Get-NetIPAddress -InterfaceAlias $ifAlias -IPAddress $HostLabIP -ErrorAction SilentlyContinue) {
    Write-Host "[skip] $ifAlias already has $HostLabIP"
} else {
    # Static address, so this PC never asks the lab's DHCP server for one.
    New-NetIPAddress -InterfaceAlias $ifAlias -IPAddress $HostLabIP -PrefixLength 24 | Out-Null
    Write-Host "[done] Set $ifAlias to $HostLabIP/24"
}

if (Get-NetNat -Name $NatName -ErrorAction SilentlyContinue) {
    Write-Host "[skip] NAT $NatName exists"
} else {
    # Outbound-only translation: lab -> internet works, internet/home LAN -> lab does not.
    New-NetNat -Name $NatName -InternalIPInterfaceAddressPrefix $LabPrefix | Out-Null
    Write-Host "[done] Created NAT $NatName for $LabPrefix"
}

Write-Host ''
Write-Host 'Host setup complete. Sign out of Windows and sign back in so the Hyper-V Administrators membership applies.'
