#!/bin/bash
set -u

PATH=/usr/sbin:/usr/bin:/sbin:/bin
POLICY=${NUT_POLICY_FILE:-/etc/nut/ups-policy.conf}
LOCK_FILE=/run/lock/nut-battery-monitor.lock
UPS_NAME=${UPS_NAME:-ups}
UPS_TARGET=${UPS_TARGET:-ups@localhost}
SHUTDOWN_HELPER=${NUT_SHUTDOWN_HELPER:-/usr/local/sbin/nut-shutdown-request}

log() {
  /usr/bin/logger -t nut-battery-check -- "$*"
}

if (( EUID != 0 )); then
  log "error=must_run_as_root"
  exit 1
fi

if [[ ! -r "$POLICY" ]]; then
  log "error=policy_unreadable path=$POLICY"
  exit 1
fi
# This file is root-owned and mode 0640; it contains only policy values.
. "$POLICY"

UPS_NAME=${UPS_NAME:-ups}
UPS_TARGET=${UPS_TARGET:-ups@localhost}
STATE_DIR=${BATTERY_STATE_DIR:-/var/lib/nut-battery-monitor}
STATE_FILE="$STATE_DIR/state"
BATTERY_NOTIFY_STEP_PERCENT=${BATTERY_NOTIFY_STEP_PERCENT:-10}
BATTERY_FULL_PERCENT=${BATTERY_FULL_PERCENT:-100}
MAX_ON_BATTERY_TIME=${MAX_ON_BATTERY_TIME:-7200}
SHUTDOWN_DRY_RUN=${SHUTDOWN_DRY_RUN:-0}

if ! [[ "${BATTERY_SHUTDOWN_PERCENT:-}" =~ ^[0-9]{1,2}$ ]] ||
   (( 10#${BATTERY_SHUTDOWN_PERCENT:-0} > 99 )) ||
   ! [[ "$BATTERY_NOTIFY_STEP_PERCENT" =~ ^[1-9][0-9]*$ ]] ||
   ! [[ "$BATTERY_FULL_PERCENT" =~ ^[1-9][0-9]?$|^100$ ]] ||
   ! [[ "$MAX_ON_BATTERY_TIME" =~ ^[1-9][0-9]*$ ]]; then
  log "error=invalid_policy battery_shutdown='${BATTERY_SHUTDOWN_PERCENT:-unset}' max_on_battery_time='$MAX_ON_BATTERY_TIME' notify_step='$BATTERY_NOTIFY_STEP_PERCENT' full_percent='$BATTERY_FULL_PERCENT'"
  exit 1
fi
BATTERY_SHUTDOWN_PERCENT=$((10#$BATTERY_SHUTDOWN_PERCENT))

mode=poll
if [[ "${1:-}" == "--event" ]]; then
  mode=${2:-}
  case "$mode" in
    onbatt|online) ;;
    *) log "error=invalid_event value='$mode'"; exit 2 ;;
  esac
elif [[ $# -gt 0 ]]; then
  log "error=invalid_arguments"
  exit 2
fi

/usr/bin/install -d -o root -g root -m 0700 "$STATE_DIR"
exec 9>"$LOCK_FILE"
/usr/bin/flock -x 9

data=$(/usr/bin/timeout -k 1s 3s /usr/bin/upsc "$UPS_TARGET" 2>/dev/null) || {
  log "upsc_failed ups=$UPS_NAME target=$UPS_TARGET mode=$mode; no custom threshold action"
  exit 0
}

getvar() {
  printf '%s\n' "$data" |
    /usr/bin/awk -F ': ' -v key="$1" '$1 == key { print $2; exit }'
}

status=$(getvar ups.status)
charge=$(getvar battery.charge)
runtime=$(getvar battery.runtime)
load=$(getvar ups.load)
[[ -n "$status" ]] || status=UNKNOWN

if ! [[ "$charge" =~ ^[0-9]+([.][0-9]+)?$ ]]; then
  log "ups=$UPS_NAME status='$status' battery.charge='$charge' unavailable mode=$mode"
  exit 0
fi

charge_int=$(/usr/bin/awk -v charge="$charge" 'BEGIN { printf "%d", int(charge) }')
is_ob=0
case " $status " in *" OB "*) is_ob=1 ;; esac
is_ol=0
case " $status " in *" OL "*) is_ol=1 ;; esac

phase=idle
next_notify_below=-1
full_alert_pending=0
on_battery_since=0
if [[ -r "$STATE_FILE" ]]; then
  while IFS='=' read -r key value; do
    case "$key" in
      phase) phase=$value ;;
      next_notify_below) next_notify_below=$value ;;
      full_alert_pending) full_alert_pending=$value ;;
      on_battery_since) on_battery_since=$value ;;
    esac
  done < "$STATE_FILE"
fi

if ! [[ "$next_notify_below" =~ ^-?[0-9]+$ ]] ||
   ! [[ "$full_alert_pending" =~ ^[01]$ ]] ||
   ! [[ "$phase" =~ ^(idle|on_battery|charging)$ ]] ||
   ! [[ "$on_battery_since" =~ ^[0-9]+$ ]]; then
  log "warning=state_invalid path=$STATE_FILE; resetting_state"
  phase=idle
  next_notify_below=-1
  full_alert_pending=0
  on_battery_since=0
fi

due_levels=()
send_full=0
send_online=0
changed=0
reset_shutdown_guard=0
now_epoch=$(/usr/bin/date +%s)

begin_outage() {
  phase=on_battery
  next_notify_below=$(( charge_int - BATTERY_NOTIFY_STEP_PERCENT ))
  full_alert_pending=0
  on_battery_since=$now_epoch
  changed=1
  log "event=ONBATT ups=$UPS_NAME status='$status' charge=${charge}% battery.runtime=${runtime:-unknown}s first_level_notice_at_or_below=${next_notify_below}% step=${BATTERY_NOTIFY_STEP_PERCENT}% max_on_battery_time=${MAX_ON_BATTERY_TIME}s"
}

begin_charging() {
  phase=charging
  next_notify_below=-1
  full_alert_pending=1
  on_battery_since=0
  changed=1
  reset_shutdown_guard=1
  send_online=1
  log "event=ONLINE ups=$UPS_NAME status='$status' charge=${charge}% full_alert_pending=1"
}

if (( is_ob )); then
  if [[ "$mode" == online ]]; then
    # Ignore a stale ONLINE callback if the UPS already reports OB again.
    log "stale_event=ONLINE ups=$UPS_NAME current_status='$status'"
  else
    if [[ "$phase" != on_battery ]]; then
      begin_outage
    elif (( on_battery_since == 0 )); then
      on_battery_since=$now_epoch
      changed=1
      log "warning=outage_start_missing ups=$UPS_NAME resetting_continuous_outage_clock"
    fi
    while (( next_notify_below >= 0 && charge_int <= next_notify_below )); do
      due_levels+=("$next_notify_below")
      next_notify_below=$(( next_notify_below - BATTERY_NOTIFY_STEP_PERCENT ))
      changed=1
    done
  fi
elif (( is_ol )); then
  if [[ -e /var/lib/nut-shutdown-request/started ]]; then
    reset_shutdown_guard=1
  fi
  if [[ "$phase" == on_battery ]]; then
    begin_charging
  elif [[ "$mode" == online && "$phase" == idle ]]; then
    # There is no matching outage state, so this is a duplicate/restarted event.
    log "event=ONLINE ups=$UPS_NAME no_unfinished_outage"
  fi

  if [[ "$phase" == charging && "$full_alert_pending" == 1 ]] &&
     /usr/bin/awk -v charge="$charge" -v full="$BATTERY_FULL_PERCENT" \
       'BEGIN { exit !(charge >= full) }'; then
    send_full=1
    full_alert_pending=0
    phase=idle
    changed=1
    log "event=BATTERY_FULL ups=$UPS_NAME status='$status' charge=${charge}% threshold=${BATTERY_FULL_PERCENT}%"
  fi
else
  log "ups=$UPS_NAME status='$status' mode=$mode; waiting_for_OB_or_OL"
fi

save_state() {
  local tmp
  tmp=$(/usr/bin/mktemp "$STATE_DIR/.state.XXXXXX") || return 1
  {
    printf 'phase=%s\n' "$phase"
    printf 'next_notify_below=%s\n' "$next_notify_below"
    printf 'full_alert_pending=%s\n' "$full_alert_pending"
    printf 'on_battery_since=%s\n' "$on_battery_since"
  } > "$tmp"
  /bin/chmod 0600 "$tmp"
  /bin/mv -f "$tmp" "$STATE_FILE"
}

if (( changed )); then
  if ! save_state; then
    log "error=state_write_failed path=$STATE_FILE"
    exit 1
  fi
fi

if (( reset_shutdown_guard )) && [[ -x "$SHUTDOWN_HELPER" ]]; then
  "$SHUTDOWN_HELPER" reset || log "warning=shutdown_guard_reset_failed ups=$UPS_NAME"
fi

log "check ups=$UPS_NAME status='$status' battery.charge=${charge}% battery.runtime=${runtime:-unknown}s ups.load=${load:-unknown}% next_notice_at_or_below=${next_notify_below}% shutdown_threshold=${BATTERY_SHUTDOWN_PERCENT}% max_on_battery_time=${MAX_ON_BATTERY_TIME}s mode=$mode"

# Request the established NUT FSD shutdown path before sending nonessential
# progress notifications. Bark timeouts therefore cannot delay this decision.
shutdown_reason=''
shutdown_detail=''
if (( is_ob )) &&
   /usr/bin/awk -v charge="$charge" -v limit="$BATTERY_SHUTDOWN_PERCENT" \
     'BEGIN { exit !(charge <= limit) }'; then
  shutdown_reason=battery-threshold
  shutdown_detail="charge=${charge}% threshold=${BATTERY_SHUTDOWN_PERCENT}%"
elif (( is_ob && on_battery_since > 0 && now_epoch - on_battery_since >= MAX_ON_BATTERY_TIME )); then
  shutdown_reason=max-time
  shutdown_detail="elapsed=$((now_epoch - on_battery_since))s threshold=${MAX_ON_BATTERY_TIME}s charge=${charge}%"
fi

if [[ -n "$shutdown_reason" ]]; then
  if [[ "$SHUTDOWN_DRY_RUN" == 1 ]]; then
    log "DRY_RUN=1 shutdown_candidate=$shutdown_reason $shutdown_detail"
  elif [[ -x "$SHUTDOWN_HELPER" ]]; then
    /usr/bin/flock -u 9
    "$SHUTDOWN_HELPER" "$shutdown_reason"
    exit $?
  else
    log "error=shutdown_helper_missing path=$SHUTDOWN_HELPER reason=$shutdown_reason $shutdown_detail"
  fi
fi

/usr/bin/flock -u 9

for level in "${due_levels[@]}"; do
  /usr/local/sbin/nut-bark BATTERY_LEVEL \
    "电量已下降到 ${level}%（当前 ${charge}%），本次停电每下降 ${BATTERY_NOTIFY_STEP_PERCENT}% 通知一次"
done

if (( send_online )); then
  /usr/local/sbin/nut-bark ONLINE \
    "市电已恢复，当前电量 ${charge}%"
fi

if (( send_full )); then
  /usr/local/sbin/nut-bark BATTERY_FULL \
    "UPS 电池已充满（${charge}%）"
fi

exit 0
