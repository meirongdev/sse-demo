# shellcheck shell=bash
# Mutual exclusion for everything that touches the shared container names and the shared 4 vCPU
# under test. Sourced by run.sh and profile.sh.
#
# Why a shared file and not two copies: every expensive harness bug in this project (缺陷 5, 缺陷 6)
# came from one rule being written twice and drifting. The lock rule is no less load-bearing than the
# sample-selection rule, and the two copies did in fact drift — profile.sh kept a shorter message.
#
# Why a separate release function: this is the fix for 缺陷 7. The release used to be the first line of
# cleanup(), and cleanup() is ALSO called directly before the run starts to sweep leftover containers.
# So the lock was freed about twenty lines after it was taken, and the ramp, the 90-second hold and
# the whole sampling window ran unlocked — the guard existed only during container startup, which is
# not when two runs can step on each other. Release now lives in a function that nothing but the EXIT
# trap calls.
#
# The lock is an owner-stamped directory. mkdir is atomic; the pid inside is for the message printed
# when it is already held, so "someone else is running" names a process you can go look at instead of
# a bare suggestion to rmdir.

LOCK="${LOCK:-/tmp/ssebench.lock}"

# Resolved inside each function instead of captured once at source time. `VAR=x . file` is a natural
# thing to write, and bash reverts that assignment when the source returns — the functions then read
# an empty $LOCK and announce "another bench run holds  — refusing to start" with no path in the
# message. Measured, not hypothetical: that is what the first version of this file did in testing.
bench_lock_path() { printf '%s' "${LOCK:-/tmp/ssebench.lock}"; }

bench_lock_acquire() {
  local path owner
  path="$(bench_lock_path)"
  if ! mkdir "$path" 2>/dev/null; then
    owner="$(cat "$path/pid" 2>/dev/null || true)"
    if [ -n "$owner" ] && ! kill -0 "$owner" 2>/dev/null; then
      # A run that was SIGKILLed leaves this behind; its pid can be reused, so it is reported, never
      # stolen. Deleting someone else's live lock is the exact failure this file exists to prevent.
      echo "$path looks stale: pid $owner is not alive — confirm nothing is running, then rmdir it" >&2
    else
      echo "another bench run (pid ${owner:-unknown}) holds $path — refusing to start" >&2
    fi
    return 3
  fi
  bench_lock_owner=$$
  printf '%s\n' "$$" >"$path/pid"
}

# Called from the EXIT trap only, and it frees the lock only if this process still owns it.
bench_lock_release() {
  local path
  path="$(bench_lock_path)"
  [ "${bench_lock_owner:-}" = "$$" ] || return 0
  if [ "$(cat "$path/pid" 2>/dev/null || true)" != "$$" ]; then
    echo "warning: $path is no longer stamped with pid $$; leaving it alone" >&2
    return 0
  fi
  rm -f "$path/pid"
  rmdir "$path" 2>/dev/null || true
  return 0
}
