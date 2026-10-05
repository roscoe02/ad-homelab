<#
.SYNOPSIS
    Phase 6: build TKT01, an Ubuntu Server 24.04 VM for the ticketing system (2 GB cap).

.DESCRIPTION
    1. Creates an SSH key just for the lab (lab-ssh\, excluded from git) and a SHA-512 hash of
       the Linux password from lab-secrets.txt.
    2. Fills unattend\ubuntu-user-data.yaml and packs it on a small ISO labeled CIDATA, which is
       where Ubuntu's installer looks for autoinstall answers.
    3. Creates the VM (Secure Boot set to the template that trusts Linux), boots the installer and
       answers its one safety question ("Continue with autoinstall?") by typing "yes".
    4. Waits for the installer to power the VM off, ejects the media, boots from disk.
    5. Adds tkt01.corp.roscoe.internal to the DC's DNS, waits for SSH, takes checkpoint "01-OS-installed".
#>
. "$PSScriptRoot\lab-common.ps1"
$Name = 'TKT01'
$IP = $LabVMs[$Name].IP
$openssl = 'C:\Program Files\Git\mingw64\bin\openssl.exe'
$keyDir = Join-Path $RepoRoot 'lab-ssh'
$key = Join-Path $keyDir 'lab_ed25519'

# Re-running is safe: if TKT01 already exists, skip straight to the post-install steps.
$vmDir = Join-Path $LabVMPath $Name
$outDir = Join-Path $RepoRoot "unattend\out\$Name"
if (Get-VM -Name $Name -ErrorAction SilentlyContinue) {
    Write-Host "[skip] $Name exists; resuming after the install"
} else {

    # 1. SSH key + password hash
    if (-not (Test-Path $key)) {
        New-Item -ItemType Directory -Path $keyDir -Force | Out-Null
        & ssh-keygen.exe -q -t ed25519 -N '""' -C 'ad-homelab' -f $key
        Write-Host "[done] Created lab SSH key in lab-ssh\"
    }
    $pubKey = (Get-Content "$key.pub" -Raw).Trim()
    # openssl reads the password from stdin, so it never appears on a command line.
    $hash = (Get-LabSecret 'LINUX_labadmin' | & $openssl passwd -6 -stdin).Trim()
    if ($hash -notmatch '^\$6\$') { throw 'Password hashing failed' }

    # 2. CIDATA seed ISO (files: user-data, meta-data)
    New-Item -ItemType Directory -Path $outDir -Force | Out-Null
    $userData = (Get-Content (Join-Path $RepoRoot 'unattend\ubuntu-user-data.yaml') -Raw).Replace('{{PASSWORD_HASH}}', $hash).Replace('{{SSH_PUBKEY}}', $pubKey)
    $utf8 = New-Object Text.UTF8Encoding $false
    [IO.File]::WriteAllText((Join-Path $outDir 'user-data'), $userData.Replace("`r`n", "`n"), $utf8)
    [IO.File]::WriteAllText((Join-Path $outDir 'meta-data'), "instance-id: tkt01`n", $utf8)
    New-Item -ItemType Directory -Path $vmDir -Force | Out-Null
    $seedIso = New-LabIsoFromFolder -Folder $outDir -VolumeName 'CIDATA' -IsoPath (Join-Path $vmDir "$Name-seed.iso")

    # 3. VM + install
    New-LabVM -Name $Name -InstallIso (Find-LabIso 'ubuntu-24.04*-live-server-amd64.iso') -UnattendIso $seedIso | Out-Null
    Start-VM -Name $Name
    Write-Host '[info] TKT01 booting the Ubuntu installer...'
    # Ubuntu's installer stops once to ask "Continue with autoinstall? (yes|no)", a safety check so a
    # stray USB stick can't wipe a PC. Typing "yes" too early lands in the GRUB boot menu (where "e"
    # means "edit"), so first wait out GRUB's 30-second countdown, then answer "yes" every 15 seconds
    # until the virtual disk grows past 500 MB, which means the install has really started.
    Start-Sleep -Seconds 60
    $vhd = Join-Path $vmDir "Virtual Hard Disks\$Name.vhdx"
    $deadline = (Get-Date).AddMinutes(10)
    while ((Get-Item $vhd).Length -lt 500MB) {
        if ((Get-Date) -gt $deadline) { throw 'Ubuntu install did not start; check the TKT01 console' }
        # Individual key presses (Y, E, S, Enter): the Linux console ignores Hyper-V's TypeText.
        try { foreach ($k in 0x59, 0x45, 0x53, 0x0D) { Send-LabVMKey -Name $Name -KeyCode $k } } catch {}
        Start-Sleep -Seconds 15
    }
    Write-Host '[info] Install running; waiting for it to power off (about 10-15 minutes)...'
    $deadline = (Get-Date).AddMinutes(45)
    while ((Get-VM $Name).State -ne 'Off') {
        if ((Get-Date) -gt $deadline) { throw 'TKT01 install did not finish in 45 minutes' }
        Start-Sleep -Seconds 20
    }
}

# 4. Eject media, boot from disk
# Ubuntu's installer may already have ejected its own DVD, so empty and remove each drive by location.
foreach ($dvd in @(Get-VMDvdDrive -VMName $Name)) {
    Remove-VMDvdDrive -VMName $Name -ControllerNumber $dvd.ControllerNumber -ControllerLocation $dvd.ControllerLocation
}
Remove-Item (Join-Path $vmDir "$Name-seed.iso"), $outDir -Recurse -Force -ErrorAction SilentlyContinue
Set-VMFirmware -VMName $Name -FirstBootDevice (Get-VMHardDiskDrive -VMName $Name)
if ((Get-VM $Name).State -ne 'Running') { Start-VM -Name $Name }

# 5. DNS record on the DC, wait for SSH, checkpoint
Invoke-Command -VMName DC01 -Credential (Get-LabCredential "$DomainNetBIOS\labadmin" 'DOMAIN_ADMIN_labadmin') -ArgumentList $IP -ScriptBlock {
    param($ip)
    $zone = (Get-ADDomain).DNSRoot
    if (-not (Get-DnsServerResourceRecord -ZoneName $zone -Name 'tkt01' -ErrorAction SilentlyContinue)) {
        Add-DnsServerResourceRecordA -ZoneName $zone -Name 'tkt01' -IPv4Address $ip -CreatePtr
    }
}
Write-Host '[done] DNS: tkt01.corp.roscoe.internal -> 10.10.10.20'

# PowerShell 5.1 treats anything a program writes to stderr as an error, so relax that while polling SSH.
$ErrorActionPreference = 'Continue'
$deadline = (Get-Date).AddMinutes(10)
do {
    Start-Sleep -Seconds 10
    $out = & ssh.exe -i $key -o LogLevel=ERROR -o BatchMode=yes -o StrictHostKeyChecking=accept-new -o UserKnownHostsFile="$keyDir\known_hosts" -o ConnectTimeout=5 "labadmin@$IP" 'hostname && lsb_release -ds' 2>$null
} until ($LASTEXITCODE -eq 0 -or (Get-Date) -gt $deadline)
$ErrorActionPreference = 'Stop'
if ($LASTEXITCODE -ne 0) { throw 'SSH to TKT01 did not come up' }
Write-Host "[ready] TKT01: $($out -join ' / ')"

if (-not (Get-VMSnapshot -VMName $Name -Name '01-OS-installed' -ErrorAction SilentlyContinue)) {
    Checkpoint-VM -Name $Name -SnapshotName '01-OS-installed'
}
Write-Host "[done] TKT01 installed. Checkpoint '01-OS-installed'. Lab disk usage: $(Get-LabDiskUsage) GB"
