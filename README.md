# Monitoring

Monitoring is a macOS menu bar app for CPU, GPU, memory, disk, network, fans, and battery. The built app is `Monitoring.app`. The Xcode project and target stay named `BLZPHRS`.

## Features

- Menu bar with one to three metrics (memory, swap, and disk by default)
- Dashboard for CPU cores, GPU, memory pressure, free space, network, and fans
- Top apps by memory or CPU, with Quit and Force Quit
- Fan modes Auto, Cool, and Max through a privileged helper
- Optional 80% charge limit, Low Lag (AWDL off), keep-awake, and a black screen
- Camera and microphone activity, plus battery rings for Bluetooth accessories

The helper is required only for writing fan and charge settings, disabling AWDL, and closed-lid sleep. Everything it changes is put back when Monitoring quits or the helper loses the connection. Install the release build in `/Applications` before enabling the helper in System Settings → General → Login Items.

If Mole is running, set its fan to Auto and turn off its charge limit and Low Lag first. Two controllers will fight.

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

## Measurement behavior and overhead

- One coalesced timer: 1 s with the dashboard open, 3 s hidden. Hidden mode samples only selected menu metrics plus battery data needed by the controllers.
- Temperatures, fans, power and process lists refresh at most once every 3 s while visible; battery every 5 s (15 s hidden); accessories every 15 s while visible; capacity every 60 s. Opening the dashboard can request an immediate sample.
- Rates use continuous monotonic time. Initial samples, counter resets, source changes and gaps over 10 s produce missing values, not zero. Wake resets interval baselines. Unavailable readings show `—`; retained capacity/memory/battery readings carry a stale status.
- Charts retain at most 601 timestamped points over 5 minutes, with gaps for missing data. CPU/GPU/used-memory charts use 0–100%; pressure uses the OS levels 1/2/4. Network and disk use labeled adaptive scales and separate directions.
- Disk I/O selects a positively identified internal physical drive and caches its registry handle. If more than one internal drive is found, I/O stays unavailable rather than guessing. Capacity describes the home volume; it is labeled separately from physical-drive I/O.
- Memory uses GiB; disk capacity and transfer rates use decimal GB/MB. Process CPU uses 100% per core; total CPU uses 100% for the whole machine. Process rows warm up before displaying CPU usage.
- SMC sensor mapping and IOReport power depend on the Mac/OS. Temperature details expose average, hottest sensor and rolling peak. Battery health is an estimate from raw full/design capacity, not a claim to reproduce macOS Battery Health; charging-time estimates average recent current and use the active limit.
- No history is written to disk, no continuous subprocess is launched, and subprocess fallbacks have a one-second timeout. Privileged helper behavior is unchanged.

Run verification with:

```sh
xcodebuild -project BLZPHRS.xcodeproj -scheme BLZPHRS -destination 'platform=macOS' -parallel-testing-enabled NO test
```

`SamplingTests` cover missing values, counter resets, long gaps, rolling windows, bounded storage, freshness and charge targets. `EnginePerformanceTests` report short steady-state CPU measurements for hidden/open sampling (without UI rendering); these are diagnostics, not portable performance guarantees. `DashboardRenderingTests` writes a fixture preview to `/tmp/monitoring-metrics-preview.png`. Hosted tests do not initialize hardware controllers.

### Live application profiling

The signed Release executable accepts `--performance-probe --performance-output /absolute/path/report.json`. This opt-in diagnostic runs the normal menu bar and dashboard: 20 s warmup, 3 min closed, 30 s warmup, 3 min open, then 1 min closed again. It records process CPU, child CPU, physical footprint, wakeups and actual panel visibility every 5 s, saves progress and quits. Hardware controls are disabled and user preferences are not modified during this mode. Normal launches do not create a profiling timer.

Run `python3 Tools/analyze_performance.py /absolute/path/report.json` to summarize completed phases. The analysis excludes warmup, intervals with the wrong visibility and 10 s of settling afterward. Keep the panel untouched during measurement; the raw report retains visibility mismatches. CPU includes the app's live UI but does not attribute shared WindowServer/GPU compositor work. The chart UI uses vector paths rather than per-chart Canvas backing resources.
