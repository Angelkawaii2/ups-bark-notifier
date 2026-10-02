#!/bin/bash
set -euo pipefail

repo_dir=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
test_dir=$(mktemp -d)
trap 'rm -rf -- "$test_dir"' EXIT

mkdir "$test_dir/state"
cat > "$test_dir/bark-stub" <<'EOF'
#!/bin/sh
printf '%s\n' "$1" >> "$TEST_BARK_LOG"
EOF
chmod 0755 "$test_dir/bark-stub"

export NUT_UPSSCHED_RUNDIR="$test_dir/state"
export NUT_UPSSCHED_CONFIG="$repo_dir/upssched.conf.example"
export NUT_BARK_CMD="$test_dir/bark-stub"
export NUT_LOGGER_CMD=/usr/bin/true
export TEST_BARK_LOG="$test_dir/bark-events"

run_event() {
  "$repo_dir/nut-upssched-cmd.sh" "$1"
}

delay=$(awk '$1 == "AT" && $2 == "COMMBAD" && $4 == "START-TIMER" &&
  $5 == "commbad-alert" { print $6; exit }' "$NUT_UPSSCHED_CONFIG")
[[ "$delay" == 900 ]] || { echo "Expected a 900-second timer" >&2; exit 1; }

# Recovery before the timer expires must produce no Bark event.
run_event commbad-start
run_event commbad-alert
run_event commok
[[ ! -s "$TEST_BARK_LOG" ]] || { echo "Short flap sent Bark" >&2; exit 1; }

# A timer left over from the previous failure must not alert during a new one.
run_event commbad-start
run_event commbad-alert
[[ ! -s "$TEST_BARK_LOG" ]] || { echo "Stale timer sent Bark" >&2; exit 1; }

# Repeated COMMBAD must preserve the original start time.
now=$(awk '{ print int($1) }' /proc/uptime)
(( now > delay )) || { echo "Host uptime is too short for this check" >&2; exit 1; }
started=$(( now - delay - 1 ))
printf '%s\n' "$started" > "$NUT_UPSSCHED_RUNDIR/commbad-active"
run_event commbad-start
[[ $(< "$NUT_UPSSCHED_RUNDIR/commbad-active") == "$started" ]] || {
  echo "Repeated COMMBAD reset the clock" >&2
  exit 1
}

# A persistent failure alerts once; recovery then alerts once.
run_event commbad-alert
run_event commbad-alert
run_event commok
[[ $(cat "$TEST_BARK_LOG") == $'COMMBAD\nCOMMOK' ]] || {
  echo "Persistent failure did not produce exactly COMMBAD then COMMOK" >&2
  exit 1
}

echo "communication debounce checks passed"
