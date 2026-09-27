#!/bin/bash
set -u
umask 077

PATH=/usr/sbin:/usr/bin:/sbin:/bin
POLICY=${NUT_POLICY_FILE:-/etc/nut/ups-policy.conf}
STATE_DIR=${SHUTDOWN_STATE_DIR:-/var/lib/nut-shutdown-request}
STATE_FILE="$STATE_DIR/started"
LOCK_FILE=/run/lock/nut-shutdown-request.lock
UPS_NAME=${UPS_NAME:-ups}
UPS_TARGET=${UPS_TARGET:-ups@localhost}

log() {
  /usr/bin/logger -t nut-monitor -- "$*"
}

if (( EUID != 0 )); then
  log "error=must_run_as_root"
  exit 1
fi

if [[ ! -r "$POLICY" ]]; then
  log "error=policy_unreadable path=$POLICY"
  exit 1
fi
. "$POLICY"
UPS_NAME=${UPS_NAME:-ups}
UPS_TARGET=${UPS_TARGET:-ups@localhost}
SHUTDOWN_DRY_RUN=${SHUTDOWN_DRY_RUN:-0}

if ! [[ "${BATTERY_SHUTDOWN_PERCENT:-}" =~ ^[0-9]{1,2}$ ]] ||
   (( 10#${BATTERY_SHUTDOWN_PERCENT:-0} > 99 )) ||
   ! [[ "${MAX_ON_BATTERY_TIME:-}" =~ ^[1-9][0-9]*$ ]]; then
  log "error=invalid_policy battery_shutdown='${BATTERY_SHUTDOWN_PERCENT:-unset}' max_on_battery_time='${MAX_ON_BATTERY_TIME:-unset}'"
  exit 1
fi
BATTERY_SHUTDOWN_PERCENT=$((10#$BATTERY_SHUTDOWN_PERCENT))

action=${1:-}
case "$action" in
  battery-threshold|max-time|reset) ;;
  *) log "error=invalid_action action='$action'"; exit 2 ;;
esac

/usr/bin/install -d -o root -g root -m 0700 "$STATE_DIR"
exec 9>"$LOCK_FILE"
/usr/bin/flock -x 9

data=$(/usr/bin/timeout -k 1s 3s /usr/bin/upsc "$UPS_TARGET" 2>/dev/null) || {
  log "action=$action ups=$UPS_NAME upsc_failed; no shutdown action"
  exit 0
}
getvar() {
  printf '%s\n' "$data" |
    /usr/bin/awk -F ': ' -v key="$1" '$1 == key { print $2; exit }'
}
status=$(getvar ups.status)
charge=$(getvar battery.charge)
runtime=$(getvar battery.runtime)
now=$(/usr/bin/date +%s)
case " $status " in *" OB "*) is_ob=1 ;; *) is_ob=0 ;; esac
case " $status " in *" OL "*) is_ol=1 ;; *) is_ol=0 ;; esac
case " $status " in *" FSD "*) is_fsd=1 ;; *) is_fsd=0 ;; esac

if [[ "$action" == reset ]]; then
  if (( is_ol && ! is_fsd )); then
    if [[ -e "$STATE_FILE" ]]; then
      /bin/rm -f "$STATE_FILE"
      log "event=ONLINE ups=$UPS_NAME shutdown_guard_reset status='$status'"
    fi
  else
    log "event=ONLINE ups=$UPS_NAME shutdown_guard_not_reset status='$status'"
  fi
  exit 0
fi

if (( is_fsd )); then
  log "event=FSD ups=$UPS_NAME action=$action already_in_progress status='$status'"
  exit 0
fi
if (( ! is_ob )); then
  log "action=$action ups=$UPS_NAME rejected status='$status' reason=not_on_battery"
  exit 0
fi
if ! [[ "$charge" =~ ^[0-9]+([.][0-9]+)?$ ]]; then
  log "action=$action ups=$UPS_NAME rejected status='$status' reason=battery_charge_unavailable"
  exit 0
fi

detail=''
case "$action" in
  battery-threshold)
    if ! /usr/bin/awk -v charge="$charge" -v limit="$BATTERY_SHUTDOWN_PERCENT" \
      'BEGIN { exit !(charge <= limit) }'; then
      log "action=$action ups=$UPS_NAME rejected charge=${charge}% threshold=${BATTERY_SHUTDOWN_PERCENT}%"
      exit 0
    fi
    detail="电池剩余 ${charge}%，关机阈值 ${BATTERY_SHUTDOWN_PERCENT}%"
    ;;
  max-time)
    on_battery_since=0
    if [[ -r /var/lib/nut-battery-monitor/state ]]; then
      while IFS='=' read -r key value; do
        if [[ "$key" == on_battery_since && "$value" =~ ^[0-9]+$ ]]; then
          on_battery_since=$value
          break
        fi
      done < /var/lib/nut-battery-monitor/state
    fi
    elapsed=0
    if (( on_battery_since > 0 )); then
      elapsed=$((now - on_battery_since))
    fi
    if (( on_battery_since == 0 || elapsed < MAX_ON_BATTERY_TIME )); then
      log "action=$action ups=$UPS_NAME rejected elapsed=${elapsed}s threshold=${MAX_ON_BATTERY_TIME}s reason=timeout_not_reached"
      exit 0
    fi
    elapsed_minutes=$(( (elapsed + 30) / 60 ))
    runtime_text=未知
    if [[ "$runtime" =~ ^[0-9]+$ ]]; then
      runtime_text="$(( (runtime + 30) / 60 )) 分钟"
    fi
    detail="已连续停电约 ${elapsed_minutes} 分钟，当前电量 ${charge}%，预计续航 ${runtime_text}"
    ;;
esac

if [[ "$SHUTDOWN_DRY_RUN" == 1 ]]; then
  log "DRY_RUN=1 shutdown_candidate=$action ups=$UPS_NAME status='$status' charge=${charge}% detail='$detail'"
  exit 0
fi

if ! /bin/systemctl is-active --quiet nut-monitor.service; then
  log "error=shutdown_request_failed action=$action ups=$UPS_NAME reason=nut_monitor_inactive"
  exit 1
fi

if [[ -e "$STATE_FILE" ]]; then
  log "shutdown_duplicate_suppressed action=$action ups=$UPS_NAME status='$status'"
  exit 0
fi
tmp=$(/usr/bin/mktemp "$STATE_DIR/.started.XXXXXX") || {
  log "error=shutdown_state_create_failed action=$action ups=$UPS_NAME"
  exit 1
}
{
  printf 'action=%s\n' "$action"
  printf 'started_at=%s\n' "$now"
  printf 'charge=%s\n' "$charge"
  printf 'ups_status=%s\n' "$status"
} > "$tmp"
/bin/chmod 0600 "$tmp"
/bin/mv -f "$tmp" "$STATE_FILE"

# Bark has bounded network timeouts. Its failure is logged by nut-bark and
# cannot prevent the subsequent NUT FSD request.
/usr/bin/timeout -k 1s 9s /usr/local/sbin/nut-bark PRE_SHUTDOWN "$detail" || true

log "event=FSD ups=$UPS_NAME reason=$action charge=${charge}% detail='$detail' requesting=upsmon-fsd"
if /usr/sbin/upsmon -c fsd; then
  log "event=FSD ups=$UPS_NAME reason=$action result=request_accepted"
  exit 0
fi

/bin/rm -f "$STATE_FILE"
log "error=shutdown_request_failed action=$action ups=$UPS_NAME reason=upsmon_fsd_failed"
exit 1
