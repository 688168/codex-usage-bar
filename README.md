# Codex Usage Bar

A lightweight native macOS menu bar app for checking Codex usage and using an
available reset without opening the Codex app.

[简体中文](README.zh-CN.md)

> Independent community project. Not affiliated with or endorsed by OpenAI.

## Features

- Shows the remaining Codex percentage directly in the menu bar.
- Displays the current usage window, refresh time, and account plan.
- Shows the number of available resets, or `No reset currently available`.
- Requires confirmation before consuming a reset.
- Stores the time and result of the latest manual reset locally.
- Refreshes automatically every five minutes.
- Uses the signed-in local Codex account; no ChatGPT token is read or stored.
- Optionally shows after startup through the standard macOS service; it is
  never enabled automatically.

## Requirements

- macOS 13 Ventura or later.
- Codex or ChatGPT for macOS installed and signed in, or Codex CLI installed
  with Homebrew.
- Apple Command Line Tools. Install them with `xcode-select --install` if
  needed.

## Install

Clone the repository and run the installer:

```bash
git clone https://github.com/688168/codex-usage-bar.git
cd codex-usage-bar
./scripts/install.sh
```

The app is built locally, copied to `/Applications/Codex Usage Bar.app`, and
opened. Use its menu to enable **Show After Startup** if desired.

You can also give the repository URL to Codex and ask it to clone the project,
run `./scripts/install.sh`, verify the signature and self-test, and open the
installed app.

## Update

```bash
cd codex-usage-bar
git pull --ff-only
./scripts/install.sh
```

## Build without installing

```bash
./scripts/build.sh
open "dist/Codex Usage Bar.app"
```

The build uses native Objective-C/AppKit and the system Command Line Tools. It
does not require third-party dependencies or a full Xcode installation.

## Verification

Offline self-test:

```bash
"dist/Codex Usage Bar.app/Contents/MacOS/CodexUsageBar" --self-test
```

Read-only account diagnostic:

```bash
"dist/Codex Usage Bar.app/Contents/MacOS/CodexUsageBar" --diagnose
```

The diagnostic reads account, usage, and reset availability. It never consumes
a reset.

## Privacy and security

- Authentication is handled by the local Codex App Server.
- The app does not read, log, or store ChatGPT access tokens.
- Account email is masked before it is shown.
- The latest manual reset result is stored only in macOS user defaults on that
  Mac and is not synchronized.
- Consuming a reset always requires an explicit confirmation.
- Startup launch is opt-in and is never enabled by the app automatically.

The downloadable community build is ad-hoc signed and not Apple-notarized.
Building from source is recommended until a notarized release is available.

## Uninstall

Disable **Show After Startup** from the app menu, quit the app, and move
`/Applications/Codex Usage Bar.app` to the Trash.

## License

Source code is available under the [MIT License](LICENSE). Third-party marks
and artwork are covered by [NOTICE.md](NOTICE.md).
