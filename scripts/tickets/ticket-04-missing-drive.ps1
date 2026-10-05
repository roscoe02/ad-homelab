<#
.SYNOPSIS
    Ticket 04: "My S: drive disappeared" (Drew Marchetti, Sales).

.DESCRIPTION
    Lab setup: Drew is removed from SG-Sales (as if by mistake during a group cleanup), then signs in
    on CL01 and has no S: drive.
    The tech checks group membership, uses gpresult to see the "Map Sales Drive" GPO being filtered
    out, uses AD replication metadata to see WHEN the membership changed, confirms with the manager,
    re-adds Drew with delegated rights, and has Drew sign out and back in so the change takes effect.
#>
. "$PSScriptRoot\ticket-common.ps1"
New-LabSecret -Name 'USER_dmarchetti' -Comment "ticket 04: Drew Marchetti's normal password"

# ----- Lab setup before the call -----
Open-LabTicket -Number '04' -Slug 'missing-mapped-drive' -Requester 'dmarchetti' -Category 'File Shares' -Urgency 3 `
    -Title 'S: (Sales) drive missing after signing in' `
    -Description 'Drew Marchetti (Sales) called: the S: drive with the Sales files is gone this morning. It was there yesterday. Other Sales colleagues still have it.'

Invoke-TicketStep -NoRecord -AsAdmin -Title 'Setup: give Drew a normal, working password' -ArgumentList (ConvertTo-SecureString (Get-LabSecret 'USER_dmarchetti') -AsPlainText -Force) -ScriptBlock {
    param($cred, $pw)
    Set-ADAccountPassword dmarchetti -Reset -NewPassword $pw
    Set-ADUser dmarchetti -ChangePasswordAtLogon $false
    'Drew has a working password (simulates an existing user).'
} | Out-Null
Invoke-TicketStep -NoRecord -AsAdmin -Title 'Setup: remove Drew from SG-Sales (simulates a mistake during a group cleanup)' -ScriptBlock {
    param($cred)
    Remove-ADGroupMember SG-Sales -Members dmarchetti -Confirm:$false
    'Removed dmarchetti from SG-Sales.'
} | Out-Null

$shots = @(Invoke-LabUserSignIn -VM CL01 -User dmarchetti -SecretName 'USER_dmarchetti')
Show-LabThisPC -VM CL01
$shots += Save-TicketScreenshot -VM CL01 -File 'ticket04-before-no-s-drive.png'

# ----- The help desk work -----
Invoke-TicketStep -Title "Check Drew's group membership" -ScriptBlock {
    param($cred)
    'Drew is in: ' + ((Get-ADPrincipalGroupMembership dmarchetti -Credential $cred).Name -join ', ')
    'SG-Sales members: ' + ((Get-ADGroupMember SG-Sales -Credential $cred).SamAccountName -join ', ')
} -Note 'The S: drive GPO only applies to members of SG-Sales, and Drew is not in it.' | Out-Null

Invoke-TicketStep -On CL01 -AsAdmin -Title "Confirm with gpresult on Drew's PC" -ScriptBlock {
    param($cred)
    $r = gpresult /user CORP\dmarchetti /scope user /r
    $i = [array]::IndexOf($r, ($r | Where-Object { $_ -match 'filtered out' } | Select-Object -First 1))
    if ($i -ge 0) { $r[$i..($i + 8)] | ForEach-Object { $_.TrimEnd() } | Where-Object { $_ } }
} -Note '"Denied (Security)" means the GPO was skipped because of security filtering: Drew is not in the group that has Apply permission.' | Out-Null

Invoke-TicketStep -Title 'When did the membership change? (AD replication metadata)' -ScriptBlock {
    param($cred)
    # AD keeps metadata for each group member, including when it was removed.
    Get-ADReplicationAttributeMetadata (Get-ADGroup SG-Sales -Credential $cred).DistinguishedName -Server DC01 -Credential $cred -Properties member -ShowAllLinkedValues |
        Where-Object AttributeValue -like '*Drew Marchetti*' |
        Format-List @{ n = 'Member'; e = { $_.AttributeValue } }, FirstOriginatingCreateTime, LastOriginatingDeleteTime, LastOriginatingChangeTime
} -Note 'Shows Drew was removed from SG-Sales today, which matches "it was there yesterday".' | Out-Null

Add-TicketNote 'Checked with Sales Manager Casey Thornbury: Drew is still in Sales and should have the Sales share. Removal was a mistake during a group cleanup. (Simulated in the lab.)'

Invoke-TicketStep -Title 'Re-add Drew to SG-Sales' -ScriptBlock {
    param($cred)
    # Runs as CORP\aquinlan using the delegated "write members" right on OU=Groups.
    Add-ADGroupMember SG-Sales -Members dmarchetti -Credential $cred
    'Drew is in: ' + ((Get-ADPrincipalGroupMembership dmarchetti -Credential $cred).Name -join ', ')
} | Out-Null

Add-TicketNote 'Asked Drew to sign out and back in. Group membership is read at sign-in (it goes into the Kerberos ticket), so the drive returns on the next sign-in, not immediately.'
Invoke-LabSignOut -VM CL01
Start-Sleep -Seconds 10
$shots += Invoke-LabUserSignIn -VM CL01 -User dmarchetti -SecretName 'USER_dmarchetti'
Show-LabThisPC -VM CL01
$shots += Save-TicketScreenshot -VM CL01 -File 'ticket04-after-s-drive-back.png'

Invoke-TicketStep -On CL01 -AsAdmin -Title 'Verify the drive and GPO after signing back in' -ScriptBlock {
    param($cred)
    $sid = (New-Object Security.Principal.NTAccount('CORP\dmarchetti')).Translate([Security.Principal.SecurityIdentifier]).Value
    "S: drive -> " + (Get-ItemProperty "Registry::HKEY_USERS\$sid\Network\S" -ErrorAction SilentlyContinue).RemotePath
    gpresult /user CORP\dmarchetti /scope user /r | Select-String -Pattern 'Applied Group Policy Objects' -Context 0, 4 | ForEach-Object { $_.ToString().Trim() }
} | Out-Null

Invoke-LabSignOut -VM CL01
Close-LabTicket -Screenshots $shots `
    -RootCause 'Drew had been removed from SG-Sales (simulated as a mistake during a group cleanup). The "Map Sales Drive" GPO is security-filtered to SG-Sales, so it stopped applying and the S: drive was no longer mapped.' `
    -Solution 'Confirmed the missing group membership in AD and with gpresult (GPO filtered out: Denied (Security)), found the removal time in replication metadata, got the manager''s confirmation, and re-added Drew to SG-Sales with delegated help desk rights. After signing out and back in, the GPO applied and S: was mapped again.'
