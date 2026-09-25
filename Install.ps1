# Sets up the Agent Traffic Light on this machine.
#
# Put the whole folder anywhere, then run this once from inside it. Safe to run
# again: it never duplicates a hook or a shortcut, it points hooks from an
# earlier install at this folder, and it restores your settings file if
# anything about the edit looks wrong.
#
#   powershell -NoProfile -ExecutionPolicy Bypass -File .\Install.ps1

$ErrorActionPreference = 'Stop'

$toolDir  = $PSScriptRoot
$script   = Join-Path $toolDir 'AgentTrafficLight.ps1'
$hooksDir = Join-Path $toolDir 'hooks'
$stateDir = Join-Path $toolDir 'state'

Write-Host "Agent Traffic Light installer"
Write-Host "  folder: $toolDir"
Write-Host ""

# --- checks -----------------------------------------------------------------

foreach ($needed in @($script,
                      (Join-Path $toolDir 'AgentTrafficLight.xaml'),
                      (Join-Path $toolDir 'Row.xaml'),
                      (Join-Path $toolDir 'Header.xaml'),
                      (Join-Path $hooksDir 'notify.ps1'),
                      (Join-Path $hooksDir 'clear.ps1'))) {
    if (-not (Test-Path $needed)) {
        Write-Host "MISSING: $needed" -ForegroundColor Red
        Write-Host "Copy the complete folder, not just the script." -ForegroundColor Red
        exit 1
    }
}

if ($PSVersionTable.PSVersion.Major -lt 5) {
    Write-Host "Needs Windows PowerShell 5.1 or newer." -ForegroundColor Red
    exit 1
}

if (-not (Test-Path $stateDir)) { New-Item -ItemType Directory -Path $stateDir | Out-Null }

# --- hooks ------------------------------------------------------------------
#
# The card can show working and waiting on its own, from the terminal window
# titles. The third state, waiting on a permission prompt, has no glyph in the
# title and can only come from these two hooks.

$settingsPath = Join-Path $env:USERPROFILE '.claude\settings.json'
if (-not (Test-Path $settingsPath)) {
    Write-Host "No $settingsPath - is Claude Code installed for this user?" -ForegroundColor Red
    exit 1
}

$originalText = Get-Content $settingsPath -Raw
$settings = $originalText | ConvertFrom-Json
$originalKeys = @($settings.PSObject.Properties.Name)

$pairs = @(@{ Event = 'Notification';      Script = 'notify.ps1' },
           @{ Event = 'UserPromptSubmit';  Script = 'clear.ps1'  })
foreach ($pair in $pairs) {
    $pair.Command = 'powershell -NoProfile -ExecutionPolicy Bypass -File "' + (Join-Path $hooksDir $pair.Script) + '"'
}

# An entry is ours when every hook in it carries our status message. Entries
# from an earlier install in another folder match this too, which is how they
# get replaced rather than left writing markers into a folder nothing reads.
function Test-OurEntry {
    param($Entry)
    $hooks = @($Entry.hooks)
    if ($hooks.Count -eq 0) { return $false }
    foreach ($h in $hooks) { if ($h.statusMessage -ne 'traffic light') { return $false } }
    return $true
}

$current = $true
foreach ($pair in $pairs) {
    $found = $false
    if ($settings.PSObject.Properties.Name.Contains('hooks') -and
        $settings.hooks.PSObject.Properties.Name.Contains($pair.Event)) {
        foreach ($e in @($settings.hooks.($pair.Event))) {
            foreach ($h in @($e.hooks)) { if ($h.command -eq $pair.Command) { $found = $true } }
        }
    }
    if (-not $found) { $current = $false }
}

if ($current) {
    Write-Host "hooks        already registered, left alone"
} else {
    $backup = $settingsPath + '.before-traffic-light.bak'
    if (-not (Test-Path $backup)) { Copy-Item $settingsPath $backup }

    if (-not $settings.PSObject.Properties.Name.Contains('hooks')) {
        $settings | Add-Member -MemberType NoteProperty -Name hooks -Value ([pscustomobject]@{})
    }

    foreach ($pair in $pairs) {
        $entry = [pscustomobject]@{
            hooks = @([pscustomobject]@{
                type          = 'command'
                command       = $pair.Command
                timeout       = 10
                statusMessage = 'traffic light'
            })
        }
        $existing = @()
        if ($settings.hooks.PSObject.Properties.Name.Contains($pair.Event)) {
            $existing = @($settings.hooks.($pair.Event) | Where-Object { -not (Test-OurEntry $_) })
        }
        $combined = @($existing) + @($entry)
        if ($settings.hooks.PSObject.Properties.Name.Contains($pair.Event)) {
            $settings.hooks.($pair.Event) = $combined
        } else {
            $settings.hooks | Add-Member -MemberType NoteProperty -Name $pair.Event -Value $combined
        }
    }

    $settings | ConvertTo-Json -Depth 32 | Set-Content -Path $settingsPath -Encoding UTF8

    # Read it back rather than trusting the write. A settings file is the user's,
    # and a round trip through ConvertTo-Json is the kind of thing that quietly
    # drops a key.
    $ok = $true
    try {
        $check = Get-Content $settingsPath -Raw | ConvertFrom-Json
        foreach ($k in $originalKeys) {
            if (-not $check.PSObject.Properties.Name.Contains($k)) { $ok = $false }
        }
        if (-not ($check.hooks.PSObject.Properties.Name.Contains('Notification'))) { $ok = $false }
        if (-not ($check.hooks.PSObject.Properties.Name.Contains('UserPromptSubmit'))) { $ok = $false }
    } catch { $ok = $false }

    if ($ok) {
        Write-Host "hooks        registered in $settingsPath"
    } else {
        Set-Content -Path $settingsPath -Value $originalText -Encoding UTF8 -NoNewline
        Write-Host "hooks        FAILED, your settings file was restored unchanged" -ForegroundColor Red
        Write-Host "             the card still works, without the permission colour" -ForegroundColor Yellow
    }
}

# --- shortcuts --------------------------------------------------------------

$shell = New-Object -ComObject WScript.Shell
$targets = @{
    'Startup'    = Join-Path ([Environment]::GetFolderPath('Startup')) 'Agent Traffic Light.lnk'
    'Start Menu' = Join-Path ([Environment]::GetFolderPath('Programs')) 'Agent Traffic Light.lnk'
}
foreach ($name in $targets.Keys) {
    $link = $shell.CreateShortcut($targets[$name])
    $link.TargetPath       = Join-Path $env:WINDIR 'System32\WindowsPowerShell\v1.0\powershell.exe'
    $link.Arguments        = '-NoProfile -ExecutionPolicy Bypass -STA -WindowStyle Hidden -File "' + $script + '"'
    $link.WorkingDirectory = $toolDir
    $link.WindowStyle      = 7
    $link.IconLocation     = 'imageres.dll,109'
    $link.Description      = 'Always-on-top status of your coding agent sessions'
    $link.Save()
    Write-Host ("{0,-12} {1}" -f $name.ToLower(), $targets[$name])
}

# --- start it ---------------------------------------------------------------

Start-Process powershell -ArgumentList '-NoProfile','-ExecutionPolicy','Bypass','-STA','-WindowStyle','Hidden','-File',$script -WindowStyle Hidden

Write-Host ""
Write-Host "Running. It starts by itself at login from now on."
Write-Host "Tray icon: left click hides or shows the card, right click quits."
Write-Host ""
Write-Host "If the card stays empty, your sessions are not in Windows Terminal windows."
Write-Host "Check with:  powershell -File `"$script`" -Probe -Passes 3"
