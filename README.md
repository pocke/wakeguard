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
- **Claude Code 2.1.196 or newer.** Two things arrived in time for it. A
  background hook gets its stdin — before 2.1.72 it did not, and wakeguard,
  finding no session id there, does nothing at all while still telling nobody.
  And the hook input carries `prompt_id`, which is what keeps one turn's `stop`
  off the next turn's holder; without it two turns back to back can end with
  nothing suppressing sleep.
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
UserPromptSubmit  ->  wakeguard.sh start        launch a holder, record a pidfile
Stop, StopFailure ->  wakeguard.sh stop         kill this turn's holder
SubagentStart     ->  wakeguard.sh agent-start  launch a holder for one subagent
SubagentStop      ->  wakeguard.sh agent-stop   kill that subagent's holder
SessionEnd        ->  wakeguard.sh end          kill every holder this session has
SessionStart      ->  wakeguard.sh reap         clean up orphaned holders
```

Every one of these but `agent-start` runs in the background, so nothing waits
for it. Putting a holder on the Windows host costs a round trip through
`powershell.exe` — a third of a second on the machine this was measured on —
and no turn should have to spend that twice. `end` is background in its own
way: SessionEnd hooks share a budget of 1.5 seconds that a plugin cannot raise,
which is not enough to release several holders, so the hook hands the work to a
detached process and returns.

Running in the background means one turn's `stop` and the next turn's `start`
overlap, which is what happens whenever a prompt is queued while a turn is
still finishing. Each pidfile has a lock beside it so the two take their turns,
and each records the `prompt_id` it belongs to so the order they arrive in
stops mattering: a `stop` carrying a different id has been overtaken by a later
turn, and leaves the holder to it.

Asking the Windows host about a holder costs the same round trip whether it is
asked about one or twenty, so `end`, `reap` and `status` ask about all of theirs
at once. On this machine a `reap` that has to release four holders takes 1.3
seconds instead of 3.7, and `status` on the same four 0.4 seconds instead of
1.9.

`agent-start` is the exception because a subagent holder has no turn to belong
to — its `stop` names a different turn from its `start`, so `prompt_id` cannot
pair them. Blocking is what keeps a subagent that fails immediately from having
its `SubagentStop` overtake the `SubagentStart` still recording the holder,
which would leave that holder with nothing to release it.

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

A subagent keeps working after the turn that spawned it has ended, so each one
gets a holder of its own that lives until its `SubagentStop` arrives. Waiting
for a review or a search to come back does not let the machine sleep.

Pidfiles live in `${XDG_STATE_HOME:-~/.local/state}/wakeguard/sessions/`, named
`<session_id>.pid` for a turn and `<session_id>.<agent_id>.pid` for a subagent.
Their locks are directories under
`${XDG_STATE_HOME:-~/.local/state}/wakeguard/locks/`, one per pidfile, cleared
away by whoever holds them and swept by `reap` when nobody comes back.

## Configuration

Set these as environment variables, or write them as `KEY=value` lines in
`${XDG_CONFIG_HOME:-~/.config}/wakeguard/config`. Environment variables win over
the file.

| Variable | Meaning | Default |
|---|---|---|
| `WAKEGUARD_CMD` | Run this command as the holder instead of the one picked by environment detection, e.g. `caffeinate -dims`. Split on whitespace, so quoting an argument does not work | unset |
| `WAKEGUARD_DISPLAY` | `1` keeps the display on as well (`caffeinate -d` / `-KeepDisplayOn`). No effect on Linux | `0` |
| `WAKEGUARD_MAX_HOURS` | How long a holder may live before it gives up on its own. A number in [0.001, 168]; anything else falls back to the default | `8` |
| `WAKEGUARD_LOG` | Append diagnostics to this file. Nothing is written anywhere without it, and a background hook's output never reaches the terminal, so this is the only way to watch what wakeguard did | unset |

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
| Session ends with exit or Ctrl-C | `SessionEnd` hook, which clears every holder the session has, subagent holders included. A pidfile another wakeguard has locked at that moment is left to the reap |
| A subagent finishes | `SubagentStop` hook |
| Claude Code is killed or crashes | macOS: `caffeinate -w` exits with it. Everywhere: the next `SessionStart` reap notices the dead pid |
| A hook is killed before it records the holder | The next `SessionStart` reap sweeps holders that no pidfile claims, on Windows and Linux. macOS has no sweep: `caffeinate` carries no marker telling ours from one the user started by hand, so an unrecorded one falls back to `caffeinate -w` and then to its `-t` deadline |
| A session closes while a background hook is still working | Claude Code kills the hook — documented for `claude -p`, and the same in every run wakeguard was tested in. That leaves the case above, and the interop round trip the hook dies in is what makes the window wide enough to hit, which puts it on Windows and WSL2, where the sweep runs |
| No hook fires at all | The holder's own `WAKEGUARD_MAX_HOURS` deadline. A `WAKEGUARD_CMD` holder gets neither this nor the sweep, since wakeguard can neither give a deadline to an arbitrary command nor recognize one it did not name |
| `wsl --shutdown` | The Windows holder outlives the VM, and the next WSL session reaps it over interop |

Before killing anything, wakeguard confirms that the recorded pid still belongs
to the holder it started — by command name on Unix, by the holder script's path
in the command line on Windows — so a recycled pid never gets an unrelated
process killed.

Half of the table leans on the reap, and the reap only runs when a session
starts. Start no session, and a holder nobody released stays until its own
`WAKEGUARD_MAX_HOURS` deadline.

**Three gaps worth knowing about.** Interrupting a turn with Esc is not a `Stop`
event, so the holder stays until the next turn ends or the session does. Until
then the machine will not sleep on its own. Whether `SubagentStop` arrives when
a subagent is interrupted along with the turn is unverified; if it does not, its
holder stays just as long. And a `Stop` hook — anybody's, not wakeguard's — can
block and hand the turn back to the model; no prompt is submitted for the
continuation, so wakeguard has already counted the turn as over and released
the holder while the model works on.

And a Windows holder is recognized by the holder script's path, which carries
the plugin version, so upgrading the plugin while a holder is running makes the
new version treat it as somebody else's process. Such a holder is left to its
`WAKEGUARD_MAX_HOURS` deadline.

## Development

```
bash test/wakeguard_test.sh
```

The tests set `WAKEGUARD_CMD` to a plain `sleep`, so they exercise the pidfiles,
the locks and the reap without PowerShell, `caffeinate` or `systemd-inhibit`,
and they run the same on every platform. They take about fifteen seconds.

## Linux

`systemd-inhibit --what=idle` blocks logind's own `IdleAction`. A desktop
environment that runs its own idle timer — GNOME and KDE both do — suspends
without consulting it, so the fallback does not hold there.

## Out of scope

**`Bash` run in the background.** No event reliably marks one as finished, so
covering it would add a way to leave the suppression on forever.

**`TaskCreated` / `TaskCompleted`.** These fire when an item is written to the
task list or marked done, which says nothing about anything starting or
finishing, so they cannot drive a suppression.
