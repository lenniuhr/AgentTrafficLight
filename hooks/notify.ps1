# Notification hook for the Agent Traffic Light.
#
# Claude's terminal title has no glyph for "blocked on the user", so this hook
# is the only way the widget can tell a finished session from one that is
# sitting on a permission prompt. It writes one marker file per blocked session
# and gets out of the way.
#
# Runs on every notification, so it does no Add-Type and no module loading:
# compiling a P/Invoke class here would add a few hundred milliseconds to a hook
# that fires constantly.

$ErrorActionPreference = 'Stop'

try {
    $raw = [Console]::In.ReadToEnd()
    if ([string]::IsNullOrWhiteSpace($raw)) { exit 0 }
    $payload = $raw | ConvertFrom-Json

    $sessionId = $payload.session_id
    if ([string]::IsNullOrWhiteSpace($sessionId)) { exit 0 }

    # Only the types that mean the session cannot continue without the user.
    # The idle-timeout notification also arrives here and must not turn a row
    # red, because a session that merely finished is amber, not an alarm.
    $blocking = @('permission_prompt', 'elicitation_dialog', 'agent_needs_input')
    $type = $payload.notification_type

    if ([string]::IsNullOrWhiteSpace($type)) {
        # Older builds send no type. Fall back to the message text rather than
        # marking every notification as blocking.
        $msg = [string]$payload.message
        if ($msg -match 'permission|approve|confirm') { $type = 'permission_prompt' }
        else { exit 0 }
    }
    if ($blocking -notcontains $type) { exit 0 }

    # The file name is the session id and that is the entire join. The widget
    # resolves each row's session id through the process chain, so it can match
    # this marker exactly. An earlier version also recorded the console title
    # for fuzzy matching; nothing needs it any more.
    # Markers have a folder of their own because the widget deletes stale ones
    # by sweeping it, and that sweep must never reach the other state files.
    $markerDir = Join-Path (Split-Path -Parent $PSScriptRoot) 'state\markers'
    if (-not (Test-Path $markerDir)) { New-Item -ItemType Directory -Path $markerDir -Force | Out-Null }

    $safeId = ($sessionId -replace '[^A-Za-z0-9\-]', '')
    $marker = Join-Path $markerDir ($safeId + '.json')

    [pscustomobject]@{
        sessionId = $sessionId
        type      = $type
        at        = (Get-Date).ToString('o')
        cwd       = [string]$payload.cwd
    } | ConvertTo-Json | Set-Content -Path $marker -Encoding UTF8
} catch {
    # A hook that fails must never block the session it is reporting on.
    exit 0
}

exit 0
