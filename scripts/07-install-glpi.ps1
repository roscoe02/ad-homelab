<#
.SYNOPSIS
    Phase 7: install GLPI on TKT01 over SSH, then check the web page answers.

.DESCRIPTION
    Sends scripts\linux\install-glpi.sh to TKT01 through SSH (with the lab key) and runs it as root.
    The passwords are put at the top of the script's input stream, so they never appear on any
    command line or in the VM's process list. Takes checkpoint "02-GLPI-installed" afterward.
#>
param([string]$GlpiVersion = '11.0.11')
. "$PSScriptRoot\lab-common.ps1"
$Name = 'TKT01'
$IP = $LabVMs[$Name].IP
$keyDir = Join-Path $RepoRoot 'lab-ssh'
$sshArgs = @('-i', "$keyDir\lab_ed25519", '-o', 'LogLevel=ERROR', '-o', 'BatchMode=yes', '-o', "UserKnownHostsFile=$keyDir\known_hosts", "labadmin@$IP")

# Build the input: variable definitions first, then the install script itself (Linux line endings).
$vars = @(
    "export GLPI_VERSION='$GlpiVersion'"
    "export GLPI_DB_PW='$(Get-LabSecret 'GLPI_DB')'"
    "export GLPI_ADMIN_PW='$(Get-LabSecret 'GLPI_ADMIN')'"
) -join "`n"
$script = (Get-Content (Join-Path $PSScriptRoot 'linux\install-glpi.sh') -Raw).Replace("`r`n", "`n")

# Pipe through a temp file so PowerShell 5.1 doesn't alter the bytes, then delete it.
$tmp = [IO.Path]::GetTempFileName()
try {
    [IO.File]::WriteAllText($tmp, "$vars`n$script", (New-Object Text.UTF8Encoding $false))
    $ErrorActionPreference = 'Continue'   # PowerShell 5.1 would treat apt/ssh stderr chatter as fatal
    cmd /c "ssh $($sshArgs -join ' ') `"sudo bash -s`" < `"$tmp`" 2>&1"
    $code = $LASTEXITCODE
    $ErrorActionPreference = 'Stop'
    if ($code -ne 0) { throw "GLPI install failed (exit $code)" }
} finally { Remove-Item $tmp -Force }

# Check from the host: the login page should answer with HTTP 200.
$resp = Invoke-WebRequest "http://$IP/" -UseBasicParsing -TimeoutSec 30
Write-Host "[check] http://$IP/ -> HTTP $($resp.StatusCode), title: $(([regex]'<title>(.*?)</title>').Match($resp.Content).Groups[1].Value)"

Checkpoint-VM -Name $Name -SnapshotName '02-GLPI-installed'
Write-Host "[done] GLPI on TKT01. Checkpoint '02-GLPI-installed'. Sign in at http://tkt01.corp.roscoe.internal/ as 'glpi' (password: GLPI_ADMIN in lab-secrets.txt)."
