# UserPromptSubmit hook for the Agent Traffic Light.
#
# The user answered, so this session is no longer blocked on them. Drops the
# marker written by notify.ps1.
#
# This is not the only cleanup: approving a permission prompt does not submit a
# prompt, so the widget also clears every marker whenever no session is waiting.
# This hook just makes the common case immediate.

$ErrorActionPreference = 'Stop'

try {
    $raw = [Console]::In.ReadToEnd()
    if ([string]::IsNullOrWhiteSpace($raw)) { exit 0 }
    $payload = $raw | ConvertFrom-Json

    $sessionId = $payload.session_id
    if ([string]::IsNullOrWhiteSpace($sessionId)) { exit 0 }

    $markerDir = Join-Path (Split-Path -Parent $PSScriptRoot) 'state\markers'
    $safeId = ($sessionId -replace '[^A-Za-z0-9\-]', '')
    $marker = Join-Path $markerDir ($safeId + '.json')
    if (Test-Path $marker) { Remove-Item $marker -Force -ErrorAction SilentlyContinue }
} catch {
    exit 0
}

exit 0
