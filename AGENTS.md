# Instructions for coding agents

Read `TLDR.md` first, then the relevant parts of `README.md` and the scripts
before changing behavior.

## Project facts

- This repository is deployed on a Debian 13 mini PC with NUT 2.8.1 in
  standalone mode, a CyberPower 1200 USB UPS (`0764:0601`), and UPS name `ups`.
- NUT's driver/server/monitor and all notification and shutdown logic run on
  the host under systemd. Do not introduce Docker or a resident polling loop.
- `nut-battery-check.sh` is a root-run one-shot called by the 60-second
  `nut-battery-check.timer` and immediately for ONBATT/ONLINE callbacks.
- `/etc/nut/ups-policy.conf` is the live policy source. The checked-in
  `ups-policy.conf.example` should match its safe defaults. Durations are
  seconds: current `MAX_ON_BATTERY_TIME=7200`; the charge threshold is 30%.
- Battery/outage state is stored under `/var/lib/nut-battery-monitor`; the
  shutdown idempotency marker is under `/var/lib/nut-shutdown-request`.
- `nut-shutdown-request.sh` checks the live UPS state and policy, sends only a
  bounded best-effort Bark notice, and enters the regular NUT sequence using
  `upsmon -c fsd`. Do not replace this with a direct `poweroff` or bypass NUT's
  `SHUTDOWNCMD`/`POWERDOWNFLAG` path.
- Bark credentials are not source files. The host reads
  `/etc/nut/bark.conf`; `.gitignore` excludes the workspace `bark.conf`.
  `bark.conf.example` must contain placeholders only.

## Safety and secret handling

- Never read, print, log, stage, or commit `bark.conf`, live NUT credentials,
  API keys, access tokens, private signing keys, or backups containing them.
- Before committing, inspect `git status --ignored` and confirm live config is
  ignored. Review staged filenames and diff for secrets.
- Do not execute `upsmon -c fsd`, run a live shutdown trigger, simulate LOWBATT,
  or power off the host unless the user explicitly requests a real shutdown.
- For policy behavior checks, prefer `SHUTDOWN_DRY_RUN=1` and a controlled OB
  condition. A Bark `TEST` event sends a real phone notification; do this only
  when the user asks for a push test.
- Deployment under `/etc`, `/usr/local/sbin`, or systemd requires root. Do not
  alter live host configuration or restart NUT services unless the user asks
  for deployment or service changes.

## Maintenance

- Keep systemd units, tmpfiles snippets, and `ups-policy.conf.example` aligned
  with the scripts and documented installed paths.
- NUT `NOTIFYFLAG` values use `SYSLOG+EXEC`; `SYS+EXEC` is invalid here.
- Keep Bark HTTP timeouts bounded and ensure notification errors never change
  the result of a shutdown request.
- Keep NUT's native LOWBATT/FSD shutdown protection intact.
