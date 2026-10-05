<#
.SYNOPSIS
    Ticket 02: new-hire onboarding (request from Casey Thornbury, Sales Manager).

.DESCRIPTION
    A new Sales Representative starts today. The account is created with the same bulk-user script
    used to build the lab (one CSV row), so onboarding is repeatable and consistent. The new hire then
    signs in on CL02, sets their own password, and the tech confirms OU, groups, S: drive and policies.
    Creating accounts is an IT admin task (help desk has no create rights), so that one step runs as
    CORP\labadmin.
#>
. "$PSScriptRoot\ticket-common.ps1"
New-LabSecret -Name 'USER_lvarga' -Comment 'ticket 02: password the new hire Lennox Varga chose at first sign-in'

Open-LabTicket -Number '02' -Slug 'new-hire-onboarding' -Requester 'cthornbury' -Category 'Onboarding' -Type Request -Urgency 3 `
    -Title 'New hire: Lennox Varga, Sales Representative, starts today' `
    -Description 'Casey Thornbury (Sales Manager): Lennox Varga joins Sales as a Sales Representative today. Needs a computer login, the Sales shared drive, and the standard Sales setup.'

Add-TicketNote 'Request came from the hiring manager (Casey Thornbury). Matched it to the HR new-hire notice for Lennox Varga before creating anything. (Simulated in the lab.)'

$csv = @"
FirstName,LastName,Department,Title,Groups
Lennox,Varga,Sales,Sales Representative,SG-Sales
"@
Invoke-TicketStep -Title 'Preview the account with the bulk-user script (-WhatIf)' -AsAdmin -ArgumentList $csv, (ConvertTo-SecureString (Get-LabSecret 'NEW_USER_INITIAL') -AsPlainText -Force) -ScriptBlock {
    param($cred, $csv, $initialPassword)
    Set-Content -Path C:\LabScripts\new-hire-lvarga.csv -Value $csv -Encoding UTF8
    & C:\LabScripts\New-BulkADUsers.ps1 -CsvPath C:\LabScripts\new-hire-lvarga.csv -InitialPassword $initialPassword -WhatIf 6>&1
} -Note 'Same script and CSV format used to create the original 15 users. -WhatIf shows what would happen without changing anything.' | Out-Null

Invoke-TicketStep -Title 'Create the account' -AsAdmin -ArgumentList (ConvertTo-SecureString (Get-LabSecret 'NEW_USER_INITIAL') -AsPlainText -Force) -ScriptBlock {
    param($cred, $initialPassword)
    & C:\LabScripts\New-BulkADUsers.ps1 -CsvPath C:\LabScripts\new-hire-lvarga.csv -InitialPassword $initialPassword 6>&1
} -Note 'Run with an IT admin account (CORP\labadmin): creating accounts is outside the help desk delegation.' | Out-Null

Invoke-TicketStep -Title 'Verify OU, title, groups and first-login settings' -ScriptBlock {
    param($cred)
    Get-ADUser lvarga -Credential $cred -Properties Department, Title, pwdLastSet, Enabled |
        Format-List SamAccountName, UserPrincipalName, DistinguishedName, Department, Title, Enabled, @{ n = 'MustChangeAtNextLogon'; e = { $_.pwdLastSet -eq 0 } }
    'Groups: ' + ((Get-ADPrincipalGroupMembership lvarga -Credential $cred).Name -join ', ')
} | Out-Null

Add-TicketNote 'Gave Lennox the username (lvarga) and the temporary first-login password in person on their first morning. (Simulated in the lab.)'

$shots = @(Invoke-LabUserSignIn -VM CL02 -User lvarga -SecretName 'NEW_USER_INITIAL' -NewSecretName 'USER_lvarga' -ShotPrefix 'ticket02')
Show-LabThisPC -VM CL02
$shots += Save-TicketScreenshot -VM CL02 -File 'ticket02-new-hire-this-pc.png'
Add-TicketNote 'Lennox signed in on CL02, chose their own password, and File Explorer shows the Sales (S:) drive.'

Invoke-TicketStep -Title "Confirm Lennox's drive and policies on CL02" -On CL02 -AsAdmin -ScriptBlock {
    param($cred)
    $sid = (New-Object Security.Principal.NTAccount('CORP\lvarga')).Translate([Security.Principal.SecurityIdentifier]).Value
    "S: drive -> " + (Get-ItemProperty "Registry::HKEY_USERS\$sid\Network\S" -ErrorAction SilentlyContinue).RemotePath
    "Control Panel blocked (NoControlPanel) = " + (Get-ItemProperty "Registry::HKEY_USERS\$sid\Software\Microsoft\Windows\CurrentVersion\Policies\Explorer" -ErrorAction SilentlyContinue).NoControlPanel
    gpresult /user CORP\lvarga /scope user /r | Select-String -Pattern 'Applied Group Policy Objects' -Context 0, 4 | ForEach-Object { $_.ToString().Trim() }
} | Out-Null

Invoke-LabSignOut -VM CL02
Close-LabTicket -Screenshots $shots `
    -RootCause 'Not a fault: standard new-hire request.' `
    -Solution 'Created lvarga in OU=Sales with the bulk-user script (one CSV row), in SG-Sales, with a temporary password that must be changed at first sign-in. Lennox signed in on CL02, set a new password, and received the S: drive and Sales policies automatically through group membership and Group Policy.'
