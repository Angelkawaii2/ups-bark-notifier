#!/bin/bash
set -o pipefail

PATH=/usr/bin:/bin
event=${1:-TEST}
detail=${2:-}
script_dir=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
default_config=/etc/nut/bark.conf
if [[ ! -r "$default_config" && -r "$script_dir/bark.conf" ]]; then
  default_config="$script_dir/bark.conf"
fi
config=${BARK_CONFIG_FILE:-$default_config}
policy=${UPS_POLICY_FILE:-/etc/nut/ups-policy.conf}
if [[ -r "$policy" ]]; then
  . "$policy"
fi
ups_name=${UPS_NAME:-ups}
ups_target=${UPS_TARGET:-ups@localhost}

case "$event" in
  ONLINE)       title='UPS 市电恢复'; level='active' ;;
  ONBATT)       title='UPS 市电中断'; level='timeSensitive' ;;
  LOWBATT)      title='UPS 电量低'; level='timeSensitive' ;;
  FSD)          title='NUT 已进入 FSD'; level='timeSensitive' ;;
  COMMBAD)      title='UPS 通讯异常'; level='timeSensitive' ;;
  COMMOK)       title='UPS 通讯恢复'; level='active' ;;
  PRE_SHUTDOWN) title='UPS 即将关闭服务器'; level='timeSensitive' ;;
  BATTERY_LEVEL) title='UPS 电池电量变化'; level='active' ;;
  BATTERY_FULL) title='UPS 电池已充满'; level='active' ;;
  TEST)         title='UPS 监控测试'; level='active' ;;
  *)            title="UPS 事件: $event"; level='active' ;;
esac

log() {
  /usr/bin/logger -t nut-bark -- "$*"
}

data=$(/usr/bin/timeout -k 1s 2s /usr/bin/upsc "$ups_target" 2>/dev/null) || data=''
getvar() {
  printf '%s\n' "$data" |
    /usr/bin/awk -F ': ' -v key="$1" '$1 == key { print $2; exit }'
}

status=$(getvar ups.status)
charge=$(getvar battery.charge)
runtime=$(getvar battery.runtime)
load=$(getvar ups.load)
host=$(/bin/hostname -s 2>/dev/null || /bin/hostname)
now=$(/usr/bin/date '+%F %T %Z')

[[ -n "$status" ]] || status='未知'
if [[ -n "$charge" ]]; then
  charge_text="$charge"
else
  charge_text='未知'
fi
if [[ -n "$load" ]]; then
  load_text="$load"
else
  load_text='未知'
fi
if [[ "$runtime" =~ ^[0-9]+$ ]]; then
  runtime_text="$(( (runtime + 30) / 60 )) 分钟"
else
  runtime_text='未知'
fi

body=$(printf '主机: %s\nUPS: %s\n状态: %s\n电量: %s%%\n预计续航: %s\n负载: %s%%\n事件: %s\n时间: %s' \
  "$host" "$ups_name" "$status" "$charge_text" "$runtime_text" "$load_text" "$event" "$now")
if [[ -n "$detail" ]]; then
  body+=$(printf '\n详情: %s' "$detail")
fi

if [[ ! -r "$config" ]]; then
  log "send_failed event=$event reason=config_unreadable"
  exit 0
fi
# This root-owned config has shell assignments only and mode 0640.
. "$config"

if [[ -z "${BARK_URL:-}" || -z "${BARK_KEY:-}" ]]; then
  log "send_failed event=$event reason=config_incomplete"
  exit 0
fi
group=${BARK_GROUP:-UPS}

if BARK_KEY="$BARK_KEY" BARK_TITLE="$title" BARK_BODY="$body" \
   BARK_GROUP="$group" BARK_LEVEL="$level" \
   /usr/bin/python3 -c '
import json, os, sys
json.dump({
    "device_key": os.environ["BARK_KEY"],
    "title": os.environ["BARK_TITLE"],
    "body": os.environ["BARK_BODY"],
    "group": os.environ["BARK_GROUP"],
    "level": os.environ["BARK_LEVEL"],
}, sys.stdout, ensure_ascii=False)
' |
  /usr/bin/timeout -k 1s 8s /usr/bin/curl \
    --proto '=https' --request POST \
    --connect-timeout 2 --max-time 6 \
    --silent --show-error --fail --output /dev/null \
    --header 'Content-Type: application/json; charset=utf-8' \
    --data-binary @- "$BARK_URL" 2>/dev/null
then
  log "sent event=$event host=$host ups=$ups_name status='$status' charge='$charge' runtime_seconds='$runtime' load='$load'"
else
  log "send_failed event=$event host=$host ups=$ups_name status='$status' charge='$charge' runtime_seconds='$runtime' load='$load'"
fi

# Bark/network failures are logged but never propagated to NUT or shutdown code.
exit 0
