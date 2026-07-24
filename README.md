# SpeedBar

A lightweight macOS menu bar app for live network speed and connection latency.

![macOS](https://img.shields.io/badge/macOS-12.0%2B-blue)

![SpeedBar in menu bar](assets/screenshot.png)

## Features

- Live download and upload activity from the active network interface
- Clear online, connecting, offline, and paused states
- One-second TCP latency samples with a rolling five-minute history
- Adaptive chart scale, missed-probe markers, average latency, and packet-loss summary
- Cancellable download and upload capacity estimate with validated HTTP responses
- A locally saved last result and timestamp, so old readings are never presented as current
- Launch at Login, pause monitoring, About, and Quit controls in the app

## Download

For most users, download the latest release—no development tools are required.
The release is a universal app that runs natively on both Apple silicon and
Intel Macs with macOS 12 or later.

1. Go to [Releases](../../releases/latest)
2. Download `SpeedBar.zip`
3. Unzip it and drag `SpeedBar.app` into **Applications**
4. Open `SpeedBar.app`

Release builds are ad-hoc signed for bundle integrity, but they are not
Developer ID signed or notarized. macOS may therefore block the first launch.
Right-click the app and choose **Open**. If macOS still reports that the app is
damaged, run:

```bash
xattr -dr com.apple.quarantine "/Applications/SpeedBar.app"
```

Then open the app again.

## Updating

1. Quit the currently running copy of SpeedBar
2. Download `SpeedBar.zip` from the [latest release](../../releases/latest)
3. Unzip the download
4. Drag `SpeedBar.app` into **Applications**
5. Choose **Replace** when Finder asks
6. Open `SpeedBar.app` again

SpeedBar does not have accounts. It stores only the last successful speed-test
result, its timestamp, and small local preferences.

## Usage

The menu bar displays current traffic, for example: `↓1.2M/s ↑318K/s`.

- **↓** is the current download rate
- **↑** is the current upload rate
- Left-click opens live latency history and the speed test
- Right-click opens controls for testing, pausing, launching at login, About,
  and Quit

The popover separates live traffic (bytes per second) from tested connection
capacity (bits per second). It also distinguishes an idle connection from an
offline one.

The latency chart samples once per second and shows the latest five minutes.
Its vertical scale adapts to normal conditions so small changes remain visible.
Amber triangles identify spikes beyond the visible scale, red crosses identify
probes that timed out, and muted dots represent periods when the Mac was
offline. A failed probe is not treated as proof that the whole connection is
offline.

### Speed Test

The speed test is a quick capacity estimate rather than a laboratory-grade
benchmark. It warms up the connection, downloads about 20 MB, and uploads about
5 MB using Cloudflare's speed-test service. Both directions must return
successful HTTP responses before SpeedBar saves the result. The test can be
cancelled at any time.

### Launch at Login

On macOS 13 or later, use **Launch at login** in the SpeedBar popover. On macOS
12, add `SpeedBar.app` manually in **System Settings** → **General** → **Login
Items**.

## Network and Privacy

- Latency monitoring opens a short TCP connection to `1.1.1.1:443` once per
  second while monitoring is active.
- Speed tests use `speed.cloudflare.com` and transfer random upload data.
- SpeedBar does not inspect traffic contents, keep browsing history, or send
  analytics.
- Results and preferences stay in the current macOS user account.

## Build from Source

### Requirements

- macOS 12.0 or later
- Xcode Command Line Tools

### Build

```bash
# Install Xcode Command Line Tools if needed
xcode-select --install

# Clone and build
git clone https://github.com/nishantkumar1292/speedbar.git
cd speedbar
./build.sh

# Run
open SpeedBar.app

# Run the unit and render-level layout tests
swift test
```

The build creates a universal `SpeedBar.app` containing both Apple silicon and
Intel code and targets macOS 12 or later. The internal SwiftPM executable remains
named `InternetSpeed`.

The default app version is `0.2.0`. To build another version, set `VERSION`:

```bash
VERSION=0.2.1 ./build.sh
```

## Creating a Release

```bash
# Build and verify the app
VERSION=0.2.0 ./build.sh
codesign --verify --deep --strict --verbose=2 SpeedBar.app

# Package it
ditto -c -k --norsrc --keepParent SpeedBar.app SpeedBar.zip

# Create a release
gh release create v0.2.0 SpeedBar.zip \
  --title "SpeedBar v0.2.0" \
  --notes-file RELEASE_NOTES.md
```
