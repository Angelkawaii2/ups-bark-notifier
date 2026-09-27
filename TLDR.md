# TL;DR

- Debian 13 host; NUT 2.8.1 standalone; CyberPower 1200 via USB VID:PID
  `0764:0601`; NUT UPS name `ups`.
- No Docker. `usbhid-ups` → `upsd` → `upsmon`/`upssched`; a systemd timer runs
  the one-shot battery checker every 60 seconds.
- Bark key lives only in `/etc/nut/bark.conf` (`root:nut`, mode `0640`). The
  workspace `bark.conf` is local-only, mode `0600`, and Git-ignored.
- Current policy: shut down at `battery.charge <= 30%` OR after
  `MAX_ON_BATTERY_TIME=7200` seconds (2 hours) continuously on battery. The
  timer adds at most about 60 seconds to the time condition.
- During OB, Bark notifies for every 10 percentage-point charge drop from the
  outage baseline. After ONLINE, it sends a recovery alert and one full-charge
  alert at 100%.
- Custom shutdown validates live `OB`, threshold/time, and `nut-monitor`; it
  sends bounded best-effort Bark, then calls `upsmon -c fsd`. NUT's native
  `LOWBATT → FSD → SHUTDOWNCMD` protection remains enabled.
- To change thresholds, edit `/etc/nut/ups-policy.conf`; source template is
  `ups-policy.conf.example`. The next checker run reads the new values.
- Services: `nut-driver@ups.service`, `nut-server.service`,
  `nut-monitor.service`, `nut-battery-check.timer`.
- Logs: `journalctl -u nut-monitor`, `journalctl -u nut-battery-check`,
  `journalctl -t nut-bark`.
- Never commit or print Bark keys, NUT passwords, tokens, private keys, or live
  configs. Never trigger FSD or a live shutdown as a test.
