<#
.SYNOPSIS
    Shared settings and helper functions for the AD home lab. Other scripts load this with:
        . "$PSScriptRoot\lab-common.ps1"
#>

$ErrorActionPreference = 'Stop'

# ----- Lab-wide settings -----
$LabRoot     = 'E:\Labs\ad-homelab-vms'          # every VM file lives under here
$LabVMPath   = Join-Path $LabRoot 'VMs'
$LabIsoPath  = Join-Path $LabRoot 'ISOs'
$RepoRoot    = Split-Path $PSScriptRoot -Parent   # C:\Labs\ad-homelab
$SecretsFile = Join-Path $RepoRoot 'lab-secrets.txt'
$SwitchName  = 'LabSwitch'
$DomainName  = 'corp.roscoe.internal'
$DomainNetBIOS = 'CORP'

# One entry per VM. MaxMemoryGB caps each VM; the caps add up to 14 GB.
# Start order matters: the DC must be up first because everything else needs its DNS.
$LabVMs = [ordered]@{
    DC01 = @{ Role = 'DC';     MaxMemoryGB = 4; CPUs = 2; DiskGB = 60; IP = '10.10.10.10' }
    CL01 = @{ Role = 'Client'; MaxMemoryGB = 4; CPUs = 2; DiskGB = 64 }
    CL02 = @{ Role = 'Client'; MaxMemoryGB = 4; CPUs = 2; DiskGB = 64 }
    TKT01 = @{ Role = 'Linux'; MaxMemoryGB = 2; CPUs = 2; DiskGB = 30; IP = '10.10.10.20' }
}

# ----- Secrets -----
function Get-LabSecret {
    <# Reads one password from lab-secrets.txt (format NAME=value  # comment). #>
    param([Parameter(Mandatory)][string]$Name)
    $line = Get-Content $SecretsFile | Where-Object { $_ -match "^$Name=" } | Select-Object -First 1
    if (-not $line) { throw "Secret '$Name' not found in $SecretsFile" }
    ($line -replace "^$Name=", '' -split '\s+#')[0].Trim()
}

function New-LabSecret {
    <#
    Makes sure a password called $Name exists in lab-secrets.txt, generating a strong random one if
    it doesn't. Returns nothing, so the password never appears in output.
    #>
    param([Parameter(Mandatory)][string]$Name, [string]$Comment = '', [int]$Length = 20)
    if (Get-Content $SecretsFile | Where-Object { $_ -match "^$Name=" }) { return }
    $sets = 'ABCDEFGHJKLMNPQRSTUVWXYZ', 'abcdefghijkmnopqrstuvwxyz', '23456789', '!#%+-_='   # safe in XML, shells and URLs
    $rng = [Security.Cryptography.RandomNumberGenerator]::Create()
    $pick = { param($s) $b = New-Object byte[] 4; $rng.GetBytes($b); $s[[BitConverter]::ToUInt32($b, 0) % $s.Length] }
    $chars = @($sets | ForEach-Object { & $pick $_ })          # at least one of each kind (AD complexity)
    while ($chars.Count -lt $Length) { $chars += & $pick (-join $sets) }
    $pw = -join ($chars | Sort-Object { $b = New-Object byte[] 4; $rng.GetBytes($b); [BitConverter]::ToUInt32($b, 0) })
    Add-Content -Path $SecretsFile -Value "$Name=$pw   # $Comment" -Encoding utf8
}

function Get-LabCredential {
    <# Builds a PSCredential for PowerShell Direct / remoting without ever printing the password. #>
    param([Parameter(Mandatory)][string]$UserName, [Parameter(Mandatory)][string]$SecretName)
    $secure = ConvertTo-SecureString (Get-LabSecret $SecretName) -AsPlainText -Force
    New-Object System.Management.Automation.PSCredential($UserName, $secure)
}

# ----- Unattend ISO -----
# Windows Setup automatically looks for "autounattend.xml" in the root of every drive,
# including a second virtual DVD. So we build a tiny ISO containing just that file.
# IMAPI2 is the CD-burning API built into Windows, so no extra tools are needed.
if (-not ('LabIsoWriter' -as [type])) {
    Add-Type -TypeDefinition @'
using System;
using System.IO;
using System.Runtime.InteropServices.ComTypes;
public static class LabIsoWriter {
    public static void Write(string path, object stream, int blockSize, int totalBlocks) {
        IStream src = (IStream)stream;
        byte[] buffer = new byte[blockSize];
        using (FileStream dst = File.Create(path)) {
            for (int i = 0; i < totalBlocks; i++) {
                src.Read(buffer, blockSize, IntPtr.Zero);
                dst.Write(buffer, 0, blockSize);
            }
        }
    }
}
'@
}

function New-LabUnattendIso {
    <#
    Fills a template from unattend\ with this VM's name and passwords, writes it to
    unattend\out\<VM>\autounattend.xml (git-ignored), and packs it into <VMfolder>\<VM>-unattend.iso.
    #>
    param(
        [Parameter(Mandatory)][string]$VMName,
        [Parameter(Mandatory)][string]$Template,
        [Parameter(Mandatory)][hashtable]$Values,
        [Parameter(Mandatory)][string]$IsoPath
    )
    $xml = Get-Content (Join-Path $RepoRoot "unattend\$Template") -Raw
    foreach ($k in $Values.Keys) { $xml = $xml.Replace("{{$k}}", [Security.SecurityElement]::Escape([string]$Values[$k])) }
    if ($xml -match '\{\{\w+\}\}') { throw "Unfilled placeholder in $Template : $($Matches[0])" }

    $outDir = Join-Path $RepoRoot "unattend\out\$VMName"
    New-Item -ItemType Directory -Path $outDir -Force | Out-Null
    [IO.File]::WriteAllText((Join-Path $outDir 'autounattend.xml'), $xml, (New-Object Text.UTF8Encoding $false))
    New-LabIsoFromFolder -Folder $outDir -VolumeName 'UNATTEND' -IsoPath $IsoPath
}

function New-LabIsoFromFolder {
    <# Packs a folder's files into an ISO using IMAPI2, the CD-burning API built into Windows. #>
    param([Parameter(Mandatory)][string]$Folder, [Parameter(Mandatory)][string]$VolumeName, [Parameter(Mandatory)][string]$IsoPath)
    $fsi = New-Object -ComObject IMAPI2FS.MsftFileSystemImage
    $fsi.FileSystemsToCreate = 3          # ISO9660 + Joliet
    $fsi.VolumeName = $VolumeName
    $fsi.Root.AddTree($Folder, $false)    # add the folder's contents, not the folder itself
    $img = $fsi.CreateResultImage()
    if (Test-Path $IsoPath) { Remove-Item $IsoPath -Force }
    [LabIsoWriter]::Write($IsoPath, $img.ImageStream, $img.BlockSize, $img.TotalBlocks)
    [Runtime.InteropServices.Marshal]::ReleaseComObject($fsi) | Out-Null
    $IsoPath
}

# ----- Finding ISOs and editions -----
function Find-LabIso {
    <# Finds the newest ISO in the ISOs folder whose file name matches a wildcard, e.g. '*SERVER_EVAL*'. #>
    param([Parameter(Mandatory)][string]$Pattern)
    $iso = Get-ChildItem $LabIsoPath -Filter *.iso | Where-Object Name -like $Pattern |
        Sort-Object LastWriteTime -Descending | Select-Object -First 1
    if (-not $iso) { throw "No ISO matching '$Pattern' in $LabIsoPath" }
    $iso.FullName
}

function Get-LabIsoEditions {
    <#
    Lists the Windows editions inside an ISO's install.wim (index + name), so the unattend file
    can pick the right one. Reads the WIM's built-in XML description directly, so it works without
    admin rights (Get-WindowsImage needs admin).
    #>
    param([Parameter(Mandatory)][string]$IsoPath)
    $mount = Mount-DiskImage -ImagePath $IsoPath -PassThru
    try {
        $drive = ($mount | Get-Volume).DriveLetter
        $wim = Get-ChildItem "${drive}:\sources" | Where-Object Name -match '^install\.(wim|esd)$' | Select-Object -First 1
        $fs = [IO.File]::OpenRead($wim.FullName)
        try {
            $br = New-Object IO.BinaryReader($fs)
            # WIM header: the XML resource descriptor starts at byte 72:
            # 7 bytes = stored size, 1 byte = flags, 8 bytes = offset in file.
            $fs.Position = 72
            $sizeBytes = $br.ReadBytes(7) + [byte]0
            [void]$br.ReadByte()
            $size = [BitConverter]::ToInt64($sizeBytes, 0)
            $offset = $br.ReadInt64()
            $fs.Position = $offset
            $xmlText = [Text.Encoding]::Unicode.GetString($br.ReadBytes([int]$size)).TrimStart([char]0xFEFF)
        } finally { $fs.Dispose() }
        ([xml]$xmlText).WIM.IMAGE | ForEach-Object {
            [pscustomobject]@{ Index = [int]$_.INDEX; Name = $_.NAME; Edition = $_.WINDOWS.EDITIONID }
        }
    } finally { Dismount-DiskImage -ImagePath $IsoPath | Out-Null }
}

function Remove-LabUnattendMedia {
    <# After setup finishes: eject both DVDs and delete the generated answer file and ISO (they hold a password). #>
    param([Parameter(Mandatory)][string]$VMName)
    Get-VMDvdDrive -VMName $VMName | Where-Object Path | Set-VMDvdDrive -Path $null
    Remove-Item (Join-Path $LabVMPath "$VMName\$VMName-unattend.iso") -Force -ErrorAction SilentlyContinue
    Remove-Item (Join-Path $RepoRoot "unattend\out\$VMName") -Recurse -Force -ErrorAction SilentlyContinue
    Write-Host "[done] Ejected install media and deleted $VMName's answer file"
}

# ----- VM creation -----
function New-LabVM {
    <#
    Creates one Generation 2 VM on the internal LabSwitch with the lab's limits:
    capped dynamic memory, no automatic start with Windows, clean shutdown when the PC shuts down.
    #>
    param(
        [Parameter(Mandatory)][string]$Name,
        [Parameter(Mandatory)][string]$InstallIso,
        [string]$UnattendIso
    )
    $cfg = $LabVMs[$Name]
    if (Get-VM -Name $Name -ErrorAction SilentlyContinue) { throw "VM $Name already exists" }

    $vhd = Join-Path $LabVMPath "$Name\Virtual Hard Disks\$Name.vhdx"
    New-VM -Name $Name -Generation 2 -Path $LabVMPath -SwitchName $SwitchName `
        -MemoryStartupBytes 2GB -NewVHDPath $vhd -NewVHDSizeBytes ([int64]$cfg.DiskGB * 1GB) | Out-Null

    # Dynamic memory: the VM only takes what it needs, never more than its cap.
    # Windows 11 Setup refuses to install with less than 4 GB at boot, so clients start at their cap
    # (it still shrinks when idle); the others start at 2 GB.
    $startup = if ($cfg.Role -eq 'Client') { [int64]$cfg.MaxMemoryGB * 1GB } else { 2GB }
    Set-VM -Name $Name -ProcessorCount $cfg.CPUs -DynamicMemory `
        -MemoryMinimumBytes 512MB -MemoryStartupBytes $startup -MemoryMaximumBytes ([int64]$cfg.MaxMemoryGB * 1GB) `
        -AutomaticStartAction Nothing -AutomaticStopAction ShutDown `
        -AutomaticCheckpointsEnabled $false -CheckpointType Production

    # Lets the host copy files into the VM (Copy-VMFile) without any network share.
    Enable-VMIntegrationService -VMName $Name -Name 'Guest Service Interface'

    $dvd = Add-VMDvdDrive -VMName $Name -Path $InstallIso -Passthru
    if ($UnattendIso) { Add-VMDvdDrive -VMName $Name -Path $UnattendIso }

    switch ($cfg.Role) {
        'Linux'  { Set-VMFirmware -VMName $Name -FirstBootDevice $dvd -SecureBootTemplate MicrosoftUEFICertificateAuthority }
        'Client' {
            Set-VMFirmware -VMName $Name -FirstBootDevice $dvd
            # Windows 11 requires a TPM; Hyper-V provides a virtual one.
            Set-VMKeyProtector -VMName $Name -NewLocalKeyProtector
            Enable-VMTPM -VMName $Name
        }
        default  { Set-VMFirmware -VMName $Name -FirstBootDevice $dvd }
    }
    Get-VM -Name $Name
}

function Send-LabVMKey {
    <#
    Presses a key inside a VM's virtual keyboard. Used to answer
    "Press any key to boot from CD or DVD..." on first boot. 13 = Enter.
    #>
    param([Parameter(Mandatory)][string]$Name, [int]$KeyCode = 13)
    $vm = Get-CimInstance -Namespace root\virtualization\v2 -ClassName Msvm_ComputerSystem -Filter "ElementName='$Name'"
    $kb = Get-CimAssociatedInstance -InputObject $vm -ResultClassName Msvm_Keyboard
    Invoke-CimMethod -InputObject $kb -MethodName TypeKey -Arguments @{ keyCode = $KeyCode } | Out-Null
}

function Start-LabVMFromDvd {
    <# Starts a VM and taps Enter for ~15 seconds so it boots the installer DVD. #>
    param([Parameter(Mandatory)][string]$Name)
    Start-VM -Name $Name
    for ($i = 0; $i -lt 30; $i++) { Start-Sleep -Milliseconds 500; try { Send-LabVMKey -Name $Name } catch {} }
}

function Wait-LabVMReady {
    <#
    Waits until PowerShell Direct works inside the VM, which means Windows is installed and
    the account can log on. PowerShell Direct talks to the VM through Hyper-V itself, not the network.
    #>
    param(
        [Parameter(Mandatory)][string]$Name,
        [Parameter(Mandatory)][pscredential]$Credential,
        [int]$TimeoutMinutes = 45
    )
    $deadline = (Get-Date).AddMinutes($TimeoutMinutes)
    while ((Get-Date) -lt $deadline) {
        try {
            $r = Invoke-Command -VMName $Name -Credential $Credential -ScriptBlock { $env:COMPUTERNAME } -ErrorAction Stop
            Write-Host "[ready] $Name answered as $r"
            return
        } catch { Start-Sleep -Seconds 20 }
    }
    throw "$Name was not ready after $TimeoutMinutes minutes"
}

function Invoke-LabSsh {
    <#
    Runs a bash script as root on TKT01 over SSH with the lab key. The script text goes in through
    stdin (not the command line), so any secrets in it never show up in the VM's process list.
    #>
    param([Parameter(Mandatory)][string]$Script, [string]$IP = $LabVMs.TKT01.IP)
    $keyDir = Join-Path $RepoRoot 'lab-ssh'
    $tmp = [IO.Path]::GetTempFileName()
    try {
        [IO.File]::WriteAllText($tmp, $Script.Replace("`r`n", "`n"), (New-Object Text.UTF8Encoding $false))
        $ErrorActionPreference = 'Continue'   # PowerShell 5.1 treats stderr chatter as fatal
        cmd /c "ssh -i `"$keyDir\lab_ed25519`" -o LogLevel=ERROR -o BatchMode=yes -o UserKnownHostsFile=`"$keyDir\known_hosts`" labadmin@$IP `"sudo bash -s`" < `"$tmp`" 2>&1"
        if ($LASTEXITCODE -ne 0) { throw "Remote script failed on $IP (exit $LASTEXITCODE)" }
    } finally { Remove-Item $tmp -Force }
}

function Get-LabDiskUsage {
    <# Total size of everything under the lab folder, in GB. #>
    $bytes = (Get-ChildItem $LabRoot -Recurse -File -ErrorAction SilentlyContinue | Measure-Object Length -Sum).Sum
    [math]::Round($bytes / 1GB, 1)
}
