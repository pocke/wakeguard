#!/usr/bin/env bash
# wakeguard - keep the machine awake while a Claude Code turn is running.
set -u

STATE_DIR="${XDG_STATE_HOME:-${HOME:-}/.local/state}/wakeguard"
SESSIONS_DIR="$STATE_DIR/sessions"
CONFIG_FILE="${XDG_CONFIG_HOME:-${HOME:-}/.config}/wakeguard/config"

usage() {
  cat <<'USAGE'
Usage: wakeguard.sh <start|stop|end|reap|status>

  start   Launch a detached sleep-inhibiting holder for this session.
  stop    Kill the holder recorded for this session's turn.
  end     Kill every holder this session recorded.
  reap    Kill holders that no live session can still release.
  status  Print every recorded holder and what state it is in.

Hook events feed the session id on stdin as JSON.
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
# BOOT_ID, and fails when there is no holder pid to act on.
read_pidfile() {
  local file="$1" key value
  HOLDER_PID='' HOLDER_KIND='' CLAUDE_PID='' HOLDER_ENV='' STARTED_AT='' BOOT_ID=''

  [ -r "$file" ] || return 1
  while IFS='=' read -r key value; do
    case "$key" in
      HOLDER_PID) HOLDER_PID="$value" ;;
      HOLDER_KIND) HOLDER_KIND="$value" ;;
      CLAUDE_PID) CLAUDE_PID="$value" ;;
      ENV) HOLDER_ENV="$value" ;;
      STARTED_AT) STARTED_AT="$value" ;;
      BOOT_ID) BOOT_ID="$value" ;;
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
    windows_holder_probe ''
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
# the user opened. Answering in the same trip that kills keeps stop down to one
# interop round trip, which costs several hundred milliseconds.
windows_holder_probe() {
  local action="$1" ps1_win script out

  is_pid "$HOLDER_PID" || { printf unknown; return; }
  # An empty needle would make Contains match every powershell on the machine.
  ps1_win="$(holder_script_winpath)" || { printf unknown; return; }

  script='$p = Get-CimInstance Win32_Process -Filter "ProcessId=__WG_PID__"
if (-not $p) { "gone" }
elseif ($p.CommandLine -and $p.CommandLine.Contains(__WG_SCRIPT__)) { __WG_ACTION__ }
else { "foreign" }'
  script="${script//__WG_ACTION__/${action:-\"ours\"}}"
  # The replacement is quoted so bash 5.2 does not read a & in the path as
  # "insert the match here".
  script="${script//__WG_SCRIPT__/"'$ps1_win'"}"
  script="${script//__WG_PID__/$HOLDER_PID}"

  out="$(powershell_eval "$script" | grep -E '^(ours|killed|foreign|gone)$' | head -n 1)"
  printf '%s' "${out:-unknown}"
}

# Kills the holder when it is still ours, and reports what happened using the
# same vocabulary as holder_state, with "killed" in place of "ours".
holder_release() {
  local state

  if holder_is_windows; then
    # -ErrorAction Stop: without it a refused Stop-Process is non-terminating
    # and "killed" would be reported for a holder that is still running.
    windows_holder_probe 'Stop-Process -Id __WG_PID__ -Force -ErrorAction Stop; "killed"'
    return
  fi

  state="$(unix_holder_state)"
  [ "$state" = ours ] || { printf '%s' "$state"; return; }
  kill "$HOLDER_PID" 2>/dev/null || true
  printf killed
}

# --- subcommands ------------------------------------------------------------

cmd_start() {
  local session_id="$1" pidfile state

  pidfile="$(pidfile_path "$session_id")"
  if read_pidfile "$pidfile"; then
    state="$(holder_state)"
    # Starting a second holder for a state we could not read would leave the
    # first one with nothing recording it.
    if [ "$state" = ours ] || [ "$state" = unknown ]; then
      log "holder for session=$session_id pid=$HOLDER_PID is $state, leaving it"
      return 0
    fi
  fi
  rm -f "$pidfile" 2>/dev/null || true

  HOLDER_PID='' HOLDER_KIND='' STARTED_AT="$(date '+%s')"
  HOLDER_ENV="$(detect_env)"
  CLAUDE_PID="$(claude_pid)"
  BOOT_ID="$(boot_id)"

  start_holder "$CLAUDE_PID" || return 0
  is_pid "$HOLDER_PID" || { log 'holder gave no pid'; return 0; }

  if ! write_pidfile "$pidfile"; then
    log "cannot write $pidfile, killing holder pid=$HOLDER_PID"
    holder_release >/dev/null
    return 0
  fi
  log "started holder pid=$HOLDER_PID kind=$HOLDER_KIND session=$session_id"
}

# Releases the holder that read_pidfile has already loaded, then drops the
# pidfile. Fails, and keeps the pidfile, when the holder's fate could not be
# determined: the pidfile is the only way back to it.
release_pidfile() {
  local pidfile="$1" label="$2" outcome

  outcome="$(holder_release)"
  log "$label holder=$HOLDER_PID kind=$HOLDER_KIND: $outcome"
  [ "$outcome" != unknown ] || return 1
  rm -f "$pidfile" 2>/dev/null || true
}

cmd_stop() {
  local session_id="$1" pidfile
  pidfile="$(pidfile_path "$session_id")"

  if ! read_pidfile "$pidfile"; then
    log "stop session=$session_id: no holder pid recorded"
    rm -f "$pidfile" 2>/dev/null || true
    return 0
  fi
  release_pidfile "$pidfile" "stop session=$session_id" || true
}

# Everything this session recorded, not just its turn holder. Subagent holders
# outlive the turn that started them on purpose, so only the end of the session
# may sweep them up.
cmd_end() {
  local session_id="$1" pidfile

  for pidfile in "$SESSIONS_DIR/$session_id".*.pid "$(pidfile_path "$session_id")"; do
    [ -e "$pidfile" ] || continue
    if ! read_pidfile "$pidfile"; then
      log "end $(pidfile_session "$pidfile"): no holder pid recorded"
      rm -f "$pidfile" 2>/dev/null || true
      continue
    fi
    release_pidfile "$pidfile" "end $(pidfile_session "$pidfile")" || true
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

cmd_reap() {
  local pidfile session state reason
  local windows_pids='' unix_pids=''

  for pidfile in "$SESSIONS_DIR"/*.pid; do
    [ -e "$pidfile" ] || continue
    session="$(pidfile_session "$pidfile")"

    if ! read_pidfile "$pidfile"; then
      log "reaping $session: no holder pid recorded"
      rm -f "$pidfile" 2>/dev/null || true
      continue
    fi

    state="$(holder_state)"
    reason="$(reap_reason "$state")"
    if [ -n "$reason" ]; then
      release_pidfile "$pidfile" "reaping $session ($reason)" && continue
    fi

    if holder_is_windows; then
      windows_pids="$windows_pids $HOLDER_PID"
    else
      unix_pids="$unix_pids $HOLDER_PID"
    fi
  done

  sweep_unrecorded_windows "$windows_pids"
  sweep_unrecorded_systemd "$unix_pids"
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

pid_list_to_csv() {
  printf '%s' "$1" | tr -s ' ' ',' | sed 's/^,//;s/,$//'
}

cmd_status() {
  local pidfile found=0 state

  printf 'env: %s\n' "$(detect_env)"
  printf 'sessions dir: %s\n' "$SESSIONS_DIR"

  for pidfile in "$SESSIONS_DIR"/*.pid; do
    [ -e "$pidfile" ] || continue
    found=1
    if read_pidfile "$pidfile"; then
      state="$(holder_state)"
      printf '%s: %s pid=%s kind=%s env=%s claude=%s started_at=%s\n' \
        "$(pidfile_session "$pidfile")" "$state" "$HOLDER_PID" "$HOLDER_KIND" \
        "$HOLDER_ENV" "${CLAUDE_PID:--}" "$STARTED_AT"
    else
      printf '%s: no holder pid recorded\n' "$(pidfile_session "$pidfile")"
    fi
  done
  [ "$found" = 1 ] || printf 'no holders recorded\n'
}

main() {
  local subcommand="${1:-}" session_id

  case "$subcommand" in
    start|stop|end)
      # A failed suppression must never break the user's turn.
      trap 'exit 0' EXIT
      load_config
      session_id="$(json_string_field "$(drain_stdin)" session_id)"
      case "$session_id" in
        ''|.|..)
          # Without a stable id, start and stop can never find each other and
          # every turn would leave one more holder behind.
          log "no session id in the hook input, doing nothing"
          return 0
          ;;
      esac
      "cmd_$subcommand" "$session_id"
      ;;
    reap)
      trap 'exit 0' EXIT
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
