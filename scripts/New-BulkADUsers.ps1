<#
.SYNOPSIS
    Creates Active Directory users in bulk from a CSV file.

.DESCRIPTION
    For each row in the CSV (FirstName, LastName, Department, Title, Groups):
      1. Builds a username: first initial + last name, lowercase, letters only (Avery Quinlan -> aquinlan).
         If that name is taken, it adds a number (aquinlan2) so two people never collide.
      2. Creates the user in the OU that matches their department (OU=IT, OU=Sales, OU=HR).
      3. Sets one temporary password and forces "change password at next logon",
         so the help desk never knows the user's real password.
      4. Adds the user to each security group listed in the Groups column (separated by ;).
    Users that already exist are skipped, so the script is safe to run again.
    Run it with -WhatIf first to see what it would do without changing anything.

.PARAMETER CsvPath
    Path to the CSV file.

.PARAMETER InitialPassword
    The temporary first-logon password. If you leave it out, the script asks for it (typing is hidden).

.EXAMPLE
    .\New-BulkADUsers.ps1 -CsvPath .\users.csv -WhatIf
    .\New-BulkADUsers.ps1 -CsvPath .\users.csv
#>
[CmdletBinding(SupportsShouldProcess)]   # gives the script -WhatIf and -Confirm for free
param(
    [Parameter(Mandatory)][string]$CsvPath,
    [securestring]$InitialPassword
)

$ErrorActionPreference = 'Stop'
Import-Module ActiveDirectory

# Ask for the password if it wasn't passed in. SecureString keeps it out of the console and history.
if (-not $InitialPassword) {
    $InitialPassword = Read-Host 'Temporary password for new users' -AsSecureString
}

# Look up the domain once, e.g. DC=corp,DC=roscoe,DC=internal and corp.roscoe.internal.
$domain   = Get-ADDomain
$domainDN = $domain.DistinguishedName
$upnSuffix = $domain.DNSRoot

# Every department in the CSV must have a matching OU under OU=Lab. Check before creating anyone.
$users = Import-Csv -Path $CsvPath
foreach ($dept in $users.Department | Sort-Object -Unique) {
    $ouDN = "OU=$dept,OU=Lab,$domainDN"
    if (-not (Get-ADOrganizationalUnit -Filter "DistinguishedName -eq '$ouDN'")) {
        throw "OU '$ouDN' does not exist. Create the OU structure first (scripts\03-ad-structure.ps1)."
    }
}

$created = 0; $skipped = 0
foreach ($u in $users) {
    $first = $u.FirstName.Trim()
    $last  = $u.LastName.Trim()
    $displayName = "$first $last"

    # Skip anyone who already exists (matched on first + last name).
    $existing = Get-ADUser -Filter "GivenName -eq '$first' -and Surname -eq '$last'"
    if ($existing) {
        Write-Host "[skip]   $displayName already exists as $($existing.SamAccountName)"
        $skipped++
        continue
    }

    # Username: first initial + last name, letters only, lowercase ("Okonkwo-Hale" -> "okonkwohale").
    $base = ($first.Substring(0, 1) + $last) -replace '[^a-zA-Z]', ''
    $base = $base.ToLower()
    if ($base.Length -gt 20) { $base = $base.Substring(0, 20) }   # sAMAccountName limit is 20 characters

    # If the name is taken by someone else, add 2, 3, 4... until it's free.
    $sam = $base; $n = 2
    while (Get-ADUser -Filter "SamAccountName -eq '$sam'") { $sam = "$base$n"; $n++ }

    $ouDN = "OU=$($u.Department),OU=Lab,$domainDN"

    if ($PSCmdlet.ShouldProcess("$displayName ($sam) in $ouDN", 'Create AD user')) {
        New-ADUser -Name $displayName `
                   -GivenName $first -Surname $last -DisplayName $displayName `
                   -SamAccountName $sam -UserPrincipalName "$sam@$upnSuffix" `
                   -Department $u.Department -Title $u.Title `
                   -Path $ouDN `
                   -AccountPassword $InitialPassword `
                   -ChangePasswordAtLogon $true `
                   -Enabled $true

        # Groups column looks like "SG-IT;SG-HelpDesk". Add the user to each one.
        foreach ($group in ($u.Groups -split ';' | ForEach-Object Trim | Where-Object { $_ })) {
            Add-ADGroupMember -Identity $group -Members $sam
        }

        Write-Host "[create] $displayName -> $sam ($($u.Department); groups: $($u.Groups))"
        $created++
    } else {
        # -WhatIf: show exactly what would be created, without creating it.
        Write-Host "[preview] Would create $displayName -> $sam in $ouDN (groups: $($u.Groups))"
    }
}

Write-Host ''
if ($WhatIfPreference) { Write-Host "Preview only, nothing changed. Would skip: $skipped" }
else { Write-Host "Done. Created: $created  Skipped: $skipped" }
