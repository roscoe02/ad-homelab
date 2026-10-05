<#
.SYNOPSIS
    Phase 3: OUs, security groups, help desk delegation, and the bulk user import.

.DESCRIPTION
    A. OUs under OU=Lab: IT, Sales, HR, Disabled Users, Groups, Workstations, Servers.
       New computers that join the domain land in OU=Workstations instead of the default
       "Computers" container (which can't have Group Policies linked to it).
    B. Global security groups in OU=Groups: SG-IT, SG-HelpDesk, SG-Sales, SG-HR, SG-Managers.
    C. Delegation: SG-HelpDesk can reset passwords and unlock accounts in the IT, Sales and HR OUs,
       and nothing else. Help desk staff don't need to be Domain Admins.
    D. Copies New-BulkADUsers.ps1 and users.csv to C:\LabScripts on DC01 and runs it.
    E. One former employee, disabled and moved to OU=Disabled Users (the offboarding pattern).
    F. Checkpoint "03-OUs-groups-users".
#>
. "$PSScriptRoot\lab-common.ps1"
$Name = 'DC01'
$cred = Get-LabCredential "$DomainNetBIOS\labadmin" 'DOMAIN_ADMIN_labadmin'

# ---------- A-C. OUs, groups, delegation ----------
Invoke-Command -VMName $Name -Credential $cred -ScriptBlock {
    $ErrorActionPreference = 'Stop'
    $d = (Get-ADDomain).DistinguishedName
    $nb = (Get-ADDomain).NetBIOSName

    # A. OUs
    if (-not (Get-ADOrganizationalUnit -Filter "Name -eq 'Lab'" -SearchBase $d -SearchScope OneLevel)) {
        New-ADOrganizationalUnit -Name 'Lab' -Path $d -Description 'Everything created for the home lab'
    }
    foreach ($ou in 'IT', 'Sales', 'HR', 'Disabled Users', 'Groups', 'Workstations', 'Servers') {
        if (-not (Get-ADOrganizationalUnit -Filter "Name -eq '$ou'" -SearchBase "OU=Lab,$d" -SearchScope OneLevel)) {
            New-ADOrganizationalUnit -Name $ou -Path "OU=Lab,$d"   # protected from accidental deletion by default
            Write-Host "[done] OU=$ou"
        }
    }
    redircmp "OU=Workstations,OU=Lab,$d" | Out-Null
    Write-Host '[done] New computers now join into OU=Workstations'

    # B. Groups
    $groups = @{
        'SG-IT'       = 'IT department'
        'SG-HelpDesk' = 'Help desk staff: delegated password reset and unlock'
        'SG-Sales'    = 'Sales department: access to the Sales share'
        'SG-HR'       = 'HR department'
        'SG-Managers' = 'People managers across departments'
    }
    foreach ($g in $groups.Keys) {
        if (-not (Get-ADGroup -Filter "Name -eq '$g'")) {
            New-ADGroup -Name $g -GroupScope Global -GroupCategory Security -Path "OU=Groups,OU=Lab,$d" -Description $groups[$g]
            Write-Host "[done] Group $g"
        }
    }

    # C. Delegation with dsacls. /I:S = applies to objects inside the OU; ";user" = only user objects.
    #    CA "Reset Password"  = reset a password without knowing the old one
    #    RPWP lockoutTime     = read/write the field that unlocks an account
    #    RPWP pwdLastSet      = read/write the field behind "must change password at next logon"
    foreach ($ou in 'IT', 'Sales', 'HR') {
        $ouDN = "OU=$ou,OU=Lab,$d"
        dsacls $ouDN /I:S /G "$nb\SG-HelpDesk:CA;Reset Password;user" | Out-Null
        dsacls $ouDN /I:S /G "$nb\SG-HelpDesk:RPWP;lockoutTime;user" | Out-Null
        dsacls $ouDN /I:S /G "$nb\SG-HelpDesk:RPWP;pwdLastSet;user" | Out-Null
    }
    Write-Host '[done] SG-HelpDesk delegated reset/unlock on IT, Sales, HR'

    # Help desk can change who is IN the department groups (RPWP on "member"), but cannot
    # create, delete or rename groups. Group changes still need a ticket with manager approval.
    dsacls "OU=Groups,OU=Lab,$d" /I:S /G "$nb\SG-HelpDesk:RPWP;member;group" | Out-Null
    Write-Host '[done] SG-HelpDesk delegated group membership changes in OU=Groups'
}

# ---------- D. Bulk user import ----------
# Write the script and CSV onto the DC so they can also be run there by hand.
$scriptText = Get-Content (Join-Path $PSScriptRoot 'New-BulkADUsers.ps1') -Raw
$csvText    = Get-Content (Join-Path $RepoRoot 'data\users.csv') -Raw
$initialPw  = ConvertTo-SecureString (Get-LabSecret 'NEW_USER_INITIAL') -AsPlainText -Force
Invoke-Command -VMName $Name -Credential $cred -ArgumentList $scriptText, $csvText, $initialPw -ScriptBlock {
    param($scriptText, $csvText, $initialPw)
    New-Item -ItemType Directory -Path C:\LabScripts -Force | Out-Null
    Set-Content -Path C:\LabScripts\New-BulkADUsers.ps1 -Value $scriptText -Encoding UTF8
    Set-Content -Path C:\LabScripts\users.csv -Value $csvText -Encoding UTF8
    & C:\LabScripts\New-BulkADUsers.ps1 -CsvPath C:\LabScripts\users.csv -InitialPassword $initialPw
}

# ---------- E. Offboarded employee ----------
Invoke-Command -VMName $Name -Credential $cred -ArgumentList $initialPw -ScriptBlock {
    param($pw)
    $d = (Get-ADDomain).DistinguishedName
    if (-not (Get-ADUser -Filter "SamAccountName -eq 'bfairbanks'")) {
        New-ADUser -Name 'Blake Fairbanks' -GivenName Blake -Surname Fairbanks -SamAccountName bfairbanks `
            -UserPrincipalName "bfairbanks@$((Get-ADDomain).DNSRoot)" -Department Sales -Title 'Former Sales Representative' `
            -Path "OU=Sales,OU=Lab,$d" -AccountPassword $pw -Enabled $true
        # Offboarding: disable (don't delete, so the account and its history can be restored),
        # note why, remove group access, and move to the Disabled Users OU.
        Disable-ADAccount bfairbanks
        Set-ADUser bfairbanks -Description "Disabled $(Get-Date -Format yyyy-MM-dd): left company"
        Get-ADUser bfairbanks | Move-ADObject -TargetPath "OU=Disabled Users,OU=Lab,$d"
        Write-Host '[done] Former employee bfairbanks disabled and moved to OU=Disabled Users'
    }
}

# ---------- F. Checkpoint ----------
if (-not (Get-VMSnapshot -VMName $Name -Name '03-OUs-groups-users' -ErrorAction SilentlyContinue)) {
    Checkpoint-VM -Name $Name -SnapshotName '03-OUs-groups-users'
}
Write-Host "[done] Phase 3 complete. Checkpoint '03-OUs-groups-users' taken."
