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
2. The script auto-selects **Windows 11 Pro for Workstations** if available, otherwise **Pro**, otherwise prompts you to choose.
3. Everything runs unattended from there. Output ISO is saved as `win11_niix.iso` in the same folder as the source ISO.

---

## What it does

**Offline (baked into the ISO before it is ever booted):**

- Removes 50+ bloatware AppX packages (Xbox, Teams, Copilot, Bing, Cortana, etc.)
- Completely removes Microsoft Edge and all its components
- Removes OneDrive
- Disables telemetry, data collection and diagnostic services
- Disables Copilot, Recall, AI features and Bing search
- Applies dark theme for all users
- Sets custom wallpaper (`niix-wall.png`)
- Hides taskbar Search, Task View, Widgets and Chat buttons
- Left-aligned taskbar, classic right-click context menu
- Shows hidden files and file extensions in Explorer
- Disables BitLocker auto-encryption
- Bypasses TPM, Secure Boot and RAM hardware checks
- Suppresses Windows Update during OOBE
- Blocks security questions screen entirely
- Embeds `autounattend.xml` for fully automated install (no Microsoft account required)

**At first login (via `niix-tweaks.ps1` which appears on your desktop):**

- Removes Edge (runtime pass, in case Windows reinstalled it)
- Removes Windows Backup
- Disables GameBar and Xbox services
- Applies privacy service lockdown
- Disables SmartScreen, OneDrive sync and Content Delivery
- Sets Windows Update to notify-only (no auto-install)
- Applies gaming/system performance tweaks (Game Mode, Xbox Game Bar off,
  mouse acceleration off, fullscreen optimizations off, hardware-accelerated
  GPU scheduling on, Core Isolation/VBS off)

Paint, Notepad, Snipping Tool and Photos are intentionally left installed —
they are not touched by the AppX removal list.

> **Note:** this script does **not** activate Windows. You'll still need to
> activate through a genuine license (retail key, volume license, or a
> digital entitlement already tied to the machine) after install.

---

## After install

1. Set your **username and password** during the OOBE setup screen — this is the only prompt you will see.
2. At first login, **run `niix-tweaks.ps1`** from your desktop as Administrator to finish the runtime tweaks.
3. Why not try Linux in a VM at first

---

## Files

| File | Description |
|---|---|
| `niixdebloat.ps1` | Main script — run this to build the ISO |
| `niix-tweaks.ps1` | Runtime tweaks — run after installing from the ISO |

`niix-tweaks.ps1` is also embedded inside `niixdebloat.ps1` and placed on the desktop automatically after install.
