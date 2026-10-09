# Agent Traffic Light
#
# An always-on-top card showing the live state of every coding agent session.
# See README.md for why it works the way it does. The short version:
#
# The source of truth is the set of Windows Terminal windows, not
# ~/.claude/sessions/*.json. The session files are written on state change and
# never heartbeated (measured 892 s stale on a live session), so they can never
# tell us a session died. Windows can: the window closes and the row goes away.
#
# Run with -Probe to get stage-1 console output instead of the card.

param(
    [switch]$Probe,
    # Probe passes to run before exiting. 0 runs until Ctrl+C.
    [int]$Passes = 0
)

$ErrorActionPreference = 'Stop'

# The widget runs with its console hidden, so an unhandled error would otherwise
# vanish without a trace. Everything that escapes lands in state/error.log.
$errorLog = Join-Path $PSScriptRoot 'state\error.log'
function Write-ErrorLog {
    param([string]$Where, $Problem)
    try {
        $line = "{0} [{1}] {2}" -f (Get-Date -Format 'o'), $Where, ($Problem | Out-String).Trim()
        Add-Content -Path $errorLog -Value $line -Encoding UTF8
    } catch { }
}
trap {
    Write-ErrorLog -Where 'startup' -Problem $_
    break
}

$stateDir = Join-Path $PSScriptRoot 'state'
if (-not (Test-Path $stateDir)) { New-Item -ItemType Directory -Path $stateDir | Out-Null }
$positionFile = Join-Path $stateDir 'window-position.json'

# ---------------------------------------------------------------------------
# Tuning. Sizes and colours live in the XAML; only timings live here, because
# they are driven from code rather than from storyboards.
# ---------------------------------------------------------------------------
$titlePollMs   = 400    # reading titles of known handles costs 0.35 ms
$windowSweepMs = 3000   # a full EnumWindows sweep costs 6.2 ms, peaks at 36 ms
# Row height is read back from Row.xaml once a row exists, so the layout and the
# design file can never disagree about it. This is only the value used before
# the first row is built.
$rowHeight     = 42
$rowGap        = 6
$headerHeight  = 22   # drawn above every resolved workspace group
$groupGap      = 8
$ctxBarWidth   = 330  # row width less the stripe it starts after and its margins
$ctxHighMark   = 0.8  # fraction of the window at which the bar turns amber
$transcriptTail = 98304  # bytes read from the end of a transcript
$transcriptTailMax = 1572864  # furthest back the read widens to find a usage record
$cardPadding   = 10
$cardWidth     = 380
$shadowMargin  = 12
$flipMs        = 180    # colour change and slide when a row changes state
$blinkMs       = 600    # one beat of the three-beat permission alarm
$breatheMs     = 2000   # permission settles into this after the beats
$dotBreatheMs  = 2400   # the only motion on a calm card

# ---------------------------------------------------------------------------
# Glyph vocabulary. Written as code points on purpose: PowerShell 5.1 reads a
# script file as ANSI unless it has a BOM, which would mangle these characters
# if they appeared literally.
# ---------------------------------------------------------------------------
$glyphWorking = @([char]0x25D0, [char]0x25D1, [char]0x25D2, [char]0x25D3, [char]0x00B7)
$glyphWaiting = @([char]0x2733)

Add-Type -AssemblyName PresentationFramework
Add-Type -AssemblyName PresentationCore
Add-Type -AssemblyName WindowsBase
Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing

Add-Type @"
using System;
using System.Text;
using System.Runtime.InteropServices;

public class TlNative {
    public delegate bool EnumProc(IntPtr hWnd, IntPtr lParam);

    [DllImport("user32.dll")] public static extern bool EnumWindows(EnumProc cb, IntPtr lParam);
    [DllImport("user32.dll")] public static extern bool IsWindow(IntPtr hWnd);
    [DllImport("user32.dll")] public static extern bool IsWindowVisible(IntPtr hWnd);
    [DllImport("user32.dll", CharSet = CharSet.Unicode)] public static extern int GetWindowTextW(IntPtr hWnd, StringBuilder s, int max);
    [DllImport("user32.dll", CharSet = CharSet.Unicode)] public static extern int GetClassNameW(IntPtr hWnd, StringBuilder s, int max);
    [DllImport("user32.dll")] public static extern uint GetWindowThreadProcessId(IntPtr hWnd, out uint pid);

    // The link that makes workspaces knowable. A session's shell owns a hidden
    // PseudoConsoleWindow, and that window's parent is exactly the Windows
    // Terminal window showing it. Verified against known session/window pairs.
    [DllImport("user32.dll")] public static extern IntPtr GetParent(IntPtr hWnd);

    [DllImport("user32.dll")] public static extern bool SetForegroundWindow(IntPtr hWnd);
    [DllImport("user32.dll")] public static extern bool BringWindowToTop(IntPtr hWnd);
    [DllImport("user32.dll")] public static extern bool ShowWindow(IntPtr hWnd, int cmd);
    [DllImport("user32.dll")] public static extern bool IsIconic(IntPtr hWnd);
    [DllImport("user32.dll")] public static extern bool AttachThreadInput(uint attach, uint attachTo, bool doAttach);
    [DllImport("kernel32.dll")] public static extern uint GetCurrentThreadId();
    [DllImport("user32.dll")] public static extern IntPtr GetForegroundWindow();

    [StructLayout(LayoutKind.Sequential)]
    public struct FLASHWINFO {
        public uint cbSize; public IntPtr hwnd; public uint dwFlags; public uint uCount; public uint dwTimeout;
    }
    [DllImport("user32.dll")] public static extern bool FlashWindowEx(ref FLASHWINFO pwfi);

    // Parent-pid lookup via a process snapshot. The obvious PowerShell way,
    // Get-CimInstance Win32_Process, measured 300-470 ms, which is a visible
    // hitch on the UI thread every time the map is rebuilt. This is under 10.
    [StructLayout(LayoutKind.Sequential, CharSet = CharSet.Unicode)]
    public struct PROCESSENTRY32W {
        public uint dwSize; public uint cntUsage; public uint th32ProcessID;
        public IntPtr th32DefaultHeapID; public uint th32ModuleID; public uint cntThreads;
        public uint th32ParentProcessID; public int pcPriClassBase; public uint dwFlags;
        [MarshalAs(UnmanagedType.ByValTStr, SizeConst = 260)] public string szExeFile;
    }
    [DllImport("kernel32.dll")] public static extern IntPtr CreateToolhelp32Snapshot(uint flags, uint pid);
    [DllImport("kernel32.dll", CharSet = CharSet.Unicode)] public static extern bool Process32FirstW(IntPtr snap, ref PROCESSENTRY32W pe);
    [DllImport("kernel32.dll", CharSet = CharSet.Unicode)] public static extern bool Process32NextW(IntPtr snap, ref PROCESSENTRY32W pe);
    [DllImport("kernel32.dll")] public static extern bool CloseHandle(IntPtr h);

    public static System.Collections.Generic.Dictionary<int, int> ParentsOf(string exeName) {
        var map = new System.Collections.Generic.Dictionary<int, int>();
        IntPtr snap = CreateToolhelp32Snapshot(0x00000002, 0); // TH32CS_SNAPPROCESS
        if (snap == new IntPtr(-1)) { return map; }
        PROCESSENTRY32W pe = new PROCESSENTRY32W();
        pe.dwSize = (uint)Marshal.SizeOf(typeof(PROCESSENTRY32W));
        if (Process32FirstW(snap, ref pe)) {
            do {
                if (string.Equals(pe.szExeFile, exeName, StringComparison.OrdinalIgnoreCase)) {
                    map[(int)pe.th32ProcessID] = (int)pe.th32ParentProcessID;
                }
            } while (Process32NextW(snap, ref pe));
        }
        CloseHandle(snap);
        return map;
    }

    // The window scan, done here rather than in PowerShell. EnumWindows calls
    // its callback once per top-level window, a few hundred times on a normal
    // desktop, and a PowerShell scriptblock as that callback cost about 40 ms
    // per sweep. The same walk in C# is a couple of milliseconds.
    public class ScanResult {
        public System.Collections.Generic.List<IntPtr> Terminals = new System.Collections.Generic.List<IntPtr>();
        public System.Collections.Generic.Dictionary<int, IntPtr> ShellToWindow = new System.Collections.Generic.Dictionary<int, IntPtr>();
    }

    public static ScanResult Scan(string terminalClass) {
        ScanResult res = new ScanResult();
        EnumWindows(delegate(IntPtr h, IntPtr l) {
            StringBuilder cls = new StringBuilder(256);
            GetClassNameW(h, cls, 256);
            string name = cls.ToString();
            if (name == terminalClass) {
                if (IsWindowVisible(h)) { res.Terminals.Add(h); }
            } else if (name == "PseudoConsoleWindow") {
                uint owner;
                GetWindowThreadProcessId(h, out owner);
                IntPtr parent = GetParent(h);
                if (parent != IntPtr.Zero) { res.ShellToWindow[(int)owner] = parent; }
            }
            return true;
        }, IntPtr.Zero);
        return res;
    }

    [DllImport("kernel32.dll")] public static extern IntPtr GetConsoleWindow();
    [DllImport("user32.dll")] public static extern int GetWindowLong(IntPtr hWnd, int index);
    [DllImport("user32.dll")] public static extern int SetWindowLong(IntPtr hWnd, int index, int newLong);
    [DllImport("user32.dll")] public static extern bool SetProcessDpiAwarenessContext(IntPtr value);
    [DllImport("user32.dll")] public static extern bool DestroyIcon(IntPtr hIcon);

    // Flash the taskbar button as the fallback when Windows refuses to hand over
    // the foreground. FLASHW_ALL | FLASHW_TIMERNOFG.
    public static void Flash(IntPtr hWnd) {
        FLASHWINFO fi = new FLASHWINFO();
        fi.cbSize = (uint)Marshal.SizeOf(typeof(FLASHWINFO));
        fi.hwnd = hWnd;
        fi.dwFlags = 0x00000003 | 0x0000000C;
        fi.uCount = 3;
        fi.dwTimeout = 0;
        FlashWindowEx(ref fi);
    }

    // Windows refuses SetForegroundWindow from a process that does not own the
    // foreground. Clicking the card makes us the foreground process, which is
    // allowed to hand it on, but attaching to the current foreground thread
    // first is what makes it reliable. Returns false if Windows still says no,
    // and the caller falls back to flashing.
    public static bool Focus(IntPtr hWnd) {
        if (!IsWindow(hWnd)) { return false; }
        if (IsIconic(hWnd)) { ShowWindow(hWnd, 9); } // SW_RESTORE

        IntPtr fg = GetForegroundWindow();
        uint fgPid;
        uint fgThread = GetWindowThreadProcessId(fg, out fgPid);
        uint myThread = GetCurrentThreadId();

        bool attached = false;
        if (fgThread != myThread) { attached = AttachThreadInput(myThread, fgThread, true); }
        BringWindowToTop(hWnd);
        bool ok = SetForegroundWindow(hWnd);
        if (attached) { AttachThreadInput(myThread, fgThread, false); }

        if (!ok) { Flash(hWnd); }
        return ok;
    }
}
"@

$GWL_EXSTYLE       = -20
$WS_EX_TOOLWINDOW  = 0x00000080
$SW_HIDE           = 0
$TERMINAL_CLASS    = 'CASCADIA_HOSTING_WINDOW_CLASS'

# Parsed session files, keyed by path, invalidated by last-write time.
$script:sessionFileCache = @{}

# Transcript lookups. Paths are resolved once per session; the facts read out of
# each transcript are invalidated by last-write time, so an idle session costs
# nothing beyond a stat.
$script:transcriptPaths = @{}
$script:transcriptCache = @{}

# Claude reports no exact context figure anywhere, so the window is a fixed
# assumption. It used to be read from the default model in settings.json, once
# at startup, and was wrong both ways: /model rewrites that default while the
# widget runs, so a card started under "fable" kept dividing by 200k after the
# default went back to "opus[1m]", and the [1m] suffix never decided the window
# anyway. Every /context reading recorded on this machine showed 1m for Opus 5,
# Fable 5 and Fable 5.1 alike, with or without the suffix.
$script:contextWindow = 1000000

# ---------------------------------------------------------------------------
# Scanning
# ---------------------------------------------------------------------------

# One enumeration, two answers: which terminal windows exist, and which shell
# process owns which of them. Both are needed on every sweep and walking the
# whole window list twice was the single biggest cost in it.
#
# Runs on the slow timer. It decides which windows exist, never what state they
# are in; that comes from the titles on the fast timer.
function Scan-Windows {
    return [TlNative]::Scan($TERMINAL_CLASS)
}

function Get-WindowTitle {
    param([IntPtr]$Handle)
    if (-not [TlNative]::IsWindow($Handle)) { return $null }
    $sb = New-Object System.Text.StringBuilder 512
    [TlNative]::GetWindowTextW($Handle, $sb, 512) | Out-Null
    return $sb.ToString()
}

# A title is ours only if it starts with a glyph we know. That filter is what
# keeps a plain terminal window, or someone's unrelated shell, off the card.
function Read-SessionTitle {
    param([string]$Title)
    if ([string]::IsNullOrEmpty($Title)) { return $null }
    $lead = $Title[0]
    $state = $null
    if ($glyphWorking -contains $lead) { $state = 'Working' }
    elseif ($glyphWaiting -contains $lead) { $state = 'Waiting' }
    else { return $null }
    $label = $Title.Substring(1).Trim()
    if ($label -eq '') { $label = 'Session' }
    return @{ State = $state; Label = $label }
}

# Live interactive sessions, whether or not their window could be resolved.
# Only used to notice that the card is showing fewer rows than there are
# sessions, which is the tabbed-window failure the plan warns about.
function Get-LiveSessionCount {
    $dir = Join-Path $env:USERPROFILE '.claude\sessions'
    if (-not (Test-Path $dir)) { return 0 }
    $n = 0
    foreach ($f in (Get-ChildItem $dir -Filter *.json -ErrorAction SilentlyContinue)) {
        try {
            $s = Get-Content $f.FullName -Raw | ConvertFrom-Json
            if ($s.kind -ne 'interactive') { continue }
            if (Get-Process -Id $s.pid -ErrorAction SilentlyContinue) { $n++ }
        } catch { }
    }
    return $n
}

# Which session is behind which window, resolved exactly rather than guessed.
#
# The chain is: session file gives a pid and a cwd -> that claude.exe's parent
# is its shell -> the shell owns a hidden PseudoConsoleWindow -> that window's
# parent is the terminal window on screen. Every step is an identity, so there
# is no matching on titles and no time correlation anywhere in it.
#
# Runs on the slow timer because of the one process query it needs.
function Sync-SessionMap {
    param($ShellToWindow)

    $shellToWindow = $ShellToWindow
    $claudeParents = [TlNative]::ParentsOf('claude.exe')

    $map = @{}
    $live = 0
    $pending = New-Object System.Collections.ArrayList
    $dir = Join-Path $env:USERPROFILE '.claude\sessions'
    if (Test-Path $dir) {
        foreach ($f in (Get-ChildItem $dir -Filter *.json -ErrorAction SilentlyContinue)) {
            try {
                # ConvertFrom-Json costs about ten milliseconds a file in
                # PowerShell 5.1, which is most of the sweep. Nothing in a
                # session file that this cares about changes without the file
                # being rewritten, so parse only what actually moved.
                $cached = $script:sessionFileCache[$f.FullName]
                if ($null -eq $cached -or $cached.Mtime -ne $f.LastWriteTimeUtc.Ticks) {
                    $s = Get-Content $f.FullName -Raw | ConvertFrom-Json
                    $cached = @{
                        Mtime     = $f.LastWriteTimeUtc.Ticks
                        Pid       = [int]$s.pid
                        Kind      = [string]$s.kind
                        SessionId = [string]$s.sessionId
                        Cwd       = [string]$s.cwd
                        Workspace = Split-Path -Leaf ([string]$s.cwd)
                        StartedAt = [double]$s.startedAt
                        # busy or idle, and when that last changed. Claude
                        # writes this itself, so it is the one record of when
                        # a session finished that outlives a widget restart.
                        Status          = [string]$s.status
                        StatusUpdatedAt = [double]$s.statusUpdatedAt
                    }
                    $script:sessionFileCache[$f.FullName] = $cached
                }
                if ($cached.Kind -ne 'interactive') { continue }

                # A pid that is gone means a stale file. The file's age says
                # nothing, since these are written on state change and never
                # heartbeated.
                if (-not $claudeParents.ContainsKey($cached.Pid)) { continue }
                $live++

                $shell = $claudeParents[$cached.Pid]
                if (-not $shellToWindow.ContainsKey($shell)) {
                    # Windows Terminal has two hosting modes. Usually the shell
                    # itself owns the hidden console window, which is the exact
                    # join. Sometimes a separate OpenConsole.exe owns it instead,
                    # and then nothing links that window back to the shell.
                    # Park the session and pair it up below.
                    [void]$pending.Add(@{ Shell = $shell; Info = $cached })
                    continue
                }
                $hwnd = $shellToWindow[$shell]
                $map[[string][int64]$hwnd] = $cached
            } catch { }
        }
    }
    # Sessions whose window is hosted by an OpenConsole rather than by their own
    # shell. Nothing links the two by identity, so they are paired by start time:
    # a console host is created in the same instant as the shell it serves, which
    # was an exact same-second match when this was measured.
    #
    # Deliberately conservative. A session is only paired to a window if that
    # window is its nearest in time AND within five seconds. Anything ambiguous
    # is left unresolved, because a row labelled with the wrong workspace is
    # worse than a row labelled with none.
    if ($pending.Count -gt 0) {
        $unclaimed = New-Object System.Collections.ArrayList
        foreach ($hostPid in $shellToWindow.Keys) {
            $hwnd = $shellToWindow[$hostPid]
            if ($map.ContainsKey([string][int64]$hwnd)) { continue }
            $startedAt = $null
            try { $startedAt = (Get-Process -Id $hostPid -ErrorAction Stop).StartTime } catch { }
            if ($null -ne $startedAt) {
                [void]$unclaimed.Add(@{ Hwnd = $hwnd; Started = $startedAt; Taken = $false })
            }
        }

        foreach ($item in $pending) {
            $shellStart = $null
            try { $shellStart = (Get-Process -Id $item.Shell -ErrorAction Stop).StartTime } catch { }
            if ($null -eq $shellStart) { continue }

            $best = $null
            $bestGap = [double]::MaxValue
            foreach ($candidate in $unclaimed) {
                if ($candidate.Taken) { continue }
                $gap = [Math]::Abs(($candidate.Started - $shellStart).TotalSeconds)
                if ($gap -lt $bestGap) { $bestGap = $gap; $best = $candidate }
            }
            if ($null -ne $best -and $bestGap -le 5) {
                $best.Taken = $true
                $map[[string][int64]$best.Hwnd] = $item.Info
            }
        }
    }

    $script:sessionByHwnd = $map
    # Cached rather than recounted on the fast timer: this used to run a
    # Get-Process per session every 400 ms for a number that changes only when
    # a session opens or closes.
    $script:liveSessionCount = $live
}

# Model and context come from the session's own transcript, which is the only
# place either is recorded. These files reach several megabytes over a day, so
# only the tail is read, and only when the file has actually changed.
function Sync-SessionExtras {
    foreach ($key in @($script:sessionByHwnd.Keys)) {
        $info = $script:sessionByHwnd[$key]

        $path = $script:transcriptPaths[$info.SessionId]
        if (-not $path) {
            $projRoot = Join-Path $env:USERPROFILE '.claude\projects'
            if (-not (Test-Path $projRoot)) { continue }
            $hit = Get-ChildItem $projRoot -Filter ($info.SessionId + '.jsonl') -Recurse -File -ErrorAction SilentlyContinue |
                   Select-Object -First 1
            if (-not $hit) { continue }
            $path = $hit.FullName
            $script:transcriptPaths[$info.SessionId] = $path
        }

        $fi = Get-Item $path -ErrorAction SilentlyContinue
        if (-not $fi) { continue }

        $cached = $script:transcriptCache[$path]
        if ($null -eq $cached -or $cached.Mtime -ne $fi.LastWriteTimeUtc.Ticks) {
            if ($null -eq $cached) { $cached = @{ Model = ''; Prompt = 0 } }
            $cached.Mtime = $fi.LastWriteTimeUtc.Ticks

            $text = ''
            try {
                # FileShare must allow writing: the session owning this file is
                # appending to it right now.
                $stream = [System.IO.File]::Open($path, [System.IO.FileMode]::Open,
                                                 [System.IO.FileAccess]::Read,
                                                 [System.IO.FileShare]::ReadWrite)
                try {
                    # Claude writes records far larger than the tail after every
                    # reply (a prompt snapshot measured 148 KB), which pushes the
                    # last usage record out of reach. The figure from before then
                    # stayed on the bar, so a compacted session read 96 % full.
                    # Widen the read until it holds a usage record or a
                    # compaction; the first tail still finds one mid-turn, so the
                    # common case reads no more than before.
                    $take = [Math]::Min([long]$transcriptTail, $stream.Length)
                    while ($true) {
                        [void]$stream.Seek($stream.Length - $take, [System.IO.SeekOrigin]::Begin)
                        $buffer = New-Object byte[] $take
                        [void]$stream.Read($buffer, 0, $take)
                        $text = [System.Text.Encoding]::UTF8.GetString($buffer)
                        if ($text -match '"input_tokens":|"postTokens":') { break }
                        if ($take -ge $stream.Length -or $take -ge $transcriptTailMax) { break }
                        $take = [Math]::Min([Math]::Min($take * 4, [long]$transcriptTailMax), $stream.Length)
                    }
                } finally { $stream.Dispose() }
            } catch { }

            if ($text -ne '') {
                # Regex rather than ConvertFrom-Json: parsing a hundred kilobytes
                # of JSON per session per sweep is far too slow, and only a
                # handful of numbers are wanted out of it.
                #
                # Records with model "<synthetic>" carry no real token counts, so
                # walking back to the last genuine one matters; a session whose
                # tail ends in synthetic records otherwise reads as empty.
                $matchesModel = [regex]::Matches($text, '"model":"([^"]+)"')
                for ($i = $matchesModel.Count - 1; $i -ge 0; $i--) {
                    $candidate = $matchesModel[$i].Groups[1].Value
                    if ($candidate -ne '<synthetic>') { $cached.Model = $candidate; break }
                }

                $prompt = 0
                $lastUsageAt = -1
                foreach ($pattern in @('"input_tokens":(\d+)',
                                       '"cache_creation_input_tokens":(\d+)',
                                       '"cache_read_input_tokens":(\d+)')) {
                    $hits = [regex]::Matches($text, $pattern)
                    if ($hits.Count -gt 0) {
                        $prompt += [int]$hits[$hits.Count - 1].Groups[1].Value
                        $lastUsageAt = [Math]::Max($lastUsageAt, $hits[$hits.Count - 1].Index)
                    }
                }

                # A compaction later than the last usage record means the context
                # was just replaced by its summary, and no reply has reported a
                # size since. The boundary record carries that size itself as
                # postTokens, so the bar drops the moment the compaction lands
                # rather than on the next reply.
                $compactions = [regex]::Matches($text, '"postTokens":(\d+)')
                $lastCompaction = $null
                if ($compactions.Count -gt 0) { $lastCompaction = $compactions[$compactions.Count - 1] }
                if ($null -ne $lastCompaction -and $lastCompaction.Index -gt $lastUsageAt) {
                    $cached.Prompt = [int]$lastCompaction.Groups[1].Value
                } elseif ($prompt -gt 0) {
                    # Keep the previous figure rather than showing zero when the
                    # tail happens to hold no usable record.
                    $cached.Prompt = $prompt
                }
            }

            $script:transcriptCache[$path] = $cached
        }

        $info.Model = $cached.Model
        $info.Prompt = $cached.Prompt
    }
}

# Headers are pooled rather than created and destroyed, because a workspace
# appearing and disappearing is common and rebuilding elements on a 400 ms
# timer would churn the visual tree for nothing.
function Get-Header {
    param([int]$Index)
    while ($script:headerPool.Count -le $Index) {
        $element = Import-Xaml 'Header.xaml'
        $rowCanvas.Children.Add($element) | Out-Null
        [void]$script:headerPool.Add(@{
            Element = $element
            Label   = $element.FindName('HeaderLabel')
            Swatch  = $element.FindName('Swatch')
        })
    }
    return $script:headerPool[$Index]
}

# Hue by position in the alphabetically sorted list of workspaces currently on
# screen. Hashing the path was the first attempt, and it is more stable across
# restarts, but two workspaces then had a one-in-four chance of drawing the same
# colour, which is the only thing this stripe exists to prevent. Indexing can
# only shift colours when a workspace is opened or closed, which is rare and
# visible when it happens.
function Get-WorkspaceBrush {
    param([int]$Index)
    return $brush.Ws[$Index % $brush.Ws.Count]
}

# ---------------------------------------------------------------------------
# Stage 1: console probe. Kept in the shipping script so the parsing can always
# be checked against reality without the UI in the way.
# ---------------------------------------------------------------------------
if ($Probe) {
    $pass = 0
    while ($true) {
        $pass++
        $sw = [System.Diagnostics.Stopwatch]::StartNew()
        $scan = Scan-Windows
        Sync-SessionMap -ShellToWindow $scan.ShellToWindow
        $found = @()
        foreach ($h in $scan.Terminals) {
            $title = Get-WindowTitle -Handle $h
            $parsed = Read-SessionTitle -Title $title
            if ($parsed) {
                $key = [string][int64]$h
                $ws = 'UNRESOLVED'
                if ($script:sessionByHwnd.ContainsKey($key)) { $ws = $script:sessionByHwnd[$key].Workspace }
                $found += ('  {0,-10} {1,-8} {2,-28} {3}' -f [int64]$h, $parsed.State, $ws, $parsed.Label)
            }
        }
        $sw.Stop()
        # Uses the count Sync-SessionMap already worked out. Calling
        # Get-LiveSessionCount here instead would add a Get-Process per session
        # and make the timing above look four times worse than the widget's.
        Write-Host ("{0}  pass {1}  sweep {2:0.0} ms  windows={3}  live sessions={4}" -f `
            (Get-Date -Format 'HH:mm:ss'), $pass, $sw.Elapsed.TotalMilliseconds, $found.Count, $script:liveSessionCount)
        $found | ForEach-Object { Write-Host $_ }
        if ($Passes -gt 0 -and $pass -ge $Passes) { break }
        Start-Sleep -Milliseconds 1000
    }
    return
}

# ---------------------------------------------------------------------------
# Widget
# ---------------------------------------------------------------------------

# One card only. Launching from the Start Menu while the Startup copy is already
# running would otherwise stack two identical cards on top of each other.
#
# The second instance does not simply die, because the usual reason for
# launching again is that the card was hidden to the tray and is wanted back. It
# leaves a flag that the running instance picks up on its next poll, then exits.
$showFlag = Join-Path $stateDir 'show.flag'
$createdNew = $false
$script:instanceMutex = New-Object System.Threading.Mutex($true, 'Local\AgentTrafficLight', [ref]$createdNew)
if (-not $createdNew) {
    try { Set-Content -Path $showFlag -Value (Get-Date -Format 'o') -Encoding UTF8 } catch { }
    exit 0
}
if (Test-Path $showFlag) { Remove-Item $showFlag -Force -ErrorAction SilentlyContinue }

# Per-monitor v2 before any window exists. All three monitors here run at 100%
# today so this changes nothing now, but the PowerShell host declares itself DPI
# unaware, which would show as a blurry stretched card on any scaled display.
try { [TlNative]::SetProcessDpiAwarenessContext([IntPtr](-4)) | Out-Null } catch { }

[TlNative]::ShowWindow([TlNative]::GetConsoleWindow(), $SW_HIDE) | Out-Null

function Import-Xaml {
    param([string]$Name)
    $path = Join-Path $PSScriptRoot $Name
    $stream = [System.IO.File]::OpenRead($path)
    try { return [System.Windows.Markup.XamlReader]::Load($stream) }
    finally { $stream.Dispose() }
}

$window    = Import-Xaml 'AgentTrafficLight.xaml'
$rowCanvas = $window.FindName('RowCanvas')
$warnText  = $window.FindName('WarnText')
$workClock     = $window.FindName('WorkClock')
$workClockText = $window.FindName('WorkClockText')
$workClockSub  = $window.FindName('WorkClockSub')

$brush = @{
    Working      = $window.FindResource('BrushWorking')
    Waiting      = $window.FindResource('BrushWaiting')
    Blocked      = $window.FindResource('BrushBlocked')
    RowBase      = $window.FindResource('BrushRowBase')
    Text         = $window.FindResource('BrushText')
    TextDim      = $window.FindResource('BrushTextDim')
    TextOnWait   = $window.FindResource('BrushTextOnWait')
    TextOnBlock  = $window.FindResource('BrushTextOnBlock')
    TimerOnWait  = $window.FindResource('BrushTimerOnWait')
    TimerOnBlock = $window.FindResource('BrushTimerOnBlock')
    WsNeutral    = $window.FindResource('BrushWsNeutral')
    CtxFill      = $window.FindResource('BrushCtxFill')
    CtxHigh      = $window.FindResource('BrushCtxHigh')
    Ws           = @(
        $window.FindResource('BrushWs0'),
        $window.FindResource('BrushWs1'),
        $window.FindResource('BrushWs2'),
        $window.FindResource('BrushWs3')
    )
}

# One brush shared by every working dot, breathing on one clock. Each dot used
# to start its own animation the moment its row began working, so no two were
# ever in step; painting them all with one brush means they cannot drift apart.
# It only runs while some row is working, so a card of finished sessions still
# costs nothing to draw.
$script:dotPulse = $brush.Working.Clone()
$script:dotBreathe = New-Object System.Windows.Media.Animation.DoubleAnimation
$script:dotBreathe.From = 0.5
$script:dotBreathe.To = 1.0
$script:dotBreathe.Duration = [System.Windows.Duration][TimeSpan]::FromMilliseconds($dotBreatheMs)
$script:dotBreathe.AutoReverse = $true
$script:dotBreathe.RepeatBehavior = [System.Windows.Media.Animation.RepeatBehavior]::Forever
$script:pulseRunning = $false

# Lift for a row being dragged, so it reads as picked up and above the others.
$script:liftShadow = New-Object System.Windows.Media.Effects.DropShadowEffect
$script:liftShadow.Color = [System.Windows.Media.Colors]::Black
$script:liftShadow.BlurRadius = 14
$script:liftShadow.ShadowDepth = 3
$script:liftShadow.Direction = 270
$script:liftShadow.Opacity = 0.55

# Window handles in the order rows were dragged into. A row is a terminal window,
# and its handle stays the same for as long as that window is open: through a
# /clear, through a new session started in it, and through a restart of this
# widget. It also does not depend on matching the window to a session file,
# which a session id would. Only the order inside one workspace group means
# anything, since each group is laid out on its own. A window that is not listed
# sorts after the listed ones by session start time, so a new session still
# lands at the bottom of its group exactly as before.
$orderFile = Join-Path $stateDir 'row-order.json'
$script:userOrder = New-Object System.Collections.ArrayList
$script:orderIndex = @{}

function Update-OrderIndex {
    $script:orderIndex = @{}
    for ($i = 0; $i -lt $script:userOrder.Count; $i++) {
        $script:orderIndex[[string]$script:userOrder[$i]] = $i
    }
}

try {
    # Assigned before the loop on purpose: PowerShell 5.1's ConvertFrom-Json
    # sends a JSON array down the pipeline as one object, not item by item.
    $saved = Get-Content $orderFile -Raw -ErrorAction Stop | ConvertFrom-Json
    foreach ($id in $saved) { [void]$script:userOrder.Add([string]$id) }
} catch { }
Update-OrderIndex

# The row being dragged, or null. Holds the row, its group, where in the row the
# pointer grabbed it, the slot it would drop into, and the order on screen.
$script:drag = $null
# Per group, the top of its first slot and how many slots it has; and the rows
# in the order last laid out. Both are written by Update-Layout, and the drag
# reads them to know where it may go and where it started.
$script:groupSlots = @{}
$script:groupOrder = @{}
$script:pressCanvasY = 0.0

$script:sessionByHwnd = @{}
$script:liveSessionCount = 0
$script:headerPool = New-Object System.Collections.ArrayList

if (Test-Path $positionFile) {
    try {
        $pos = Get-Content $positionFile -Raw | ConvertFrom-Json
        $window.Left = [double]$pos.Left
        $window.Top  = [double]$pos.Top
    } catch { }
}

function Save-Position {
    try {
        @{ Left = $window.Left; Top = $window.Top } | ConvertTo-Json | Set-Content -Path $positionFile -Encoding UTF8
    } catch { }
}

# rows: handle (as int64 string) -> record. Order in $rowOrder is presentation
# order, which is what the slide animation animates between.
$rows = @{}
$script:firstSeen = 0

function New-Row {
    param([IntPtr]$Handle, [string]$Label, [string]$State)
    $element = Import-Xaml 'Row.xaml'
    # Keep the layout honest about the size the design file actually specifies.
    if ($element.Height -gt 0) { $script:rowHeight = $element.Height }
    $script:firstSeen++
    $rec = @{
        Handle    = $Handle
        Element   = $element
        Bg        = $element
        Dot       = $element.FindName('Dot')
        Stripe    = $element.FindName('Stripe')
        LabelText = $element.FindName('Label')
        TimerText = $element.FindName('Timer')
        ModelText = $element.FindName('Model')
        CtxFill   = $element.FindName('CtxFill')
        State     = ''
        Label     = ''
        Since     = Get-Date
        # WorkSince ticks while the session works, cut to the whole second so
        # every running timer on the card turns over at the same moment.
        # FinishedAt is the clock time the work stopped. It replaced the frozen
        # duration of that work, which nobody read once a row was green; the
        # time it finished says how old the session is, which people do want.
        WorkSince = $null
        FinishedAt = $null
        SessionStatus   = ''
        StatusUpdatedAt = [double]0
        Top       = -1.0
        Seq       = $script:firstSeen
        Alarm     = $null
        SessionId = ''
        Cwd       = ''
        Workspace = ''
        StartedAt = [double]0
        Model     = ''
        Prompt    = 0
    }

    $element.Tag = $Handle

    # Press on a row is ambiguous: it starts either a click that focuses the
    # session, or a drag that moves the row within its group. Deciding once the
    # pointer moves, not on press, is what keeps rows clickable. Handled stops
    # the press bubbling to the card's own drag, which moves the whole window.
    $element.Add_MouseLeftButtonDown({
        param($sender, $e)
        $script:pressPoint = $e.GetPosition($window)
        # Kept in canvas coordinates too, so a drag that starts four pixels
        # later grabs the row where the press landed, without a jump.
        $script:pressCanvasY = $e.GetPosition($rowCanvas).Y
        $script:pressRow = $sender
        $e.Handled = $true
    })

    # Release either drops a dragged row or, if the pointer never went far
    # enough to start a drag, is a click that focuses the session's window.
    # Focus is best effort by design: if Windows refuses the foreground change
    # the native helper flashes the taskbar button instead.
    $element.Add_MouseLeftButtonUp({
        param($sender, $e)
        if ($null -ne $script:drag) {
            try { Complete-RowDrag -Commit $true } catch { Write-ErrorLog -Where 'drop' -Problem $_ }
        } elseif ($script:pressRow -eq $sender) {
            [TlNative]::Focus([IntPtr]$sender.Tag) | Out-Null
        }
        $script:pressRow = $null
        $e.Handled = $true
    })

    # Capture can be taken away mid-drag, by Alt+Tab or a window stealing the
    # focus. The drag is abandoned rather than dropped, so the row goes back
    # where it was instead of landing wherever the pointer happened to be.
    $element.Add_LostMouseCapture({
        param($sender, $e)
        if ($null -ne $script:drag -and [object]::ReferenceEquals($script:drag.Rec.Element, $sender)) {
            try { Complete-RowDrag -Commit $false } catch { Write-ErrorLog -Where 'drag' -Problem $_ }
        }
    })

    $rowCanvas.Children.Add($element) | Out-Null
    return $rec
}

function Set-RowState {
    param($Rec, [string]$State, [string]$Label)

    if ($Rec.Label -ne $Label) {
        $Rec.LabelText.Text = $Label
        $Rec.Label = $Label
    }
    if ($Rec.State -eq $State) { return }

    $now = Get-Date
    if ($State -eq 'Working') {
        $Rec.WorkSince = Get-WholeSecond -At $now
        $Rec.FinishedAt = $null
    } elseif ($null -ne $Rec.WorkSince) {
        # Left the working state, so note the clock time it stopped. Guarded on
        # WorkSince so that Waiting turning into Blocked, or back, keeps the
        # original time instead of moving it.
        $Rec.FinishedAt = $now
        $Rec.WorkSince = $null
    }

    $Rec.State = $State
    $Rec.Since = $now

    # Stop whatever motion the previous state was running before starting the
    # next one, or the two animations fight over the same property.
    if ($Rec.Alarm) { $Rec.Alarm.Stop(); $Rec.Alarm = $null }
    $Rec.Bg.BeginAnimation([System.Windows.UIElement]::OpacityProperty, $null)

    switch ($State) {
        'Working' {
            $Rec.Bg.Background        = $brush.RowBase
            $Rec.LabelText.Foreground = $brush.Text
            $Rec.TimerText.Foreground = $brush.TextDim
            $Rec.Dot.Visibility       = 'Visible'
            # The only thing that moves on a calm card. Every dot paints with
            # the one shared breathing brush, so all of them are in step.
            $Rec.Dot.Fill             = $script:dotPulse
            $Rec.Bg.Opacity           = 1.0
        }
        'Waiting' {
            Start-FillAnimation -Rec $Rec -To $brush.Waiting.Color
            $Rec.LabelText.Foreground = $brush.TextOnWait
            $Rec.TimerText.Foreground = $brush.TimerOnWait
            $Rec.Dot.Visibility       = 'Collapsed'
            $Rec.Bg.Opacity           = 1.0
            # Deliberately still. A filled row is already loud; pulsing every
            # finished session would make the alarm state indistinguishable.
        }
        'Blocked' {
            Start-FillAnimation -Rec $Rec -To $brush.Blocked.Color
            $Rec.LabelText.Foreground = $brush.TextOnBlock
            $Rec.TimerText.Foreground = $brush.TimerOnBlock
            $Rec.Dot.Visibility       = 'Collapsed'
            Start-Alarm -Rec $Rec
        }
    }
}

function Start-FillAnimation {
    param($Rec, $To)
    # Animate from whatever is there now, so a Waiting row promoted to Blocked
    # slides amber to vermilion instead of snapping.
    $from = [System.Windows.Media.Color]::FromArgb(0, 20, 22, 26)
    if ($Rec.Bg.Background -is [System.Windows.Media.SolidColorBrush]) {
        $from = $Rec.Bg.Background.Color
    }
    $solid = New-Object System.Windows.Media.SolidColorBrush $from
    $Rec.Bg.Background = $solid
    $anim = New-Object System.Windows.Media.Animation.ColorAnimation
    $anim.From = $from
    $anim.To = $To
    $anim.Duration = [System.Windows.Duration][TimeSpan]::FromMilliseconds($flipMs)
    $solid.BeginAnimation([System.Windows.Media.SolidColorBrush]::ColorProperty, $anim)
}

# Three hard beats, then a slow breathe that never stops. The beats are what
# catches the eye; the breathe is what stops the row from blending back into a
# static card while it waits.
function Start-Alarm {
    param($Rec)
    $beats = New-Object System.Windows.Media.Animation.DoubleAnimationUsingKeyFrames
    $beats.Duration = [System.Windows.Duration][TimeSpan]::FromMilliseconds($blinkMs * 3)
    $t = 0
    for ($i = 0; $i -lt 3; $i++) {
        $t += $blinkMs / 2
        $k1 = New-Object System.Windows.Media.Animation.LinearDoubleKeyFrame(0.42, [System.Windows.Media.Animation.KeyTime][TimeSpan]::FromMilliseconds($t))
        $beats.KeyFrames.Add($k1) | Out-Null
        $t += $blinkMs / 2
        $k2 = New-Object System.Windows.Media.Animation.LinearDoubleKeyFrame(1.0, [System.Windows.Media.Animation.KeyTime][TimeSpan]::FromMilliseconds($t))
        $beats.KeyFrames.Add($k2) | Out-Null
    }

    $breathe = New-Object System.Windows.Media.Animation.DoubleAnimation
    $breathe.From = 1.0
    $breathe.To = 0.78
    $breathe.BeginTime = [TimeSpan]::FromMilliseconds($blinkMs * 3)
    $breathe.Duration = [System.Windows.Duration][TimeSpan]::FromMilliseconds($breatheMs)
    $breathe.AutoReverse = $true
    $breathe.RepeatBehavior = [System.Windows.Media.Animation.RepeatBehavior]::Forever

    $sb = New-Object System.Windows.Media.Animation.Storyboard
    foreach ($a in @($beats, $breathe)) {
        [System.Windows.Media.Animation.Storyboard]::SetTarget($a, $Rec.Bg)
        [System.Windows.Media.Animation.Storyboard]::SetTargetProperty($a, (New-Object System.Windows.PropertyPath '(UIElement.Opacity)'))
        $sb.Children.Add($a) | Out-Null
    }
    $sb.Begin()
    $Rec.Alarm = $sb
}

function Move-RowTo {
    param($Rec, [double]$Top)
    if ([Math]::Abs($Rec.Top - $Top) -lt 0.5) { return }
    $first = $Rec.Top -lt 0
    $Rec.Top = $Top
    # Slide from where the row is drawn right now, not from where it was last
    # sent. During a drag rows change slot faster than a slide finishes, and
    # starting from the old target made them jump back before moving.
    $from = [System.Windows.Controls.Canvas]::GetTop($Rec.Element)
    if ($first -or [double]::IsNaN($from)) {
        [System.Windows.Controls.Canvas]::SetTop($Rec.Element, $Top)
        return
    }
    $anim = New-Object System.Windows.Media.Animation.DoubleAnimation
    $anim.From = $from
    $anim.To = $Top
    $anim.Duration = [System.Windows.Duration][TimeSpan]::FromMilliseconds($flipMs)
    $ease = New-Object System.Windows.Media.Animation.CubicEase
    $ease.EasingMode = 'EaseOut'
    $anim.EasingFunction = $ease
    $Rec.Element.BeginAnimation([System.Windows.Controls.Canvas]::TopProperty, $anim)
}

function Format-Elapsed {
    param([TimeSpan]$Span)
    # Floor, never [int]: PowerShell's [int] rounds, which made 40 seconds read
    # as 1:40 and every minute show one too many for its second half.
    $hours = [Math]::Floor($Span.TotalHours)
    if ($hours -ge 1) { return ('{0}:{1:00}:{2:00}' -f $hours, $Span.Minutes, $Span.Seconds) }
    return ('{0}:{1:00}' -f [Math]::Floor($Span.TotalMinutes), $Span.Seconds)
}

function Get-WholeSecond {
    param([datetime]$At)
    return $At.AddTicks(-($At.Ticks % [TimeSpan]::TicksPerSecond))
}

# Today's finish as "at 14:05". Older ones only need the day to judge their age,
# which also keeps the column narrow. Invariant culture because the rest of the
# card is English.
function Format-FinishedAt {
    param([datetime]$At, [datetime]$Now)
    $inv = [System.Globalization.CultureInfo]::InvariantCulture
    if ($At.Date -eq $Now.Date) { return 'at ' + $At.ToString('HH:mm', $inv) }
    if (($Now.Date - $At.Date).TotalDays -lt 7) { return $At.ToString('ddd', $inv) }
    return $At.ToString('d MMM', $inv)
}

# The right-hand column of every row, all written in one pass so every running
# timer turns over together. A working row counts up from the whole second its
# work started. Any other row shows the clock time it stopped, with "at" in
# front and in italics, so it can never be read as a running figure.
function Update-Timers {
    $now = Get-Date
    $second = Get-WholeSecond -At $now
    foreach ($rec in @($rows.Values)) {
        $text = ''
        $italic = $false
        if ($null -ne $rec.WorkSince) {
            $text = Format-Elapsed -Span ($second - $rec.WorkSince)
        } else {
            $stopped = $rec.FinishedAt
            # The widget did not see this one finish, usually because it was
            # started afterwards. Claude's own session file still knows when it
            # went idle. Only idle counts: a busy status would give the time the
            # turn began, not when it ended.
            if ($null -eq $stopped -and $rec.SessionStatus -eq 'idle' -and $rec.StatusUpdatedAt -gt 0) {
                $stopped = [DateTimeOffset]::FromUnixTimeMilliseconds([int64]$rec.StatusUpdatedAt).LocalDateTime
            }
            if ($null -ne $stopped) {
                $text = Format-FinishedAt -At $stopped -Now $now
                $italic = $true
            }
        }
        if ($rec.TimerText.Text -ne $text) { $rec.TimerText.Text = $text }
        if ($italic) {
            $rec.TimerText.FontStyle = [System.Windows.FontStyles]::Italic
        } else {
            $rec.TimerText.FontStyle = [System.Windows.FontStyles]::Normal
        }
    }
}

# ---------------------------------------------------------------------------
# Work clock: today's time with at least one session open, shown at the top of
# the card with today's first start and this week's total under the label. Kept
# in state/worktime.csv as one "yyyy-MM-dd,h:mm:ss,HH:mm" line per day, the last
# line being today; the third column is when the day's counting began. Weeks
# start on Monday.
# ---------------------------------------------------------------------------
$workClockFile = Join-Path $stateDir 'worktime.csv'
$workClockMaxStepSec = 5    # a longer gap between ticks is sleep, not work
$workClockSaveSec    = 30
$workClockSep = ' ' + [char]0x00B7 + ' '   # code point: the file is read as ANSI

function Format-WorkClock {
    param([double]$Seconds, [switch]$NoSeconds)
    $span = [TimeSpan]::FromSeconds([Math]::Floor($Seconds))
    if ($NoSeconds) { return ('{0}:{1:00}' -f [Math]::Floor($span.TotalHours), $span.Minutes) }
    return ('{0}:{1:00}:{2:00}' -f [Math]::Floor($span.TotalHours), $span.Minutes, $span.Seconds)
}

# One line as @{ Date; Seconds; Start }, or $null if it does not parse.
function ConvertFrom-WorkLine {
    param([string]$Line)
    $parts = $Line.Split(',')
    if ($parts.Count -lt 2) { return $null }
    $hms = $parts[1].Split(':')
    if ($hms.Count -ne 3) { return $null }
    $start = $null
    if ($parts.Count -ge 3 -and $parts[2].Trim()) { $start = $parts[2].Trim() }
    return @{
        Date    = $parts[0]
        Seconds = [double]([int]$hms[0] * 3600 + [int]$hms[1] * 60 + [int]$hms[2])
        Start   = $start
    }
}

function Get-WorkLines {
    if (-not (Test-Path $workClockFile)) { return @() }
    return @(Get-Content $workClockFile | Where-Object { $_.Trim() })
}

# Today's figures from the last line, and this week's total before today, which
# only changes at midnight so it is summed once rather than every second.
function Read-WorkClock {
    $script:workDate = (Get-Date).Date
    $script:workSeconds = 0.0
    $script:workStart = $null
    $today = $script:workDate.ToString('yyyy-MM-dd')
    $monday = $script:workDate.AddDays(-(([int]$script:workDate.DayOfWeek + 6) % 7)).ToString('yyyy-MM-dd')
    $script:workWeekBefore = 0.0
    foreach ($l in Get-WorkLines) {
        $w = ConvertFrom-WorkLine -Line $l
        if ($null -eq $w) { continue }
        if ($w.Date -eq $today) {
            $script:workSeconds = $w.Seconds
            $script:workStart = $w.Start
        } elseif ($w.Date -ge $monday -and $w.Date -lt $today) {
            $script:workWeekBefore += $w.Seconds
        }
    }
}

# Rewrites today's line in place, or appends it on the first save of a day.
function Save-WorkClock {
    $day = $script:workDate.ToString('yyyy-MM-dd')
    $line = $day + ',' + (Format-WorkClock -Seconds $script:workSeconds)
    if ($script:workStart) { $line += ',' + $script:workStart }
    $lines = @(Get-WorkLines)
    if ($lines.Count -gt 0 -and $lines[-1].StartsWith($day + ',')) {
        $lines[-1] = $line
    } else {
        $lines += $line
    }
    [System.IO.File]::WriteAllLines($workClockFile, [string[]]$lines)
    $script:workSavedAt = Get-Date
}

# Called once a second from the clock timer.
function Update-WorkClock {
    $now = Get-Date
    $step = ($now - $script:workTickAt).TotalSeconds
    $script:workTickAt = $now
    if ($step -gt $workClockMaxStepSec) { $step = $workClockMaxStepSec }

    if ($now.Date -ne $script:workDate) {
        Save-WorkClock
        Read-WorkClock
    }
    if ($rows.Count -gt 0 -and $step -gt 0) {
        $script:workSeconds += $step
        if (-not $script:workStart) { $script:workStart = $now.ToString('HH:mm') }
    }

    $text = Format-WorkClock -Seconds $script:workSeconds
    if ($workClockText.Text -ne $text) { $workClockText.Text = $text }
    $sub = 'week ' + (Format-WorkClock -Seconds ($script:workWeekBefore + $script:workSeconds) -NoSeconds)
    if ($script:workStart) { $sub = 'since ' + $script:workStart + $workClockSep + $sub }
    if ($workClockSub.Text -ne $sub) { $workClockSub.Text = $sub }
    if (($now - $script:workSavedAt).TotalSeconds -ge $workClockSaveSec) { Save-WorkClock }
}

Read-WorkClock
$script:workTickAt = Get-Date
$script:workSavedAt = Get-Date

function Set-DotPulse {
    param([bool]$On)
    if ($On -eq $script:pulseRunning) { return }
    $script:pulseRunning = $On
    if ($On) {
        $script:dotPulse.BeginAnimation([System.Windows.Media.Brush]::OpacityProperty, $script:dotBreathe)
    } else {
        $script:dotPulse.BeginAnimation([System.Windows.Media.Brush]::OpacityProperty, $null)
    }
}

# ---------------------------------------------------------------------------
# Dragging a row within its group. The order is remembered by window handle in
# state/row-order.json, so it survives a restart of the widget.
# ---------------------------------------------------------------------------

# Rows of one group in display order: dragged order first, then the rest by
# when their session started, which is the order a new session gets.
function Get-GroupOrder {
    param($Group)
    return @($Group | Sort-Object @{ Expression = {
                $i = $script:orderIndex[[string][int64]$_.Handle]
                if ($null -eq $i) { [int]::MaxValue } else { $i }
            } }, @{ Expression = { $_.StartedAt } }, @{ Expression = { $_.Seq } })
}

function Start-RowDrag {
    param($Element, [double]$PointerY)
    $rec = $rows[[string][int64]$Element.Tag]
    # A row whose session is not resolved yet sits in the unnamed group at the
    # bottom and moves into its real group once it resolves, so an order given
    # to it now would mean nothing. It stays put; the press just stops being a
    # click.
    if ($null -eq $rec -or $rec.Workspace -eq 'unknown') { return }

    $order = @($script:groupOrder[$rec.Workspace])
    $index = 0
    for ($i = 0; $i -lt $order.Count; $i++) {
        if ([object]::ReferenceEquals($order[$i], $rec)) { $index = $i }
    }

    # Pin the row where it is drawn right now, in case it was mid-slide.
    $top = [System.Windows.Controls.Canvas]::GetTop($Element)
    $Element.BeginAnimation([System.Windows.Controls.Canvas]::TopProperty, $null)
    [System.Windows.Controls.Canvas]::SetTop($Element, $top)
    $rec.Top = $top

    $script:drag = @{
        Rec    = $rec
        Group  = $rec.Workspace
        Offset = $script:pressCanvasY - $top
        Target = $index
        Order  = $order
    }
    [System.Windows.Controls.Panel]::SetZIndex($Element, 10)
    $Element.Effect = $script:liftShadow
    $Element.Cursor = [System.Windows.Input.Cursors]::SizeNS
    # Captured so the drag keeps tracking when the pointer leaves the row or
    # the card, and so the release comes back to this row wherever it happens.
    [void]$Element.CaptureMouse()
    Move-DraggedRow -PointerY $PointerY
}

function Move-DraggedRow {
    param([double]$PointerY)
    $drag = $script:drag
    if ($null -eq $drag) { return }
    $slots = $script:groupSlots[$drag.Group]
    if ($null -eq $slots) { return }
    $pitch = $script:rowHeight + $rowGap
    $first = [double]$slots.Top
    $last = $first + ($slots.Count - 1) * $pitch
    # Held inside its own group: a session cannot be dropped among another
    # workspace's rows, so its row cannot travel past its group's ends either.
    $top = [Math]::Max($first, [Math]::Min($last, $PointerY - $drag.Offset))
    [System.Windows.Controls.Canvas]::SetTop($drag.Rec.Element, $top)
    $drag.Rec.Top = $top
    $target = [int][Math]::Round(($top - $first) / $pitch)
    if ($target -ne $drag.Target) {
        $drag.Target = $target
        # Straight away, not on the next poll, so the gap opens under the row
        # as it arrives rather than up to 400 ms later.
        Update-Layout
    }
}

function Complete-RowDrag {
    param([bool]$Commit)
    $drag = $script:drag
    if ($null -eq $drag) { return }
    # Cleared before the capture is released: releasing raises
    # LostMouseCapture, whose handler must find no drag still running.
    $script:drag = $null
    $element = $drag.Rec.Element
    $element.Effect = $null
    $element.Cursor = [System.Windows.Input.Cursors]::Hand
    [System.Windows.Controls.Panel]::SetZIndex($element, 0)
    if ($element.IsMouseCaptured) { $element.ReleaseMouseCapture() }
    if ($Commit) {
        Save-UserOrder -GroupKeys @($drag.Order | ForEach-Object { [string][int64]$_.Handle })
    }
    # Slides the dropped row from under the pointer into its slot.
    Update-Layout
}

function Write-LayoutDump {
    $lines = New-Object System.Collections.ArrayList
    [void]$lines.Add(('{0:o}  drag={1}  order={2}' -f (Get-Date), ($null -ne $script:drag), ($script:userOrder -join ',')))
    foreach ($name in @($script:groupOrder.Keys)) {
        [void]$lines.Add("group $name")
        foreach ($rec in @($script:groupOrder[$name])) {
            $drawn = [System.Windows.Controls.Canvas]::GetTop($rec.Element)
            [void]$lines.Add(('  top={0,-6} drawn={1,-6} started={2:HH:mm:ss} seq={3,-3} hwnd={4,-9} idx={5,-4} {6}' -f
                $rec.Top, [Math]::Round($drawn, 1),
                [DateTimeOffset]::FromUnixTimeMilliseconds([int64]$rec.StartedAt).LocalDateTime,
                $rec.Seq, [int64]$rec.Handle, $script:orderIndex[[string][int64]$rec.Handle], $rec.Label))
        }
    }
    Set-Content -Path (Join-Path $stateDir 'dump.txt') -Value $lines -Encoding UTF8
}

function Save-UserOrder {
    param([string[]]$GroupKeys)
    # Windows no longer on the card are dropped here, so the file only ever
    # holds what is open now instead of growing forever.
    $next = New-Object System.Collections.ArrayList
    foreach ($key in $script:userOrder) {
        if ($rows.ContainsKey($key) -and $GroupKeys -notcontains $key) { [void]$next.Add($key) }
    }
    foreach ($key in $GroupKeys) { [void]$next.Add($key) }
    $script:userOrder = $next
    Update-OrderIndex
    try {
        # -InputObject rather than the pipeline, so a list of one is still
        # written as a JSON array.
        ConvertTo-Json -InputObject @($next) | Set-Content -Path $orderFile -Encoding UTF8
    } catch { Write-ErrorLog -Where 'order' -Problem $_ }
}

# ---------------------------------------------------------------------------
# Markers written by the Notification hook. This is the only source for the
# third state: Claude's terminal title has no glyph for "blocked on you", so
# there is nothing to scrape.
#
# There is no direct link from a window handle to a session id, so the join is
# a ladder of decreasing certainty. It never guesses: an unresolved marker
# leaves the row amber rather than reddening the wrong session.
# ---------------------------------------------------------------------------
function Resolve-BlockedRows {
    param($Ordered)

    # Only the markers folder: sweeping all of state/ once deleted the saved
    # row order along with the stale markers.
    $files = @(Get-ChildItem (Join-Path $stateDir 'markers') -Filter '*.json' -ErrorAction SilentlyContinue)
    if ($files.Count -eq 0) { return @() }

    # Judged on the state the titles just reported, not on the state currently
    # painted, because this runs before anything is applied.
    $waiting = @($Ordered | Where-Object { $_.PendingState -eq 'Waiting' })

    # Nothing is waiting, so no permission prompt can still be open. Approving a
    # prompt does not fire UserPromptSubmit, so without this sweep an approved
    # prompt's marker would sit here until the user typed something.
    if ($waiting.Count -eq 0) {
        foreach ($f in $files) { Remove-Item $f.FullName -Force -ErrorAction SilentlyContinue }
        return @()
    }

    # An exact join. The marker file is named after the session id, and every
    # row now knows its own session id through the process chain, so a marker
    # either belongs to a row or belongs to nothing.
    #
    # This replaced a ladder of console-title matching and time correlation.
    # None of that was ever needed once the window could be resolved properly.
    $blocked = @()
    foreach ($f in $files) {
        $id = [System.IO.Path]::GetFileNameWithoutExtension($f.Name)
        $hit = $waiting | Where-Object { $_.SessionId -eq $id } | Select-Object -First 1
        if ($hit) {
            $blocked += $hit
        } else {
            # Its session is not waiting, so whatever it was blocked on is
            # resolved. Approving a permission prompt does not submit a prompt,
            # so the clear hook alone would leave this behind.
            Remove-Item $f.FullName -Force -ErrorAction SilentlyContinue
        }
    }
    return $blocked
}

# ---------------------------------------------------------------------------
# The poll
# ---------------------------------------------------------------------------
$script:knownHandles = New-Object System.Collections.ArrayList

# ---------------------------------------------------------------------------
# Auto-hide. An empty card is only clutter on a screen it is always on top of,
# so it leaves and says what little it has to say through the tray dot until a
# session comes back.
# ---------------------------------------------------------------------------
$script:autoHidden = $false
$script:manualShow = $false

# Every show or hide a person asks for goes through here, so the poll can tell
# a card it hid itself from one the user opened deliberately. An opened card
# stays open, empty or not, until it next has rows to lose.
function Set-CardVisible {
    param([bool]$Visible, [switch]$Activate)
    if ($Visible) {
        if (-not $window.IsVisible) { $window.Show() }
        if ($Activate) { $window.Activate() | Out-Null }
        $script:manualShow = $true
        $script:autoHidden = $false
    } else {
        $window.Hide()
        $script:manualShow = $false
        $script:autoHidden = $false
    }
}

function Update-Card {
    # Someone launched the shortcut again while this instance was already
    # running. Treat it as "bring the card back" rather than ignoring it.
    if (Test-Path $showFlag) {
        Remove-Item $showFlag -Force -ErrorAction SilentlyContinue
        Set-CardVisible -Visible $true -Activate
    }

    # Touch state/dump.flag and this poll writes what every row is laid out from
    # to state/dump.txt. Checks the live card against reality without stopping
    # it, the way -Probe checks the window parsing.
    $dumpFlag = Join-Path $stateDir 'dump.flag'
    if (Test-Path $dumpFlag) {
        Remove-Item $dumpFlag -Force -ErrorAction SilentlyContinue
        Write-LayoutDump
    }

    $seen = @{}

    foreach ($h in @($script:knownHandles)) {
        $title = Get-WindowTitle -Handle $h
        if ($null -eq $title) {
            # Window is gone. Drop it now rather than waiting for the sweep, so
            # a closed session never lingers on the card.
            $script:knownHandles.Remove($h)
            continue
        }
        $parsed = Read-SessionTitle -Title $title
        if (-not $parsed) { continue }
        $key = [string][int64]$h
        if (-not $rows.ContainsKey($key)) {
            $rows[$key] = New-Row -Handle $h -Label $parsed.Label -State $parsed.State
        }
        $rows[$key].PendingState = $parsed.State
        $rows[$key].PendingLabel = $parsed.Label
        $seen[$key] = $true
    }

    foreach ($key in @($rows.Keys)) {
        if (-not $seen.ContainsKey($key)) {
            # A session closing mid-drag takes its row with it. Drop the drag
            # first so nothing is left holding capture on a removed element.
            if ($null -ne $script:drag -and [object]::ReferenceEquals($script:drag.Rec, $rows[$key])) {
                Complete-RowDrag -Commit $false
            }
            $rowCanvas.Children.Remove($rows[$key].Element)
            $rows.Remove($key)
        }
    }

    $ordered = @($rows.Values)

    # Attach the workspace to every row before anything else looks at it. The
    # map is rebuilt on the slow timer, so this is a dictionary lookup.
    foreach ($rec in $ordered) {
        $key = [string][int64]$rec.Handle
        if ($script:sessionByHwnd.ContainsKey($key)) {
            $info = $script:sessionByHwnd[$key]
            $rec.SessionId = $info.SessionId
            $rec.Cwd       = $info.Cwd
            $rec.Workspace = $info.Workspace
            $rec.StartedAt = $info.StartedAt
            $rec.SessionStatus   = $info.Status
            $rec.StatusUpdatedAt = $info.StatusUpdatedAt
            if ($info.ContainsKey('Model'))  { $rec.Model  = $info.Model }
            if ($info.ContainsKey('Prompt')) { $rec.Prompt = $info.Prompt }
        } elseif ($rec.Workspace -eq '') {
            $rec.Workspace = 'unknown'
        }
    }

    # Promote to Blocked before anything is applied, not after. Applying the
    # title's state first and correcting it afterwards would flip the row
    # Waiting -> Blocked on every single poll, which resets its timer to zero
    # and restarts the alarm animation four hundred milliseconds into itself.
    foreach ($rec in (Resolve-BlockedRows -Ordered $ordered)) {
        $rec.PendingState = 'Blocked'
    }

    foreach ($rec in $ordered) {
        Set-RowState -Rec $rec -State $rec.PendingState -Label $rec.PendingLabel
    }

    Set-DotPulse -On (@($ordered | Where-Object { $_.State -eq 'Working' }).Count -gt 0)
    Update-Layout
    Update-Timers

    # The same rows just painted, so the tray can never disagree with the card.
    # This once passed a variable that no longer existed, which PowerShell reads
    # as $null without complaint, and the tray sat on blue whatever happened.
    Set-TrayState -Rows $ordered

    # The card carries nothing, so it gets out of the way until it does again.
    if (@($ordered).Count -eq 0) {
        if ($window.IsVisible -and -not $script:manualShow) {
            $window.Hide()
            $script:autoHidden = $true
        }
    } else {
        # It has rows again, so the next empty stretch may hide it even if this
        # one was opened by hand.
        $script:manualShow = $false
        if ($script:autoHidden) {
            if (-not $window.IsVisible) { $window.Show() }
            $script:autoHidden = $false
        }
    }
}

# Places every row and heading, fills the stripes and bars, and sizes the window
# to fit. Split out of the poll so a drag can re-lay the card the moment a row
# changes slot instead of waiting for the next poll.
function Update-Layout {
    $ordered = @($rows.Values)

    # Stable geography beats sorting attention to the top. At six rows a filled
    # row is found instantly anyway, and rows that never move let you learn
    # where each session lives. Ordering is by workspace, then by the order the
    # rows were dragged into, then by when the session started: the task label
    # changes every turn, so ordering by anything about it would reshuffle the
    # card constantly.
    # Grouped through a scriptblock, not -Property Workspace: rows are
    # hashtables, and Group-Object resolves a bare property name against the
    # Hashtable type itself rather than its keys, so every row came back in one
    # nameless group.
    $allGroups = @($ordered | Group-Object -Property { $_.Workspace })

    # A window whose session file has not appeared yet is almost always one
    # opened a second ago. It must not invent a workspace of its own, must not
    # push a single-workspace card into grouped mode, and must not take a
    # stripe colour: it just sits at the bottom until it resolves.
    $known = @($allGroups | Where-Object { $_.Name -ne 'unknown' } | Sort-Object Name)
    $unresolved = @($allGroups | Where-Object { $_.Name -eq 'unknown' })
    $groups = @($known) + @($unresolved)
    # Headers show even with a single workspace: the folder name is worth
    # reading on an ordinary one-repository day too, not only when there are
    # two to tell apart.
    $showGroups = $known.Count -gt 0

    $y = 0.0
    $script:groupSlots = @{}
    $script:groupOrder = @{}
    $headerIndex = 0
    $trailingGroupGap = $false

    $groupIndex = 0
    foreach ($g in $groups) {
        $isResolved = ($g.Name -ne 'unknown')
        $wsBrush = Get-WorkspaceBrush -Index $groupIndex
        if ($isResolved) { $groupIndex++ }
        $showThisGroup = ($showGroups -and $isResolved)

        if ($showThisGroup) {
            $header = Get-Header -Index $headerIndex
            $headerIndex++
            $header.Label.Text = $g.Name
            $header.Swatch.Fill = $wsBrush
            $header.Element.Visibility = 'Visible'
            [System.Windows.Controls.Canvas]::SetTop($header.Element, $y)
            $y += $headerHeight
        }

        $inGroup = @(Get-GroupOrder -Group $g.Group)
        $drag = $script:drag
        if ($null -ne $drag -and $drag.Group -eq $g.Name) {
            # The dragged row takes the slot under the pointer and the others
            # close up around it. Kept on the drag, so a drop saves exactly the
            # order that was on screen at that moment.
            $list = New-Object System.Collections.ArrayList
            foreach ($other in $inGroup) {
                if (-not [object]::ReferenceEquals($other, $drag.Rec)) { [void]$list.Add($other) }
            }
            $list.Insert([Math]::Max(0, [Math]::Min([int]$drag.Target, $list.Count)), $drag.Rec)
            $inGroup = @($list)
            $drag.Order = $inGroup
        }
        $script:groupSlots[$g.Name] = @{ Top = $y; Count = $inGroup.Count }
        $script:groupOrder[$g.Name] = $inGroup

        foreach ($rec in $inGroup) {
            # Always drawn, because it holds the model name. It takes the hue of
            # its group's header swatch, so the two always agree; only a row
            # whose session is not resolved yet stays neutral.
            if ($showThisGroup) {
                $rec.Stripe.Background = $wsBrush
            } else {
                $rec.Stripe.Background = $brush.WsNeutral
            }
            # The row under the pointer is placed by the drag, not by the layout.
            if (-not ($null -ne $drag -and [object]::ReferenceEquals($rec, $drag.Rec))) {
                Move-RowTo -Rec $rec -Top $y
            }

            # "claude-opus-5" is noise on a row this narrow; "opus" is the part
            # that answers the question.
            if ($rec.Model -match 'claude-([a-z]+)') {
                $rec.ModelText.Text = $matches[1]
            } else {
                $rec.ModelText.Text = ''
            }

            $limit = $script:contextWindow
            $fraction = 0.0
            if ($limit -gt 0) { $fraction = [Math]::Min(1.0, $rec.Prompt / $limit) }
            $rec.CtxFill.Width = [Math]::Round($ctxBarWidth * $fraction)
            if ($fraction -ge $ctxHighMark) {
                $rec.CtxFill.Background = $brush.CtxHigh
            } else {
                $rec.CtxFill.Background = $brush.CtxFill
            }

            $y += $script:rowHeight + $rowGap
        }

        if ($showThisGroup) { $y += $groupGap }
        $trailingGroupGap = $showThisGroup
    }

    # Any header left over from a workspace that has closed.
    for ($i = $headerIndex; $i -lt $script:headerPool.Count; $i++) {
        $script:headerPool[$i].Element.Visibility = 'Collapsed'
    }

    $count = @($ordered).Count
    $liveFiles = $script:liveSessionCount
    if ($liveFiles -gt $count) {
        # One session per window is load-bearing: if two ever share a window as
        # tabs, only the active tab's title is readable and the other session
        # disappears. Fail loudly instead of silently showing four of five.
        $warnText.Text = ("{0} sessions running, {1} shown - check for tabbed windows" -f $liveFiles, $count)
        $warnText.Visibility = 'Visible'
    } else {
        $warnText.Visibility = 'Collapsed'
    }

    # The layout loop already walked the exact height; trim the trailing gaps it
    # left behind rather than recomputing from counts, which would have to know
    # about headers and group spacing all over again.
    $contentHeight = $y
    if ($count -gt 0) {
        $contentHeight -= $rowGap
        # Only if the final group actually added one; an unresolved group at the
        # bottom does not.
        if ($trailingGroupGap) { $contentHeight -= $groupGap }
    } else {
        $contentHeight = $rowHeight
    }
    $bodyHeight = $contentHeight + $cardPadding * 2
    if ($warnText.Visibility -eq 'Visible') { $bodyHeight += 20 }
    $bodyHeight += $workClock.Height + $workClock.Margin.Top
    $window.Height = $bodyHeight + $shadowMargin * 2
}

function Sweep-Windows {
    $scan = Scan-Windows
    foreach ($h in $scan.Terminals) {
        if (-not $script:knownHandles.Contains($h)) {
            $title = Get-WindowTitle -Handle $h
            if (Read-SessionTitle -Title $title) { [void]$script:knownHandles.Add($h) }
        }
    }
    Sync-SessionMap -ShellToWindow $scan.ShellToWindow
    Sync-SessionExtras
}

# ---------------------------------------------------------------------------
# Tray icon. Doubles as a miniature of the card: it takes the colour of the
# worst state, so the widget still says something while hidden.
# ---------------------------------------------------------------------------
$notify = New-Object System.Windows.Forms.NotifyIcon
$notify.Text = 'Agent Traffic Light'
$notify.Visible = $true
$script:trayColor = ''
$script:trayIcon = $null

function Set-TrayState {
    param($Rows)
    $worst = 'Working'
    if (@($Rows | Where-Object { $_.State -eq 'Waiting' }).Count -gt 0) { $worst = 'Waiting' }
    if (@($Rows | Where-Object { $_.State -eq 'Blocked' }).Count -gt 0) { $worst = 'Blocked' }
    if (@($Rows).Count -eq 0) { $worst = 'Empty' }
    if ($worst -eq $script:trayColor) { return }
    $script:trayColor = $worst

    # Brighter than the row fills on purpose: a 12 px dot in the tray has almost
    # no area to carry the colour, so the muted card tones would read as grey.
    $rgb = switch ($worst) {
        'Blocked' { [System.Drawing.Color]::FromArgb(214, 146, 58) }
        'Waiting' { [System.Drawing.Color]::FromArgb(62, 160, 120) }
        'Working' { [System.Drawing.Color]::FromArgb(76, 155, 232) }
        default   { [System.Drawing.Color]::FromArgb(90, 98, 110) }
    }
    $bmp = New-Object System.Drawing.Bitmap 16, 16
    $g = [System.Drawing.Graphics]::FromImage($bmp)
    $g.SmoothingMode = 'AntiAlias'
    $g.Clear([System.Drawing.Color]::Transparent)
    $g.FillEllipse((New-Object System.Drawing.SolidBrush $rgb), 2, 2, 12, 12)
    $g.Dispose()
    $h = $bmp.GetHicon()
    $old = $script:trayIcon
    $script:trayIcon = [System.Drawing.Icon]::FromHandle($h)
    $notify.Icon = $script:trayIcon
    if ($old) { [TlNative]::DestroyIcon($old.Handle) | Out-Null }
    $bmp.Dispose()
}

$menu = New-Object System.Windows.Forms.ContextMenuStrip
$showItem = $menu.Items.Add('Show / hide')
$showItem.Add_Click({ Set-CardVisible -Visible (-not $window.IsVisible) })
$menu.Items.Add('-') | Out-Null
$quitItem = $menu.Items.Add('Quit')
$quitItem.Add_Click({
    Save-Position
    try { Save-WorkClock } catch { Write-ErrorLog -Where 'workclock' -Problem $_ }
    $notify.Visible = $false
    $notify.Dispose()
    [System.Windows.Application]::Current.Shutdown()
})
$notify.ContextMenuStrip = $menu
$notify.Add_MouseClick({
    param($sender, $e)
    if ($e.Button -eq [System.Windows.Forms.MouseButtons]::Left) {
        Set-CardVisible -Visible (-not $window.IsVisible) -Activate
    }
})

# ---------------------------------------------------------------------------
# Window behaviour
# ---------------------------------------------------------------------------
$window.Add_SourceInitialized({
    $helper = New-Object System.Windows.Interop.WindowInteropHelper $window
    $hwnd = $helper.Handle
    # Verified missing by default: without this the card is an Alt-Tab entry,
    # which defeats the point of a thing that is always visible anyway.
    $ex = [TlNative]::GetWindowLong($hwnd, $GWL_EXSTYLE)
    [TlNative]::SetWindowLong($hwnd, $GWL_EXSTYLE, $ex -bor $WS_EX_TOOLWINDOW) | Out-Null
})

$script:pressRow = $null
$script:pressPoint = $null

# The card moves only from where there is no row: its empty edge, the gaps
# between rows and the group headings. Rows handle their own press, so it never
# reaches this.
$window.FindName('Card').Add_MouseLeftButtonDown({
    $script:pressRow = $null
    $window.DragMove()
    Save-Position
})

# A press on a row that travels far enough stops being a click and becomes a
# drag of that row within its group. Four pixels is below what a normal click
# produces and above the jitter of a hand resting on the mouse.
$window.Add_MouseMove({
    param($sender, $e)
    try {
        if ($null -ne $script:drag) {
            Move-DraggedRow -PointerY $e.GetPosition($rowCanvas).Y
            return
        }
        if ($null -eq $script:pressRow) { return }
        if ($e.LeftButton -ne [System.Windows.Input.MouseButtonState]::Pressed) { return }
        $now = $e.GetPosition($window)
        $dx = $now.X - $script:pressPoint.X
        $dy = $now.Y - $script:pressPoint.Y
        if ([Math]::Sqrt($dx * $dx + $dy * $dy) -lt 4) { return }
        $row = $script:pressRow
        $script:pressRow = $null
        Start-RowDrag -Element $row -PointerY $e.GetPosition($rowCanvas).Y
    } catch { Write-ErrorLog -Where 'drag' -Problem $_ }
})

$window.Add_Closing({
    Save-Position
    try { Save-WorkClock } catch { Write-ErrorLog -Where 'workclock' -Problem $_ }
})

# A throw inside a timer tick does not reach the trap above, and an unlogged
# crash in a hidden-console app looks exactly like the widget silently freezing.
$titleTimer = New-Object System.Windows.Threading.DispatcherTimer
$titleTimer.Interval = [TimeSpan]::FromMilliseconds($titlePollMs)
$titleTimer.Add_Tick({
    try { Update-Card } catch { Write-ErrorLog -Where 'poll' -Problem $_ }
})

$sweepTimer = New-Object System.Windows.Threading.DispatcherTimer
$sweepTimer.Interval = [TimeSpan]::FromMilliseconds($windowSweepMs)
$sweepTimer.Add_Tick({
    try { Sweep-Windows } catch { Write-ErrorLog -Where 'sweep' -Problem $_ }
})

# Running timers turn over on the wall-clock second. Start times are already cut
# to whole seconds, so every row changes together; this timer makes that land
# right on the second instead of whenever the 400 ms poll next comes round,
# which ticked unevenly. It re-aims at the next boundary each time it fires,
# plus a little, so it never lands just before one.
$clockTimer = New-Object System.Windows.Threading.DispatcherTimer
$clockTimer.Interval = [TimeSpan]::FromMilliseconds(1015 - (Get-Date).Millisecond)
$clockTimer.Add_Tick({
    param($sender, $e)
    try { Update-Timers } catch { Write-ErrorLog -Where 'clock' -Problem $_ }
    try { Update-WorkClock } catch { Write-ErrorLog -Where 'workclock' -Problem $_ }
    $sender.Interval = [TimeSpan]::FromMilliseconds(1015 - (Get-Date).Millisecond)
})

Sweep-Windows
$window.Show()
Update-Card
$titleTimer.Start()
$sweepTimer.Start()
$clockTimer.Start()

$app = New-Object System.Windows.Application
# Hiding the card must not end the process, or the tray icon would go with it.
$app.ShutdownMode = [System.Windows.ShutdownMode]::OnExplicitShutdown
$app.Run() | Out-Null

$notify.Visible = $false
$notify.Dispose()
