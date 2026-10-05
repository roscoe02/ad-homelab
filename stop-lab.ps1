<#
.SYNOPSIS
    Cleanly shuts down every lab VM: clients and the ticketing server first, DC01 last,
    so nothing loses its domain controller mid-shutdown. When this finishes the lab uses
    no CPU or RAM at all.
#>
. "$PSScriptRoot\scripts\lab-common.ps1"

$running = @($LabVMs.Keys | Where-Object { (Get-VM -Name $_ -ErrorAction SilentlyContinue).State -eq 'Running' })
if (-not $running) { Write-Host 'Lab is already off.'; return }

# Members first, in parallel (Stop-VM asks Windows/Linux inside the VM to shut down cleanly).
$members = @($running | Where-Object { $_ -ne 'DC01' })
if ($members) {
    Write-Host "[stop] $($members -join ', ')"
    $jobs = $members | ForEach-Object { Stop-VM -Name $_ -Force -AsJob }
    $jobs | Wait-Job | Remove-Job
}

if ($running -contains 'DC01') {
    Write-Host '[stop] DC01'
    Stop-VM -Name DC01 -Force
}

Get-VM -Name @($LabVMs.Keys | Where-Object { Get-VM -Name $_ -ErrorAction SilentlyContinue }) | Format-Table Name, State -AutoSize
Write-Host "Lab is off. Disk used by the lab: $(Get-LabDiskUsage) GB"
