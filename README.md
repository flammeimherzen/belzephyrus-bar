# Monitoring

Monitoring is a macOS menu bar app for quick system monitoring. The built app is `Monitoring.app`. The Xcode project and target stay named `BLZPHRS`.

## Features

- Memory and disk usage overview
- Top apps by memory usage
- Quick refresh and Activity Monitor shortcut
- Quit or force quit selected running apps
- Lightweight SwiftUI menu bar interface

## Requirements

- macOS 26.2 or later
- Apple Silicon Mac
- Xcode 26 or later

## Build

Open `BLZPHRS.xcodeproj` in Xcode and run the `BLZPHRS` scheme.

Or build from the command line:

```sh
xcodebuild -project BLZPHRS.xcodeproj -scheme BLZPHRS -configuration Release build
```

## Distribution

Public releases should be signed with `Developer ID Application`, notarized, and distributed as a signed/notarized `.dmg` or `.pkg`.

