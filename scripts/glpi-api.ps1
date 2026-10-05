<#
.SYNOPSIS
    Small helpers for GLPI's REST API (apirest.php). Load with:  . "$PSScriptRoot\glpi-api.ps1"
    Needs lab-common.ps1 loaded first (for Get-LabSecret).
#>

$GlpiApi = 'http://10.10.10.20/apirest.php'

function Connect-Glpi {
    <# Logs in as the GLPI admin and returns a session token. #>
    $pair = 'glpi:' + (Get-LabSecret 'GLPI_ADMIN')
    $basic = [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($pair))
    (Invoke-RestMethod "$GlpiApi/initSession" -Headers @{ Authorization = "Basic $basic" } -ContentType 'application/json').session_token
}

function Disconnect-Glpi {
    param([string]$Session)
    try { Invoke-RestMethod "$GlpiApi/killSession" -Headers @{ 'Session-Token' = $Session } -ContentType 'application/json' | Out-Null } catch {}
}

function Invoke-Glpi {
    <# Calls one API endpoint, e.g. Invoke-Glpi $s POST 'Ticket' @{ input = @{ name = '...' } } #>
    param(
        [Parameter(Mandatory)][string]$Session,
        [Parameter(Mandatory)][ValidateSet('GET', 'POST', 'PUT', 'DELETE')][string]$Method,
        [Parameter(Mandatory)][string]$Path,
        $Body
    )
    $req = @{ Uri = "$GlpiApi/$Path"; Method = $Method; Headers = @{ 'Session-Token' = $Session }; ContentType = 'application/json; charset=utf-8' }
    if ($Body) { $req.Body = [Text.Encoding]::UTF8.GetBytes(($Body | ConvertTo-Json -Depth 10)) }
    Invoke-RestMethod @req
}

function Find-GlpiId {
    <# Returns the id of the item of this type whose name matches exactly, or $null. #>
    param([string]$Session, [string]$ItemType, [string]$Name)
    $items = Invoke-Glpi $Session GET "$ItemType`?range=0-500"
    ($items | Where-Object name -eq $Name | Select-Object -First 1).id
}
