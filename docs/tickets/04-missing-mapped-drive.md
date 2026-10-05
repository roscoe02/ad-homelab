# Ticket 04: S: (Sales) drive missing after signing in

| | |
|---|---|
| GLPI ticket | #4 (Incident, category: File Shares) |
| Requester | dmarchetti (fake user) |
| Assigned to | aquinlan, Avery Quinlan (help desk, SG-HelpDesk) |
| Status | Solved |

**User's report:** Drew Marchetti (Sales) called: the S: drive with the Sales files is gone this morning. It was there yesterday. Other Sales colleagues still have it.

## Lab setup (simulating the problem)

**Setup: give Drew a normal, working password** (on DC01 as CORP\labadmin)

```powershell
Set-ADAccountPassword dmarchetti -Reset -NewPassword $pw
Set-ADUser dmarchetti -ChangePasswordAtLogon $false
'Drew has a working password (simulates an existing user).'
```
```text
Drew has a working password (simulates an existing user).
```

**Setup: remove Drew from SG-Sales (simulates a mistake during a group cleanup)** (on DC01 as CORP\labadmin)

```powershell
Remove-ADGroupMember SG-Sales -Members dmarchetti -Confirm:$false
'Removed dmarchetti from SG-Sales.'
```
```text
Removed dmarchetti from SG-Sales.
```

## Troubleshooting and fix

### 1. Check Drew's group membership

*Ran on DC01 as CORP\aquinlan (help desk)*

The S: drive GPO only applies to members of SG-Sales, and Drew is not in it.

```powershell
'Drew is in: ' + ((Get-ADPrincipalGroupMembership dmarchetti -Credential $cred).Name -join ', ')
'SG-Sales members: ' + ((Get-ADGroupMember SG-Sales -Credential $cred).SamAccountName -join ', ')
```
```text
Drew is in: Domain Users
SG-Sales members: mvexley, cthornbury, tbrightwell, jokonkwohale, rhaverford, qabernathy, lvarga
```

### 2. Confirm with gpresult on Drew's PC

*Ran on CL01 as CORP\labadmin*

"Denied (Security)" means the GPO was skipped because of security filtering: Drew is not in the group that has Apply permission.

```powershell
$r = gpresult /user CORP\dmarchetti /scope user /r
$i = [array]::IndexOf($r, ($r | Where-Object { $_ -match 'filtered out' } | Select-Object -First 1))
if ($i -ge 0) { $r[$i..($i + 8)] | ForEach-Object { $_.TrimEnd() } | Where-Object { $_ } }
```
```text
The following GPOs were not applied because they were filtered out
    -------------------------------------------------------------------
        Map Sales Drive
            Filtering:  Denied (Security)
        Local Group Policy
            Filtering:  Not Applied (Empty)
    The user is a part of the following security groups
```

### 3. When did the membership change? (AD replication metadata)

*Ran on DC01 as CORP\aquinlan (help desk)*

Shows Drew was removed from SG-Sales today, which matches "it was there yesterday".

```powershell
# AD keeps metadata for each group member, including when it was removed.
Get-ADReplicationAttributeMetadata (Get-ADGroup SG-Sales -Credential $cred).DistinguishedName -Server DC01 -Credential $cred -Properties member -ShowAllLinkedValues |
    Where-Object AttributeValue -like '*Drew Marchetti*' |
    Format-List @{ n = 'Member'; e = { $_.AttributeValue } }, FirstOriginatingCreateTime, LastOriginatingDeleteTime, LastOriginatingChangeTime
```
```text
Member                     : CN=Drew Marchetti,OU=Sales,OU=Lab,DC=corp,DC=roscoe,DC=internal
FirstOriginatingCreateTime : 10/5/2026 2:43:30 AM
LastOriginatingDeleteTime  : 10/5/2026 3:32:45 AM
LastOriginatingChangeTime  : 10/5/2026 3:32:45 AM
```

### 4. Note

Checked with Sales Manager Casey Thornbury: Drew is still in Sales and should have the Sales share. Removal was a mistake during a group cleanup. (Simulated in the lab.)

### 5. Re-add Drew to SG-Sales

*Ran on DC01 as CORP\aquinlan (help desk)*

```powershell
# Runs as CORP\aquinlan using the delegated "write members" right on OU=Groups.
Add-ADGroupMember SG-Sales -Members dmarchetti -Credential $cred
'Drew is in: ' + ((Get-ADPrincipalGroupMembership dmarchetti -Credential $cred).Name -join ', ')
```
```text
Drew is in: Domain Users, SG-Sales
```

### 6. Note

Asked Drew to sign out and back in. Group membership is read at sign-in (it goes into the Kerberos ticket), so the drive returns on the next sign-in, not immediately.

### 7. Verify the drive and GPO after signing back in

*Ran on CL01 as CORP\labadmin*

```powershell
$sid = (New-Object Security.Principal.NTAccount('CORP\dmarchetti')).Translate([Security.Principal.SecurityIdentifier]).Value
"S: drive -> " + (Get-ItemProperty "Registry::HKEY_USERS\$sid\Network\S" -ErrorAction SilentlyContinue).RemotePath
gpresult /user CORP\dmarchetti /scope user /r | Select-String -Pattern 'Applied Group Policy Objects' -Context 0, 4 | ForEach-Object { $_.ToString().Trim() }
```
```text
S: drive -> \\DC01.corp.roscoe.internal\Sales
>     Applied Group Policy Objects
      -----------------------------
          User Restrictions - No Control Panel
          Map Sales Drive
```

![ticket04-before-no-s-drive.png](../../screenshots/ticket04-before-no-s-drive.png)

![ticket04-after-s-drive-back.png](../../screenshots/ticket04-after-s-drive-back.png)

## Root cause

Drew had been removed from SG-Sales (simulated as a mistake during a group cleanup). The "Map Sales Drive" GPO is security-filtered to SG-Sales, so it stopped applying and the S: drive was no longer mapped.

## Resolution

Confirmed the missing group membership in AD and with gpresult (GPO filtered out: Denied (Security)), found the removal time in replication metadata, got the manager's confirmation, and re-added Drew to SG-Sales with delegated help desk rights. After signing out and back in, the GPO applied and S: was mapped again.
