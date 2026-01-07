# InternetSpeed

A minimal macOS menu bar app that displays real-time upload/download speeds.

## Requirements

- macOS 12.0+
- Xcode Command Line Tools

## Install & Build

```bash
# 1. Install Xcode Command Line Tools (if not already installed)
xcode-select --install

# 2. Build the app
./build.sh

# 3. Run the app
open InternetSpeed.app

# 4. (Optional) Install to Applications
cp -r InternetSpeed.app /Applications/
```

## Usage

The app shows in your menu bar: `↓1.2M ↑0.3K`

- **↓** = Download speed (bytes/sec)
- **↑** = Upload speed (bytes/sec)

Click the menu bar item and select **Quit** to exit.

## Launch at Login

1. Open **System Settings** → **General** → **Login Items**
2. Click **+** and add `InternetSpeed.app`
