# SpeedBar

A minimal macOS menu bar app that displays real-time upload/download speeds.

![macOS](https://img.shields.io/badge/macOS-12.0%2B-blue)

![SpeedBar in menu bar](assets/screenshot.png)

## Download

**For most users:** Download the latest release and run—no coding required.

1. Go to [Releases](../../releases/latest)
2. Download `SpeedBar.zip`
3. Unzip and drag `InternetSpeed.app` to your Applications folder
4. Double-click to run

> **Note:** On first launch, macOS may block the app. Right-click the app → **Open** → **Open** to allow it.

## Usage

The app shows in your menu bar: `↓1.2M ↑0.3K`

- **↓** = Download speed (bytes/sec)
- **↑** = Upload speed (bytes/sec)

Click the menu bar item and select **Quit** to exit.

### Launch at Login

1. Open **System Settings** → **General** → **Login Items**
2. Click **+** and add `InternetSpeed.app`

---

## Build from Source

For developers who want to build from source:

### Requirements

- macOS 12.0+
- Xcode Command Line Tools

### Build

```bash
# Install Xcode Command Line Tools (if needed)
xcode-select --install

# Clone and build
git clone https://github.com/YOUR_USERNAME/speedbar.git
cd speedbar
./build.sh

# Run
open InternetSpeed.app
```

---

## Creating a Release (for devs)

To publish a new release with downloadable artifacts:

```bash
# 1. Build the app
./build.sh

# 2. Create a zip for distribution
zip -r SpeedBar.zip InternetSpeed.app

# 3. Create a GitHub release
gh release create v1.0.0 SpeedBar.zip \
  --title "SpeedBar v1.0.0" \
  --notes "Initial release - macOS menu bar internet speed monitor"
```

Or manually via GitHub:
1. Go to your repo → **Releases** → **Create a new release**
2. Tag: `v1.0.0`, Title: `SpeedBar v1.0.0`
3. Upload `SpeedBar.zip`
4. Publish release
