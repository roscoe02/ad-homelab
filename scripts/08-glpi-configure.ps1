<#
.SYNOPSIS
    Phase 8: get GLPI ready for the help desk tickets.

.DESCRIPTION
    A. Sets GLPI's URL to http://tkt01.corp.roscoe.internal and turns on its REST API, allowed
       ONLY from the Hyper-V host's lab address (10.10.10.1), so PowerShell can log tickets.
    B. Creates the help desk tech's AD password (Avery Quinlan, member of SG-HelpDesk) so the
       ticket fixes can be done with delegated rights instead of Domain Admin.
    C. Creates GLPI accounts: Avery Quinlan as a Technician, plus the five people who raise tickets
       (Self-Service). Usernames match their AD accounts.
    D. Adds ticket categories: Account Access, Onboarding, File Shares, Permissions.
#>
. "$PSScriptRoot\lab-common.ps1"
. "$PSScriptRoot\glpi-api.ps1"

# ---------- A. URL + API ----------
Invoke-LabSsh -Script @'
set -e
mysql glpi <<'SQL'
UPDATE glpi_configs SET value = 'http://tkt01.corp.roscoe.internal' WHERE context = 'core' AND name = 'url_base';
UPDATE glpi_configs SET value = 'http://tkt01.corp.roscoe.internal/apirest.php' WHERE context = 'core' AND name = 'url_base_api';
UPDATE glpi_configs SET value = '1' WHERE context = 'core' AND name IN ('enable_api', 'enable_api_login_credentials');
INSERT INTO glpi_apiclients (entities_id, is_recursive, name, date_mod, is_active, ipv4_range_start, ipv4_range_end, dolog_method, comment)
SELECT 0, 1, 'Lab host (10.10.10.1)', NOW(), 1, INET_ATON('10.10.10.1'), INET_ATON('10.10.10.1'), 0, 'Ticket automation from the Hyper-V host'
WHERE NOT EXISTS (SELECT 1 FROM glpi_apiclients WHERE name = 'Lab host (10.10.10.1)');
SQL
cd /var/www/glpi && sudo -u www-data php bin/console cache:clear > /dev/null
echo "[done] GLPI URL set; REST API on, allowed from 10.10.10.1 only"
'@

# ---------- B. Help desk tech's AD password ----------
New-LabSecret -Name 'HELPDESK_aquinlan' -Comment 'CORP\aquinlan, help desk tech (SG-HelpDesk), used for ticket fixes'
Invoke-Command -VMName DC01 -Credential (Get-LabCredential "$DomainNetBIOS\labadmin" 'DOMAIN_ADMIN_labadmin') `
    -ArgumentList (ConvertTo-SecureString (Get-LabSecret 'HELPDESK_aquinlan') -AsPlainText -Force) -ScriptBlock {
    param($pw)
    # Same as Avery finishing her own first sign-in: her chosen password, no "must change" flag.
    Set-ADAccountPassword aquinlan -Reset -NewPassword $pw
    Set-ADUser aquinlan -ChangePasswordAtLogon $false
}
Write-Host '[done] CORP\aquinlan (help desk) has her own password'

# ---------- C + D. GLPI users and categories ----------
$s = Connect-Glpi
try {
    $people = @(
        @{ name = 'aquinlan';   firstname = 'Avery';  realname = 'Quinlan';   profile = 'Technician' }
        @{ name = 'mvexley';    firstname = 'Morgan'; realname = 'Vexley';    profile = 'Self-Service' }
        @{ name = 'cthornbury'; firstname = 'Casey';  realname = 'Thornbury'; profile = 'Self-Service' }
        @{ name = 'tbrightwell';firstname = 'Taylor'; realname = 'Brightwell';profile = 'Self-Service' }
        @{ name = 'dmarchetti'; firstname = 'Drew';   realname = 'Marchetti'; profile = 'Self-Service' }
        @{ name = 'plindqvist'; firstname = 'Parker'; realname = 'Lindqvist'; profile = 'Self-Service' }
    )
    $profiles = @{}
    (Invoke-Glpi $s GET 'Profile?range=0-50') | ForEach-Object { $profiles[$_.name] = $_.id }
    foreach ($p in $people) {
        if (Find-GlpiId $s 'User' $p.name) { Write-Host "[skip] GLPI user $($p.name)"; continue }
        $uid = (Invoke-Glpi $s POST 'User' @{ input = @{ name = $p.name; firstname = $p.firstname; realname = $p.realname; is_active = 1 } }).id
        if ($p.profile -ne 'Self-Service') {
            Invoke-Glpi $s POST 'Profile_User' @{ input = @{ users_id = $uid; profiles_id = $profiles[$p.profile]; entities_id = 0; is_recursive = 1 } } | Out-Null
        }
        Write-Host "[done] GLPI user $($p.name) ($($p.profile))"
    }
    foreach ($c in 'Account Access', 'Onboarding', 'File Shares', 'Permissions') {
        if (-not (Find-GlpiId $s 'ITILCategory' $c)) {
            Invoke-Glpi $s POST 'ITILCategory' @{ input = @{ name = $c; is_helpdeskvisible = 1 } } | Out-Null
            Write-Host "[done] Category $c"
        }
    }
} finally { Disconnect-Glpi $s }
