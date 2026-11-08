# Notch Agents

A Dynamic-Island-style pill at the notch of your Mac that shows live [Claude Code](https://claude.com/claude-code) activity: every running chat and sub-agent, what tool it's on, and how long it's been going. Hover to expand.

> Independent open-source project. Not affiliated with or endorsed by Anthropic.

## Install
Download the latest `.dmg` from [Releases](../../releases), drag **Notch Agents** to Applications, open it, then choose **Install Claude Code hooks…** from the menu bar icon. Restart any running Claude Code sessions.

Requires macOS 14+. Works on Macs without a notch too (the pill sits at top-center).

## How it works
```
Claude Code hooks -> ~/.notch-agents/hook.sh -> Unix socket ~/.notch-agents/sock -> app -> notch pill
```
- Hooks used: `SessionStart`, `PreToolUse`, `PostToolUse`, `SubagentStart`, `SubagentStop`, `Stop`, `Notification`.
- The hook script only pipes the event JSON to a local socket (mode 0600) and exits 0 immediately, even when the app isn't running, so it can never block Claude.
- No network access, no analytics. Events live in memory only.
- **Install hooks** edits `~/.claude/settings.json`: it writes a timestamped backup (`settings.json.bak.<unix-time>`) and only adds/removes entries pointing at `~/.notch-agents/hook.sh`. **Remove Claude Code hooks** reverses it.

## Build from source
```bash
swift build && .build/debug/NotchAgents     # run
Scripts/simulate.sh                         # fake multi-agent activity, no Claude needed
Scripts/build-app.sh                        # dist/Notch Agents.app + .dmg (ad-hoc signed)
```
For a signed, notarized release set `SIGN_IDENTITY="Developer ID Application: …"` and `NOTARY_PROFILE=<notarytool keychain profile>`.

## Landing page
Live at **https://notch-agents.vercel.app**. `docs/index.html` is a single self-contained page; Vercel deploys it from `/docs` on every push to `main`.

## Contributing
See [CONTRIBUTING.md](CONTRIBUTING.md). MIT licensed.
