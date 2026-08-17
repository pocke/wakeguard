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
  export WAKEGUARD_LOCK_WAIT_SECONDS=2
  SESSIONS="$XDG_STATE_HOME/wakeguard/sessions"
  LOCKS="$XDG_STATE_HOME/wakeguard/locks"
  STRAYS=()
}

teardown() {
  local pid
  for pid in $(sed -n 's/.*started holder pid=\([0-9]*\).*/\1/p' "$WAKEGUARD_LOG" 2>/dev/null) \
             ${STRAYS[@]+"${STRAYS[@]}"}; do
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
  sleep 30 >/dev/null 2>&1 &
  pid=$!
  mkdir -p "$lock"
  printf '%s %s\n' "$pid" "$(date '+%s')" >"$lock/owner"
  printf '%s' "$pid"
}

# Ages a holder past WAKEGUARD_MAX_HOURS without waiting for it.
backdate_pidfile() {
  local pidfile="$1" seconds="$2" started
  started="$(field "$pidfile" STARTED_AT)"
  sed "s/^STARTED_AT=.*/STARTED_AT=$(( started - seconds ))/" "$pidfile" >"$pidfile.aged"
  mv "$pidfile.aged" "$pidfile"
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

# SessionEnd hands its work to a detached process, so the caller sees the
# result appear rather than be there on return.
wait_gone() {
  local path="$1" tries=100
  while [ -e "$path" ] && [ "$tries" -gt 0 ]; do
    sleep 0.1
    tries=$(( tries - 1 ))
  done
}

assert_log() {
  grep -q -- "$1" "$WAKEGUARD_LOG" 2>/dev/null || fail "$2: nothing logged about '$1'"
}

run_tests() {
  local name
  for name in $(declare -F | sed -n 's/^declare -f \(test_.*\)/\1/p'); do
    CURRENT="$name"
    printf '.. %s\n' "$name"
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
  STRAYS+=("$owner")
  WAKEGUARD_LOCK_WAIT_SECONDS=20 wg start "$(turn s1 p1)" &
  sleep 1
  assert_no_file "$SESSIONS/s1.pid" 'start should wait rather than touch a locked pidfile'

  # Killing the owner alone: the waiting start has to notice and take the lock
  # over by itself, the way it would after a hook was killed mid-turn.
  kill "$owner" 2>/dev/null
  wait
  assert_file "$SESSIONS/s1.pid" 'start should take over the lock of a process that is gone'
  assert_alive "$(field "$SESSIONS/s1.pid" HOLDER_PID)" 'the holder should be running'
}

test_start_gives_up_on_a_lock_it_cannot_take() {
  local owner
  owner="$(hold_lock s1)"
  STRAYS+=("$owner")

  wg start "$(turn s1 p1)"
  assert_no_file "$SESSIONS/s1.pid" 'start should not touch a pidfile it never locked'
  assert_log 'the lock stayed taken' 'giving up should leave a trace'
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

test_starts_racing_each_other_produce_one_holder() {
  local started
  wg start "$(turn s1 p1)" &
  wg start "$(turn s1 p2)" &
  wg start "$(turn s1 p3)" &
  wait

  started="$(grep -c 'started holder' "$WAKEGUARD_LOG")"
  assert_eq "$started" 1 'three starts at once should agree on one holder'
  assert_alive "$(field "$SESSIONS/s1.pid" HOLDER_PID)" 'the holder should be running'
}

test_a_stop_racing_the_next_start_leaves_a_live_holder() {
  local pid
  wg start "$(turn s1 p1)"
  pid="$(field "$SESSIONS/s1.pid" HOLDER_PID)"

  wg stop "$(turn s1 p1)" &
  wg start "$(turn s1 p2)" &
  wait

  assert_file "$SESSIONS/s1.pid" 'the second turn should end up with a pidfile'
  assert_alive "$(field "$SESSIONS/s1.pid" HOLDER_PID)" 'the second turn should end up suppressing sleep'
  assert_eq "$(field "$SESSIONS/s1.pid" PROMPT_ID)" p2 'the pidfile should belong to the second turn'
  [ "$(field "$SESSIONS/s1.pid" HOLDER_PID)" = "$pid" ] || assert_dead "$pid" 'a replaced holder should not be left running'
}

# --- reap ---------------------------------------------------------------------

test_reap_skips_a_locked_pidfile() {
  local pid owner
  wg start "$(turn s1 p1)"
  pid="$(field "$SESSIONS/s1.pid" HOLDER_PID)"
  backdate_pidfile "$SESSIONS/s1.pid" 90000
  owner="$(hold_lock s1)"
  STRAYS+=("$owner")

  wg reap
  assert_alive "$pid" 'reap should leave a pidfile another wakeguard is holding'
  assert_file "$SESSIONS/s1.pid" 'reap should leave the pidfile it skipped'

  kill "$owner" 2>/dev/null
  rm -rf "$LOCKS/s1.lock"
  wg reap
  assert_dead "$pid" 'reap should release the holder once the lock is free'
}

test_reap_releases_a_holder_past_the_deadline() {
  local pid
  wg start "$(turn s1 p1)"
  pid="$(field "$SESSIONS/s1.pid" HOLDER_PID)"
  backdate_pidfile "$SESSIONS/s1.pid" 90000

  wg reap
  assert_dead "$pid" 'a holder past WAKEGUARD_MAX_HOURS should be reaped'
  assert_no_file "$SESSIONS/s1.pid" 'the pidfile should be gone after reap'
}

test_reap_judges_every_pidfile_of_a_walk_on_its_own() {
  local expired healthy locked owner
  wg start "$(turn s1 p1)"
  wg start "$(turn s2 p1)"
  wg start "$(turn s3 p1)"
  expired="$(field "$SESSIONS/s1.pid" HOLDER_PID)"
  healthy="$(field "$SESSIONS/s2.pid" HOLDER_PID)"
  locked="$(field "$SESSIONS/s3.pid" HOLDER_PID)"
  backdate_pidfile "$SESSIONS/s1.pid" 90000
  backdate_pidfile "$SESSIONS/s3.pid" 90000
  owner="$(hold_lock s3)"
  STRAYS+=("$owner")

  wg reap
  assert_dead "$expired" 'the holder past its deadline should be released'
  assert_alive "$healthy" 'a holder still inside its deadline should be left alone'
  assert_alive "$locked" 'a pidfile under somebody else lock should be skipped'
  assert_no_file "$SESSIONS/s1.pid" 'the released pidfile should be gone'
  assert_file "$SESSIONS/s2.pid" 'the healthy pidfile should stay'
  assert_file "$SESSIONS/s3.pid" 'the skipped pidfile should stay'
  assert_no_file "$LOCKS/s1.lock" 'reap should hand back every lock it took'
  assert_no_file "$LOCKS/s2.lock" 'reap should hand back every lock it took'
}

test_reap_removes_a_lock_nobody_holds() {
  local lock="$LOCKS/s1.lock"
  mkdir -p "$lock"
  printf '%s %s\n' "$(dead_pid)" "$(date '+%s')" >"$lock/owner"

  wg reap
  assert_no_file "$lock" 'reap should clear out an abandoned lock'
}

test_a_second_reap_does_nothing_while_the_first_runs() {
  local owner
  owner="$(hold_lock 'reap+all')"
  STRAYS+=("$owner")

  wg reap
  assert_log 'another reap is already running' 'the second reap should stand down'
}

test_a_reap_lock_nobody_signed_does_not_wedge_reap() {
  local pid
  mkdir -p "$LOCKS/reap+all.lock"
  # GNU touch is the one that reads a relative -d, BSD touch the one with -A.
  touch -d '3 hours ago' "$LOCKS/reap+all.lock" 2>/dev/null ||
    touch -A -030000 "$LOCKS/reap+all.lock"
  wg start "$(turn s1 p1)"
  pid="$(field "$SESSIONS/s1.pid" HOLDER_PID)"
  backdate_pidfile "$SESSIONS/s1.pid" 90000

  wg reap
  assert_dead "$pid" 'reap should take over a lock left without an owner and carry on'
}

# --- session end --------------------------------------------------------------

test_end_releases_the_turn_holder_and_every_subagent_holder() {
  local turn_pid agent_pid
  wg start "$(turn s1 p1)"
  wg agent-start '{"session_id":"s1","agent_id":"a1"}'
  turn_pid="$(field "$SESSIONS/s1.pid" HOLDER_PID)"
  agent_pid="$(field "$SESSIONS/s1.a1.pid" HOLDER_PID)"

  wg end '{"session_id":"s1"}'
  assert_log 'handed over to pid=' 'end should not do the work in the hook itself'
  wait_gone "$SESSIONS/s1.pid"
  wait_gone "$SESSIONS/s1.a1.pid"

  assert_dead "$turn_pid" 'end should release the turn holder'
  assert_dead "$agent_pid" 'end should release the subagent holder'
  assert_no_file "$SESSIONS/s1.pid" 'end should drop the turn pidfile'
  assert_no_file "$SESSIONS/s1.a1.pid" 'end should drop the subagent pidfile'
}

test_stop_leaves_a_pid_that_belongs_to_something_else() {
  local pid
  wg start "$(turn s1 p1)"
  pid="$(field "$SESSIONS/s1.pid" HOLDER_PID)"
  sed 's/^HOLDER_KIND=.*/HOLDER_KIND=not-a-real-command/' "$SESSIONS/s1.pid" >"$SESSIONS/s1.pid.x"
  mv "$SESSIONS/s1.pid.x" "$SESSIONS/s1.pid"

  wg stop "$(turn s1 p1)"
  assert_alive "$pid" 'a recycled pid should never get an unrelated process killed'
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
