<#
.SYNOPSIS
    Phase 5: a file share on DC01 and three Group Policies.

.DESCRIPTION
    A. Share \\DC01\Sales (C:\Shares\Sales). Share permissions are wide open to signed-in users;
       NTFS permissions do the real control: SG-Sales = Modify, admins = Full, nobody else.
    B. Password and lockout policy for the whole domain (stored in the Default Domain Policy,
       the only place a domain password policy takes effect):
       12+ characters, complexity, remember 24, max age 90 days, lock after 5 bad tries for 15 minutes.
    C. GPO "Map Sales Drive": maps S: to \\DC01\Sales. Linked to OU=Lab but security-filtered
       to SG-Sales, so only Sales members get the drive no matter which OU they're in.
    D. GPO "User Restrictions - No Control Panel": blocks Control Panel and Settings.
       Linked to the Sales and HR OUs only. IT keeps access.
    E. Checkpoint "04-share-GPOs".
#>
. "$PSScriptRoot\lab-common.ps1"
$Name = 'DC01'
$cred = Get-LabCredential "$DomainNetBIOS\labadmin" 'DOMAIN_ADMIN_labadmin'

Invoke-Command -VMName $Name -Credential $cred -ScriptBlock {
    $ErrorActionPreference = 'Stop'
    Import-Module GroupPolicy
    $dom = Get-ADDomain
    $d = $dom.DistinguishedName; $fqdn = $dom.DNSRoot; $nb = $dom.NetBIOSName

    # ---------- A. File share ----------
    $path = 'C:\Shares\Sales'
    New-Item -ItemType Directory -Path $path -Force | Out-Null
    # NTFS: stop inheriting from C:\, then grant exactly who should have access.
    $acl = Get-Acl $path
    $acl.SetAccessRuleProtection($true, $false)          # disable inheritance, drop inherited entries
    $acl.Access | ForEach-Object { [void]$acl.RemoveAccessRule($_) }
    $inherit = 'ContainerInherit,ObjectInherit'
    foreach ($rule in @(
        @('BUILTIN\Administrators', 'FullControl'),
        @('NT AUTHORITY\SYSTEM',    'FullControl'),
        @("$nb\Domain Admins",      'FullControl'),
        @("$nb\SG-Sales",           'Modify')
    )) {
        $acl.AddAccessRule((New-Object Security.AccessControl.FileSystemAccessRule($rule[0], $rule[1], $inherit, 'None', 'Allow')))
    }
    Set-Acl -Path $path -AclObject $acl
    if (-not (Get-SmbShare -Name 'Sales' -ErrorAction SilentlyContinue)) {
        # Access-based enumeration: people only see folders they have permission to open.
        New-SmbShare -Name 'Sales' -Path $path -ChangeAccess 'Authenticated Users' -FullAccess 'Administrators' `
            -FolderEnumerationMode AccessBased -Description 'Sales department share' | Out-Null
    }
    Set-Content -Path "$path\Welcome to the Sales share.txt" -Value 'If you can read this, your S: drive is mapped correctly.'
    Write-Host "[done] \\$env:COMPUTERNAME\Sales shared (NTFS: SG-Sales Modify, admins Full)"

    # ---------- B. Password and lockout policy ----------
    Set-ADDefaultDomainPasswordPolicy -Identity $fqdn `
        -MinPasswordLength 12 -ComplexityEnabled $true -PasswordHistoryCount 24 `
        -MaxPasswordAge '90.00:00:00' -MinPasswordAge '1.00:00:00' `
        -LockoutThreshold 5 -LockoutDuration '00:15:00' -LockoutObservationWindow '00:15:00'
    Write-Host '[done] Domain password policy: 12+ chars, complexity, history 24, 90 days; lockout 5 tries / 15 min'

    # ---------- C. Mapped drive GPO ----------
    $gpoName = 'Map Sales Drive'
    $gpo = Get-GPO -Name $gpoName -ErrorAction SilentlyContinue
    if (-not $gpo) {
        $gpo = New-GPO -Name $gpoName -Comment 'Maps S: to the Sales share for members of SG-Sales'
        $gpo | New-GPLink -Target "OU=Lab,$d" | Out-Null

        # Security filtering: everyone can READ the GPO (computers need this since MS16-072),
        # but only SG-Sales members APPLY it.
        Set-GPPermission -Name $gpoName -TargetName 'Authenticated Users' -TargetType Group -PermissionLevel GpoRead -Replace | Out-Null
        Set-GPPermission -Name $gpoName -TargetName 'SG-Sales' -TargetType Group -PermissionLevel GpoApply | Out-Null

        # Drive maps are a Group Policy *Preference*. There's no cmdlet for preferences, so write the
        # same Drives.xml file the Group Policy Management Editor would create in SYSVOL.
        $gpoId = "{$($gpo.Id.ToString().ToUpper())}"
        $prefDir = "\\$fqdn\SYSVOL\$fqdn\Policies\$gpoId\User\Preferences\Drives"
        New-Item -ItemType Directory -Path $prefDir -Force | Out-Null
        $uid = "{$([guid]::NewGuid().ToString().ToUpper())}"
        $now = Get-Date -Format 'yyyy-MM-dd HH:mm:ss'
        $xml = @"
<?xml version="1.0" encoding="utf-8"?>
<Drives clsid="{8FDDCC1A-0C3C-43cd-A6B4-71A6DF20DA8C}"><Drive clsid="{935D1B74-9CB8-4e3c-9914-7DD559B7A417}" name="S:" status="S:" image="2" changed="$now" uid="$uid" bypassErrors="1"><Properties action="U" thisDrive="NOCHANGE" allDrives="NOCHANGE" userName="" path="\\$env:COMPUTERNAME.$fqdn\Sales" label="Sales" persistent="1" useLetter="1" letter="S"/></Drive></Drives>
"@
        Set-Content -Path "$prefDir\Drives.xml" -Value $xml -Encoding UTF8

        # Tell clients this GPO now has drive-map settings (the Drive Maps client-side extension)
        # and bump the user-side version number so clients notice the change.
        $gpoDN = "CN=$gpoId,CN=Policies,CN=System,$d"
        Set-ADObject $gpoDN -Replace @{ gPCUserExtensionNames = '[{00000000-0000-0000-0000-000000000000}{2EA1A81B-48E5-45E9-8BB7-A6E3AC170006}][{5794DAFD-BE60-433F-88A2-1A31939AC01F}{2EA1A81B-48E5-45E9-8BB7-A6E3AC170006}]' }
        $ver = [int](Get-ADObject $gpoDN -Properties versionNumber).versionNumber + 65536   # user version = upper 16 bits
        Set-ADObject $gpoDN -Replace @{ versionNumber = $ver }
        $gptIni = "\\$fqdn\SYSVOL\$fqdn\Policies\$gpoId\GPT.INI"
        Set-Content -Path $gptIni -Value "[General]`r`nVersion=$ver" -Encoding ASCII
    }
    Write-Host "[done] GPO '$gpoName' linked to OU=Lab, applies only to SG-Sales"

    # ---------- D. Desktop restriction GPO ----------
    $gpoName = 'User Restrictions - No Control Panel'
    if (-not (Get-GPO -Name $gpoName -ErrorAction SilentlyContinue)) {
        New-GPO -Name $gpoName -Comment 'Blocks Control Panel and Settings for non-IT staff' | Out-Null
        # Same setting as: User Configuration > Policies > Administrative Templates > Control Panel >
        # "Prohibit access to Control Panel and PC settings"
        Set-GPRegistryValue -Name $gpoName -Key 'HKCU\Software\Microsoft\Windows\CurrentVersion\Policies\Explorer' `
            -ValueName 'NoControlPanel' -Type DWord -Value 1 | Out-Null
        foreach ($ou in 'Sales', 'HR') { New-GPLink -Name $gpoName -Target "OU=$ou,OU=Lab,$d" | Out-Null }
    }
    Write-Host "[done] GPO '$gpoName' linked to OU=Sales and OU=HR"

    # ---------- Workstation security baseline (computer settings) ----------
    $gpoName = 'Workstation Security Baseline'
    if (-not (Get-GPO -Name $gpoName -ErrorAction SilentlyContinue)) {
        New-GPO -Name $gpoName -Comment 'Computer settings for every domain workstation' | Out-Null
        # Computer Configuration > Windows Settings > Security Settings > Local Policies > Security Options >
        # "Interactive logon: Don't display last signed-in". Hides the last username on the sign-in screen,
        # so someone at the PC has to know both the username and the password.
        Set-GPRegistryValue -Name $gpoName -Key 'HKLM\Software\Microsoft\Windows\CurrentVersion\Policies\System' `
            -ValueName 'DontDisplayLastUserName' -Type DWord -Value 1 | Out-Null
        New-GPLink -Name $gpoName -Target "OU=Workstations,OU=Lab,$d" | Out-Null
    }
    Write-Host "[done] GPO '$gpoName' linked to OU=Workstations"

    # Save an HTML report of every GPO for the write-up.
    New-Item -ItemType Directory -Path C:\LabScripts -Force | Out-Null
    Get-GPOReport -All -ReportType Html -Path C:\LabScripts\gpo-report.html
}

# ---------- E. Checkpoint ----------
if (-not (Get-VMSnapshot -VMName $Name -Name '04-share-GPOs' -ErrorAction SilentlyContinue)) {
    Checkpoint-VM -Name $Name -SnapshotName '04-share-GPOs'
}
Write-Host "[done] Phase 5 complete. Checkpoint '04-share-GPOs' taken on DC01."
