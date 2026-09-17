# niixdebloat

Build a privacy-hardened, debloated, gaming-tuned Windows 11 install ISO from an official Microsoft ISO — no manual post-install cleanup required. Everything below is applied automatically during Windows Setup and at first logon.

Based on [WinUtil](https://github.com/ChrisTitusTech/winutil) by Chris Titus and the [Schneegans unattend generator](https://schneegans.de/windows/unattend-generator/), customised by [techniix](https://github.com/techniixdotcom).

## Files in this repo

| File | What it is |
|---|---|
| `niixdebloat.ps1` | The builder. Mounts a Windows 11 ISO, applies offline registry/image edits, bakes in the answer file and tweaks script, and produces a new customized `.iso`. |
| `unattend.xml` | Plain-text Windows Setup answer file (`autounattend.xml`). Bypasses TPM/Secure Boot/RAM checks, skips Microsoft-account push, and wires up automatic first-logon customization. |
| `niix-tweaks.ps1` | Plain-text post-install script. Auto-runs once, elevated, at first logon — this is where most of the debloat/privacy/performance work actually happens. |

All three files must stay together in the same folder — `niixdebloat.ps1` reads the other two as plain text at build time. Open either file directly in a text editor to see exactly what it does or to customize it.

## Requirements

- Windows 10/11 with PowerShell (run `niixdebloat.ps1` **as Administrator**)
- An official Windows 11 ISO from Microsoft
- `oscdimg.exe` (from the Windows ADK Deployment Tools, or installed automatically via `winget` if missing) — used to build the final ISO
- Internet access on the build machine (for `oscdimg` if not already installed)

## Quick start

1. Download an official Windows 11 ISO from Microsoft.
2. Put `niixdebloat.ps1`, `unattend.xml`, and `niix-tweaks.ps1` in the same folder.
3. *(Optional)* Drop a `wallpaper.jpg`, `wallpaper.jpeg`, or `wallpaper.png` into that same folder to use it as the default desktop background. Skip this and Windows keeps its normal default wallpaper.
4. Open Terminal (as admin): cd to the script folder and `powershell -ExecutionPolicy Bypass -File .\niixdebloat.ps1`
5. Wait for it to finish — it mounts the image, applies every tweak listed below directly into the offline registry hives, bakes in the answer file, and builds a new `.iso`.
6. Boot from the resulting ISO (see below) and install Windows normally — no further input needed beyond the screens Windows Setup still asks interactively (language/keyboard, disk partitioning, Windows edition, and your local account name/password).

![debloadimage](https://raw.githubusercontent.com/techniixdotcom/niix-debloat/refs/heads/main/niixdebloat.png)

## Booting the ISO

How you turn the built `.iso` into something you can actually boot from **matters** — the answer file only works if Windows Setup can find `autounattend.xml` at the root of whatever media it boots from.

### Virtual machine
Mount the `.iso` directly as a virtual DVD (VirtualBox / VMware / Hyper-V). Works automatically, no extra steps.

### USB via Rufus
Flash the `.iso` to a USB drive with Rufus in normal ISO mode. **Do not** enable any of Rufus's own "Customize Windows installation" options — those generate a *second* answer file that will conflict with (and can override) ours. Works automatically otherwise.

### USB via Ventoy
Ventoy does **not** read an ISO's own internal `autounattend.xml` — it needs the answer file placed separately on the Ventoy drive and mapped to the ISO via its **Auto Install Plugin**:

1. At the root of your Ventoy USB, create a folder named `Templates`.
2. Copy `autounattend.xml` (found at the root of the built `.iso` — mount it or open it with 7-Zip to grab the file) into `Templates\`.
3. Run `VentoyPlugson.exe` (ships in the Ventoy release zip). It opens a local web UI.
4. Go to the **Auto Install** plugin page → **Add**.
5. Select your Windows ISO (or `[parent]` to cover a whole folder of ISOs), and set the Template Path to `\Templates\autounattend.xml`. Save.
6. Boot the Ventoy USB and select the ISO as usual — Ventoy now applies the mapped answer file automatically.

## What happens automatically during install

1. **Offline, baked into the image at build time** — dark theme, transparency, taskbar layout, and most registry-level tweaks are written directly into the mounted image, live from the very first boot.
2. **Windows Setup (`specialize` pass)** — runs as SYSTEM before any interactive logon. Registers a scheduled task that will run `niix-tweaks.ps1` elevated (no UAC prompt) at first logon.
3. **First interactive logon** — dark theme, classic right-click menu, and your custom wallpaper (if supplied) are applied in your actual account's context.
4. **`niix-tweaks.ps1` runs automatically**, once, elevated — this is where the bulk of the debloat/privacy/performance work happens (full list below). It unregisters its own scheduled task so it never runs twice, then asks whether to restart.
5. **Logs** — a full transcript is saved to `Documents\NiixDebloat-Logs`, and a safety-net copy of every install-phase log is also written to `C:\Users\Public\Documents\NiixDebloat-Logs`.

## What this script removes, disables, and changes

### Bloatware removed
Xbox apps (Game Bar, Xbox app, Xbox Identity/Speech-to-Text overlays), Bing News/Search/Weather, Copilot, Cross Device Experience, Get Help, Get Started, 3D Viewer, Office Hub, Solitaire Collection, Sticky Notes, Mixed Reality Portal, Paint, OneNote, Office push notifications, the new Outlook app, People, Power Automate Desktop, Skype, Start Experiences, To Do, Wallet, Dev Home, Teams (both variants), Alarms, Camera, Mail & Calendar, Feedback Hub, Maps, Sound Recorder, Groove Music/Movies & TV, Clipchamp, and the Windows Backup capability.

### Microsoft Edge & WebView2
Edge browser is removed and blocked from reinstalling. **WebView2 Runtime is deliberately kept working** (with explicit policy overrides) since many third-party apps — Stremio, WhatsApp Desktop, and most Electron/webview-based apps — depend on it even with Edge itself gone.

### Privacy & telemetry
- Full diagnostic telemetry disabled (`AllowTelemetry=0`), advertising ID disabled, activity feed/timeline disabled, tailored experiences disabled
- Location services, background app access, and cross-device clipboard sync disabled
- Consumer features, sponsored Start/lock-screen content, and all the "tips & suggestions" toasts disabled
- Defender's automatic cloud sample submission turned off (real-time protection itself is left fully on)
- Clipboard "Suggested Actions" (the popup that appears when you copy a phone number/date) disabled
- Telemetry-related services disabled: `DiagTrack`, `dmwappushservice`, `WerSvc`, `RemoteRegistry`, `RetailDemo`, `PcaSvc`, and others
- BitLocker auto-encryption disabled

### Copilot, Recall & AI
Windows Copilot, Recall, and the newer on-device AI data-analysis/snapshot features are all disabled via policy, and the Recall optional feature is removed outright if present.

### OneDrive
Fully uninstalled, and blocked from reinstalling or defaulting your folders to it.

### Taskbar & Start menu
Classic (Windows 10-style) right-click context menu, search box hidden, Widgets/News-and-interests removed, Task View button hidden, Microsoft Store unpinned, "Recommended" section removed from Start, empty pinned-apps/taskbar layout, seconds shown in the clock, left-aligned taskbar.

### Appearance
Dark mode (system + apps), transparency effects **on**, classic accent color, custom wallpaper support.

### Windows Update
Suppressed only during OOBE (so it doesn't nag mid-setup) and fully re-enabled after — the scheduled-task folders that actually drive WU's background scanning are explicitly *not* touched, since deleting them (as earlier debloat scripts often do) permanently breaks Windows Update.

### Gaming performance & power (this build)
- Reserved Storage disabled (reclaims ~7GB)
- Hibernation disabled (reclaims disk space equal to installed RAM; also turns off Fast Startup)
- NTFS last-access timestamp updates disabled (fewer background disk writes)
- MMCSS network/multimedia throttling disabled, Games task priority raised (standard low-latency gaming tweak)
- USB selective suspend disabled (stops peripherals power-cycling when briefly idle)
- Power plan set to **High performance**

### Miscellaneous
Long path support enabled, Sticky Keys prompt disabled, SmartScreen disabled, password expiration removed, boot menu timeout set to 0, boot timeout, GameDVR/Game Bar overlay disabled.

## Notes & caveats

- This build bypasses the TPM 2.0 / Secure Boot / RAM requirement checks (`LabConfig` registry keys) — standard practice for installing Windows 11 on unsupported or borderline hardware, but worth knowing it's happening.
- Language/keyboard, disk partitioning, Windows edition selection, and your local account name/password are still asked interactively during Setup — this answer file automates *privacy, telemetry, and OOBE noise*, not the core install decisions.
- The **High performance power plan + hibernation-off + USB-suspend-off** trio in this build assumes a desktop with no battery to manage. If you ever reuse this on a laptop, remove or adjust the Section 16 block in `niix-tweaks.ps1` first.
- Disabling Defender's cloud sample submission is a deliberate privacy/protection trade-off — real-time protection and local signature detection are unaffected, you just lose automatic cloud lookups on brand-new/unknown files.
- If anything doesn't apply as expected, check `Documents\NiixDebloat-Logs` (or `C:\Users\Public\Documents\NiixDebloat-Logs`) after first logon — every install phase writes a full log there.

## License

Personal-use debloat/privacy tooling. Based on WinUtil (MIT) and the Schneegans unattend generator. Use at your own risk — always test in a VM before deploying to real hardware.
