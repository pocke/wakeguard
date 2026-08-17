#!/usr/bin/env bash
# Drives wakeguard.sh with WAKEGUARD_CMD so the tests need neither PowerShell
# interop nor caffeinate.
set -u

WG="$(cd -- "$(dirname -- "$0")/.." && pwd)/bin/wakeguard.sh"
FAILURES=0
CURRENT=''

# --- harness ------------------------------------------------------------------

setup() {
  WORK="$(mktemp -d)"
  export XDG_STATE_HOME="$WORK/state"
  export XDG_CONFIG_HOME="$WORK/config"
  export WAKEGUARD_CMD='sleep 3600'
  export WAKEGUARD_MAX_HOURS=8
  export WAKEGUARD_LOG="$WORK/log"
  SESSIONS="$XDG_STATE_HOME/wakeguard/sessions"
  LOCKS="$XDG_STATE_HOME/wakeguard/locks"
}

teardown() {
  local pid
  for pid in $(sed -n 's/.*started holder pid=\([0-9]*\).*/\1/p' "$WAKEGUARD_LOG" 2>/dev/null); do
    kill "$pid" 2>/dev/null
  done
  rm -rf "$WORK"
}

wg() {
  printf '%s' "${2:-}" | bash "$WG" "$1"
}

turn() {
  printf '{"session_id":"%s","prompt_id":"%s"}' "$1" "$2"
}

field() {
  sed -n "s/^$2=//p" "$1" 2>/dev/null
}

# Holds the lock named $1 on behalf of a process that stays alive, and answers
# with that process's pid.
hold_lock() {
  local lock="$LOCKS/$1.lock" pid
  # Without closing its stdout the command substitution around this function
  # would wait for the whole sleep.
  sleep 60 >/dev/null 2>&1 &
  pid=$!
  mkdir -p "$lock"
  printf '%s %s\n' "$pid" "$(date '+%s')" >"$lock/owner"
  printf '%s' "$pid"
}

# A pid that is certain to be gone.
dead_pid() {
  local pid
  sleep 0 >/dev/null 2>&1 &
  pid=$!
  wait "$pid" 2>/dev/null
  printf '%s' "$pid"
}

fail() {
  printf 'FAIL %s\n  %s\n' "$CURRENT" "$1"
  FAILURES=$(( FAILURES + 1 ))
}

assert_eq() {
  [ "$1" = "$2" ] || fail "$3: expected '$2', got '$1'"
}

assert_alive() {
  kill -0 "$1" 2>/dev/null || fail "$2: pid $1 is not running"
}

assert_dead() {
  ! kill -0 "$1" 2>/dev/null || fail "$2: pid $1 is still running"
}

assert_file() {
  [ -e "$1" ] || fail "$2: $1 does not exist"
}

assert_no_file() {
  [ ! -e "$1" ] || fail "$2: $1 still exists"
}

run_tests() {
  local name
  for name in $(declare -F | sed -n 's/^declare -f \(test_.*\)/\1/p'); do
    CURRENT="$name"
    setup
    "$name"
    teardown
  done

  if [ "$FAILURES" -eq 0 ]; then
    printf 'all tests passed\n'
    return 0
  fi
  printf '%s failure(s)\n' "$FAILURES"
  return 1
}

# --- the turn holder ----------------------------------------------------------

test_stop_releases_the_holder_of_its_own_turn() {
  local pid
  wg start "$(turn s1 p1)"
  pid="$(field "$SESSIONS/s1.pid" HOLDER_PID)"
  assert_alive "$pid" 'the holder should be running after start'

  wg stop "$(turn s1 p1)"
  assert_dead "$pid" 'the holder should be gone after stop'
  assert_no_file "$SESSIONS/s1.pid" 'the pidfile should be gone after stop'
}

test_stop_leaves_a_holder_that_a_later_turn_took_over() {
  local pid
  wg start "$(turn s1 p1)"
  pid="$(field "$SESSIONS/s1.pid" HOLDER_PID)"

  wg start "$(turn s1 p2)"
  assert_eq "$(field "$SESSIONS/s1.pid" HOLDER_PID)" "$pid" 'the second turn should reuse the holder'
  assert_eq "$(field "$SESSIONS/s1.pid" PROMPT_ID)" p2 'the second turn should record itself'

  wg stop "$(turn s1 p1)"
  assert_alive "$pid" 'the first turn should not kill the second turn holder'
  assert_file "$SESSIONS/s1.pid" 'the pidfile should survive a stop from an older turn'
}

test_start_reusing_a_holder_keeps_started_at() {
  local started
  wg start "$(turn s1 p1)"
  started="$(field "$SESSIONS/s1.pid" STARTED_AT)"
  sleep 1

  wg start "$(turn s1 p2)"
  assert_eq "$(field "$SESSIONS/s1.pid" STARTED_AT)" "$started" \
    'reusing a holder should not reset the age reap measures'
}

test_stop_releases_a_pidfile_written_without_a_prompt_id() {
  local pid
  wg start "$(turn s1 p1)"
  pid="$(field "$SESSIONS/s1.pid" HOLDER_PID)"
  grep -v '^PROMPT_ID=' "$SESSIONS/s1.pid" >"$SESSIONS/s1.pid.tmp"
  mv "$SESSIONS/s1.pid.tmp" "$SESSIONS/s1.pid"

  wg stop "$(turn s1 p1)"
  assert_dead "$pid" 'a pidfile from an older wakeguard should still be released'
}

test_stop_releases_when_the_event_carries_no_prompt_id() {
  local pid
  wg start "$(turn s1 p1)"
  pid="$(field "$SESSIONS/s1.pid" HOLDER_PID)"

  wg stop '{"session_id":"s1"}'
  assert_dead "$pid" 'a stop without a prompt id should still release'
}

# --- locking ------------------------------------------------------------------

test_start_waits_for_a_lock_held_by_a_live_process() {
  local owner
  owner="$(hold_lock s1)"

  wg start "$(turn s1 p1)" &
  sleep 2
  assert_no_file "$SESSIONS/s1.pid" 'start should wait rather than touch a locked pidfile'

  kill "$owner" 2>/dev/null
  rm -rf "$LOCKS/s1.lock"
  wait
  assert_file "$SESSIONS/s1.pid" 'start should go through once the lock is free'
  assert_alive "$(field "$SESSIONS/s1.pid" HOLDER_PID)" 'the holder should be running'
}

test_start_takes_over_a_lock_whose_owner_is_gone() {
  local lock="$LOCKS/s1.lock"
  mkdir -p "$lock"
  printf '%s %s\n' "$(dead_pid)" "$(date '+%s')" >"$lock/owner"

  wg start "$(turn s1 p1)"
  assert_file "$SESSIONS/s1.pid" 'start should take over a lock nobody holds any more'
  assert_alive "$(field "$SESSIONS/s1.pid" HOLDER_PID)" 'the holder should be running'
}

test_a_lock_is_released_after_the_subcommand() {
  wg start "$(turn s1 p1)"
  assert_no_file "$LOCKS/s1.lock" 'start should not leave its lock behind'
}

# --- reap ---------------------------------------------------------------------

test_reap_skips_a_locked_pidfile() {
  local pid owner
  WAKEGUARD_MAX_HOURS=0.001 wg start "$(turn s1 p1)"
  pid="$(field "$SESSIONS/s1.pid" HOLDER_PID)"
  sleep 5
  owner="$(hold_lock s1)"

  WAKEGUARD_MAX_HOURS=0.001 wg reap
  assert_alive "$pid" 'reap should leave a pidfile another wakeguard is holding'
  assert_file "$SESSIONS/s1.pid" 'reap should leave the pidfile it skipped'

  kill "$owner" 2>/dev/null
  rm -rf "$LOCKS/s1.lock"
  WAKEGUARD_MAX_HOURS=0.001 wg reap
  assert_dead "$pid" 'reap should release the holder once the lock is free'
}

test_reap_releases_a_holder_past_the_deadline() {
  local pid
  WAKEGUARD_MAX_HOURS=0.001 wg start "$(turn s1 p1)"
  pid="$(field "$SESSIONS/s1.pid" HOLDER_PID)"
  sleep 5

  WAKEGUARD_MAX_HOURS=0.001 wg reap
  assert_dead "$pid" 'a holder past WAKEGUARD_MAX_HOURS should be reaped'
  assert_no_file "$SESSIONS/s1.pid" 'the pidfile should be gone after reap'
}

test_reap_removes_a_lock_nobody_holds() {
  local lock="$LOCKS/s1.lock"
  mkdir -p "$lock"
  printf '%s %s\n' "$(dead_pid)" "$(date '+%s')" >"$lock/owner"

  wg reap
  assert_no_file "$lock" 'reap should clear out an abandoned lock'
}

# --- session end --------------------------------------------------------------

test_end_releases_the_turn_holder_and_every_subagent_holder() {
  local turn_pid agent_pid
  wg start "$(turn s1 p1)"
  wg agent-start '{"session_id":"s1","agent_id":"a1"}'
  turn_pid="$(field "$SESSIONS/s1.pid" HOLDER_PID)"
  agent_pid="$(field "$SESSIONS/s1.a1.pid" HOLDER_PID)"

  wg end '{"session_id":"s1"}'
  assert_dead "$turn_pid" 'end should release the turn holder'
  assert_dead "$agent_pid" 'end should release the subagent holder'
  assert_no_file "$SESSIONS/s1.pid" 'end should drop the turn pidfile'
  assert_no_file "$SESSIONS/s1.a1.pid" 'end should drop the subagent pidfile'
}

test_a_subagent_holder_outlives_the_turn_that_spawned_it() {
  local agent_pid
  wg start "$(turn s1 p1)"
  wg agent-start '{"session_id":"s1","agent_id":"a1"}'
  agent_pid="$(field "$SESSIONS/s1.a1.pid" HOLDER_PID)"

  wg stop "$(turn s1 p1)"
  assert_alive "$agent_pid" 'stopping the turn should not touch a subagent holder'

  wg agent-stop '{"session_id":"s1","agent_id":"a1"}'
  assert_dead "$agent_pid" 'agent-stop should release the subagent holder'
}

run_tests
