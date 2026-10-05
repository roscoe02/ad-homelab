<#
.SYNOPSIS
    Shared plumbing for the five help desk ticket walkthroughs.

.DESCRIPTION
    Every ticket script follows the same pattern a real help desk tech would:
      1. Open-LabTicket       log the call in GLPI (requester, category, assigned to Avery Quinlan)
      2. Invoke-TicketStep    run a real command in the lab (on DC01 or a client), and record the
                              command plus its actual output as a GLPI follow-up
      3. Close-LabTicket      write the solution in GLPI and save the whole walkthrough to docs\tickets\
    Commands that need help desk rights run with Avery's own account (CORP\aquinlan), which only has
    the delegated reset/unlock rights from phase 3, not Domain Admin.
#>
. "$PSScriptRoot\..\lab-common.ps1"
. "$PSScriptRoot\..\glpi-api.ps1"

$script:AdminCred    = Get-LabCredential "$DomainNetBIOS\labadmin" 'DOMAIN_ADMIN_labadmin'
$script:HelpDeskCred = Get-LabCredential "$DomainNetBIOS\aquinlan" 'HELPDESK_aquinlan'

function Connect-GlpiAsTech {
    <#
    Logs in to GLPI as Avery Quinlan, so tickets and follow-ups show her as the author.
    The first time, her GLPI password is set by the admin. Then the session is switched to her
    Technician profile (new GLPI users also get Self-Service, which can't assign tickets).
    #>
    $pw = Get-LabSecret 'HELPDESK_aquinlan'
    $basic = [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes("aquinlan:$pw"))
    $login = { (Invoke-RestMethod "$GlpiApi/initSession" -Headers @{ Authorization = "Basic $basic" } -ContentType 'application/json').session_token }
    try { $s = & $login } catch {
        $admin = Connect-Glpi
        try {
            $id = Find-GlpiId $admin 'User' 'aquinlan'
            Invoke-Glpi $admin PUT "User/$id" @{ input = @{ password = $pw; password2 = $pw } } | Out-Null
        } finally { Disconnect-Glpi $admin }
        $s = & $login
    }
    $tech = (Invoke-Glpi $s GET 'getMyProfiles').myprofiles | Where-Object name -eq 'Technician'
    Invoke-Glpi $s POST 'changeActiveProfile' @{ profiles_id = $tech.id } | Out-Null
    $s
}

function Open-LabTicket {
    param(
        [Parameter(Mandatory)][string]$Number,      # e.g. '01', used for the doc file name
        [Parameter(Mandatory)][string]$Slug,        # e.g. 'password-reset'
        [Parameter(Mandatory)][string]$Title,
        [Parameter(Mandatory)][string]$Description,
        [Parameter(Mandatory)][string]$Requester,   # AD / GLPI username
        [Parameter(Mandatory)][string]$Category,
        [ValidateSet('Incident', 'Request')][string]$Type = 'Incident',
        [ValidateRange(1, 5)][int]$Urgency = 3
    )
    # Look up IDs with the admin session (technicians can't list categories), then work as Avery.
    $admin = Connect-Glpi
    try {
        $ids = @{
            Category  = Find-GlpiId $admin 'ITILCategory' $Category
            Requester = Find-GlpiId $admin 'User' $Requester
            Tech      = Find-GlpiId $admin 'User' 'aquinlan'
        }
    } finally { Disconnect-Glpi $admin }
    $s = Connect-GlpiAsTech
    $fields = @{
        name               = $Title
        content            = "<p>$([Net.WebUtility]::HtmlEncode($Description))</p>"
        type               = if ($Type -eq 'Incident') { 1 } else { 2 }
        urgency            = $Urgency
        requesttypes_id    = 3   # Phone: the user called the help desk
        itilcategories_id  = $ids.Category
        _users_id_requester = $ids.Requester
        _users_id_assign   = $ids.Tech
    }
    $id = (Invoke-Glpi $s POST 'Ticket' @{ input = $fields }).id
    Write-Host "[ticket] GLPI #$id opened: $Title"
    $script:Ticket = [pscustomobject]@{
        Session = $s; Id = $id; Number = $Number; Slug = $Slug; Title = $Title; Description = $Description
        Requester = $Requester; Category = $Category; Type = $Type; Steps = [Collections.Generic.List[object]]::new()
    }
}

function Invoke-TicketStep {
    <#
    Runs one troubleshooting/fix step and records it. -On picks the machine (PowerShell Direct).
    By default the step runs as the help desk tech; -AsAdmin runs it as CORP\labadmin (used only for
    things the scenario needs that a tech wouldn't do, like simulating the problem).
    #>
    param(
        [Parameter(Mandatory)][string]$Title,
        [Parameter(Mandatory)][scriptblock]$ScriptBlock,
        [string]$On = 'DC01',
        [object[]]$ArgumentList = @(),
        [switch]$AsAdmin,
        [string]$Note = '',
        [switch]$NoRecord          # for simulating the problem: shown in the doc as setup, not as a fix step
    )
    # PowerShell Direct connects as an admin; inside, AD commands use -Credential $cred (Avery) when given.
    $cred = if ($AsAdmin) { $null } else { $script:HelpDeskCred }
    $output = Invoke-Command -VMName $On -Credential $script:AdminCred -ScriptBlock $ScriptBlock -ArgumentList (@(, $cred) + $ArgumentList) 2>&1 |
        Out-String -Width 140
    # Drop the bookkeeping properties PowerShell remoting adds to every object.
    $output = (($output -split "`r?`n") | Where-Object { $_ -notmatch '^\s*(PSComputerName|RunspaceId|PSShowComputerName)\s*:' }) -join "`n"
    $output = $output.Trim()
    $code = ($ScriptBlock.ToString() -split "`n" | Where-Object { $_ -notmatch '^\s*param\(' } | ForEach-Object { $_.TrimEnd() }) -join "`n"
    $code = $code.Trim("`r", "`n")
    # Remove the common leading indentation so the recorded command reads cleanly.
    $indent = ($code -split "`n" | Where-Object { $_.Trim() } | ForEach-Object { ($_ -replace '^(\s*).*', '$1').Length } | Measure-Object -Minimum).Minimum
    if ($indent) { $code = ($code -split "`n" | ForEach-Object { if ($_.Length -ge $indent) { $_.Substring($indent) } else { $_.TrimStart() } }) -join "`n" }

    $step = [pscustomobject]@{ Title = $Title; On = $On; RunAs = $(if ($AsAdmin) { 'CORP\labadmin' } else { 'CORP\aquinlan (help desk)' }); Code = $code; Output = $output; Note = $Note; Setup = [bool]$NoRecord }
    $script:Ticket.Steps.Add($step)
    Write-Host "  [step] $Title"
    if ($output) { $output -split "`n" | ForEach-Object { Write-Host "         $_" } }

    if (-not $NoRecord) {
        $enc = { param($t) [Net.WebUtility]::HtmlEncode($t) }
        $html = "<p><b>$(& $enc $Title)</b> (on $On as $($step.RunAs))</p>"
        if ($Note) { $html += "<p>$(& $enc $Note)</p>" }
        $html += "<pre>PS&gt; $(& $enc $code)`n`n$(& $enc $output)</pre>"
        Invoke-Glpi $script:Ticket.Session POST 'ITILFollowup' @{ input = @{ itemtype = 'Ticket'; items_id = $script:Ticket.Id; content = $html } } | Out-Null
    }
    $output
}

function Add-TicketNote {
    <# A plain-text follow-up (e.g. "Verified the caller's identity by calling back their desk phone"). #>
    param([Parameter(Mandatory)][string]$Text)
    $script:Ticket.Steps.Add([pscustomobject]@{ Title = $Text; On = ''; RunAs = ''; Code = ''; Output = ''; Note = ''; Setup = $false })
    Invoke-Glpi $script:Ticket.Session POST 'ITILFollowup' @{ input = @{ itemtype = 'Ticket'; items_id = $script:Ticket.Id; content = "<p>$([Net.WebUtility]::HtmlEncode($Text))</p>" } } | Out-Null
    Write-Host "  [note] $Text"
}

function Close-LabTicket {
    <# Adds the solution in GLPI (status becomes Solved) and writes docs\tickets\<nn>-<slug>.md. #>
    param([Parameter(Mandatory)][string]$Solution, [Parameter(Mandatory)][string]$RootCause, [string[]]$Screenshots = @())
    $t = $script:Ticket
    Invoke-Glpi $t.Session POST 'ITILSolution' @{ input = @{ itemtype = 'Ticket'; items_id = $t.Id; content = "<p>$([Net.WebUtility]::HtmlEncode($Solution))</p>" } } | Out-Null
    $status = (Invoke-Glpi $t.Session GET "Ticket/$($t.Id)").status
    Disconnect-Glpi $t.Session

    $md = [Text.StringBuilder]::new()
    [void]$md.AppendLine("# Ticket $($t.Number): $($t.Title)")
    [void]$md.AppendLine()
    [void]$md.AppendLine("| | |")
    [void]$md.AppendLine("|---|---|")
    [void]$md.AppendLine("| GLPI ticket | #$($t.Id) ($($t.Type), category: $($t.Category)) |")
    [void]$md.AppendLine("| Requester | $($t.Requester) (fake user) |")
    [void]$md.AppendLine("| Assigned to | aquinlan, Avery Quinlan (help desk, SG-HelpDesk) |")
    [void]$md.AppendLine("| Status | $(if ($status -eq 5) { 'Solved' } else { "GLPI status $status" }) |")
    [void]$md.AppendLine()
    [void]$md.AppendLine("**User's report:** $($t.Description)")
    [void]$md.AppendLine()
    $setup = @($t.Steps | Where-Object Setup)
    if ($setup) {
        [void]$md.AppendLine('## Lab setup (simulating the problem)')
        [void]$md.AppendLine()
        foreach ($st in $setup) {
            [void]$md.AppendLine("**$($st.Title)** (on $($st.On) as $($st.RunAs))")
            [void]$md.AppendLine()
            [void]$md.AppendLine('```powershell'); [void]$md.AppendLine($st.Code); [void]$md.AppendLine('```')
            if ($st.Output) { [void]$md.AppendLine('```text'); [void]$md.AppendLine($st.Output); [void]$md.AppendLine('```') }
            [void]$md.AppendLine()
        }
    }
    [void]$md.AppendLine('## Troubleshooting and fix')
    [void]$md.AppendLine()
    $n = 1
    foreach ($st in @($t.Steps | Where-Object { -not $_.Setup })) {
        if (-not $st.Code) { [void]$md.AppendLine("### $n. Note"); [void]$md.AppendLine(); [void]$md.AppendLine($st.Title); [void]$md.AppendLine(); $n++; continue }
        [void]$md.AppendLine("### $n. $($st.Title)")
        [void]$md.AppendLine()
        [void]$md.AppendLine("*Ran on $($st.On) as $($st.RunAs)*")
        if ($st.Note) { [void]$md.AppendLine(); [void]$md.AppendLine($st.Note) }
        [void]$md.AppendLine()
        [void]$md.AppendLine('```powershell'); [void]$md.AppendLine($st.Code); [void]$md.AppendLine('```')
        if ($st.Output) { [void]$md.AppendLine('```text'); [void]$md.AppendLine($st.Output); [void]$md.AppendLine('```') }
        [void]$md.AppendLine()
        $n++
    }
    foreach ($shot in $Screenshots) { [void]$md.AppendLine("![$shot](../../screenshots/$shot)"); [void]$md.AppendLine() }
    [void]$md.AppendLine('## Root cause'); [void]$md.AppendLine(); [void]$md.AppendLine($RootCause); [void]$md.AppendLine()
    [void]$md.AppendLine('## Resolution'); [void]$md.AppendLine(); [void]$md.AppendLine($Solution)

    $docDir = Join-Path $RepoRoot 'docs\tickets'
    New-Item -ItemType Directory -Path $docDir -Force | Out-Null
    $path = Join-Path $docDir "$($t.Number)-$($t.Slug).md"
    [IO.File]::WriteAllText($path, $md.ToString(), (New-Object Text.UTF8Encoding $false))
    Write-Host "[ticket] GLPI #$($t.Id) solved. Walkthrough: docs\tickets\$(Split-Path $path -Leaf)"
}

# ----- Interactive sign-in on a client, through the VM's virtual keyboard -----
function Get-LabVMKeyboard {
    param([string]$Name)
    $vm = Get-CimInstance -Namespace root\virtualization\v2 -ClassName Msvm_ComputerSystem -Filter "ElementName='$Name'"
    Get-CimAssociatedInstance -InputObject $vm -ResultClassName Msvm_Keyboard
}

function Send-LabKeys {
    <#
    Types text into a VM one character at a time. (Long strings sent in one go can lose characters,
    which made the first sign-in test fail with "The user name or password is incorrect".)
    #>
    param([string]$VM, [string]$Text)
    $kb = Get-LabVMKeyboard $VM
    foreach ($ch in $Text.ToCharArray()) {
        Invoke-CimMethod -InputObject $kb -MethodName TypeText -Arguments @{ asciiText = [string]$ch } | Out-Null
        Start-Sleep -Milliseconds 40
    }
}

function Send-LabKey {
    <# Presses one key by virtual key code (13 Enter, 9 Tab, 8 Backspace, 27 Esc), optionally with Ctrl/Shift held. #>
    param([string]$VM, [int]$KeyCode, [switch]$Ctrl, [switch]$Shift)
    $kb = Get-LabVMKeyboard $VM
    $mods = @(); if ($Ctrl) { $mods += 17 }; if ($Shift) { $mods += 16 }
    foreach ($m in $mods) { Invoke-CimMethod -InputObject $kb -MethodName PressKey -Arguments @{ keyCode = $m } | Out-Null }
    Invoke-CimMethod -InputObject $kb -MethodName TypeKey -Arguments @{ keyCode = $KeyCode } | Out-Null
    foreach ($m in $mods) { Invoke-CimMethod -InputObject $kb -MethodName ReleaseKey -Arguments @{ keyCode = $m } | Out-Null }
    Start-Sleep -Milliseconds 150
}

function Start-LabSignIn {
    <# From the lock screen: Ctrl+Alt+Del, fill in "CORP\user" and the password, press Enter. #>
    param([string]$VM, [string]$User, [string]$SecretName)
    Send-LabKey $VM 16; Start-Sleep -Seconds 2               # Shift wakes a sleeping display without typing anything
    Invoke-CimMethod -InputObject (Get-LabVMKeyboard $VM) -MethodName TypeCtrlAltDel | Out-Null
    Start-Sleep -Seconds 3
    Send-LabKey $VM 0x41 -Ctrl; Send-LabKey $VM 8            # clear the user name box
    Send-LabKeys $VM "$DomainNetBIOS\$User"
    Send-LabKey $VM 9                                        # Tab to the password box
    Send-LabKey $VM 0x41 -Ctrl; Send-LabKey $VM 8
    Send-LabKeys $VM (Get-LabSecret $SecretName)
    Send-LabKey $VM 13
}

function Invoke-LabUserSignIn {
    <#
    Signs a user in on a client through the sign-in screen and waits for their desktop.
    With -NewSecretName the account has "must change password" set: Windows asks for a new password,
    which is typed from lab-secrets.txt. Screenshots are only taken of screens without passwords.
    #>
    param([string]$VM, [string]$User, [string]$SecretName, [string]$NewSecretName, [string]$ShotPrefix)
    $shots = @()
    Start-LabSignIn -VM $VM -User $User -SecretName $SecretName
    Start-Sleep -Seconds 6
    if ($NewSecretName) {
        if ($ShotPrefix) { $shots += Save-TicketScreenshot -VM $VM -File "$ShotPrefix-must-change-password.png" }
        Send-LabKey $VM 13; Start-Sleep -Seconds 3
        Send-LabKeys $VM (Get-LabSecret $NewSecretName); Send-LabKey $VM 9
        Send-LabKeys $VM (Get-LabSecret $NewSecretName); Send-LabKey $VM 13
        Start-Sleep -Seconds 5
        Send-LabKey $VM 13
    }
    $deadline = (Get-Date).AddMinutes(5)
    do {
        Start-Sleep -Seconds 10
        $up = Invoke-Command -VMName $VM -Credential $script:AdminCred -ArgumentList $User -ScriptBlock {
            param($u) [bool](Get-Process explorer -IncludeUserName -ErrorAction SilentlyContinue | Where-Object UserName -like "*\$u")
        }
    } until ($up -or (Get-Date) -gt $deadline)
    if (-not $up) { throw "$User did not reach the desktop on $VM" }
    Start-Sleep -Seconds 20   # let the first-sign-in animation and Group Policy finish
    $shots
}

function Show-LabThisPC {
    <# Opens File Explorer at "This PC" in the signed-in user's session (Win+R, then a shell command). #>
    param([string]$VM)
    Send-LabKey $VM 27                                   # close the Start menu if it is open
    $kb = Get-LabVMKeyboard $VM
    Invoke-CimMethod -InputObject $kb -MethodName PressKey -Arguments @{ keyCode = 0x5B } | Out-Null
    Invoke-CimMethod -InputObject $kb -MethodName TypeKey -Arguments @{ keyCode = 0x52 } | Out-Null
    Invoke-CimMethod -InputObject $kb -MethodName ReleaseKey -Arguments @{ keyCode = 0x5B } | Out-Null
    Start-Sleep -Seconds 2
    Send-LabKeys $VM 'explorer.exe shell:MyComputerFolder'
    Send-LabKey $VM 13
    Start-Sleep -Seconds 4
}

function Save-TicketScreenshot {
    <# Saves the VM's screen to screenshots\<file>. Only call when no password is visible. #>
    param([string]$VM, [string]$File)
    $dir = Join-Path $RepoRoot 'screenshots'
    New-Item -ItemType Directory -Path $dir -Force | Out-Null
    & (Join-Path $PSScriptRoot '..\Get-LabVMScreenshot.ps1') -Name $VM -OutFile (Join-Path $dir $File) | Out-Null
    $File
}

function Invoke-LabSignOut {
    <# Signs every interactive user out of a client (like clicking Sign out). #>
    param([string]$VM)
    Invoke-Command -VMName $VM -Credential $script:AdminCred -ScriptBlock {
        $sessions = quser 2>$null | Select-Object -Skip 1
        foreach ($line in $sessions) {
            $id = ($line -replace '^>', '' -split '\s+' | Where-Object { $_ -match '^\d+$' } | Select-Object -First 1)
            if ($id) { logoff $id }
        }
    }
}
