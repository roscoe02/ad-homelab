<#
.SYNOPSIS
    Ticket 03: "My account is locked" (Taylor Brightwell, Sales).

.DESCRIPTION
    Lab setup: Taylor gets a normal working password, then six sign-in attempts with a WRONG password
    are made from CL02 (like someone typing an old password). After 5, the domain lockout policy
    from phase 5 locks the account.
    The tech then confirms the lockout, finds WHERE the bad attempts came from (event 4740 in the DC's
    Security log), unlocks the account with delegated rights, and confirms Taylor can sign in.
#>
. "$PSScriptRoot\ticket-common.ps1"
New-LabSecret -Name 'USER_tbrightwell' -Comment "ticket 03: Taylor Brightwell's normal password"

Open-LabTicket -Number '03' -Slug 'locked-account' -Requester 'tbrightwell' -Category 'Account Access' -Urgency 4 `
    -Title 'Account locked out - cannot sign in' `
    -Description 'Taylor Brightwell (Sales) called: Windows says "The referenced account is currently locked out and may not be logged on to." Taylor is sure they are typing the right password now.'

# ----- Lab setup: create the problem (recorded as setup, not as part of the fix) -----
Invoke-TicketStep -NoRecord -AsAdmin -Title 'Setup: give Taylor a normal, working password' -ArgumentList (ConvertTo-SecureString (Get-LabSecret 'USER_tbrightwell') -AsPlainText -Force) -ScriptBlock {
    param($cred, $pw)
    Set-ADAccountPassword tbrightwell -Reset -NewPassword $pw
    Set-ADUser tbrightwell -ChangePasswordAtLogon $false
    'Taylor has a working password (simulates an existing user).'
} | Out-Null
Invoke-TicketStep -NoRecord -AsAdmin -On CL02 -Title 'Setup: six sign-in attempts with wrong (old) passwords from CL02' -ScriptBlock {
    param($cred)
    foreach ($i in 1..6) {
        # A different wrong password each time (in testing, repeating one identical bad password did not raise the counter every time).
        $r = cmd /c "net use \\DC01\IPC$ /user:CORP\tbrightwell OldPassword$i! 2>&1"
        "Attempt ${i}: " + (($r | Where-Object { $_ -match 'error|locked|password' }) -join ' ').Trim()
    }
} | Out-Null

# ----- The help desk work -----
Invoke-TicketStep -Title 'Confirm the account is locked out' -ScriptBlock {
    param($cred)
    Search-ADAccount -LockedOut -UsersOnly -Credential $cred | Select-Object SamAccountName, LockedOut | Format-Table -AutoSize
    Get-ADUser tbrightwell -Credential $cred -Properties LockedOut, AccountLockoutTime, badPwdCount, LastBadPasswordAttempt, Enabled |
        Format-List SamAccountName, Enabled, LockedOut, AccountLockoutTime, badPwdCount, LastBadPasswordAttempt
} -Note 'Locked out, not disabled and not expired. The lockout policy is 5 bad attempts within 15 minutes.' | Out-Null

Invoke-TicketStep -AsAdmin -Title 'Find where the bad passwords came from (event 4740 on the DC)' -ScriptBlock {
    param($cred)
    # Event 4740 = "A user account was locked out". Its "Caller Computer Name" says which machine sent the bad passwords.
    Get-WinEvent -FilterHashtable @{ LogName = 'Security'; Id = 4740 } -MaxEvents 10 -ErrorAction SilentlyContinue |
        Where-Object { $_.Properties[0].Value -eq 'tbrightwell' } | Select-Object -First 1 |
        ForEach-Object { [pscustomobject]@{ Time = $_.TimeCreated; LockedAccount = $_.Properties[0].Value; CallerComputer = $_.Properties[1].Value } } |
        Format-List
} -Note 'Reading the DC Security log needs admin (or Event Log Readers) rights, so this step used the IT admin account.' | Out-Null

Add-TicketNote 'Asked Taylor about CL02: Taylor used the shared PC at the front desk earlier and tried an old password several times there. (Simulated in the lab: six wrong-password attempts from CL02.) Nothing suspicious; the attempts came from inside the office.'

Invoke-TicketStep -Title 'Unlock the account' -ScriptBlock {
    param($cred)
    # Runs as CORP\aquinlan using the delegated write access to lockoutTime on the Sales OU.
    Unlock-ADAccount tbrightwell -Credential $cred
    Get-ADUser tbrightwell -Credential $cred -Properties LockedOut | Select-Object SamAccountName, LockedOut | Format-Table -AutoSize
} -Note 'No password reset needed: Taylor knows the current password, the lockout came from an old one.' | Out-Null

$shots = @(Invoke-LabUserSignIn -VM CL02 -User tbrightwell -SecretName 'USER_tbrightwell')
$shots += Save-TicketScreenshot -VM CL02 -File 'ticket03-taylor-signed-in.png'
Add-TicketNote 'Taylor signed in on CL02 successfully with their current password.'

Invoke-TicketStep -Title 'Verify the account is healthy after sign-in' -ScriptBlock {
    param($cred)
    Get-ADUser tbrightwell -Credential $cred -Properties LockedOut, badPwdCount, LastLogonDate |
        Format-List SamAccountName, LockedOut, badPwdCount, LastLogonDate
} | Out-Null

Invoke-LabSignOut -VM CL02
Close-LabTicket -Screenshots $shots `
    -RootCause 'Six sign-in attempts with an old password from the shared PC CL02 triggered the domain lockout policy (5 bad attempts in 15 minutes). In the lab these attempts were simulated with net use.' `
    -Solution 'Confirmed the lockout, traced it to CL02 with event 4740 on the domain controller, confirmed with Taylor that the attempts were theirs, and unlocked the account with delegated help desk rights. Taylor signed in normally. Advised Taylor to sign out of shared PCs and not to retry an old password. If lockouts come back, check CL02 for saved credentials (Credential Manager, mapped drives, scheduled tasks).'
