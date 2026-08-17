#!/usr/bin/env bash
# wakeguard - keep the machine awake while a Claude Code turn is running.
set -u

STATE_DIR="${XDG_STATE_HOME:-${HOME:-}/.local/state}/wakeguard"
SESSIONS_DIR="$STATE_DIR/sessions"
LOCKS_DIR="$STATE_DIR/locks"
CONFIG_FILE="${XDG_CONFIG_HOME:-${HOME:-}/.config}/wakeguard/config"

usage() {
  cat <<'USAGE'
Usage: wakeguard.sh <start|stop|end|agent-start|agent-stop|reap|status>

  start        Launch a detached sleep-inhibiting holder for this session.
  stop         Kill the holder recorded for this session's turn.
  end          Kill every holder this session recorded.
  agent-start  Launch a holder for one subagent, which outlives the turn.
  agent-stop   Kill the holder recorded for one subagent.
  reap         Kill holders that no live session can still release.
  status       Print every recorded holder and what state it is in.

Hook events feed the session id, and for agent-* the agent id, on stdin
as JSON.
USAGE
}

# --- configuration ----------------------------------------------------------

load_config() {
  local line key value

  if [ -r "$CONFIG_FILE" ]; then
    # `|| [ -n "$line" ]` picks up a last line with no newline after it, and a
    # config written on Windows arrives with a \r that would end up inside the
    # value.
    while IFS= read -r line || [ -n "$line" ]; do
      line="${line%$'\r'}"
      case "$line" in
        WAKEGUARD_CMD=*|WAKEGUARD_DISPLAY=*|WAKEGUARD_MAX_HOURS=*|WAKEGUARD_LOG=*) ;;
        *) continue ;;
      esac
      key="${line%%=*}"
      # An environment variable set for this run wins over the file.
      [ -z "${!key:-}" ] || continue
      value="${line#*=}"
      value="${value#[\"\']}"
      value="${value%[\"\']}"
      printf -v "$key" '%s' "$value"
    done <"$CONFIG_FILE"
  fi

  WAKEGUARD_CMD="${WAKEGUARD_CMD:-}"
  WAKEGUARD_DISPLAY="${WAKEGUARD_DISPLAY:-0}"
  WAKEGUARD_MAX_HOURS="${WAKEGUARD_MAX_HOURS:-8}"
  WAKEGUARD_LOG="${WAKEGUARD_LOG:-}"

  normalize_max_hours
}

# An out-of-range or malformed value does not fail loudly: it makes the holder
# exit the moment it starts, and wakeguard would record a suppression that is
# not there.
normalize_max_hours() {
  local value=''

  case "$WAKEGUARD_MAX_HOURS" in
    ''|*[!0-9.]*|*.*.*) ;;
    # The bounds are the ones wakeguard-hold.ps1 accepts.
    *) value="$(awk -v hours="$WAKEGUARD_MAX_HOURS" \
         'BEGIN { if (hours + 0 >= 0.001 && hours + 0 <= 168) printf "%g", hours + 0 }')" ;;
  esac

  if [ -z "$value" ]; then
    log "WAKEGUARD_MAX_HOURS=$WAKEGUARD_MAX_HOURS is not a number in [0.001, 168], using 8"
    value=8
  fi
  WAKEGUARD_MAX_HOURS="$value"
}

max_hours_seconds() {
  awk -v hours="$WAKEGUARD_MAX_HOURS" 'BEGIN { printf "%d", hours * 3600 }'
}

log() {
  [ -n "$WAKEGUARD_LOG" ] || return 0
  printf '%s [%s] %s\n' "$(date '+%Y-%m-%dT%H:%M:%S%z')" "$$" "$*" \
    >>"$WAKEGUARD_LOG" 2>/dev/null || true
}

detect_env() {
  case "$(uname -s)" in
    Darwin) echo macos ;;
    Linux)
      if grep -qi microsoft /proc/version 2>/dev/null; then echo wsl; else echo linux; fi ;;
    MINGW*|MSYS*|CYGWIN*) echo winbash ;;
    *) echo unknown ;;
  esac
}

# --- Windows interop --------------------------------------------------------

to_winpath() {
  if command -v wslpath >/dev/null 2>&1; then
    wslpath -w "$1" 2>/dev/null
  elif command -v cygpath >/dev/null 2>&1; then
    cygpath -w "$1" 2>/dev/null
  fi
}

# CLAUDE_PLUGIN_ROOT can reach a Windows bash as a Windows path, and dirname
# then answers "." for it.
to_unixpath() {
  case "$1" in
    ?:\\*|?:/*|\\\\*)
      if command -v cygpath >/dev/null 2>&1; then
        cygpath -u "$1" 2>/dev/null
      elif command -v wslpath >/dev/null 2>&1; then
        wslpath -u "$1" 2>/dev/null
      fi
      ;;
    *) printf '%s' "$1" ;;
  esac
}

holder_script() {
  local self dir
  self="$(to_unixpath "$0")"
  dir="$(cd -- "$(dirname -- "$self")" 2>/dev/null && pwd)" || return 1
  printf '%s/wakeguard-hold.ps1' "$dir"
}

powershell_bin() {
  if command -v powershell.exe >/dev/null 2>&1; then
    printf 'powershell.exe'
    return 0
  fi
  # interop.appendWindowsPath=false keeps powershell.exe off PATH without
  # disabling interop itself.
  local fallback
  fallback="$(wslpath -u 'C:\Windows\System32\WindowsPowerShell\v1.0\powershell.exe' 2>/dev/null)"
  [ -n "$fallback" ] && [ -x "$fallback" ] || return 1
  printf '%s' "$fallback"
}

powershell_eval() {
  local bin
  bin="$(powershell_bin)" || return 1
  # MSYS rewrites arguments that look like paths on the way to a Windows
  # binary, which would mangle the script text.
  MSYS2_ARG_CONV_EXCL='*' "$bin" -NoProfile -ExecutionPolicy Bypass \
    -Command "$1" 2>/dev/null | tr -d '\r'
}

# --- hook input -------------------------------------------------------------

drain_stdin() {
  # Exiting without reading the hook's JSON can hand the writer a SIGPIPE.
  [ -t 0 ] && return 0
  cat
}

# Reads one string field out of the hook's JSON. The key goes into the pattern
# unescaped, so pass a literal word. Matching it together with its quotes is
# what keeps "agent_type" from answering for "agent_id".
#
# The answer is reduced to characters that are safe in a filename, and the dot
# is not among them: ids are joined with one to name a subagent's pidfile, so a
# dot inside an id would make two different pairs share a name.
json_string_field() {
  local json="$1" key="$2" value
  value="$(printf '%s' "$json" |
    LC_ALL=C grep -o "\"$key\"[[:space:]]*:[[:space:]]*\"[^\"]*\"" |
    head -n 1 |
    LC_ALL=C sed 's/.*"\([^"]*\)"$/\1/')"
  printf '%s' "$value" | LC_ALL=C tr -c 'A-Za-z0-9_-' '_'
}

# --- pidfile ----------------------------------------------------------------

pidfile_path() {
  printf '%s/%s.pid' "$SESSIONS_DIR" "$1"
}

pidfile_session() {
  basename "$1" .pid
}

# Sets HOLDER_PID / HOLDER_KIND / CLAUDE_PID / HOLDER_ENV / STARTED_AT /
# BOOT_ID / PROMPT_ID, and fails when there is no holder pid to act on.
read_pidfile() {
  local file="$1" key value
  HOLDER_PID='' HOLDER_KIND='' CLAUDE_PID='' HOLDER_ENV='' STARTED_AT='' BOOT_ID='' PROMPT_ID=''

  [ -r "$file" ] || return 1
  while IFS='=' read -r key value; do
    case "$key" in
      HOLDER_PID) HOLDER_PID="$value" ;;
      HOLDER_KIND) HOLDER_KIND="$value" ;;
      CLAUDE_PID) CLAUDE_PID="$value" ;;
      ENV) HOLDER_ENV="$value" ;;
      STARTED_AT) STARTED_AT="$value" ;;
      BOOT_ID) BOOT_ID="$value" ;;
      PROMPT_ID) PROMPT_ID="$value" ;;
    esac
  done <"$file"

  is_pid "$HOLDER_PID"
}

write_pidfile() {
  local file="$1" tmp
  tmp="$file.$$.tmp"
  (umask 077 && mkdir -p "$SESSIONS_DIR") 2>/dev/null || return 1
  {
    {
      printf 'HOLDER_PID=%s\n' "$HOLDER_PID"
      printf 'HOLDER_KIND=%s\n' "$HOLDER_KIND"
      printf 'CLAUDE_PID=%s\n' "$CLAUDE_PID"
      printf 'ENV=%s\n' "$HOLDER_ENV"
      printf 'STARTED_AT=%s\n' "$STARTED_AT"
      printf 'BOOT_ID=%s\n' "$BOOT_ID"
      printf 'PROMPT_ID=%s\n' "$PROMPT_ID"
    } >"$tmp" &&
      mv -f "$tmp" "$file"
  } 2>/dev/null || { rm -f "$tmp" 2>/dev/null; return 1; }
}

is_pid() {
  case "${1:-}" in
    ''|0|*[!0-9]*) return 1 ;;
  esac
  return 0
}

# --- locking ------------------------------------------------------------------
#
# Everything that touches a pidfile holds its lock.

LOCK_WAIT_SECONDS="${WAKEGUARD_LOCK_WAIT_SECONDS:-20}"
# A holder that lives through a whole session is expected; a wakeguard run that
# does is not.
LOCK_STALE_SECONDS=120
LOCK_POLL_SECONDS=0.2

HELD_LOCKS=()

lock_path() {
  printf '%s/%s.lock' "$LOCKS_DIR" "$1"
}

# Waits up to $2 seconds for the lock named $1. Fails when the wait runs out.
acquire_lock() {
  local name="$1" wait_seconds="$2" lock deadline
  lock="$(lock_path "$name")"
  deadline=$(( $(date '+%s') + wait_seconds ))

  (umask 077 && mkdir -p "$LOCKS_DIR") 2>/dev/null || return 1
  while :; do
    if mkdir "$lock" 2>/dev/null; then
      # A lock nobody can be identified through is one nobody can hand back,
      # so failing to sign it is failing to take it.
      # The 2>/dev/null comes first so that the redirection failing is quiet.
      if printf '%s %s\n' "$$" "$(date '+%s')" 2>/dev/null >"$lock/owner"; then
        HELD_LOCKS+=("$lock")
        return 0
      fi
      rmdir "$lock" 2>/dev/null
      return 1
    fi

    lock_is_stale "$lock" && steal_lock "$lock" && continue
    [ "$(date '+%s')" -lt "$deadline" ] || return 1
    sleep "$LOCK_POLL_SECONDS" 2>/dev/null || sleep 1
  done
}

# A hook is killed when its session's process exits, so a lock whose owner is
# gone is an ordinary leftover rather than a sign of a crash.
lock_is_stale() {
  local lock="$1" owner pid taken_at

  owner="$(cat "$lock/owner" 2>/dev/null)"
  pid="${owner%% *}"
  taken_at="${owner##* }"
  case "$taken_at" in ''|*[!0-9]*) taken_at='' ;; esac

  # Between the mkdir that takes a lock and the line that signs it, and again
  # between unsigning it and removing it, a lock says nothing about who holds
  # it. Its own age is then the only thing that tells a live one from a corpse.
  if ! is_pid "$pid" || [ -z "$taken_at" ]; then
    [ -n "$(find "$lock" -maxdepth 0 -mmin "+$(( LOCK_STALE_SECONDS / 60 ))" 2>/dev/null)" ]
    return
  fi

  kill -0 "$pid" 2>/dev/null || return 0
  # The pid may have been recycled by an unrelated process.
  [ "$(( $(date '+%s') - 10#$taken_at ))" -gt "$LOCK_STALE_SECONDS" ]
}

# Renaming is atomic, so of the processes that give up on one lock at the same
# moment only one gets to clear it away.
steal_lock() {
  local lock="$1" taken="$1.stale.$$"

  mv "$lock" "$taken" 2>/dev/null || return 1
  rm -rf "$taken" 2>/dev/null
  log "took over the abandoned lock $lock"
}

release_lock() {
  local count="${#HELD_LOCKS[@]}" lock owner

  [ "$count" -gt 0 ] || return 0
  lock="${HELD_LOCKS[count - 1]}"
  unset 'HELD_LOCKS[count - 1]'

  owner="$(cat "$lock/owner" 2>/dev/null)"
  if [ "${owner%% *}" != "$$" ]; then
    # Losing the lock means the pidfile was open to somebody else all along.
    log "the lock $lock was taken from us"
    return 0
  fi
  rm -f "$lock/owner" 2>/dev/null
  rmdir "$lock" 2>/dev/null
}

release_locks() {
  while [ "${#HELD_LOCKS[@]}" -gt 0 ]; do
    release_lock
  done
}

# Changes on every boot, so a pidfile written before a reboot can be told apart
# from one written by a session that is still running. Empty when unavailable.
boot_id() {
  if [ -r /proc/sys/kernel/random/boot_id ]; then
    tr -d '\n' </proc/sys/kernel/random/boot_id
  else
    # Not kern.boottime, which XNU recomputes from the wall clock and so shifts
    # on every NTP correction after a wake.
    sysctl -n kern.bootsessionuuid 2>/dev/null | LC_ALL=C tr -c 'A-Za-z0-9' '_'
  fi
}

# --- process inspection -----------------------------------------------------

process_command() {
  local pid="$1" out=''
  if [ -r "/proc/$pid/comm" ] && read -r out <"/proc/$pid/comm" 2>/dev/null; then
    printf '%s' "$out"
    return 0
  fi
  out="$(ps -o comm= -p "$pid" 2>/dev/null)"
  if [ -n "$out" ]; then
    printf '%s' "$out"
    return 0
  fi
  # MSYS ps understands neither -o nor comm=, so fall back to its table.
  ps -p "$pid" 2>/dev/null | awk 'NR == 2 { print $NF }'
}

parent_pid() {
  local pid="$1" ppid=''
  if [ -r "/proc/$pid/status" ]; then
    ppid="$(awk '/^PPid:/ { print $2 }' "/proc/$pid/status" 2>/dev/null)"
  else
    ppid="$(ps -o ppid= -p "$pid" 2>/dev/null | tr -d ' ')"
  fi
  is_pid "$ppid" || return 1
  printf '%s' "$ppid"
}

# How many shells sit between Claude Code and a hook depends on whether the
# wrapper shell exec's itself away, so walk up by name rather than assume a
# fixed depth. Returning nothing beats returning the wrong pid, which would
# either keep the crash safeties from firing or point them at a live session.
claude_pid() {
  local pid="$PPID" depth=0

  while [ "$depth" -lt 8 ] && is_pid "$pid" && [ "$pid" != 1 ]; do
    case "$(process_command "$pid")" in
      claude|claude-code|*/claude|*/claude-code|node|*/node)
        printf '%s' "$pid"
        return 0
        ;;
    esac
    pid="$(parent_pid "$pid")" || return 0
    depth=$(( depth + 1 ))
  done
}

# --- holder lifecycle -------------------------------------------------------

run_detached() {
  if command -v setsid >/dev/null 2>&1; then
    # Without a session of its own the holder stays in the hook's process
    # group and goes down with it when a hook is killed on timeout.
    setsid "$@" </dev/null >/dev/null 2>&1 &
  else
    nohup "$@" </dev/null >/dev/null 2>&1 &
  fi
  HOLDER_PID=$!
  disown 2>/dev/null || true
}

# Sets HOLDER_PID and HOLDER_KIND on success.
start_holder() {
  local claude_pid="$1"

  if [ -n "$WAKEGUARD_CMD" ]; then
    start_holder_custom
    return
  fi

  case "$HOLDER_ENV" in
    macos) start_holder_macos "$claude_pid" ;;
    linux) start_holder_systemd ;;
    # Not a typo for wsl: a suppression inside the VM is pointless because the
    # Windows host suspends the VM along with itself.
    wsl|winbash) start_holder_windows ;;
    *)
      log "no holder available for env=$HOLDER_ENV"
      return 1
      ;;
  esac
}

start_holder_macos() {
  local claude_pid="$1"
  local -a cmd=(caffeinate -i -t "$(max_hours_seconds)")

  command -v caffeinate >/dev/null 2>&1 || { log 'caffeinate not found'; return 1; }
  [ "$WAKEGUARD_DISPLAY" = 1 ] && cmd+=(-d)
  # -w makes caffeinate exit with Claude Code, which covers a crash that fires
  # no hook at all.
  [ -n "$claude_pid" ] && cmd+=(-w "$claude_pid")

  run_detached "${cmd[@]}"
  HOLDER_KIND=caffeinate
}

start_holder_systemd() {
  command -v systemd-inhibit >/dev/null 2>&1 ||
    { log 'systemd-inhibit not found'; return 1; }

  run_detached systemd-inhibit --what=idle --who=wakeguard \
    --why='Claude Code turn in progress' \
    sleep "${WAKEGUARD_MAX_HOURS}h"
  HOLDER_KIND=systemd-inhibit
}

start_holder_windows() {
  local ps1 ps1_win arglist pid

  ps1="$(holder_script)" && [ -r "$ps1" ] ||
    { log "holder script not found next to $0"; return 1; }
  ps1_win="$(holder_script_winpath)" ||
    { log "cannot convert to a Windows path: $ps1"; return 1; }

  # Start-Process joins -ArgumentList with spaces and quotes nothing, so the
  # path brings its own quotes to survive a user name like "John Doe".
  arglist="'-NoProfile','-ExecutionPolicy','Bypass','-File','\"$ps1_win\"'"
  arglist="$arglist,'-TimeoutHours','$WAKEGUARD_MAX_HOURS'"
  [ "$WAKEGUARD_DISPLAY" = 1 ] && arglist="$arglist,'-KeepDisplayOn'"

  # Anything but a bare number is interop noise such as the UNC working
  # directory warning.
  pid="$(powershell_eval \
    "(Start-Process powershell -ArgumentList $arglist -WindowStyle Hidden -PassThru).Id" |
    grep -E '^[0-9]+$' | tail -n 1)"
  is_pid "$pid" || { log 'Start-Process returned no pid'; return 1; }

  HOLDER_PID="$pid"
  HOLDER_KIND=powershell
}

# The Windows path of the holder script, escaped for a PowerShell single-quoted
# string.
holder_script_winpath() {
  local ps1 win
  ps1="$(holder_script)" || return 1
  win="$(to_winpath "$ps1")"
  [ -n "$win" ] || return 1
  printf '%s' "${win//\'/\'\'}"
}

start_holder_custom() {
  local -a cmd
  read -r -a cmd <<<"$WAKEGUARD_CMD"
  [ "${#cmd[@]}" -gt 0 ] || { log 'WAKEGUARD_CMD is empty'; return 1; }

  run_detached "${cmd[@]}"
  HOLDER_KIND="${cmd[0]##*/}"
}

# --- holder identity --------------------------------------------------------
#
# A recorded pid may have been recycled by an unrelated process, so every path
# that touches a holder first asks what is actually running under that pid:
#
#   ours     the holder this pidfile describes
#   foreign  a live process that is not it
#   gone     no such process
#   unknown  the question could not be answered

# A powershell holder's pid is a Windows pid, unusable with kill(2) even when
# wakeguard.sh itself runs under WSL2.
holder_is_windows() {
  [ "$HOLDER_KIND" = powershell ]
}

holder_state() {
  if holder_is_windows; then
    windows_state "$HOLDER_PID"
  else
    unix_holder_state
  fi
}

unix_holder_state() {
  local comm

  is_pid "$HOLDER_PID" || { printf unknown; return; }
  kill -0 "$HOLDER_PID" 2>/dev/null || { printf gone; return; }

  comm="$(process_command "$HOLDER_PID")"
  comm="${comm##*/}"
  if [ -z "$comm" ]; then
    printf unknown
  elif [ "$comm" = "$HOLDER_KIND" ]; then
    printf ours
  elif [ "${#comm}" -eq 15 ] && [ "${HOLDER_KIND#"$comm"}" != "$HOLDER_KIND" ]; then
    # Linux cuts comm at 15 characters, so a longer holder name only ever
    # matches on its prefix.
    printf ours
  else
    printf foreign
  fi
}

# Every powershell.exe on the machine answers to ProcessName "powershell", so
# only the holder script in its command line tells ours apart from a session
# the user opened.
#
# Reaching the Windows host costs several hundred milliseconds, and it costs the
# same whether the question is about one holder or twenty. Answers
# "<pid> <state>" a line at a time, and says nothing at all about a pid it could
# not reach a verdict on.
windows_holders_probe() {
  local pids="$1" action="$2" ps1_win filter='' pid script

  for pid in $pids; do
    filter="${filter:+$filter or }ProcessId=$pid"
  done
  [ -n "$filter" ] || return 0
  # An empty needle would make Contains match every powershell on the machine.
  ps1_win="$(holder_script_winpath)" || return 0

  script="$(cat <<'POWERSHELL'
$found = @{}
try {
  Get-CimInstance Win32_Process -Filter "__WG_FILTER__" -ErrorAction Stop |
    ForEach-Object { $found[[string]$_.ProcessId] = $_ }
} catch {
  # Going on would leave $found empty and call every live holder gone, and gone
  # is a verdict the caller acts on.
  exit
}
foreach ($id in @(__WG_PIDS__)) {
  $p = $found[[string]$id]
  if (-not $p) { "$id gone" }
  elseif ($p.CommandLine -and $p.CommandLine.Contains(__WG_SCRIPT__)) { __WG_ACTION__ }
  else { "$id foreign" }
}
POWERSHELL
  )"
  script="${script//__WG_ACTION__/${action:-\"\$id ours\"}}"
  # The replacements are quoted so bash 5.2 does not read a & in them as
  # "insert the match here".
  script="${script//__WG_SCRIPT__/"'$ps1_win'"}"
  script="${script//__WG_FILTER__/"$filter"}"
  script="${script//__WG_PIDS__/"$(pid_list_to_csv "$pids")"}"

  powershell_eval "$script" | grep -E '^[0-9]+ (ours|killed|foreign|gone)$'
}

# Kills every holder in $1 in one round trip. A Stop-Process that is refused
# would otherwise end the loop and leave the rest of the pids unanswered, and a
# refusal means the holder is still running, which is not "killed".
windows_holders_release() {
  windows_holders_probe "$1" \
    'try { Stop-Process -Id $id -Force -ErrorAction Stop; "$id killed" } catch { }'
}

# What a batch answered about one pid, or nothing when it did not answer.
state_of() {
  local answers="$1" pid="$2" line
  line="$(printf '%s\n' "$answers" | grep -m 1 -E "^$pid ")" || return 1
  printf '%s' "${line#* }"
}

# What the walk over the pidfiles already asked the Windows host, and which pids
# it asked about, so that no path asks a second time for the same holder.
WINDOWS_STATES=''
WINDOWS_PROBED=''

prefetch_windows_states() {
  WINDOWS_PROBED=" $1 "
  WINDOWS_STATES="$(windows_holders_probe "$1" '')"
}

windows_state() {
  local pid="$1" state

  is_pid "$pid" || { printf unknown; return; }
  if state="$(state_of "$WINDOWS_STATES" "$pid")"; then
    printf '%s' "$state"
    return
  fi
  # A pid the batch was asked about and did not answer for is a pid the Windows
  # host would not answer for twice either, and reap holds every lock it took
  # while it waits.
  case "$WINDOWS_PROBED" in
    *" $pid "*) printf unknown; return ;;
  esac
  state="$(state_of "$(windows_holders_probe "$pid" '')" "$pid")" || state=unknown
  printf '%s' "$state"
}

# Kills the holder when it is still ours, and reports what happened using the
# same vocabulary as holder_state, with "killed" in place of "ours".
holder_release() {
  local state

  if holder_is_windows; then
    state="$(state_of "$(windows_holders_release "$HOLDER_PID")" "$HOLDER_PID")" ||
      state=unknown
    printf '%s' "$state"
    return
  fi

  state="$(unix_holder_state)"
  [ "$state" = ours ] || { printf '%s' "$state"; return; }
  kill "$HOLDER_PID" 2>/dev/null || true
  printf killed
}

# --- subcommands ------------------------------------------------------------

cmd_start() {
  local key="$1" prompt_id="$2" pidfile state

  pidfile="$(pidfile_path "$key")"
  acquire_lock "$key" "$LOCK_WAIT_SECONDS" ||
    { log "start $key: the lock stayed taken, doing nothing"; return 0; }

  if read_pidfile "$pidfile"; then
    state="$(holder_state)"
    # Starting a second holder for a state we could not read would leave the
    # first one with nothing recording it.
    if [ "$state" = ours ] || [ "$state" = unknown ]; then
      # Recording this turn is what keeps its own stop from killing a holder
      # that a later turn has taken over. STARTED_AT stays as it was, so reap
      # goes on measuring the holder's age against WAKEGUARD_MAX_HOURS.
      PROMPT_ID="$prompt_id"
      if write_pidfile "$pidfile"; then
        log "start $key: holder pid=$HOLDER_PID is $state, keeping it for prompt=$prompt_id"
      else
        # A holder still recorded against the turn before this one is a holder
        # this turn's stop will refuse to touch.
        log "start $key: cannot update $pidfile"
        release_pidfile "$pidfile" "start $key" || true
      fi
      return 0
    fi
  fi
  rm -f "$pidfile" 2>/dev/null || true

  HOLDER_PID='' HOLDER_KIND='' STARTED_AT="$(date '+%s')"
  HOLDER_ENV="$(detect_env)"
  CLAUDE_PID="$(claude_pid)"
  BOOT_ID="$(boot_id)"
  PROMPT_ID="$prompt_id"

  start_holder "$CLAUDE_PID" || return 0
  is_pid "$HOLDER_PID" || { log 'holder gave no pid'; return 0; }

  if ! write_pidfile "$pidfile"; then
    log "cannot write $pidfile, killing holder pid=$HOLDER_PID"
    holder_release >/dev/null
    return 0
  fi
  log "started holder pid=$HOLDER_PID kind=$HOLDER_KIND session=$key prompt=$prompt_id"
}

# Records what became of a holder and drops the pidfile that named it. Fails,
# and keeps the pidfile, when the holder's fate could not be determined: the
# pidfile is the only way back to it.
apply_outcome() {
  local pidfile="$1" label="$2" pid="$3" kind="$4" outcome="$5"

  log "$label holder=$pid kind=$kind: $outcome"
  [ "$outcome" != unknown ] || return 1
  rm -f "$pidfile" 2>/dev/null || true
}

# Releases the holder that read_pidfile has already loaded.
release_pidfile() {
  local pidfile="$1" label="$2"

  apply_outcome "$pidfile" "$label" "$HOLDER_PID" "$HOLDER_KIND" "$(holder_release)"
}

# Holders waiting for one shared round trip to the Windows host, the pidfiles
# that named them, and what each release is being logged as. The three are read
# by index, and their locks stay held until the batch has answered for them.
PENDING_PIDS=()
PENDING_PIDFILES=()
PENDING_LABELS=()

# The holders the batch would not answer for, which are still running as far as
# anyone knows and so must stay out of the sweep's way.
UNRESOLVED_PIDS=''

pend_release() {
  PENDING_PIDFILES+=("$1")
  PENDING_LABELS+=("$2")
  PENDING_PIDS+=("$HOLDER_PID")
}

flush_releases() {
  local answers count="${#PENDING_PIDS[@]}" i=0 pid outcome

  UNRESOLVED_PIDS=''
  [ "$count" -gt 0 ] || return 0
  answers="$(windows_holders_release "${PENDING_PIDS[*]}")"

  while [ "$i" -lt "$count" ]; do
    pid="${PENDING_PIDS[i]}"
    outcome="$(state_of "$answers" "$pid")" || outcome=unknown
    apply_outcome "${PENDING_PIDFILES[i]}" "${PENDING_LABELS[i]}" \
      "$pid" powershell "$outcome" || UNRESOLVED_PIDS="$UNRESOLVED_PIDS $pid"
    i=$(( i + 1 ))
  done
  PENDING_PIDS=()
  PENDING_PIDFILES=()
  PENDING_LABELS=()
}

cmd_stop() {
  local key="$1" prompt_id="$2" pidfile
  pidfile="$(pidfile_path "$key")"

  acquire_lock "$key" "$LOCK_WAIT_SECONDS" ||
    { log "stop $key: the lock stayed taken, leaving the holder to end and reap"; return 0; }

  if ! read_pidfile "$pidfile"; then
    log "stop $key: no holder pid recorded"
    rm -f "$pidfile" 2>/dev/null || true
    return 0
  fi
  # Hooks reach here out of order, so a mismatch means a later turn already took
  # the holder over. Either side missing an id leaves the two impossible to
  # pair, and the holder is released.
  if [ -n "$PROMPT_ID" ] && [ -n "$prompt_id" ] && [ "$PROMPT_ID" != "$prompt_id" ]; then
    log "stop $key: holder belongs to prompt=$PROMPT_ID, not $prompt_id, leaving it"
    return 0
  fi
  release_pidfile "$pidfile" "stop $key" || true
}

# Every SessionEnd hook on the machine shares a budget of 1.5 seconds, and a
# plugin's own timeout does not raise it:
# https://code.claude.com/docs/en/hooks#sessionend
# One round trip to the Windows host is a third of that before any other hook
# has run, and a lock this run has to wait for is more. The hook therefore hands
# the work to a process that outlives it, which is what the same page recommends
# for anything that has to survive the session.
detach_end() {
  local session_id="$1" detached

  run_detached env "WAKEGUARD_END_SESSION=$session_id" bash "$0" end
  detached="$HOLDER_PID"
  log "end $session_id: handed over to pid=$detached"
}

# The waiting is capped for the whole run rather than per pidfile, so a session
# with several holders cannot spend its time on the first lock it finds taken.
END_LOCK_BUDGET_SECONDS=3

# Everything this session recorded, not just its turn holder. Subagent holders
# outlive the turn that started them on purpose, so only the end of the session
# may sweep them up.
cmd_end() {
  local session_id="$1" pidfile session deadline remaining locked=0
  deadline=$(( $(date '+%s') + END_LOCK_BUDGET_SECONDS ))

  # The turn holder goes first: it is the one a lock this run never gets would
  # leave suppressing sleep with nothing but reap to notice.
  for pidfile in "$(pidfile_path "$session_id")" "$SESSIONS_DIR/$session_id".*.pid; do
    [ -e "$pidfile" ] || continue
    session="$(pidfile_session "$pidfile")"

    remaining=$(( deadline - $(date '+%s') ))
    [ "$remaining" -ge 0 ] || remaining=0
    if ! acquire_lock "$session" "$remaining"; then
      log "end $session: the lock stayed taken, leaving the holder to reap"
      continue
    fi
    locked=$(( locked + 1 ))

    if ! read_pidfile "$pidfile"; then
      log "end $session: no holder pid recorded"
      rm -f "$pidfile" 2>/dev/null || true
    elif holder_is_windows; then
      pend_release "$pidfile" "end $session"
    else
      release_pidfile "$pidfile" "end $session" || true
    fi
  done

  flush_releases
  while [ "$locked" -gt 0 ]; do
    release_lock
    locked=$(( locked - 1 ))
  done
}

# Prints why a holder can no longer be released by the session that started it,
# or nothing when the pidfile still describes a working session.
reap_reason() {
  local state="$1" age

  case "$state" in
    gone|foreign) printf 'the holder is %s' "$state"; return 0 ;;
  esac

  # After a reboot, and after `wsl --shutdown` in particular, pids restart from
  # small numbers, so a recorded CLAUDE_PID almost certainly lands on some
  # unrelated live process.
  if [ -n "$BOOT_ID" ] && [ "$BOOT_ID" != "$(boot_id)" ]; then
    printf 'recorded before the current boot'
    return 0
  fi

  if [ -n "$CLAUDE_PID" ] && ! kill -0 "$CLAUDE_PID" 2>/dev/null; then
    printf 'claude pid %s is gone' "$CLAUDE_PID"
    return 0
  fi

  case "$STARTED_AT" in
    ''|*[!0-9]*) printf 'STARTED_AT is unusable'; return 0 ;;
  esac
  age=$(( $(date '+%s') - 10#$STARTED_AT ))
  if [ "$age" -gt "$(max_hours_seconds)" ]; then
    printf 'alive for %ss, past the %sh limit' "$age" "$WAKEGUARD_MAX_HOURS"
  fi
}

# No pidfile can be named this: json_string_field reduces an id to letters,
# digits, underscores and dashes, and the pidfiles reap walks are named after
# one or two of those.
REAP_LOCK='reap+all'

cmd_reap() {
  local pidfile session state reason locked=0 to_probe=''
  local windows_pids='' unix_pids=''
  local -a mine=()

  acquire_lock "$REAP_LOCK" 0 ||
    { log 'reap: another reap is already running'; return 0; }

  for pidfile in "$SESSIONS_DIR"/*.pid; do
    [ -e "$pidfile" ] || continue
    session="$(pidfile_session "$pidfile")"

    # Whoever holds the lock is mid-decision about this holder, and waiting for
    # them buys nothing the next SessionStart cannot do. Its pid still has to
    # reach the keep list, or the sweep below would kill a live holder for the
    # crime of not being readable right now.
    if ! acquire_lock "$session" 0; then
      log "reaping $session: another wakeguard holds the lock, skipping"
      read_pidfile "$pidfile" && keep_holder
      continue
    fi
    locked=$(( locked + 1 ))
    mine+=("$pidfile")

    if read_pidfile "$pidfile" && holder_is_windows; then
      to_probe="$to_probe $HOLDER_PID"
    fi
  done

  # One question about every windows holder at once, before any of them is
  # judged. holder_state answers out of this for the rest of the run.
  prefetch_windows_states "$to_probe"

  for pidfile in ${mine[@]+"${mine[@]}"}; do
    session="$(pidfile_session "$pidfile")"
    if ! read_pidfile "$pidfile"; then
      log "reaping $session: no holder pid recorded"
      rm -f "$pidfile" 2>/dev/null || true
      continue
    fi

    state="$(holder_state)"
    reason="$(reap_reason "$state")"
    if [ -n "$reason" ]; then
      if holder_is_windows; then
        pend_release "$pidfile" "reaping $session ($reason)"
        continue
      fi
      release_pidfile "$pidfile" "reaping $session ($reason)" && continue
    fi

    keep_holder
  done

  flush_releases
  windows_pids="$windows_pids$UNRESOLVED_PIDS"
  while [ "$locked" -gt 0 ]; do
    release_lock
    locked=$(( locked - 1 ))
  done

  # The sweeps recognize a holder by the one thing wakeguard gave it, and an
  # arbitrary command was given nothing. Every systemd-inhibit and every
  # PowerShell holder on the machine then belongs to somebody else.
  if [ -z "$WAKEGUARD_CMD" ]; then
    sweep_unrecorded_windows "$windows_pids"
    sweep_unrecorded_systemd "$unix_pids"
  fi
  sweep_abandoned_locks
}

# Appends the holder read_pidfile has loaded to cmd_reap's windows_pids or
# unix_pids, the lists it hands the sweeps.
keep_holder() {
  if holder_is_windows; then
    windows_pids="$windows_pids $HOLDER_PID"
  else
    unix_pids="$unix_pids $HOLDER_PID"
  fi
}

# A holder started by a hook that was killed before it could write its pidfile
# is invisible to every path above, and nothing is left that would ever release
# it. Kill the holders this machine is running that no pidfile claims.
#
# Every sweep skips holders younger than SWEEP_MIN_AGE_SECONDS. Walking the
# pidfiles costs an interop round trip each, and a session that starts during
# that walk would otherwise look unrecorded and lose its holder mid-turn. An
# orphan is in no hurry: it carries its own deadline.
SWEEP_MIN_AGE_SECONDS=120

sweep_unrecorded_windows() {
  local recorded="$1" ps1_win script pid

  ps1_win="$(holder_script_winpath)" || return 0
  script="$(cat <<'POWERSHELL'
$keep = @(__WG_KEEP__)
$cutoff = (Get-Date).AddSeconds(-__WG_MIN_AGE__)
Get-CimInstance Win32_Process -Filter "Name='powershell.exe'" |
  Where-Object { $_.CommandLine -and $_.CommandLine.Contains(__WG_SCRIPT__) -and
                 $_.CreationDate -lt $cutoff -and
                 $keep -notcontains $_.ProcessId } |
  ForEach-Object { Stop-Process -Id $_.ProcessId -Force; $_.ProcessId }
POWERSHELL
  )"
  # The replacement is quoted so bash 5.2 does not read a & in the path as
  # "insert the match here".
  script="${script//__WG_SCRIPT__/"'$ps1_win'"}"
  script="${script//__WG_KEEP__/"$(pid_list_to_csv "$recorded")"}"
  script="${script//__WG_MIN_AGE__/$SWEEP_MIN_AGE_SECONDS}"

  # Killed in the same trip that finds them.
  for pid in $(powershell_eval "$script" | grep -E '^[0-9]+$'); do
    log "swept unrecorded windows holder pid=$pid"
  done
}

sweep_unrecorded_systemd() {
  local recorded="$1" pid age

  for pid in $(pgrep -f -- '--who=wakeguard' 2>/dev/null); do
    case " $recorded " in *" $pid "*) continue ;; esac
    # pgrep -f matches any command line carrying that text, including a shell
    # that merely mentions it.
    [ "$(process_command "$pid")" = systemd-inhibit ] || continue
    age="$(ps -o etimes= -p "$pid" 2>/dev/null | tr -d ' ')"
    case "$age" in ''|*[!0-9]*) continue ;; esac
    [ "$age" -ge "$SWEEP_MIN_AGE_SECONDS" ] || continue
    kill "$pid" 2>/dev/null || true
    log "swept unrecorded systemd-inhibit pid=$pid"
  done
}

# A wakeguard run killed inside its critical section leaves its lock behind, and
# the session it belonged to will never come back for it.
sweep_abandoned_locks() {
  local lock

  for lock in "$LOCKS_DIR"/*.lock; do
    [ -d "$lock" ] || continue
    lock_is_stale "$lock" && steal_lock "$lock"
  done
}

pid_list_to_csv() {
  printf '%s' "$1" | tr -s ' ' ',' | sed 's/^,//;s/,$//'
}

cmd_status() {
  local pidfile found=0 state to_probe=''

  printf 'env: %s\n' "$(detect_env)"
  printf 'sessions dir: %s\n' "$SESSIONS_DIR"

  for pidfile in "$SESSIONS_DIR"/*.pid; do
    [ -e "$pidfile" ] || continue
    if read_pidfile "$pidfile" && holder_is_windows; then
      to_probe="$to_probe $HOLDER_PID"
    fi
  done
  prefetch_windows_states "$to_probe"

  for pidfile in "$SESSIONS_DIR"/*.pid; do
    [ -e "$pidfile" ] || continue
    found=1
    if read_pidfile "$pidfile"; then
      state="$(holder_state)"
      printf '%s: %s pid=%s kind=%s env=%s claude=%s started_at=%s prompt=%s\n' \
        "$(pidfile_session "$pidfile")" "$state" "$HOLDER_PID" "$HOLDER_KIND" \
        "$HOLDER_ENV" "${CLAUDE_PID:--}" "$STARTED_AT" "${PROMPT_ID:--}"
    else
      printf '%s: no holder pid recorded\n' "$(pidfile_session "$pidfile")"
    fi
  done
  [ "$found" = 1 ] || printf 'no holders recorded\n'
}

# An id that can name a pidfile. "." and ".." would name the directory itself.
usable_id() {
  case "${1:-}" in
    ''|.|..) return 1 ;;
  esac
  return 0
}

main() {
  local subcommand="${1:-}" input session_id agent_id

  case "$subcommand" in
    start|stop|end|agent-start|agent-stop)
      # A failed suppression must never break the user's turn.
      trap 'release_locks; exit 0' EXIT
      load_config

      if [ "$subcommand" = end ] && [ -n "${WAKEGUARD_END_SESSION:-}" ]; then
        cmd_end "$WAKEGUARD_END_SESSION"
        return 0
      fi
      input="$(drain_stdin)"

      session_id="$(json_string_field "$input" session_id)"
      if ! usable_id "$session_id"; then
        # Without a stable id, start and stop can never find each other and
        # every turn would leave one more holder behind.
        log "no session id in the hook input, doing nothing"
        return 0
      fi

      case "$subcommand" in
        agent-*)
          agent_id="$(json_string_field "$input" agent_id)"
          if ! usable_id "$agent_id"; then
            # The name would collapse to the session's own pidfile, and this
            # subagent's stop would then kill the turn's holder.
            log "no agent id in the hook input, doing nothing"
            return 0
          fi
          # No prompt id: a subagent holder outlives the turn that spawned it,
          # so its stop arrives carrying a turn this holder never belonged to.
          # SubagentStart blocks instead, which is what stops an agent-stop from
          # arriving while the start it belongs to is still running.
          "cmd_${subcommand#agent-}" "$session_id.$agent_id" ''
          ;;
        end)
          detach_end "$session_id"
          ;;
        *)
          "cmd_$subcommand" "$session_id" "$(json_string_field "$input" prompt_id)"
          ;;
      esac
      ;;
    reap)
      trap 'release_locks; exit 0' EXIT
      load_config
      drain_stdin >/dev/null
      cmd_reap
      ;;
    status)
      load_config
      cmd_status
      ;;
    ''|-h|--help|help)
      usage
      ;;
    *)
      usage >&2
      # Not 2: a hook exiting 2 blocks the user's prompt.
      exit 1
      ;;
  esac
}

main "$@"
exit 0
