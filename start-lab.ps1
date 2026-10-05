<#
.SYNOPSIS
    Starts the lab: DC01 first (everything else needs its DNS and DHCP), then the other VMs.

.EXAMPLE
    .\start-lab.ps1                 # whole lab
    .\start-lab.ps1 -Only DC01,CL01 # just these VMs (DC01 is always started first if listed)
#>
param([string[]]$Only)
. "$PSScriptRoot\scripts\lab-common.ps1"

$names = @($LabVMs.Keys | Where-Object { (-not $Only -or $Only -contains $_) -and (Get-VM -Name $_ -ErrorAction SilentlyContinue) })
if (-not $names) { Write-Host 'No lab VMs found to start.'; return }

if ($names -contains 'DC01') {
    if ((Get-VM DC01).State -ne 'Running') { Start-VM DC01; Write-Host '[start] DC01' }
    # Wait until the DC's DNS answers on port 53 before starting machines that depend on it.
    Write-Host '[wait] DC01 DNS...' -NoNewline
    $deadline = (Get-Date).AddMinutes(5)
    while ((Get-Date) -lt $deadline) {
        $tcp = New-Object Net.Sockets.TcpClient
        try { if ($tcp.ConnectAsync($LabVMs.DC01.IP, 53).Wait(2000) -and $tcp.Connected) { break } } catch {} finally { $tcp.Dispose() }
        Write-Host '.' -NoNewline; Start-Sleep 5
    }
    Write-Host ' up'
}

foreach ($n in $names | Where-Object { $_ -ne 'DC01' }) {
    if ((Get-VM $n).State -ne 'Running') { Start-VM $n; Write-Host "[start] $n" }
}

Get-VM -Name $names | Format-Table Name, State,
    @{ n = 'RAM now (GB)'; e = { [math]::Round($_.MemoryAssigned / 1GB, 1) } },
    @{ n = 'RAM cap (GB)'; e = { [math]::Round($_.MemoryMaximum / 1GB, 1) } } -AutoSize
Write-Host 'Connect with:  vmconnect.exe localhost <VMName>   (or Hyper-V Manager)'
