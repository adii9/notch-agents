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
- Hooks used: `SessionStart`, `PreToolUse`, `PostToolUse`, `SubagentStart`, `SubagentStop`, `Stop`, `Notification`, `PermissionRequest`.
- **Permission prompts (0.2.0):** for `PermissionRequest` the hook waits for your Allow/Deny at the notch and returns it to Claude. No answer within 25 s (or the app not running) returns nothing, so Claude asks in the terminal as usual. `AskUserQuestion` is shown as a heads-up and released immediately.
- For every other event the hook only pipes the event JSON to a local socket (mode 0600) and exits 0 immediately, even when the app isn't running, so it never holds Claude up.
- No network access, no analytics. Events live in memory only.
- **Install hooks** edits `~/.claude/settings.json`: it writes a timestamped backup (`settings.json.bak.<unix-time>`) and only adds/removes entries pointing at `~/.notch-agents/hook.sh`. **Remove Claude Code hooks** reverses it.

## Build from source
```bash
swift build && .build/debug/NotchAgents     # run
Scripts/simulate.sh                         # fake multi-agent activity, no Claude needed
Scripts/build-app.sh                        # dist/Notch Agents.app + .dmg (ad-hoc signed)
```
For a signed, notarized release set `SIGN_IDENTITY="Developer ID Application: …"` and `NOTARY_PROFILE=<notarytool keychain profile>`.

## CI / releases
- **ci** (every push to `main` and every PR): builds, checks scripts, runs `Scripts/test-hook.sh`, and uploads a DMG artifact.
- **release** (push a `v*` tag): builds the DMG, adds `SHA256SUMS.txt`, and publishes a GitHub release.
- Signing + notarization turn on automatically when these repo secrets exist: `MACOS_CERT_P12` (base64 Developer ID Application .p12), `MACOS_CERT_PASSWORD`, `APPLE_ID`, `APPLE_TEAM_ID`, `APPLE_APP_PASSWORD`. Without them, releases are ad-hoc signed.

## Landing page
Live at **https://notch-agents.vercel.app**. Vercel deploys the static `/docs` folder on every push to `main`. No build step.

- `docs/index.html`, `site.css`, `site.js`: the page. It opens on a Mac desktop; scrolling starts four Claude Code sessions, then the pill comes out of the notch.
- The island on the page is not a recording. `site.js` carries a JavaScript port of `AgentStore.swift` and feeds it hook events of the same shape Claude Code sends, so if you change how the app handles an event, mirror it there.
- `docs/scrollcraft.js` / `scrollcraft.css`: the [scroll-craft](https://github.com/nateherkai/scroll-craft) engine, unmodified. Fonts are self-hosted. Licences are in `docs/THIRD-PARTY.md`.
- Preview locally with `python3 -m http.server -d docs 4500`.

## Contributing
See [CONTRIBUTING.md](CONTRIBUTING.md). MIT licensed.
