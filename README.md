# wakeguard

[日本語](README.ja.md)

Keeps your machine awake while Claude Code is working on a turn, and lets it
sleep again as soon as the turn ends. Neither an idle session nor a crashed one
stands in the way of sleep.

Works on macOS, Windows (Git Bash) and WSL2. Bare Linux gets a `systemd-inhibit`
fallback.

## Install

Type these at the prompt inside a Claude Code session:

```
/plugin marketplace add pocke/wakeguard
/plugin install wakeguard@wakeguard
```

## What it needs

What the repository holds is what runs. Nothing is built or fetched beyond the
repository itself, and no runtime is added.

- **Everywhere**: `bash` and the basic Unix commands — `grep`, `sed`, `awk`,
  `ps` and the like; on Windows they come with Git Bash.
- **Windows and WSL2, on top of that**: Windows PowerShell 5.1, which ships
  with Windows. No extra modules. WSL2 reaches it over interop and converts
  paths with `wslpath`; Git Bash uses `cygpath`.

Suppressing sleep is left to what the OS already offers: `caffeinate` on
macOS, `systemd-inhibit` on Linux, and `SetThreadExecutionState` through
PowerShell on Windows and WSL2.

## How it works

One session gets one detached holder process, and the reference counting is left
to the operating system: as long as a single holder is alive the machine will not
sleep, so overlapping sessions need no shared counter. Releasing the suppression
is nothing more than killing the holder.

```
UserPromptSubmit  ->  wakeguard.sh start   launch a holder, record a pidfile
Stop, StopFailure ->  wakeguard.sh stop    kill the holder, delete the pidfile
SessionEnd        ->  wakeguard.sh stop
SessionStart      ->  wakeguard.sh reap    clean up orphaned holders
```

The holder per environment:

| Environment | Holder |
|---|---|
| macOS | `caffeinate -i -t <max hours in seconds> -w <claude pid>` |
| Windows (Git Bash) | `powershell.exe` running `wakeguard-hold.ps1` |
| WSL2 | the same PowerShell holder, on the **Windows host** through interop |
| Linux | `systemd-inhibit --what=idle` |

Suppressing sleep inside WSL2 would achieve nothing, because the Windows host
suspends the whole VM when it sleeps. WSL2 therefore always puts the holder on
the host side.

Pidfiles live in `${XDG_STATE_HOME:-~/.local/state}/wakeguard/sessions/`.

## Configuration

Set these as environment variables, or write them as `KEY=value` lines in
`${XDG_CONFIG_HOME:-~/.config}/wakeguard/config`. Environment variables win over
the file.

| Variable | Meaning | Default |
|---|---|---|
| `WAKEGUARD_CMD` | Run this command as the holder instead of the one picked by environment detection, e.g. `caffeinate -dims`. Split on whitespace, so quoting an argument does not work | unset |
| `WAKEGUARD_DISPLAY` | `1` keeps the display on as well (`caffeinate -d` / `-KeepDisplayOn`). No effect on Linux | `0` |
| `WAKEGUARD_MAX_HOURS` | How long a holder may live before it gives up on its own. A number in [0.001, 168]; anything else falls back to the default | `8` |
| `WAKEGUARD_LOG` | Append diagnostics to this file. Nothing is written anywhere without it, so set it first when wakeguard seems to be doing nothing | unset |

## Checking that it works

`wakeguard.sh status` lists every recorded holder and the state it is in. The
plugin installs under `~/.claude/plugins/cache/<marketplace>/<plugin>/<version>/`,
so find the copy you have and run it:

```
ls -d ~/.claude/plugins/cache/*/wakeguard/*/bin/wakeguard.sh
bash <the path that printed> status
```

To see the suppression from the operating system's side, run one of these while
a turn is in progress:

- macOS: `pmset -g assertions`, look for `PreventUserIdleSystemSleep`
- Windows: `powercfg /requests` in an elevated prompt, look for `powershell`
  under `SYSTEM`. From WSL2, check this on the Windows host, not inside WSL

## Never leaving the machine awake

Every way a session can end has something that releases the suppression:

| How it ends | What releases it |
|---|---|
| Turn finishes, normally or on an API error | `Stop` / `StopFailure` hook |
| Session ends with exit or Ctrl-C | `SessionEnd` hook |
| Claude Code is killed or crashes | macOS: `caffeinate -w` exits with it. Everywhere: the next `SessionStart` reap notices the dead pid |
| A hook is killed before it records the holder | The next `SessionStart` reap sweeps holders that no pidfile claims, on Windows and Linux. macOS has no sweep: `caffeinate` carries no marker telling ours from one the user started by hand, so an unrecorded one falls back to `caffeinate -w` and then to its `-t` deadline |
| No hook fires at all | The holder's own `WAKEGUARD_MAX_HOURS` deadline. A `WAKEGUARD_CMD` holder gets neither this nor the sweep, since wakeguard can neither give a deadline to an arbitrary command nor recognize one it did not name |
| `wsl --shutdown` | The Windows holder outlives the VM, and the next WSL session reaps it over interop |

Before killing anything, wakeguard confirms that the recorded pid still belongs
to the holder it started — by command name on Unix, by the holder script's path
in the command line on Windows — so a recycled pid never gets an unrelated
process killed.

**Two gaps worth knowing about.** Interrupting a turn with Esc is not a `Stop`
event, so the holder stays until the next turn ends or the session does. Until
then the machine will not sleep on its own.

And a Windows holder is recognized by the holder script's path, which carries
the plugin version, so upgrading the plugin while a holder is running makes the
new version treat it as somebody else's process. Such a holder is left to its
`WAKEGUARD_MAX_HOURS` deadline.

## Linux

`systemd-inhibit --what=idle` blocks logind's own `IdleAction`. A desktop
environment that runs its own idle timer — GNOME and KDE both do — suspends
without consulting it, so the fallback does not hold there.

## Out of scope

Background tasks. There is no event that reliably marks a background task as
finished, so covering them would mean risking a suppression that is never
released.
