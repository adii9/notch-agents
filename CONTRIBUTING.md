# Contributing

Issues and PRs welcome.

- `swift build` must pass without warnings.
- Test UI changes with `Scripts/simulate.sh`; for payload-related changes, test against a real Claude Code session.
- Keep the hook path non-blocking and the app offline: no network calls, no telemetry.
- Ideas wanted: permission prompts on the island, click-to-focus the terminal, sounds, settings, a non-notch layout.
