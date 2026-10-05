<#
.SYNOPSIS
    Phase 2: turn DC01 into the domain controller for corp.roscoe.internal, with DNS and DHCP.

.DESCRIPTION
    Everything runs inside the VM through PowerShell Direct (Invoke-Command -VMName),
    which goes through Hyper-V itself, so it works even before the VM has a working network.

    A. Static IP 10.10.10.10 (servers that others depend on should never change address),
       install the AD DS, DNS and DHCP roles, and promote DC01 to the first DC of a new forest.
    B. After the reboot: DNS forwarders for internet names, a reverse lookup zone, the DHCP
       scope for clients, accurate time for Kerberos, and the CORP\labadmin admin account.
    C. Checkpoint "02-AD-DNS-DHCP".

    Safe to re-run: part A is skipped if DC01 is already a domain controller.
#>
. "$PSScriptRoot\lab-common.ps1"
$Name = 'DC01'
$DCIP = $LabVMs[$Name].IP
$localCred  = Get-LabCredential 'Administrator' 'DC_LOCAL_ADMIN'
$domainCred = Get-LabCredential "$DomainNetBIOS\Administrator" 'DC_LOCAL_ADMIN'   # local Administrator becomes the domain Administrator

# ---------- A. IP, roles, promotion ----------
$alreadyDC = $false
try {
    $alreadyDC = Invoke-Command -VMName $Name -Credential $domainCred -ErrorAction Stop -ScriptBlock {
        (Get-CimInstance Win32_ComputerSystem).DomainRole -ge 4   # 4/5 = backup/primary domain controller
    }
} catch {}

if ($alreadyDC) {
    Write-Host '[skip] DC01 is already a domain controller'
} else {
    $dsrm = ConvertTo-SecureString (Get-LabSecret 'DSRM') -AsPlainText -Force
    Invoke-Command -VMName $Name -Credential $localCred -ArgumentList $DCIP, $DomainName, $DomainNetBIOS, $dsrm -ScriptBlock {
        param($ip, $domain, $netbios, $dsrm)
        $ErrorActionPreference = 'Stop'

        # Static IP. Gateway = the host's NAT address. DNS = itself (the DNS role is installed next).
        $nic = Get-NetAdapter | Where-Object Status -eq 'Up' | Select-Object -First 1
        if (-not (Get-NetIPAddress -InterfaceIndex $nic.ifIndex -IPAddress $ip -ErrorAction SilentlyContinue)) {
            Set-NetIPInterface -InterfaceIndex $nic.ifIndex -Dhcp Disabled
            New-NetIPAddress -InterfaceIndex $nic.ifIndex -IPAddress $ip -PrefixLength 24 -DefaultGateway '10.10.10.1' | Out-Null
        }
        Set-DnsClientServerAddress -InterfaceIndex $nic.ifIndex -ServerAddresses '127.0.0.1'
        Write-Host "[done] Static IP $ip"

        Install-WindowsFeature AD-Domain-Services, DNS, DHCP -IncludeManagementTools | Out-Null
        Write-Host '[done] Installed AD DS, DNS and DHCP roles'

        # New forest = brand new domain with this server as its first domain controller.
        # The DSRM password is for "Directory Services Restore Mode", the DC's offline repair mode.
        Install-ADDSForest -DomainName $domain -DomainNetbiosName $netbios -InstallDns `
            -SafeModeAdministratorPassword $dsrm -NoRebootOnCompletion -Force -WarningAction SilentlyContinue | Out-Null
        Write-Host "[done] Promoted to domain controller for $domain"
        Restart-Computer -Force
    }
    Write-Host '[info] DC01 is restarting as a domain controller (first boot takes a few minutes)...'
    Start-Sleep -Seconds 60
    Wait-LabVMReady -Name $Name -Credential $domainCred
}

# ---------- B. Post-promotion configuration ----------
Invoke-Command -VMName $Name -Credential $domainCred -ArgumentList $DCIP, $DomainName, (ConvertTo-SecureString (Get-LabSecret 'DOMAIN_ADMIN_labadmin') -AsPlainText -Force) -ScriptBlock {
    param($ip, $domain, $labadminPw)
    $ErrorActionPreference = 'Stop'

    # Wait for Active Directory Web Services, which the AD PowerShell module talks to.
    for ($i = 0; $i -lt 30; $i++) { try { Get-ADDomain | Out-Null; break } catch { Start-Sleep 10 } }

    # DNS: the DC answers for corp.roscoe.internal and forwards everything else to public resolvers.
    Set-DnsServerForwarder -IPAddress '1.1.1.1', '9.9.9.9'
    if (-not (Get-DnsServerZone -Name '10.10.10.in-addr.arpa' -ErrorAction SilentlyContinue)) {
        # Reverse zone: lets you look up a name from an IP (nslookup 10.10.10.10).
        Add-DnsServerPrimaryZone -NetworkId '10.10.10.0/24' -ReplicationScope Domain
    }
    Write-Host '[done] DNS forwarders and reverse lookup zone'

    # DHCP: must be "authorized" in AD before it will hand out addresses. This is AD's built-in
    # protection against rogue DHCP servers on a domain network.
    $fqdn = "$env:COMPUTERNAME.$domain"
    if (-not (Get-DhcpServerInDC | Where-Object IPAddress -eq $ip)) { Add-DhcpServerInDC -DnsName $fqdn -IPAddress $ip }
    Add-DhcpServerSecurityGroup -ErrorAction SilentlyContinue
    Set-ItemProperty 'HKLM:\SOFTWARE\Microsoft\ServerManager\Roles\12' -Name ConfigurationState -Value 2  # clears Server Manager's "finish DHCP setup" flag
    Restart-Service DHCPServer

    # Clients get .100-.200. Servers (.10 DC01, .20 TKT01) are static and outside the range.
    if (-not (Get-DhcpServerv4Scope -ScopeId '10.10.10.0' -ErrorAction SilentlyContinue)) {
        Add-DhcpServerv4Scope -Name 'Lab clients' -StartRange '10.10.10.100' -EndRange '10.10.10.200' `
            -SubnetMask '255.255.255.0' -LeaseDuration '8.00:00:00' -State Active
    }
    Set-DhcpServerv4OptionValue -ScopeId '10.10.10.0' -Router '10.10.10.1' -DnsServer $ip -DnsDomain $domain
    Write-Host '[done] DHCP authorized; scope 10.10.10.100-200 (gateway 10.10.10.1, DNS 10.10.10.10)'

    # Time: Kerberos fails if clocks differ by more than 5 minutes. The first DC is the domain's
    # time source, so it syncs from internet time, not from the Hyper-V host.
    Set-ItemProperty 'HKLM:\SYSTEM\CurrentControlSet\Services\W32Time\TimeProviders\VMICTimeProvider' -Name Enabled -Value 0
    w32tm /config /manualpeerlist:"time.windows.com,0x8 pool.ntp.org,0x8" /syncfromflags:manual /reliable:yes /update | Out-Null
    Restart-Service w32time
    w32tm /resync /force | Out-Null
    Write-Host '[done] DC time syncs from internet NTP'

    # Day-to-day admin account, so the built-in Administrator stays a break-glass account.
    if (-not (Get-ADUser -Filter "SamAccountName -eq 'labadmin'")) {
        New-ADUser -Name 'Lab Admin' -SamAccountName 'labadmin' -UserPrincipalName "labadmin@$domain" `
            -AccountPassword $labadminPw -Enabled $true -PasswordNeverExpires $true -Description 'Lab domain administrator'
    }
    Add-ADGroupMember 'Domain Admins' -Members 'labadmin'
    Write-Host '[done] CORP\labadmin created in Domain Admins'
}

# ---------- C. Checkpoint ----------
if (-not (Get-VMSnapshot -VMName $Name -Name '02-AD-DNS-DHCP' -ErrorAction SilentlyContinue)) {
    Checkpoint-VM -Name $Name -SnapshotName '02-AD-DNS-DHCP'
}
Write-Host "[done] DC01 configured. Checkpoint '02-AD-DNS-DHCP' taken. Lab disk usage: $(Get-LabDiskUsage) GB"
