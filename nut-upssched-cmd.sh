#!/bin/bash
set -u
umask 077

PATH=/usr/sbin:/usr/bin:/sbin:/bin
RUNDIR=/run/nut-upssched
cmd=${1:-}
ups=${UPSNAME:-ups}
msg=${NOTIFYMSG:-}

log() {
  /usr/bin/logger -t nut-monitor -- "$*"
}

case "$cmd" in
  onbatt-start)
    if ! /usr/bin/sudo -n /usr/local/sbin/nut-battery-check --event onbatt; then
      log "event=ONBATT ups=$ups battery_state_hook_failed"
    else
      log "event=ONBATT ups=$ups outage_state_recorded timer_armed message='$msg'"
    fi
    ;;

  onbatt-notify)
    exec 9>"$RUNDIR/event-state.lock"
    /usr/bin/flock -x 9
    if [[ -e "$RUNDIR/onbatt-notified" ]]; then
      /usr/bin/flock -u 9
      log "event=ONBATT ups=$ups duplicate_notification_suppressed"
    else
      : > "$RUNDIR/onbatt-notified"
      /usr/bin/flock -u 9
      /usr/local/sbin/nut-bark ONBATT
    fi
    ;;

  online)
    if ! /usr/bin/sudo -n /usr/local/sbin/nut-battery-check --event online; then
      log "event=ONLINE ups=$ups battery_state_hook_failed"
    fi
    exec 9>"$RUNDIR/event-state.lock"
    /usr/bin/flock -x 9
    /bin/rm -f "$RUNDIR/onbatt-notified"
    /usr/bin/flock -u 9
    log "event=ONLINE ups=$ups timer_cancelled message='$msg'"
    ;;

  lowbatt)
    log "event=LOWBATT ups=$ups message='$msg'"
    /usr/local/sbin/nut-bark LOWBATT
    ;;

  fsd)
    log "event=FSD ups=$ups message='$msg'"
    /usr/local/sbin/nut-bark FSD
    ;;

  commbad-start)
    log "event=COMMBAD ups=$ups debounce_timer_started"
    ;;

  commbad-alert)
    exec 9>"$RUNDIR/event-state.lock"
    /usr/bin/flock -x 9
    : > "$RUNDIR/commbad-notified"
    log "event=COMMBAD ups=$ups persisted_past_debounce"
    /usr/local/sbin/nut-bark COMMBAD
    /usr/bin/flock -u 9
    ;;

  commok)
    send=0
    exec 9>"$RUNDIR/event-state.lock"
    /usr/bin/flock -x 9
    if [[ -e "$RUNDIR/commbad-notified" ]]; then
      /bin/rm -f "$RUNDIR/commbad-notified"
      send=1
    fi
    /usr/bin/flock -u 9
    log "event=COMMOK ups=$ups message='$msg'"
    if (( send )); then
      /usr/local/sbin/nut-bark COMMOK
    else
      log "event=COMMOK ups=$ups short_communication_flap_suppressed"
    fi
    ;;

  *)
    log "unrecognized_upssched_command='$cmd' ups=$ups"
    ;;
esac

exit 0
