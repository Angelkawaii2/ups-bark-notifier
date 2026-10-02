#!/bin/bash
set -u
umask 077

PATH=/usr/sbin:/usr/bin:/sbin:/bin
RUNDIR=${NUT_UPSSCHED_RUNDIR:-/run/nut-upssched}
UPSSCHED_CONFIG=${NUT_UPSSCHED_CONFIG:-/etc/nut/upssched.conf}
BARK_CMD=${NUT_BARK_CMD:-/usr/local/sbin/nut-bark}
LOGGER_CMD=${NUT_LOGGER_CMD:-/usr/bin/logger}
cmd=${1:-}
ups=${UPSNAME:-ups}
msg=${NOTIFYMSG:-}

log() {
  "$LOGGER_CMD" -t nut-monitor -- "$*"
}

uptime_seconds() {
  /usr/bin/awk '{ print int($1) }' /proc/uptime
}

commbad_delay_seconds() {
  /usr/bin/awk '$1 == "AT" && $2 == "COMMBAD" && $3 == "*" &&
    $4 == "START-TIMER" && $5 == "commbad-alert" { print $6; exit }' \
    "$UPSSCHED_CONFIG"
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
      "$BARK_CMD" ONBATT
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
    "$BARK_CMD" LOWBATT
    ;;

  fsd)
    log "event=FSD ups=$ups message='$msg'"
    "$BARK_CMD" FSD
    ;;

  commbad-start)
    exec 9>"$RUNDIR/event-state.lock"
    /usr/bin/flock -x 9
    now=$(uptime_seconds)
    started=0
    if [[ -r "$RUNDIR/commbad-active" ]]; then
      started=$(< "$RUNDIR/commbad-active")
    fi
    if [[ "$started" =~ ^[0-9]+$ ]] && (( started > 0 && started <= now )); then
      log "event=COMMBAD ups=$ups duplicate_event original_start=${started}s"
    else
      printf '%s\n' "$now" > "$RUNDIR/commbad-active"
      /bin/rm -f "$RUNDIR/commbad-notified"
      log "event=COMMBAD ups=$ups debounce_timer_started start=${now}s"
    fi
    /usr/bin/flock -u 9
    ;;

  commbad-alert)
    exec 9>"$RUNDIR/event-state.lock"
    /usr/bin/flock -x 9
    if [[ ! -r "$RUNDIR/commbad-active" ]]; then
      log "event=COMMBAD ups=$ups alert_suppressed reason=already_recovered"
      exit 0
    fi
    if [[ -e "$RUNDIR/commbad-notified" ]]; then
      log "event=COMMBAD ups=$ups alert_suppressed reason=already_notified"
      exit 0
    fi
    started=$(< "$RUNDIR/commbad-active")
    now=$(uptime_seconds)
    delay=$(commbad_delay_seconds 2>/dev/null) || delay=''
    if ! [[ "$started" =~ ^[0-9]+$ && "$delay" =~ ^[1-9][0-9]*$ ]] ||
       (( started > now )); then
      log "event=COMMBAD ups=$ups alert_suppressed reason=invalid_debounce_state"
      exit 0
    fi
    elapsed=$(( now - started ))
    if (( elapsed < delay )); then
      log "event=COMMBAD ups=$ups alert_suppressed reason=timer_from_previous_outage elapsed=${elapsed}s threshold=${delay}s"
      exit 0
    fi
    : > "$RUNDIR/commbad-notified"
    log "event=COMMBAD ups=$ups persisted_past_debounce elapsed=${elapsed}s threshold=${delay}s"
    "$BARK_CMD" COMMBAD
    /usr/bin/flock -u 9
    ;;

  commok)
    send=0
    exec 9>"$RUNDIR/event-state.lock"
    /usr/bin/flock -x 9
    if [[ -e "$RUNDIR/commbad-active" && -e "$RUNDIR/commbad-notified" ]]; then
      send=1
    fi
    /bin/rm -f "$RUNDIR/commbad-active" "$RUNDIR/commbad-notified"
    /usr/bin/flock -u 9
    log "event=COMMOK ups=$ups message='$msg'"
    if (( send )); then
      "$BARK_CMD" COMMOK
    else
      log "event=COMMOK ups=$ups unalerted_communication_flap_suppressed"
    fi
    ;;

  *)
    log "unrecognized_upssched_command='$cmd' ups=$ups"
    ;;
esac

exit 0
