# niixdebloat

Builds a custom debloated Windows 11 ISO from any stock Windows 11 ISO.
Everything is embedded in a single `.ps1` file — no extra files needed.

---

## Requirements

- Windows 10 or 11
- PowerShell 5.1+
- A stock Windows 11 ISO
- Internet connection (for oscdimg install if not already present)
- Run as Administrator (the script self-elevates)

---

## Usage

```powershell
PowerShell -ExecutionPolicy Bypass -File "niixdebloat.ps1"
```

1. Place the script anywhere. If a `.iso` file is in the same folder it will be picked up automatically, otherwise a file browser opens.
2. You'll be asked whether to inject this PC's drivers into the ISO — say yes if the
   target machine is this same PC (or identical hardware) and you want networking,
   storage and GPU drivers working immediately after install with nothing extra to
   install. This exports only non-inbox (OEM/third-party) drivers via `dism /Export-Driver`
   and injects them into the offline image via `dism /Add-Driver /Recurse`.
3. The script auto-selects **Windows 11 Pro for Workstations** if available, otherwise **Pro**, otherwise prompts you to choose.
4. Everything runs unattended from there. Output ISO is saved as `win11_niix.iso` in the same folder as the source ISO.

---

## What it does

**Everything is baked into the ISO before it is ever booted** — Windows Backup and Recall
are removed via offline DISM (`/Image:` mode) against the mounted install image, and every
other tweak is a registry edit applied to the offline SYSTEM/SOFTWARE hives and the Default
user profile hive (which Windows copies whenever it creates a new account, including the
one you create during OOBE). Because these are set before the image is ever booted, there's
no "old" live state to transition away from — settings like GPU scheduling and VBS are
already in their target state on the very first boot, so **no post-install reboot is needed
to apply them.**

- Removes 50+ bloatware AppX packages (Xbox, Teams, Copilot, Bing, Cortana, etc.)
- Completely removes Microsoft Edge and all its components
- Removes OneDrive, Windows Backup (via offline DISM capability removal) and the Recall
  optional feature (via offline DISM feature removal)
- Disables telemetry, data collection and diagnostic services
- Disables Copilot, Recall, AI features and Bing search
- Disables GameBar/Xbox services and privacy-invasive services (DiagTrack, SysMain, etc.)
- Applies dark theme for all users
- Sets custom wallpaper (`niix-wall.png`)
- Hides taskbar Search, Task View, Widgets and Chat buttons
- Left-aligned taskbar, classic right-click context menu
- Shows hidden files and file extensions in Explorer
- Disables SmartScreen, OneDrive sync and Content Delivery
- Disables BitLocker auto-encryption
- Bypasses TPM, Secure Boot and RAM hardware checks
- Disables Core Isolation / Memory Integrity (VBS/HVCI) via both the runtime and the
  policy registry keys, so it stays off even after Microsoft's October 13, 2026 update
  that auto-enables it on eligible PCs (Microsoft has said that update skips PCs where
  it's already explicitly disabled via policy/registry)
- Applies gaming/system performance tweaks: Game Mode on, Xbox Game Bar off, mouse
  acceleration off, fullscreen optimizations off, hardware-accelerated GPU scheduling on
- Sets Windows Update to notify-only during specialize/first-logon (fully automated —
  Windows' own install process already reboots multiple times, so this needs no extra
  user-triggered restart)
- Suppresses Windows Update during OOBE, blocks security questions screen, embeds
  `autounattend.xml` for a fully automated install (no Microsoft account required)

A handful of things genuinely can't be set on an offline, unbooted image (setting the
local password-age policy, clearing an already-active BitLocker volume, the boot menu
timeout) — those run automatically and silently as part of Windows Setup's own
`specialize`/`oobeSystem` passes via the embedded `autounattend.xml`, which happens
during Windows' own automatic install reboots. You won't see a prompt for any of it.

Paint, Notepad, Snipping Tool and Photos are intentionally left installed —
they are not touched by the AppX removal list.

> **Note:** this script does **not** activate Windows. You'll still need to
> activate through a genuine license (retail key, volume license, or a
> digital entitlement already tied to the machine) after install.

---

## After install

1. Set your **username and password** during the OOBE setup screen — this is the only prompt you will see.
2. That's it. All tweaks are already applied — nothing to run, nothing extra to reboot for.
3. Activate Windows with your own valid license key (Settings → System → Activation).

`niix-tweaks.ps1` is still placed on your desktop as an **optional** maintenance script —
useful if you ever want to re-apply these tweaks on an *existing* Windows install (not one
built from this ISO), or reapply after a Windows feature update resets a setting. It is not
required for a fresh install from this ISO.

---

## Files

| File | Description |
|---|---|
| `niixdebloat.ps1` | Main script — run this to build the ISO |
| `niix-tweaks.ps1` | Optional standalone maintenance script — re-applies the same tweaks live, e.g. on an existing Windows install |

`niix-tweaks.ps1` is also embedded inside `niixdebloat.ps1` and placed on the desktop
automatically after install, purely for convenience if you want it later.
