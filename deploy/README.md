# deploy/

Service files shipped with every release:

- `run-clawd.sh` — wrapper that sources `clawd.env` and execs `clawd run`.
- `com.ivanmagda.swift-claw.plist` — launchd LaunchAgent (macOS).
- `swift-claw.service` — systemd user service (Linux).

Install, start, update, and uninstall instructions — for both the scripted
`~/.swift-claw` layout and the manual `/usr/local/bin` layout — live in
[docs/INSTALL.md](../docs/INSTALL.md).

The service wrapper sources `clawd.env`, including the optional
`CLAW_TELEGRAM_GROUP_CHAT_ID=-100…`. Before enabling that value, disable the bot's privacy mode in
BotFather so Telegram delivers ambient group history; see the
[shared-group setup](../docs/GETTING_STARTED.md#optional-connect-one-shared-group). The value is a
group/supergroup chat ID, never a forum topic ID.

Exit codes are diagnostic:

| Code | Meaning |
|---|---|
| 10 | invalid config |
| 11 | secret loading failed |
| 12 | another instance holds the state-root lock |
| 13 | storage error |
