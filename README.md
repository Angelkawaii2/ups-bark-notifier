# Debian NUT UPS monitor with Bark alerts

This repository contains the host-side scripts and systemd units for a Debian
13 mini PC monitoring a CyberPower UPS over USB with NUT 2.8.1. It sends Bark
notifications for power, battery, and communication events and requests a safe
NUT shutdown when either configured battery condition is met.

The live Bark key and machine-specific NUT credentials are deliberately not in
this repository. See [TLDR.md](TLDR.md) for the short operator guide and
[AGENTS.md](AGENTS.md) for project-specific instructions for coding agents.

## Architecture

```text
CyberPower UPS --USB--> usbhid-ups --> upsd --> upsmon --> upssched
                                                   |          |
                                      systemd timer +--> Bark event scripts
                                                   |
                       charge/time condition --> nut-shutdown-request
                                                   |
                                           upsmon -c fsd
                                                   |
                               NUT SHUTDOWNCMD / POWERDOWNFLAG flow
```

NUT's own `LOWBATT` handling remains enabled as the final safety path. Custom
shutdown requests are idempotent and recheck the live UPS state before asking
`upsmon` to enter FSD. Bark calls use HTTPS POST with JSON and bounded timeouts;
a Bark/network failure must never hold up shutdown.

## Behavior and policy

The deployed policy is in `/etc/nut/ups-policy.conf`; the checked-in template
is [`ups-policy.conf.example`](ups-policy.conf.example). Edit the deployed
file to change these values:

| Setting | Current/default value | Meaning |
| --- | ---: | --- |
| `BATTERY_SHUTDOWN_PERCENT` | `30` | Request NUT FSD at or below this charge while OB. |
| `MAX_ON_BATTERY_TIME` | `7200` seconds | Request NUT FSD after two continuous hours on battery. |
| `BATTERY_NOTIFY_STEP_PERCENT` | `10` | Notify once for each 10-point charge drop during an outage, measured from its first sample. |
| `BATTERY_FULL_PERCENT` | `100` | Send one full-charge notice after mains returns and charge reaches this value. |
| `SHUTDOWN_DRY_RUN` | `0` | Set to `1` only for a controlled dry run; restore `0` afterward. |

`nut-battery-check.timer` checks once per minute. NUT's ONBATT/ONLINE callbacks
also record transitions immediately, so recovery clears the outage clock even
if an outage was shorter than one timer interval. The time condition can be
acted on up to about 60 seconds after its configured limit. There is no
background `sleep` process.

## Files

| File | Installed path / purpose |
| --- | --- |
| `nut-battery-check.sh` | `/usr/local/sbin/nut-battery-check`; one-shot charge/time policy checker. |
| `nut-shutdown-request.sh` | `/usr/local/sbin/nut-shutdown-request`; verifies OB and the reason, serializes requests, then calls `upsmon -c fsd`. |
| `nut-bark.sh` | `/usr/local/sbin/nut-bark`; formats and sends Bark JSON. |
| `nut-upssched-cmd.sh` | `/usr/local/sbin/nut-upssched-cmd`; handles NUT notifications and communication debounce. |
| `bark.conf.example` | Safe template for `/etc/nut/bark.conf`; replace the placeholder outside Git. |
| `ups-policy.conf.example` | Template for `/etc/nut/ups-policy.conf`. |
| `upssched.conf.example` | Template for `/etc/nut/upssched.conf`. |
| `nut-battery-check.service`, `.timer` | One-shot checker and its 60-second timer. |
| `nut-battery-monitor-tmpfiles.conf` | Persistent state directories and permissions. |
| `nut-upssched-tmpfiles.conf` | Private runtime directory for NUT event deduplication. |

## Requirements

- Debian 13, systemd, NUT 2.8.x in standalone mode, and a configured local UPS
  named `ups` readable through `upsc ups@localhost`.
- `curl`, `python3`, `sudo`, `flock`, and the NUT programs `upsc`, `upsmon`, and
  `upssched`.
- A NUT primary monitor account and matching `MONITOR ups@localhost ...
  primary` entry. Keep the password in `/etc/nut/upsd.users` and
  `/etc/nut/upsmon.conf`; never commit those files.

## Install

Run from the repository root. Root privileges are needed for system paths,
systemd, and the NUT FSD helper. Keep existing NUT device settings and the
existing `SHUTDOWNCMD` and `POWERDOWNFLAG` directives.

```sh
sudo apt-get install nut curl python3 sudo

sudo install -o root -g root -m 0755 nut-battery-check.sh /usr/local/sbin/nut-battery-check
sudo install -o root -g root -m 0755 nut-shutdown-request.sh /usr/local/sbin/nut-shutdown-request
sudo install -o root -g root -m 0755 nut-bark.sh /usr/local/sbin/nut-bark
sudo install -o root -g root -m 0755 nut-upssched-cmd.sh /usr/local/sbin/nut-upssched-cmd

sudo install -o root -g nut -m 0640 bark.conf.example /etc/nut/bark.conf
sudoedit /etc/nut/bark.conf
sudo install -o root -g nut -m 0640 ups-policy.conf.example /etc/nut/ups-policy.conf
sudo install -o root -g nut -m 0640 upssched.conf.example /etc/nut/upssched.conf

sudo install -o root -g root -m 0644 nut-battery-check.service /etc/systemd/system/
sudo install -o root -g root -m 0644 nut-battery-check.timer /etc/systemd/system/
sudo install -o root -g root -m 0644 nut-battery-monitor-tmpfiles.conf /etc/tmpfiles.d/nut-battery-monitor.conf
sudo install -o root -g root -m 0644 nut-upssched-tmpfiles.conf /etc/tmpfiles.d/nut-upssched.conf
```

Set the Bark values in `/etc/nut/bark.conf`, with no secrets in command-line
arguments or logs. Keep it `root:nut 0640`; the workspace-only `bark.conf` is
ignored by Git and should remain mode `0600`.

Configure `/etc/nut/upsmon.conf` with the matching primary account, event
command, and flags. Preserve existing `MINSUPPLIES`, `SHUTDOWNCMD`, and
`POWERDOWNFLAG` values:

```conf
MONITOR ups@localhost 1 nutmon <same-password-as-upsd.users> primary
NOTIFYCMD /usr/sbin/upssched
NOTIFYFLAG ONLINE SYSLOG+EXEC
NOTIFYFLAG ONBATT SYSLOG+EXEC
NOTIFYFLAG LOWBATT SYSLOG+EXEC
NOTIFYFLAG FSD SYSLOG+EXEC
NOTIFYFLAG COMMBAD SYSLOG+EXEC
NOTIFYFLAG COMMOK SYSLOG+EXEC
```

In `/etc/nut/upsd.users`, define the matching account:

```conf
[nutmon]
  password = <strong-local-password>
  upsmon primary
```

Use `visudo` to create `/etc/sudoers.d/nut-ups` with only the narrowly scoped
callbacks below; set the file mode to `0440` and validate it with
`visudo -cf`:

```sudoers
nut ALL=(root) NOPASSWD: /usr/local/sbin/nut-battery-check --event onbatt, /usr/local/sbin/nut-battery-check --event online
```

Enable the monitor and checker after the NUT configuration is valid:

```sh
sudo systemd-tmpfiles --create
sudo systemctl daemon-reload
sudo systemctl enable --now nut-monitor.service
sudo systemctl enable --now nut-battery-check.timer
```

`upssched` is invoked by `upsmon` through `NOTIFYCMD`; it does not need a
separate systemd service. The NUT event process runs as `nut`, while the
checker and shutdown helper run as root.

## Logs and operations

```sh
journalctl -u nut-monitor.service -f
journalctl -u nut-battery-check.service -f
journalctl -t nut-monitor -f
journalctl -t nut-battery-check -f
journalctl -t nut-bark -f
systemctl list-timers nut-battery-check.timer
upsc ups@localhost
```

Change thresholds in `/etc/nut/ups-policy.conf`. After changing a value, the
next one-shot checker run reads it; no timer restart is needed.

## Safe verification

- A Bark connectivity check can be sent with
  `/usr/local/sbin/nut-bark TEST`; this sends a real notification.
- For a controlled shutdown-policy dry run, set
  `SHUTDOWN_DRY_RUN=1` in `/etc/nut/ups-policy.conf`, check the
  `nut-battery-check` journal during a safe OB condition, then restore `0`.
- Do not use `upsmon -c fsd`, invoke the shutdown helper with a live trigger, or
  simulate `LOWBATT` on a production host unless an actual shutdown is intended.
  FSD follows NUT's configured shutdown path and will power off the host.

## Secret handling

- `bark.conf`, local NUT configs, environment files, private keys, and backups
  are ignored by `.gitignore`.
- `bark.conf.example` contains only a placeholder. Never put a real Bark key,
  NUT password, access token, or private signing key in source, docs, commit
  messages, or logs.
- Bark send logs include event and UPS readings only; the key is not logged.
