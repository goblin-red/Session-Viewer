# GOBL(in) Session Viewer

**English** · [Русский](README.ru.md)

Lets you view all the sessions of your terminal and desktop agents.

One window lists every conversation you had with Claude Code, Codex, Grok and OpenCode on this Mac:
the first message, the folder, where it was started, the size and the date. Click a title to read how the
conversation began. For Claude and Codex it can also put a terminal session into the history of the
desktop app, so you can continue it there.
One of the apps of [GOBL(in)](https://goblin.red).

## Features

- Four sources: Claude and Codex with import, Grok and OpenCode for viewing only.
- Filter by project, with the number of sessions in each one.
- For every session: the first message, the folder, where it was started (terminal, desktop app, SDK),
  the size, the date and the status.
- Click a session's title to see its first ten exchanges.
- Click a column header to sort the table.
- Automated runs (sessions started by scripts and other agents, subagents) are hidden by default;
  the "Automated runs" checkbox shows them.
- Sessions that are already in the desktop app are marked and can't be imported twice.
- The list loads 50 sessions at a time.
- Two interface languages, English and Russian: English by default, switched with the EN / RU buttons.

## Where the sessions come from

| Source | Where sessions are found | What import writes |
| --- | --- | --- |
| **Claude** | `~/.claude/projects/<project>/*.jsonl` | a small `local_<id>.json` card in `~/Library/Application Support/Claude/claude-code-sessions/…` |
| **Codex** | `~/.codex/sessions/**/rollout-*.jsonl` | a row in the `threads` table of `~/.codex/state_5.sqlite` |
| **Grok** | `~/.grok/sessions/<project>/<id>/` | nothing: view only |
| **OpenCode** | `~/.local/share/opencode/opencode.db` | nothing: view only |

Viewing only reads these files. Import does not copy or change the conversation itself: it adds a record
that tells the desktop app "this session exists, and here it is". After the import, quit the desktop app
(⌘Q) and open it again: the session appears in its history.

## Install

Paste this into Terminal:

```sh
curl -fsSL https://raw.githubusercontent.com/goblin-red/session-viewer/main/install.sh | bash
```

The script downloads the ready-made build from [Releases](https://github.com/goblin-red/session-viewer/releases/latest),
puts it into `/Applications` and opens it. The build is universal: it runs on Apple Silicon and on Intel Macs,
and no Xcode tools are needed. To update, run the same command again.

Downloaded the zip by hand? The app is not notarized by Apple, so macOS blocks a downloaded copy.
Unblock it once:

```sh
xattr -dr com.apple.quarantine "/path/to/GOBL(in) Session Viewer.app"
```

## Please note

The app reads the session files of the agents, and import writes to the internal storage of the Claude
desktop app and of Codex. These formats are not documented and may change with any update, so a source
or the import may stop working. It is a personal tool, use it at your own risk.

## Requirements

- macOS 10.15 or newer
- At least one of the agents: Claude Code, Codex, Grok, OpenCode

## Build from source

Needs Xcode Command Line Tools (`xcode-select --install`).

```sh
git clone https://github.com/goblin-red/session-viewer.git
cd session-viewer

./build_app.sh
open "build/GOBL(in) Session Viewer.app"
```

## Project

| Path | Purpose |
| --- | --- |
| `Sources/main.swift` | the app (AppKit, SQLite) |
| `build_app.sh` | builds the app (arm64 + x86_64) |
| `install.sh` | installs the ready-made build from Releases |
| `package.sh` | packs the build for Releases: `build/goblin-session-viewer-macos.zip` |
| `logo.svg`, `AppIcon.icns` | the Goblin logo for the window and the app icon |
| `CHANGELOG.md` | change history (in Russian) |

Code comments are in Russian.

## License

[MIT](LICENSE)
