# Pewter

A tiny menubar scratchpad for AI-assisted work. Double-tap **Shift** to capture
whatever text you've selected — in ChatGPT, Claude, Cursor, your browser,
anywhere — into a floating checklist. Type the prompts already in your head but
not ready to send. Copy items back out one at a time or as a whole list, and
check them off as you go.

Free and open source. Everything stays on your Mac.

- **Local files** — your notes are a plain markdown file you can open in any editor
- **No tracking, no account, no sync** — the app never touches the network
- **Keyboard-first** — capture, navigate, toggle, and copy without the mouse
- **Configurable trigger** — double-tap Shift, Control, Option, or Command, or a
  chord hotkey (⌃⇧C). Pick around your setup: double-tap ⌘ collides with
  Type to Siri, double-tap ⇧ with Karabiner's SpaceCadet
- **Native** — Swift/SwiftUI menubar app, near-zero idle footprint

## Install

Build from source (for now):

```sh
git clone https://github.com/oakoss/pewter.git
cd pewter
mise install        # or: brew install xcodegen swiftformat
make run
```

Requires macOS 14+ and Xcode.

## Why Accessibility permission?

Pewter asks for Accessibility access for exactly two things:

1. Listening for the double-tap capture shortcut
2. Reading the text you have selected in the frontmost app when you trigger a capture

Capture tries three tiers in order: the Accessibility API (invisible, no
clipboard side effects), a synthesized copy with clipboard restore (apps that
hide their selection from Accessibility), and — for terminal UIs that
auto-copy their own selection, like Claude Code — clipboard content that
arrived within the last few seconds. The app never reads your clipboard
outside of a capture you triggered.

It reads nothing else, stores everything in a local file, and makes no network
requests. The code is right here if you want to check.

## Your data

One markdown file: `~/Library/Application Support/Pewter/pewter.md`.
It's a plain task list — edit it by hand, sync it yourself, or point other
tools at it. Pewter picks up external changes automatically.

## Development

```sh
make gen     # generate Pewter.xcodeproj (XcodeGen)
make build   # CLI build
make test    # Core package unit tests
make run     # build + launch
```

See [CONTRIBUTING.md](CONTRIBUTING.md) for the signing/TCC gotchas before
hacking on the capture pipeline.

## License

[MIT](LICENSE)
