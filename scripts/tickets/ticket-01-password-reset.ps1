<#
.SYNOPSIS
    Ticket 01: "I forgot my password and can't sign in" (Morgan Vexley, Sales).

.DESCRIPTION
    The help desk tech (Avery Quinlan) verifies the caller, checks the account, resets the password
    with her DELEGATED rights (not Domain Admin) and forces a change at next sign-in. Morgan then
    signs in on CL01, is made to choose a new password, and the tech confirms the account is healthy
    and that Morgan's Sales drive and restrictions loaded.
#>
. "$PSScriptRoot\ticket-common.ps1"
New-LabSecret -Name 'TEMP_mvexley' -Comment 'ticket 01: temporary password given to Morgan by phone'
New-LabSecret -Name 'USER_mvexley' -Comment 'ticket 01: the new password Morgan chose at sign-in'

Open-LabTicket -Number '01' -Slug 'password-reset' -Requester 'mvexley' -Category 'Account Access' -Urgency 4 `
    -Title 'Forgot password - cannot sign in' `
    -Description 'Morgan Vexley (Sales) called: came back from a week off, forgot their password and cannot sign in to their PC. Needs to work on a customer quote this morning.'

Add-TicketNote 'Verified the caller before making any change: called Morgan back on the desk number listed in the company directory and confirmed their manager (Casey Thornbury). Never reset a password based only on an inbound call. (Simulated in the lab.)'

Invoke-TicketStep -Title 'Check the account before changing anything' -ScriptBlock {
    param($cred)
    Get-ADUser mvexley -Credential $cred -Properties Enabled, LockedOut, PasswordExpired, PasswordLastSet, LastLogonDate, badPwdCount, DistinguishedName |
        Format-List SamAccountName, DistinguishedName, Enabled, LockedOut, PasswordExpired, PasswordLastSet, LastLogonDate, badPwdCount
} -Note 'Account is enabled and not locked, so this is a forgotten password, not a lockout or a disabled account.' | Out-Null

Invoke-TicketStep -Title 'Reset the password and require a change at next sign-in' -ArgumentList (ConvertTo-SecureString (Get-LabSecret 'TEMP_mvexley') -AsPlainText -Force) -ScriptBlock {
    param($cred, $tempPassword)
    # Runs as CORP\aquinlan, who has only the delegated "Reset Password" and pwdLastSet rights on the Sales OU.
    Set-ADAccountPassword mvexley -Reset -NewPassword $tempPassword -Credential $cred
    Set-ADUser mvexley -ChangePasswordAtLogon $true -Credential $cred
    Get-ADUser mvexley -Properties pwdLastSet -Credential $cred | Select-Object SamAccountName, @{ n = 'MustChangeAtNextLogon'; e = { $_.pwdLastSet -eq 0 } }
} -Note 'Temporary password given to Morgan over the phone (never by email or chat). It only works until Morgan picks a new one.' | Out-Null

Invoke-TicketStep -Title 'Confirm the help desk account cannot change accounts outside its delegation' -ScriptBlock {
    param($cred)
    # Least-privilege check: Avery can reset Sales users, but must NOT be able to modify an admin account.
    try {
        Set-ADUser labadmin -Description 'help desk write test' -Credential $cred -ErrorAction Stop
        'UNEXPECTED: write to labadmin succeeded'
    } catch { "Expected result - access denied: $($_.Exception.Message)" }
} | Out-Null

# Morgan signs in on CL01 with the temporary password and is forced to pick a new one.
Start-LabSignIn -VM CL01 -User mvexley -SecretName 'TEMP_mvexley'
Start-Sleep -Seconds 6
$shots = @(Save-TicketScreenshot -VM CL01 -File 'ticket01-must-change-password.png')
Send-LabKey CL01 13; Start-Sleep -Seconds 3                     # OK on "password must be changed"
Send-LabKeys CL01 (Get-LabSecret 'USER_mvexley'); Send-LabKey CL01 9
Send-LabKeys CL01 (Get-LabSecret 'USER_mvexley'); Send-LabKey CL01 13
Start-Sleep -Seconds 5
$shots += Save-TicketScreenshot -VM CL01 -File 'ticket01-password-changed.png'
Send-LabKey CL01 13                                             # OK on "Your password has been changed"
$deadline = (Get-Date).AddMinutes(4)
do {
    Start-Sleep -Seconds 10
    $up = Invoke-Command -VMName CL01 -Credential $script:AdminCred -ScriptBlock { [bool](Get-Process explorer -IncludeUserName -ErrorAction SilentlyContinue | Where-Object UserName -like '*mvexley') }
} until ($up -or (Get-Date) -gt $deadline)
Start-Sleep -Seconds 20
Add-TicketNote "Morgan signed in on CL01 with the temporary password, was required to choose a new one, and reached the desktop."

Invoke-TicketStep -Title 'Verify the account after Morgan signed in' -ScriptBlock {
    param($cred)
    Get-ADUser mvexley -Credential $cred -Properties PasswordLastSet, pwdLastSet, LastLogonDate, badPwdCount, LockedOut |
        Format-List SamAccountName, PasswordLastSet, @{ n = 'MustChangeAtNextLogon'; e = { $_.pwdLastSet -eq 0 } }, LockedOut, badPwdCount
} -Note 'PasswordLastSet is now the time Morgan chose a new password, and the must-change flag is cleared.' | Out-Null

Invoke-TicketStep -Title "Check Morgan's session, S: drive and policies on CL01" -On CL01 -AsAdmin -ScriptBlock {
    param($cred)
    quser
    $sid = (New-Object Security.Principal.NTAccount('CORP\mvexley')).Translate([Security.Principal.SecurityIdentifier]).Value
    "S: drive -> " + (Get-ItemProperty "Registry::HKEY_USERS\$sid\Network\S" -ErrorAction SilentlyContinue).RemotePath
    "Control Panel blocked (NoControlPanel) = " + (Get-ItemProperty "Registry::HKEY_USERS\$sid\Software\Microsoft\Windows\CurrentVersion\Policies\Explorer" -ErrorAction SilentlyContinue).NoControlPanel
    gpresult /user CORP\mvexley /scope user /r | Select-String -Pattern 'Applied Group Policy Objects' -Context 0, 4 | ForEach-Object { $_.ToString().Trim() }
} -Note "Morgan is a Sales user, so the S: drive and the Control Panel restriction should both apply." | Out-Null

$shots += Save-TicketScreenshot -VM CL01 -File 'ticket01-morgan-desktop.png'
Invoke-LabSignOut -VM CL01

Close-LabTicket -Screenshots $shots `
    -RootCause 'User forgot their password after time off. The account itself was healthy (enabled, not locked out).' `
    -Solution 'Verified the caller by calling back the directory number. Reset the password with delegated help desk rights, required a change at next sign-in, and confirmed Morgan signed in on CL01 and set a new password. S: drive and policies loaded normally.'
