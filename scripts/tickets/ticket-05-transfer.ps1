<#
.SYNOPSIS
    Ticket 05: group and permission change. Reese Calloway transfers from HR to Sales
    (request from Parker Lindqvist, HR Manager).

.DESCRIPTION
    A transfer is a classic "permissions change" ticket: the person must GAIN the new team's access
    and LOSE the old team's access (otherwise access piles up over time, called "privilege creep").
      - Group change (SG-HR -> SG-Sales): done by the help desk with delegated rights.
      - OU move and job title: escalated to an IT admin, since help desk can't move accounts.
    Reese then signs in and gets the Sales drive.
#>
. "$PSScriptRoot\ticket-common.ps1"
New-LabSecret -Name 'USER_rcalloway' -Comment "ticket 05: Reese Calloway's normal password"

Open-LabTicket -Number '05' -Slug 'transfer-group-change' -Requester 'plindqvist' -Category 'Permissions' -Type Request -Urgency 3 `
    -Title 'Transfer: Reese Calloway from HR to Sales (access change)' `
    -Description 'Parker Lindqvist (HR Manager): Reese Calloway moves from HR (Recruiter) to Sales as a Sales Coordinator starting today. Please give Reese the Sales access and remove HR access.'

Invoke-TicketStep -NoRecord -AsAdmin -Title 'Setup: give Reese a normal, working password' -ArgumentList (ConvertTo-SecureString (Get-LabSecret 'USER_rcalloway') -AsPlainText -Force) -ScriptBlock {
    param($cred, $pw)
    Set-ADAccountPassword rcalloway -Reset -NewPassword $pw
    Set-ADUser rcalloway -ChangePasswordAtLogon $false
    'Reese has a working password (simulates an existing user).'
} | Out-Null

Add-TicketNote 'Approvals: requested by Reese''s current manager (Parker Lindqvist, HR) and approved by the new manager (Casey Thornbury, Sales). (Simulated in the lab.)'

Invoke-TicketStep -Title 'Record the current state before changing anything' -ScriptBlock {
    param($cred)
    Get-ADUser rcalloway -Credential $cred -Properties Department, Title | Format-List SamAccountName, DistinguishedName, Department, Title
    'Groups: ' + ((Get-ADPrincipalGroupMembership rcalloway -Credential $cred).Name -join ', ')
} -Note 'Writing down the "before" state makes the change easy to reverse if needed.' | Out-Null

Invoke-TicketStep -Title 'Swap the department group: remove SG-HR, add SG-Sales' -ScriptBlock {
    param($cred)
    # Runs as CORP\aquinlan using the delegated "write members" right on OU=Groups.
    Remove-ADGroupMember SG-HR -Members rcalloway -Credential $cred -Confirm:$false
    Add-ADGroupMember SG-Sales -Members rcalloway -Credential $cred
    'Groups now: ' + ((Get-ADPrincipalGroupMembership rcalloway -Credential $cred).Name -join ', ')
} -Note 'Removing the old group matters as much as adding the new one, to avoid privilege creep.' | Out-Null

Invoke-TicketStep -AsAdmin -Title 'Move the account to OU=Sales and update the job details' -ScriptBlock {
    param($cred)
    $d = (Get-ADDomain).DistinguishedName
    Get-ADUser rcalloway | Move-ADObject -TargetPath "OU=Sales,OU=Lab,$d"
    Set-ADUser rcalloway -Department 'Sales' -Title 'Sales Coordinator'
    Get-ADUser rcalloway -Properties Department, Title | Format-List SamAccountName, DistinguishedName, Department, Title
} -Note 'Escalated to an IT admin (CORP\labadmin): moving accounts between OUs is outside the help desk delegation. The OU decides which GPOs apply and who can manage the account.' | Out-Null

$shots = @(Invoke-LabUserSignIn -VM CL02 -User rcalloway -SecretName 'USER_rcalloway')
Show-LabThisPC -VM CL02
$shots += Save-TicketScreenshot -VM CL02 -File 'ticket05-reese-sales-drive.png'
Add-TicketNote 'Reese signed in on CL02 after the change.'

Invoke-TicketStep -On CL02 -AsAdmin -Title "Verify Reese's new access on CL02" -ScriptBlock {
    param($cred)
    $sid = (New-Object Security.Principal.NTAccount('CORP\rcalloway')).Translate([Security.Principal.SecurityIdentifier]).Value
    "S: drive -> " + (Get-ItemProperty "Registry::HKEY_USERS\$sid\Network\S" -ErrorAction SilentlyContinue).RemotePath
    gpresult /user CORP\rcalloway /scope user /r | Select-String -Pattern 'Applied Group Policy Objects' -Context 0, 4 | ForEach-Object { $_.ToString().Trim() }
} | Out-Null

Invoke-LabSignOut -VM CL02
Close-LabTicket -Screenshots $shots `
    -RootCause 'Not a fault: approved department transfer.' `
    -Solution 'With both managers'' approval, removed Reese from SG-HR and added them to SG-Sales (help desk, delegated rights), then an IT admin moved the account to OU=Sales and set Department = Sales, Title = Sales Coordinator. Reese signed in on CL02 and received the S: drive through the SG-Sales group. HR access was removed at the same time to prevent privilege creep.'
