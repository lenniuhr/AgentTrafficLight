# Agent Traffic Light

An always-on-top card for Windows that shows the live state of every coding agent session you have
open, so a session that has finished or is waiting on a permission prompt gets noticed without
hunting through terminal windows.

It currently supports [Claude Code](https://claude.com/claude-code) CLI sessions running in Windows
Terminal. The name is generic on purpose, so other agents can be added later.

## What it shows

One row per session, grouped by the folder the session runs in:

| Row | Meaning |
| --- | --- |
| Dark row, breathing blue dot | Working. The time on the right counts up. |
| Green row | Finished and waiting for you. The time on the right is when it stopped. |
| Amber row, pulsing | Blocked on you: a permission prompt or a question. |

Each row also shows the model in the coloured stripe on its left, and a thin bar along its bottom
showing how much of the context window is in use. The bar turns amber past 80 %.

Clicking a row brings that session's window to the front. Dragging a row reorders it within its
group, and the order is remembered. Drag the card by its empty edge to move it.

The tray icon takes the colour of the most urgent row. Left click hides or shows the card; right
click quits. The card hides itself when no session is open.

The colours avoid red against green, the pair colour-blind people most often cannot separate.

## Requirements

- Windows 10 or 11
- Windows PowerShell 5.1 (built in)
- Claude Code CLI, each session in its own Windows Terminal window

## Install

Clone or download this repository to wherever you want it to live, then run the installer once from
inside it:

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File .\Install.ps1
```

The installer:

1. Registers two hooks in `~/.claude/settings.json`. It keeps a backup of the file first, and
   restores the original if the edit looks wrong.
2. Adds an "Agent Traffic Light" shortcut to Startup, so the card starts at login, and to the Start
   Menu.
3. Starts the card.

Running it again is safe. It never duplicates hooks or shortcuts, and if you move the folder it
points the hooks at the new place.

## How it works

The card needs no configuration and no daemon. It reads three things:

- **Terminal window titles.** Claude Code puts a spinner glyph at the front of the window title
  while it works and `✳` while it waits. That gives the working and waiting states, and the title
  itself is the row's label.
- **Session files** in `~/.claude/sessions/`. The card links each window to its session through
  the process chain from the session to its shell to the terminal window, which gives the folder,
  the start time and the session id.
- **Two hooks.** The title has no sign for "blocked on a permission prompt", so a `Notification`
  hook writes a small marker file for that session and a `UserPromptSubmit` hook removes it.

It polls window titles every 400 ms and looks for new windows every 3 s. A full check takes about
10 ms.

Model and context come from the tail of each session's transcript, read only when that file
changes.

## Troubleshooting

If the card stays empty, check what it can see:

```powershell
powershell -File .\AgentTrafficLight.ps1 -Probe -Passes 3
```

This prints every agent window it finds, its state and its folder.

To see how the live card has laid out its rows, create an empty file called `state\dump.flag`.
The card writes its layout to `state\dump.txt` on its next poll.

Errors from the hidden card are logged to `state\error.log`.

## Limits

- **One session per window.** With two sessions as tabs in one window, only the active tab's title
  can be read. The card shows a warning when it counts more sessions than rows.
- **The title format is not a documented interface.** If a Claude Code update changes the glyphs,
  the card stops finding windows. `-Probe` is the quickest way to check.
- **Context is an estimate.** It is taken from the last reported token usage and measured against a
  fixed 1M-token window.
- Sessions inside the Claude desktop app are not shown, because they have no terminal window.
- A topmost window cannot draw over the Windows security prompt or over exclusive-fullscreen apps.

## Uninstall

1. Quit from the tray icon.
2. Delete the two "Agent Traffic Light" shortcuts from Startup (`shell:startup`) and the Start Menu.
3. Remove the two hook entries with `"statusMessage": "traffic light"` from `~/.claude/settings.json`.
4. Delete the folder.

## License

MIT, see [LICENSE](LICENSE).
