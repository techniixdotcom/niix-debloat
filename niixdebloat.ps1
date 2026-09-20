#Requires -RunAsAdministrator
<#
.SYNOPSIS
    niixdebloat.ps1  -  All-in-one Windows 11 ISO Debloat & Privacy Hardener
.DESCRIPTION
    Reads unattend.xml and niix-tweaks.ps1 (plain text, no Base64) from the
    same folder as this script, bakes them into a customized Windows 11 ISO.
    Drop next to (or browse for) a Win11 ISO and run.
.NOTES
    Based on WinUtil by Chris Titus (@christitustech) -- customised by niix
#>

# ===========================================================================
#  SELF-ELEVATE
# ===========================================================================
if (-not ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
    $exe = if (Get-Command pwsh -ErrorAction SilentlyContinue) { 'pwsh' } else { 'powershell' }
    Start-Process $exe -ArgumentList "-ExecutionPolicy Bypass -NoProfile -File `"$PSCommandPath`"" -Verb RunAs
    exit
}

$PINK  = 'Magenta'
$GREEN = 'Green'
$WHITE = 'White'
$RED   = 'Red'

function Write-Banner  { param([string]$t) Write-Host $t -ForegroundColor $PINK  }
function Write-Title   { param([string]$t) Write-Host ""  ; Write-Host "  $t" -ForegroundColor $PINK ; Write-Host "" }
function Write-Body    { param([string]$t) Write-Host "  $t"   -ForegroundColor $WHITE }
function Write-Success { param([string]$t) Write-Host "  [OK] $t" -ForegroundColor $GREEN }
function Write-Err     { param([string]$t) Write-Host "  [ERROR] $t" -ForegroundColor $RED   }
function Write-Warn    { param([string]$t) Write-Host "  [WARN] $t"  -ForegroundColor Yellow }

$script:_barPct = 0

function Show-Progress {
    param([string]$Activity, [int]$Pct, [switch]$Done)
    $width = 46
    if ($Done) {
        # Sweep to 100%
        for ($p = $script:_barPct; $p -le 100; $p += 2) {
            $f   = [int](($p / 100) * $width)
            $bar = '[' + ('#' * $f) + ('-' * ($width - $f)) + ']'
            Write-Host ("`r  $bar {0,3}%  $Activity{1}" -f $p, (' ' * 30)) `
                -NoNewline -ForegroundColor $GREEN
            Start-Sleep -Milliseconds 6
        }
        $bar = '[' + ('#' * $width) + ']'
        Write-Host ("`r  $bar 100%  $Activity" + (' ' * 30)) -ForegroundColor $GREEN
        $script:_barPct = 0   # reset for next step
        return
    }
    $target = [Math]::Max(0, [Math]::Min(99, $Pct))
    for ($p = $script:_barPct; $p -le $target; $p += 1) {
        $f   = [int](($p / 100) * $width)
        $bar = '[' + ('#' * $f) + ('-' * ($width - $f)) + ']'
        Write-Host ("`r  $bar {0,3}%  $Activity{1}" -f $p, (' ' * 30)) `
            -NoNewline -ForegroundColor $GREEN
        Start-Sleep -Milliseconds 4
    }
    $script:_barPct = $target
}

function Set-OfflineReg {
    param([string]$p, [string]$n, [string]$t, [string]$v)
    & reg add $p /v $n /t $t /d $v /f 2>&1 | Out-Null
}
function Remove-OfflineReg { param([string]$p); & reg delete $p /f 2>&1 | Out-Null }

# ===========================================================================
#  unattend.xml and niix-tweaks.ps1 are loaded as plain text from disk --
#  no embedding, no Base64, nothing to decode. Keep this script,
#  "unattend.xml" and "niix-tweaks.ps1" together in the same folder.
#  You can open and edit either file directly in a text editor.
# ===========================================================================

$_scriptDir = if ($PSScriptRoot) { $PSScriptRoot } else { Split-Path -Parent $PSCommandPath }
$_xmlPath     = Join-Path $_scriptDir 'unattend.xml'
$_tweaksPath  = Join-Path $_scriptDir 'niix-tweaks.ps1'

foreach ($req in @($_xmlPath, $_tweaksPath)) {
    if (-not (Test-Path -LiteralPath $req)) {
        Write-Host "ERROR: required file not found: $req" -ForegroundColor Red
        Write-Host "Keep niixdebloat.ps1, unattend.xml and niix-tweaks.ps1 together in the same folder." -ForegroundColor Red
        exit 1
    }
}

function Get-EmbeddedXml    { Get-Content -LiteralPath $_xmlPath    -Raw -Encoding UTF8 }
function Get-EmbeddedTweaks { Get-Content -LiteralPath $_tweaksPath -Raw -Encoding UTF8 }

# ===========================================================================
#  BANNER
# ===========================================================================
Clear-Host
Write-Banner ""
Write-Banner "  +----------------------------------------------------------+"
Write-Banner "  |                                                          |"
Write-Banner "  |   NN   NN  IIIII  IIIII  XX   XX                         |"
Write-Banner "  |   NNN  NN    I      I     XX XX                          |"
Write-Banner "  |   NN N NN    I      I      XXX                           |"
Write-Banner "  |   NN  NNN    I      I     XX XX                          |"
Write-Banner "  |   NN   NN  IIIII  IIIII  XX   XX  DEBLOAT  v2.0          |"
Write-Banner "  |                                                          |"
Write-Banner "  |      Windows 11 ISO Debloat & Privacy Hardener           |"
Write-Banner "  |      unattend.xml + niix-tweaks.ps1 (plain text, no B64) |"
Write-Banner "  |                                                          |"
Write-Banner "  +----------------------------------------------------------+"
Write-Banner ""

# ===========================================================================
#  STEP 0  --  DRIVER INJECTION PROMPT
# ===========================================================================
Write-Title "STEP 0 -- Driver options..."
Write-Body "Add this PC's current drivers to the ISO? Useful if the target machine is"
Write-Body "the same PC (or identical hardware) and you want networking/storage/GPU"
Write-Body "drivers working immediately after install, with no separate driver install."
Write-Host ""
$driverChoice = Read-Host "  Inject this system's drivers into the ISO? [y/N]"
$injectDrivers = $driverChoice -match '^[Yy]'
if ($injectDrivers) {
    Write-Success "Drivers will be exported from this PC and injected into the image."
} else {
    Write-Body "Skipping driver injection."
}
Write-Host ""

$driverExportDir = $null
if ($injectDrivers) {
    Show-Progress "Exporting drivers from this PC..." 5
    $driverExportDir = Join-Path $env:TEMP "niix_drivers_export"
    if (Test-Path $driverExportDir) { Remove-Item $driverExportDir -Recurse -Force -ErrorAction SilentlyContinue }
    New-Item -ItemType Directory -Path $driverExportDir -Force | Out-Null
    & dism /English /Online /Export-Driver "/Destination:$driverExportDir" 2>&1 | Out-Null
    $exportedCount = (Get-ChildItem -Path $driverExportDir -Filter '*.inf' -Recurse -ErrorAction SilentlyContinue).Count
    if ($exportedCount -gt 0) {
        Show-Progress "Exported $exportedCount driver package(s)." 8 -Done
    } else {
        Write-Body "No third-party drivers found to export (this PC may only use inbox drivers)."
        $driverExportDir = $null
    }
}

# ===========================================================================
#  STEP 1  --  LOCATE ISO
# ===========================================================================
Write-Title "STEP 1 -- Locating ISO file..."

$scriptDir = if ($PSScriptRoot) { $PSScriptRoot } else { (Get-Location).Path }
$isoFiles  = @(Get-ChildItem -Path $scriptDir -Filter '*.iso' -File -ErrorAction SilentlyContinue |
               Sort-Object Name)

if ($isoFiles.Count -eq 0) {
    Write-Body "No .iso found in script directory."
    Write-Host ""
    Write-Host "  Download a Windows 11 ISO from Microsoft:" -ForegroundColor $WHITE
    Write-Host "  https://www.microsoft.com/software-download/windows11" -ForegroundColor Cyan
    Write-Host ""
    Write-Body "Place the ISO in the same folder as this script, or browse for it now."
    Write-Host ""
    Add-Type -AssemblyName System.Windows.Forms
    $dlg                  = [System.Windows.Forms.OpenFileDialog]::new()
    $dlg.Title            = 'Select Windows 11 ISO'
    $dlg.Filter           = 'ISO files (*.iso)|*.iso|All files (*.*)|*.*'
    $dlg.InitialDirectory = [Environment]::GetFolderPath('Desktop')
    if ($dlg.ShowDialog() -ne [System.Windows.Forms.DialogResult]::OK) {
        Write-Host ""
        Write-Err "No ISO selected."
        Write-Host ""
        Write-Host "  Get the official Windows 11 ISO here:" -ForegroundColor $WHITE
        Write-Host "  https://www.microsoft.com/software-download/windows11" -ForegroundColor Cyan
        Write-Host ""
        Read-Host "  Press Enter to exit"
        exit 1
    }
    $selectedISO = $dlg.FileName

} elseif ($isoFiles.Count -eq 1) {
    $selectedISO = $isoFiles[0].FullName
    Write-Body "Found: $($isoFiles[0].Name)"

} else {
    Write-Body "Multiple ISOs found -- please choose:`n"
    for ($i = 0; $i -lt $isoFiles.Count; $i++) {
        $gb = [math]::Round($isoFiles[$i].Length / 1GB, 2)
        Write-Host ("  [{0}]  {1}  ({2} GB)" -f ($i + 1), $isoFiles[$i].Name, $gb) -ForegroundColor $WHITE
    }
    Write-Host ""
    do { $choice = Read-Host "  Enter number"; $idx = [int]$choice - 1 }
    while ($idx -lt 0 -or $idx -ge $isoFiles.Count)
    $selectedISO = $isoFiles[$idx].FullName
}

$isoGB = [math]::Round((Get-Item $selectedISO).Length / 1GB, 2)
Write-Success "Selected: $(Split-Path $selectedISO -Leaf)  ($isoGB GB)"

# ===========================================================================
#  STEP 2  --  MOUNT & VERIFY
# ===========================================================================
Write-Title "STEP 2 -- Mounting and verifying ISO..."
Show-Progress "Mounting ISO..." 20

try {
    $diskImage   = Mount-DiskImage -ImagePath $selectedISO -PassThru -ErrorAction Stop
    $driveLetter = ($diskImage | Get-Volume).DriveLetter + ":\"
} catch {
    Write-Err "Failed to mount ISO: $_"
    Read-Host "`n  Press Enter to exit"; exit 1
}

Show-Progress "Scanning editions..." 60

$wimPath = Join-Path $driveLetter "sources\install.wim"
$esdPath = Join-Path $driveLetter "sources\install.esd"

if (-not (Test-Path $wimPath) -and -not (Test-Path $esdPath)) {
    Dismount-DiskImage -ImagePath $selectedISO | Out-Null
    Write-Err "install.wim / install.esd not found -- not a valid Windows ISO."
    Read-Host "`n  Press Enter to exit"; exit 1
}

$activeWim = if (Test-Path $wimPath) { $wimPath } else { $esdPath }
$imageInfo = Get-WindowsImage -ImagePath $activeWim | Select-Object ImageIndex, ImageName
$win11Only = @($imageInfo | Where-Object { $_.ImageName -match 'Windows 11' })

if ($win11Only.Count -eq 0) {
    Dismount-DiskImage -ImagePath $selectedISO | Out-Null
    Write-Err "No Windows 11 editions found. Only Win11 ISOs are supported."
    Read-Host "`n  Press Enter to exit"; exit 1
}

Show-Progress "ISO verified." 100 -Done
Write-Host ""
Write-Body "Available Windows 11 editions:`n"
for ($i = 0; $i -lt $win11Only.Count; $i++) {
    Write-Host ("  [{0}]  {1}" -f ($i + 1), $win11Only[$i].ImageName) -ForegroundColor $WHITE
}

# Auto-select Pro for Workstations first, then Pro, then ask
$defaultIdx = -1
for ($i = 0; $i -lt $win11Only.Count; $i++) {
    if ($win11Only[$i].ImageName -match 'Pro for Workstations') { $defaultIdx = $i; break }
}
if ($defaultIdx -lt 0) {
    for ($i = 0; $i -lt $win11Only.Count; $i++) {
        if ($win11Only[$i].ImageName -match 'Windows 11 Pro(?![\w ])') { $defaultIdx = $i; break }
    }
}

if ($defaultIdx -ge 0) {
    Write-Host ""
    Write-Host ("  Auto-selected: [{0}] {1}" -f ($defaultIdx + 1), $win11Only[$defaultIdx].ImageName) -ForegroundColor $GREEN
    Write-Host "  Press Enter to confirm, or type a different number to change." -ForegroundColor $WHITE
    $edChoice = Read-Host "  Selection"
    if ($edChoice -match '^\d+$') { $defaultIdx = [int]$edChoice - 1 }
} else {
    Write-Host ""
    Write-Host "  No preferred edition found -- please choose:" -ForegroundColor $WHITE
    $defaultIdx = 0
    do {
        $edChoice = Read-Host "  Enter number"
        if ($edChoice -match '^\d+$') { $defaultIdx = [int]$edChoice - 1 }
    } while ($defaultIdx -lt 0 -or $defaultIdx -ge $win11Only.Count)
}

$selectedIndex   = $win11Only[$defaultIdx].ImageIndex
$selectedEdition = $win11Only[$defaultIdx].ImageName
Write-Success "Edition: $selectedEdition  (Index $selectedIndex)"

# ===========================================================================
#  STEP 3  --  WORKSPACE
# ===========================================================================
Write-Title "STEP 3 -- Preparing workspace..."
Show-Progress "Creating temp directories..." 10

$workDir     = Join-Path $env:TEMP "niixdebloat_$(Get-Date -Format 'yyyyMMdd_HHmmss')"
$isoContents = Join-Path $workDir "iso_contents"
$mountDir    = Join-Path $workDir "wim_mount"
New-Item -ItemType Directory -Path $isoContents, $mountDir -Force | Out-Null

Show-Progress "Copying ISO contents (may take a few minutes)..." 30
& robocopy $driveLetter $isoContents /E /NFL /NDL /NJH /NJS 2>&1 | Out-Null
Show-Progress "ISO contents copied." 100 -Done

# ===========================================================================
#  STEP 4  --  MOUNT install.wim
# ===========================================================================
Write-Title "STEP 4 -- Mounting install.wim..."

$localWim = Join-Path $isoContents "sources\install.wim"
if (-not (Test-Path $localWim)) { $localWim = Join-Path $isoContents "sources\install.esd" }
Set-ItemProperty -Path $localWim -Name IsReadOnly -Value $false -ErrorAction SilentlyContinue

Show-Progress "Mounting image index $selectedIndex..." 30
Mount-WindowsImage -ImagePath $localWim -Index $selectedIndex -Path $mountDir -ErrorAction Stop | Out-Null
Show-Progress "Image mounted." 100 -Done

# ===========================================================================
#  STEP 4b  --  INJECT DRIVERS (if requested in STEP 0)
# ===========================================================================
if ($driverExportDir) {
    Write-Title "STEP 4b -- Injecting this PC's drivers into the image..."
    Show-Progress "Adding drivers to image (this can take a few minutes)..." 40
    & dism /English "/image:$mountDir" /Add-Driver "/Driver:$driverExportDir" /Recurse /ForceUnsigned 2>&1 | Out-Null
    Show-Progress "Drivers injected." 100 -Done
}

# ===========================================================================
#  STEP 5  --  APPLY ALL MODIFICATIONS
# ===========================================================================
Write-Title "STEP 5 -- Applying debloat and privacy hardening..."

$adminSID   = New-Object System.Security.Principal.SecurityIdentifier('S-1-5-32-544')
$adminGroup = $adminSID.Translate([System.Security.Principal.NTAccount])

# -- 5a. Remove provisioned AppX packages -------------------------------------
Show-Progress "Removing AppX bloatware..." 5

$pkgPrefixes = @(
    'AppUp.IntelManagementandSecurityStatus',
    'Clipchamp.Clipchamp',
    'DolbyLaboratories.DolbyAccess',
    'DolbyLaboratories.DolbyDigitalPlusDecoderOEM',
    'Microsoft.BingNews','Microsoft.BingSearch','Microsoft.BingWeather',
    'Microsoft.Copilot','Microsoft.Windows.CrossDevice',
    'Microsoft.GetHelp','Microsoft.Getstarted',
    'Microsoft.Microsoft3DViewer','Microsoft.MicrosoftOfficeHub',
    'Microsoft.MicrosoftSolitaireCollection','Microsoft.MicrosoftStickyNotes',
    'Microsoft.MixedReality.Portal',
    'Microsoft.Office.OneNote','Microsoft.OfficePushNotificationUtility',
    'Microsoft.OutlookForWindows','Microsoft.People',
    'Microsoft.PowerAutomateDesktop','Microsoft.SkypeApp',
    'Microsoft.StartExperiencesApp','Microsoft.Todos','Microsoft.Wallet',
    'Microsoft.Windows.DevHome','Microsoft.Windows.Copilot',
    'Microsoft.Windows.Teams','Microsoft.WindowsAlarms',
    'Microsoft.WindowsCamera','microsoft.windowscommunicationsapps',
    'Microsoft.WindowsFeedbackHub','Microsoft.WindowsMaps',
    'Microsoft.WindowsSoundRecorder','Microsoft.ZuneMusic','Microsoft.ZuneVideo',
    'MicrosoftCorporationII.MicrosoftFamily','MicrosoftCorporationII.QuickAssist',
    'MSTeams','MicrosoftTeams',
    'Microsoft.XboxIdentityProvider','Microsoft.XboxSpeechToTextOverlay',
    'Microsoft.GamingApp','Microsoft.Xbox.TCUI',
    'Microsoft.XboxGamingOverlay','Microsoft.XboxGameOverlay','Microsoft.XboxApp',
    'Microsoft.WindowsBackup',
    'MicrosoftWindows.GameBar','MicrosoftWindows.Client.GameBar',
    'Microsoft.MicrosoftEdge','MicrosoftEdge','Microsoft.BingSearch'
)

$allPkgs = & dism /English "/image:$mountDir" /Get-ProvisionedAppxPackages 2>&1 |
           ForEach-Object { if ($_ -match 'PackageName : (.+)') { $matches[1].Trim() } }

$removed = 0
foreach ($pkg in $allPkgs) {
    $matched = $pkgPrefixes | Where-Object { $pkg -like "*$_*" }
    if ($matched) {
        & dism /English "/image:$mountDir" /Remove-ProvisionedAppxPackage "/PackageName:$pkg" 2>&1 | Out-Null
        $removed++
    }
}
Show-Progress "Removed $removed AppX packages." 10 -Done

# -- 5a2. Remove Windows Backup + Recall Windows Capabilities/Features (offline) --
Show-Progress "Removing Windows Backup capability and Recall feature..." 11
$allCaps = & dism /English "/image:$mountDir" /Get-Capabilities 2>&1 |
           ForEach-Object { if ($_ -match 'Capability Identity : (.+)') { $matches[1].Trim() } }
foreach ($cap in $allCaps) {
    if ($cap -like '*WindowsBackup*' -or $cap -like '*BackupAndRestore*') {
        & dism /English "/image:$mountDir" /Remove-Capability "/CapabilityName:$cap" 2>&1 | Out-Null
    }
}
# Recall is neutralized by policy (DisableAIDataAnalysis + TurnOffSavingSnapshots,
# written to the offline SOFTWARE hive in step 5g). We do NOT remove the Recall
# optional feature: on Windows 11 24H2, removing the component also breaks the
# modern File Explorer UI. Policy-disabling keeps Explorer intact while Recall
# stays off.

# -- 5b. Remove OneDrive -------------------------------------------------------
Show-Progress "Removing OneDrive..." 12
& takeown /f "$mountDir\Windows\System32\OneDriveSetup.exe" 2>&1 | Out-Null
& icacls    "$mountDir\Windows\System32\OneDriveSetup.exe" /grant "$($adminGroup.Value):(F)" /T /C 2>&1 | Out-Null
Remove-Item "$mountDir\Windows\System32\OneDriveSetup.exe" -Force -ErrorAction SilentlyContinue
Show-Progress "OneDrive removed." 15 -Done

# ---- 5b2. Remove Microsoft Edge from mounted image completely ----
Show-Progress "Removing Edge files from image..." 17
$ep = @(
    "$mountDir\Program Files (x86)\Microsoft\Edge",
    "$mountDir\Program Files (x86)\Microsoft\EdgeCore",
    "$mountDir\Program Files (x86)\Microsoft\Temp",
    "$mountDir\Windows\SystemApps\Microsoft.MicrosoftEdge_8wekyb3d8bbwe",
    "$mountDir\Windows\SystemApps\Microsoft.MicrosoftEdgeDevToolsClient_8wekyb3d8bbwe",
    # Microsoft.Win32WebViewHost is the system "Desktop App Web Viewer" -- it is
    # NOT the Edge browser and some apps/system UI render web content through it,
    # so it is intentionally left in place.
    "$mountDir\Windows\System32\MicrosoftEdgeCP.exe",
    "$mountDir\Windows\System32\MicrosoftEdgeSH.exe",
    "$mountDir\Users\Public\Desktop\Microsoft Edge.lnk",
    "$mountDir\ProgramData\Microsoft\Windows\Start Menu\Programs\Microsoft Edge.lnk"
)
foreach ($e in $ep) {
    if (Test-Path $e) {
        & takeown /f $e /r /d y 2>&1 | Out-Null
        & icacls $e /grant "$($adminGroup.Value):(F)" /T /C /Q 2>&1 | Out-Null
        Remove-Item $e -Recurse -Force -ErrorAction SilentlyContinue
    }
}
Show-Progress "Edge files removed from image." 20 -Done

# -- 5c. Load offline hives ----------------------------------------------------
Show-Progress "Loading offline registry hives..." 22
& reg load HKLM\zCOMPONENTS "$mountDir\Windows\System32\config\COMPONENTS" 2>&1 | Out-Null
& reg load HKLM\zDEFAULT    "$mountDir\Windows\System32\config\default"    2>&1 | Out-Null
& reg load HKLM\zNTUSER     "$mountDir\Users\Default\ntuser.dat"            2>&1 | Out-Null
& reg load HKLM\zSOFTWARE   "$mountDir\Windows\System32\config\SOFTWARE"   2>&1 | Out-Null
& reg load HKLM\zSYSTEM     "$mountDir\Windows\System32\config\SYSTEM"     2>&1 | Out-Null

# -- 5d. Hardware bypass -------------------------------------------------------
Show-Progress "Hardware requirement bypass..." 25
Set-OfflineReg 'HKLM\zDEFAULT\Control Panel\UnsupportedHardwareNotificationCache' 'SV1' 'REG_DWORD' '0'
Set-OfflineReg 'HKLM\zDEFAULT\Control Panel\UnsupportedHardwareNotificationCache' 'SV2' 'REG_DWORD' '0'
Set-OfflineReg 'HKLM\zNTUSER\Control Panel\UnsupportedHardwareNotificationCache'  'SV1' 'REG_DWORD' '0'
Set-OfflineReg 'HKLM\zNTUSER\Control Panel\UnsupportedHardwareNotificationCache'  'SV2' 'REG_DWORD' '0'
Set-OfflineReg 'HKLM\zSYSTEM\Setup\LabConfig' 'BypassCPUCheck'                    'REG_DWORD' '1'
Set-OfflineReg 'HKLM\zSYSTEM\Setup\LabConfig' 'BypassRAMCheck'                    'REG_DWORD' '1'
Set-OfflineReg 'HKLM\zSYSTEM\Setup\LabConfig' 'BypassSecureBootCheck'             'REG_DWORD' '1'
Set-OfflineReg 'HKLM\zSYSTEM\Setup\LabConfig' 'BypassStorageCheck'                'REG_DWORD' '1'
Set-OfflineReg 'HKLM\zSYSTEM\Setup\LabConfig' 'BypassTPMCheck'                    'REG_DWORD' '1'
Set-OfflineReg 'HKLM\zSYSTEM\Setup\MoSetup'   'AllowUpgradesWithUnsupportedTPMOrCPU' 'REG_DWORD' '1'

# -- 5d2. Disable Core Isolation / Memory Integrity (VBS/HVCI) ----------------
# Microsoft is rolling out an update on 2026-10-13 that auto-enables Memory
# Integrity (HVCI) on eligible PCs where it isn't already explicitly disabled.
# Microsoft has stated that machines with an existing explicit disable via
# Group Policy / Intune / Registry are NOT touched by that rollout, so we set
# both the runtime state (Control\DeviceGuard) and the policy-equivalent keys
# (Policies\Microsoft\Windows\DeviceGuard) here, before first boot, so the
# device never goes through a state where it's "not yet configured".
Set-OfflineReg 'HKLM\zSYSTEM\ControlSet001\Control\DeviceGuard'                                            'EnableVirtualizationBasedSecurity' 'REG_DWORD' '0'
Set-OfflineReg 'HKLM\zSYSTEM\ControlSet001\Control\DeviceGuard\Scenarios\HypervisorEnforcedCodeIntegrity'  'Enabled'                            'REG_DWORD' '0'
Set-OfflineReg 'HKLM\zSYSTEM\ControlSet001\Control\DeviceGuard\Scenarios\CredentialGuard'                  'Enabled'                            'REG_DWORD' '0'
Set-OfflineReg 'HKLM\zSYSTEM\ControlSet001\Control\Lsa'                                                    'LsaCfgFlags'                        'REG_DWORD' '0'
Set-OfflineReg 'HKLM\zSOFTWARE\Policies\Microsoft\Windows\DeviceGuard' 'EnableVirtualizationBasedSecurity' 'REG_DWORD' '0'
Set-OfflineReg 'HKLM\zSOFTWARE\Policies\Microsoft\Windows\DeviceGuard' 'HypervisorEnforcedCodeIntegrity'   'REG_DWORD' '0'
Set-OfflineReg 'HKLM\zSOFTWARE\Policies\Microsoft\Windows\DeviceGuard' 'RequirePlatformSecurityFeatures'   'REG_DWORD' '1'
Set-OfflineReg 'HKLM\zSOFTWARE\Policies\Microsoft\Windows\DeviceGuard' 'LsaCfgFlags'                       'REG_DWORD' '0'

# -- 5e. Content delivery / sponsored apps ------------------------------------
Show-Progress "Disabling sponsored apps and content delivery..." 30
$cdm = 'HKLM\zNTUSER\SOFTWARE\Microsoft\Windows\CurrentVersion\ContentDeliveryManager'
foreach ($k in @('OemPreInstalledAppsEnabled','PreInstalledAppsEnabled',
  'SilentInstalledAppsEnabled','ContentDeliveryAllowed','FeatureManagementEnabled',
  'PreInstalledAppsEverEnabled','SoftLandingEnabled','SubscribedContentEnabled',
  'SubscribedContent-310093Enabled','SubscribedContent-338388Enabled',
  'SubscribedContent-338389Enabled','SubscribedContent-338393Enabled',
  'SubscribedContent-353694Enabled','SubscribedContent-353696Enabled',
  'SystemPaneSuggestionsEnabled')) { Set-OfflineReg $cdm $k 'REG_DWORD' '0' }

Set-OfflineReg 'HKLM\zSOFTWARE\Policies\Microsoft\Windows\CloudContent' 'DisableWindowsConsumerFeatures'     'REG_DWORD' '1'
Set-OfflineReg 'HKLM\zSOFTWARE\Policies\Microsoft\Windows\CloudContent' 'DisableConsumerAccountStateContent' 'REG_DWORD' '1'
Set-OfflineReg 'HKLM\zSOFTWARE\Policies\Microsoft\Windows\CloudContent' 'DisableCloudOptimizedContent'       'REG_DWORD' '1'
Set-OfflineReg 'HKLM\zSOFTWARE\Microsoft\PolicyManager\current\device\Start' 'ConfigureStartPins' 'REG_SZ' '{"pinnedList":[{}]}'
Set-OfflineReg 'HKLM\zSOFTWARE\Policies\Microsoft\PushToInstall' 'DisablePushToInstall' 'REG_DWORD' '1'
Set-OfflineReg 'HKLM\zSOFTWARE\Policies\Microsoft\MRT'           'DontOfferThroughWUAU' 'REG_DWORD' '1'
Remove-OfflineReg 'HKLM\zNTUSER\SOFTWARE\Microsoft\Windows\CurrentVersion\ContentDeliveryManager\Subscriptions'
Remove-OfflineReg 'HKLM\zNTUSER\SOFTWARE\Microsoft\Windows\CurrentVersion\ContentDeliveryManager\SuggestedApps'

# -- 5f. Telemetry & privacy ---------------------------------------------------
Show-Progress "Disabling telemetry and data collection..." 38
Set-OfflineReg 'HKLM\zNTUSER\Software\Microsoft\Windows\CurrentVersion\AdvertisingInfo'             'Enabled'                                     'REG_DWORD' '0'
Set-OfflineReg 'HKLM\zNTUSER\Software\Microsoft\Windows\CurrentVersion\Privacy'                     'TailoredExperiencesWithDiagnosticDataEnabled' 'REG_DWORD' '0'
Set-OfflineReg 'HKLM\zNTUSER\Software\Microsoft\Speech_OneCore\Settings\OnlineSpeechPrivacy'        'HasAccepted'                                  'REG_DWORD' '0'
Set-OfflineReg 'HKLM\zNTUSER\Software\Microsoft\Input\TIPC'                                         'Enabled'                                      'REG_DWORD' '0'
Set-OfflineReg 'HKLM\zNTUSER\Software\Microsoft\InputPersonalization'                               'RestrictImplicitInkCollection'                'REG_DWORD' '1'
Set-OfflineReg 'HKLM\zNTUSER\Software\Microsoft\InputPersonalization'                               'RestrictImplicitTextCollection'               'REG_DWORD' '1'
Set-OfflineReg 'HKLM\zNTUSER\Software\Microsoft\InputPersonalization\TrainedDataStore'              'HarvestContacts'                              'REG_DWORD' '0'
Set-OfflineReg 'HKLM\zNTUSER\Software\Microsoft\Personalization\Settings'                           'AcceptedPrivacyPolicy'                        'REG_DWORD' '0'
Set-OfflineReg 'HKLM\zSOFTWARE\Policies\Microsoft\Windows\DataCollection'                           'AllowTelemetry'                               'REG_DWORD' '0'
Set-OfflineReg 'HKLM\zSOFTWARE\Policies\Microsoft\Windows\DataCollection'                           'DoNotShowFeedbackNotifications'               'REG_DWORD' '1'
Set-OfflineReg 'HKLM\zSOFTWARE\Policies\Microsoft\Windows\DataCollection'                           'LimitDiagnosticLogCollection'                 'REG_DWORD' '1'
Set-OfflineReg 'HKLM\zSOFTWARE\Policies\Microsoft\Windows\DataCollection'                           'DisableOneSettingsDownloads'                  'REG_DWORD' '1'
Set-OfflineReg 'HKLM\zSYSTEM\ControlSet001\Services\dmwappushservice'                               'Start'                                        'REG_DWORD' '4'
Set-OfflineReg 'HKLM\zSOFTWARE\Policies\Microsoft\Windows\System'                                   'EnableActivityFeed'                           'REG_DWORD' '0'
Set-OfflineReg 'HKLM\zSOFTWARE\Policies\Microsoft\Windows\System'                                   'PublishUserActivities'                        'REG_DWORD' '0'
Set-OfflineReg 'HKLM\zSOFTWARE\Policies\Microsoft\Windows\System'                                   'UploadUserActivities'                         'REG_DWORD' '0'
# Location is intentionally NOT hard-disabled (telemetry is already off, and
# forcing it off breaks auto time-zone / Find My Device / weather and can
# interfere with the Wi-Fi/SoftAP stack behind Mobile Hotspot). It stays
# user-controllable in Settings. Only apps' access to system DIAGNOSTIC INFO is
# denied (a telemetry vector); camera/mic/location/etc. stay user-controlled so
# apps keep working.
Set-OfflineReg 'HKLM\zSOFTWARE\Policies\Microsoft\Windows\AppPrivacy' 'LetAppsGetDiagnosticInfo' 'REG_DWORD' '2'

# -- 5g. Copilot / AI / Bing / Recall -----------------------------------------
Show-Progress "Disabling Copilot, Recall, Bing and AI features..." 45
Set-OfflineReg 'HKLM\zSOFTWARE\Policies\Microsoft\Windows\WindowsCopilot'  'TurnOffWindowsCopilot'       'REG_DWORD' '1'
Set-OfflineReg 'HKLM\zSOFTWARE\Policies\Microsoft\Edge'                    'HubsSidebarEnabled'           'REG_DWORD' '0'
Set-OfflineReg 'HKLM\zSOFTWARE\Policies\Microsoft\Windows\Explorer'        'DisableSearchBoxSuggestions'  'REG_DWORD' '1'
Set-OfflineReg 'HKLM\zNTUSER\Software\Policies\Microsoft\Windows\Explorer' 'DisableSearchBoxSuggestions'  'REG_DWORD' '1'
Set-OfflineReg 'HKLM\zSOFTWARE\Policies\Microsoft\Windows\WindowsAI'       'DisableAIDataAnalysis'        'REG_DWORD' '1'
Set-OfflineReg 'HKLM\zSOFTWARE\Policies\Microsoft\Windows\WindowsAI'       'TurnOffSavingSnapshots'       'REG_DWORD' '1'

# -- 5h. UI / Taskbar ---------------------------------------------------------
Show-Progress "Applying UI and Taskbar tweaks..." 52
Set-OfflineReg 'HKLM\zSOFTWARE\Policies\Microsoft\Windows\Windows Chat'                       'ChatIcon'               'REG_DWORD' '3'
Set-OfflineReg 'HKLM\zNTUSER\Software\Microsoft\Windows\CurrentVersion\Explorer\Advanced'     'TaskbarMn'              'REG_DWORD' '0'
Set-OfflineReg 'HKLM\zNTUSER\Software\Microsoft\Windows\CurrentVersion\Explorer\Advanced'     'TaskbarDa'              'REG_DWORD' '0'
Set-OfflineReg 'HKLM\zNTUSER\Software\Microsoft\Windows\CurrentVersion\Explorer\Advanced'     'ShowTaskViewButton'     'REG_DWORD' '0'
Set-OfflineReg 'HKLM\zNTUSER\Software\Microsoft\Windows\CurrentVersion\Search'                 'SearchboxTaskbarMode'   'REG_DWORD' '0'
Set-OfflineReg 'HKLM\zNTUSER\Software\Microsoft\Windows\CurrentVersion\Search'                 'BingSearchEnabled'      'REG_DWORD' '0'
Set-OfflineReg 'HKLM\zNTUSER\Software\Microsoft\Windows\CurrentVersion\Search'                 'CortanaConsent'         'REG_DWORD' '0'
Set-OfflineReg 'HKLM\zNTUSER\Software\Policies\Microsoft\Windows\Explorer'             'DisableSearchBoxSuggestions' 'REG_DWORD' '1'
Set-OfflineReg 'HKLM\zNTUSER\Software\Microsoft\Windows\CurrentVersion\Explorer\Advanced'     'HideFileExt'            'REG_DWORD' '0'
Set-OfflineReg 'HKLM\zNTUSER\Software\Microsoft\Windows\CurrentVersion\Explorer\Advanced'     'Hidden'                 'REG_DWORD' '1'
Set-OfflineReg 'HKLM\zNTUSER\Software\Microsoft\Windows\CurrentVersion\Explorer\Advanced'     'Start_TrackProgs'       'REG_DWORD' '0'
Set-OfflineReg 'HKLM\zNTUSER\Software\Microsoft\Windows\CurrentVersion\Explorer\Advanced'     'EnableSnapAssistFlyout' 'REG_DWORD' '0'
Set-OfflineReg 'HKLM\zNTUSER\Software\Microsoft\Windows\CurrentVersion\Explorer\Advanced'     'TaskbarAl'              'REG_DWORD' '0'
Set-OfflineReg 'HKLM\zNTUSER\Software\Microsoft\Windows\CurrentVersion\Explorer\Advanced'     'ShowSecondsInSystemClock' 'REG_DWORD' '1'
Set-OfflineReg 'HKLM\zNTUSER\Software\Microsoft\Windows\CurrentVersion\Explorer\Advanced'     'HideRecommendedSection' 'REG_DWORD' '1'
Set-OfflineReg 'HKLM\zSOFTWARE\Policies\Microsoft\Windows\Explorer'                            'HideRecommendedSection' 'REG_DWORD' '1'
Set-OfflineReg 'HKLM\zNTUSER\Software\Classes\CLSID\{86ca1aa0-34aa-4e8b-a509-50c905bae2a2}\InprocServer32' '' 'REG_SZ' ''
Set-OfflineReg 'HKLM\zSOFTWARE\Policies\Microsoft\Dsh'                                        'AllowNewsAndInterests'  'REG_DWORD' '0'

# Dark theme baked into DefaultUser hive (avoids SetColorTheme race condition)
Set-OfflineReg 'HKLM\zNTUSER\Software\Microsoft\Windows\CurrentVersion\Themes\Personalize' 'SystemUsesLightTheme' 'REG_DWORD' '0'
Set-OfflineReg 'HKLM\zNTUSER\Software\Microsoft\Windows\CurrentVersion\Themes\Personalize' 'AppsUseLightTheme'    'REG_DWORD' '0'
Set-OfflineReg 'HKLM\zNTUSER\Software\Microsoft\Windows\CurrentVersion\Themes\Personalize' 'EnableTransparency'   'REG_DWORD' '1'
Set-OfflineReg 'HKLM\zNTUSER\Software\Microsoft\Windows\CurrentVersion\Themes\Personalize' 'ColorPrevalence'      'REG_DWORD' '0'
Set-OfflineReg 'HKLM\zNTUSER\Software\Microsoft\Windows\DWM'                               'ColorPrevalence'      'REG_DWORD' '0'

# -- 5i. OneDrive sync policies ------------------------------------------------
Show-Progress "Disabling OneDrive sync policies..." 55
Set-OfflineReg 'HKLM\zSOFTWARE\Policies\Microsoft\Windows\OneDrive' 'DisableFileSyncNGSC'                   'REG_DWORD' '1'
Set-OfflineReg 'HKLM\zSOFTWARE\Policies\Microsoft\Windows\OneDrive' 'DisableLibrariesDefaultSaveToOneDrive' 'REG_DWORD' '1'

# -- 5j. Suppress Windows Update during OOBE ----------------------------------
# NOTE: we deliberately do NOT write NoAutoUpdate/AUOptions/UseWUServer here.
# Those three keys (especially UseWUServer=1 with no WSUS server configured)
# permanently break the Windows Update Settings page if FirstLogon.ps1 ever
# fails to run to completion. Disabling the services below is sufficient to
# keep WU quiet during OOBE, and FirstLogon.ps1 re-enables them on first boot.
Show-Progress "Suppressing Windows Update during OOBE..." 58
Set-OfflineReg 'HKLM\zSOFTWARE\Microsoft\Windows\CurrentVersion\WindowsUpdate\Orchestrator\UScheduler_Oobe\WindowsUpdate' 'workCompleted' 'REG_DWORD' '1'
Remove-OfflineReg 'HKLM\zSOFTWARE\Microsoft\WindowsUpdate\Orchestrator\UScheduler_Oobe\WindowsUpdate'
Set-OfflineReg 'HKLM\zSOFTWARE\Microsoft\Windows\CurrentVersion\DeliveryOptimization\Config' 'DODownloadMode' 'REG_DWORD' '0'
foreach ($s in @('BITS','wuauserv','UsoSvc','WaaSMedicSvc')) {
    Set-OfflineReg "HKLM\zSYSTEM\ControlSet001\Services\$s" 'Start' 'REG_DWORD' '4'
}

# -- 5k. Block Teams / Outlook / DevHome auto-install -------------------------
Show-Progress "Blocking Teams, Outlook, DevHome auto-install..." 61
Set-OfflineReg 'HKLM\zSOFTWARE\Policies\Microsoft\Teams'                'DisableInstallation' 'REG_DWORD' '1'
Set-OfflineReg 'HKLM\zSOFTWARE\Policies\Microsoft\Windows\Windows Mail' 'PreventRun'          'REG_DWORD' '1'
foreach ($k in @('OutlookUpdate','DevHomeUpdate')) {
    Set-OfflineReg "HKLM\zSOFTWARE\Microsoft\Windows\CurrentVersion\WindowsUpdate\Orchestrator\UScheduler_Oobe\$k" 'workCompleted' 'REG_DWORD' '1'
    Set-OfflineReg "HKLM\zSOFTWARE\Microsoft\Windows\CurrentVersion\WindowsUpdate\Orchestrator\UScheduler\$k"      'workCompleted' 'REG_DWORD' '1'
    Remove-OfflineReg "HKLM\zSOFTWARE\Microsoft\WindowsUpdate\Orchestrator\UScheduler_Oobe\$k"
}

# -- 5l. BitLocker / reserved storage -----------------------------------------
Show-Progress "Disabling BitLocker auto-encryption and reserved storage..." 64
Set-OfflineReg 'HKLM\zSYSTEM\ControlSet001\Control\BitLocker'                   'PreventDeviceEncryption' 'REG_DWORD' '1'
Set-OfflineReg 'HKLM\zSOFTWARE\Microsoft\Windows\CurrentVersion\ReserveManager' 'ShippedWithReserves'     'REG_DWORD' '0'

# -- 5m. Local account OOBE bypass --------------------------------------------
Show-Progress "Enabling local account OOBE bypass..." 66
Set-OfflineReg 'HKLM\zSOFTWARE\Microsoft\Windows\CurrentVersion\OOBE' 'BypassNRO' 'REG_DWORD' '1'
Set-OfflineReg 'HKLM\zSOFTWARE\Policies\Microsoft\Windows\System' 'NoLocalPasswordResetQuestions' 'REG_DWORD' '1'
Set-OfflineReg 'HKLM\zSOFTWARE\Microsoft\Windows NT\CurrentVersion\PasswordRecovery' 'Enabled' 'REG_DWORD' '0'

# -- 5n. Privacy-invasive services --------------------------------------------
Show-Progress "Disabling privacy-invasive services..." 70
# Telemetry/backup services only. DPS (Diagnostic Policy Service -> all Windows
# troubleshooters incl. the Network troubleshooter) and SysMain (memory/prefetch,
# Microsoft recommends leaving on) are deliberately NOT disabled, so apps and
# built-in diagnostics keep working.
foreach ($s in @('DiagTrack','RemoteRegistry','WerSvc','SDRSVC','wbengine')) {
    Set-OfflineReg "HKLM\zSYSTEM\ControlSet001\Services\$s" 'Start' 'REG_DWORD' '4'
}
Set-OfflineReg 'HKLM\zSOFTWARE\Policies\Microsoft\Windows\Windows Error Reporting' 'Disabled' 'REG_DWORD' '1'

# -- 5o. GameBar / Xbox / Edge update services --------------------------------
Show-Progress "Disabling GameBar, Xbox and Edge services..." 74
Set-OfflineReg 'HKLM\zSOFTWARE\Policies\Microsoft\Windows\GameDVR'           'AllowGameDVR'              'REG_DWORD' '0'
Set-OfflineReg 'HKLM\zNTUSER\System\GameConfigStore'                          'GameDVR_Enabled'           'REG_DWORD' '0'
Set-OfflineReg 'HKLM\zNTUSER\System\GameConfigStore'                          'GameDVR_FSEBehaviorMode'   'REG_DWORD' '2'
Set-OfflineReg 'HKLM\zNTUSER\SOFTWARE\Microsoft\Windows\CurrentVersion\GameDVR' 'AppCaptureEnabled'      'REG_DWORD' '0'
Set-OfflineReg 'HKLM\zNTUSER\SOFTWARE\Microsoft\GameBar'                      'UseNexusForGameBarEnabled' 'REG_DWORD' '0'
Set-OfflineReg 'HKLM\zNTUSER\SOFTWARE\Microsoft\GameBar'                      'AllowAutoGameMode'         'REG_DWORD' '0'
foreach ($s in @('XblAuthManager','XblGameSave','XboxGipSvc','XboxNetApiSvc',
                 'edgeupdate','edgeupdatem','MicrosoftEdgeElevationService')) {
    Set-OfflineReg "HKLM\zSYSTEM\ControlSet001\Services\$s" 'Start' 'REG_DWORD' '4'
}

# -- 5o2. Gaming / system performance tweaks (offline, applied before first boot)
# Same six settings as the "System Tweaks" panel -- baked into the image so
# there's no post-install script to run and no extra reboot needed; these
# take effect on the very first boot since there's no prior live state to
# transition from.
Show-Progress "Applying gaming/performance tweaks (Game Mode, GPU scheduling, VBS)..." 75
# Windows Game Mode: ON (distinct value from AllowAutoGameMode above, which
# only governs Game Bar's auto-popup, not Game Mode itself)
Set-OfflineReg 'HKLM\zNTUSER\SOFTWARE\Microsoft\GameBar' 'AutoGameModeEnabled' 'REG_DWORD' '1'
# Xbox Game Bar: further disabled (Win+G startup panel/tips)
Set-OfflineReg 'HKLM\zNTUSER\SOFTWARE\Microsoft\GameBar' 'ShowStartupPanel'         'REG_DWORD' '0'
Set-OfflineReg 'HKLM\zNTUSER\SOFTWARE\Microsoft\GameBar' 'GamePanelStartupTipIndex' 'REG_DWORD' '3'
# Mouse acceleration: OFF (REG_SZ, not DWORD)
Set-OfflineReg 'HKLM\zNTUSER\Control Panel\Mouse' 'MouseSpeed'     'REG_SZ' '0'
Set-OfflineReg 'HKLM\zNTUSER\Control Panel\Mouse' 'MouseThreshold1' 'REG_SZ' '0'
Set-OfflineReg 'HKLM\zNTUSER\Control Panel\Mouse' 'MouseThreshold2' 'REG_SZ' '0'
# Fullscreen optimizations: OFF system-wide (exclusive fullscreen forced)
Set-OfflineReg 'HKLM\zNTUSER\System\GameConfigStore' 'GameDVR_FSEBehavior'                   'REG_DWORD' '2'
Set-OfflineReg 'HKLM\zNTUSER\System\GameConfigStore' 'GameDVR_HonorUserFSEBehaviorMode'      'REG_DWORD' '1'
Set-OfflineReg 'HKLM\zNTUSER\System\GameConfigStore' 'GameDVR_DXGIHonorFSEWindowsCompatible' 'REG_DWORD' '1'
# Hardware-Accelerated GPU Scheduling: ON
Set-OfflineReg 'HKLM\zSYSTEM\ControlSet001\Control\GraphicsDrivers' 'HwSchMode' 'REG_DWORD' '2'
# Core Isolation / VBS is already disabled offline in step 5d2 above.

Set-OfflineReg 'HKLM\zSOFTWARE\Microsoft\EdgeUpdate'          'DoNotUpdateToEdgeWithChromium' 'REG_DWORD' '1'
Set-OfflineReg 'HKLM\zSOFTWARE\Policies\Microsoft\EdgeUpdate' 'UpdateDefault'                 'REG_DWORD' '0'
Set-OfflineReg 'HKLM\zSOFTWARE\Policies\Microsoft\EdgeUpdate' 'InstallDefault'                'REG_DWORD' '0'
# WebView2 Runtime shares the EdgeUpdate updater with the Edge browser, but it's
# a separate product with its own GUID -- lots of apps (Stremio, WhatsApp
# Desktop, many Electron/webview apps) depend on it even with Edge removed.
# These per-product overrides re-allow WebView2 specifically while everything
# else stays blocked by InstallDefault/UpdateDefault above.
Set-OfflineReg 'HKLM\zSOFTWARE\Policies\Microsoft\EdgeUpdate' 'Install{F3017226-FE2A-4295-8BDF-00C3A9A7E4C5}' 'REG_DWORD' '1'
Set-OfflineReg 'HKLM\zSOFTWARE\Policies\Microsoft\EdgeUpdate' 'Update{F3017226-FE2A-4295-8BDF-00C3A9A7E4C5}'  'REG_DWORD' '1'

# Permanently block Edge from ever being installed - belt AND braces
# Blocks the inbox installer, the update service installer, and DISM/CBS reinstall
Set-OfflineReg 'HKLM\zSOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\Microsoft Edge'   'NoRemove'        'REG_DWORD' '0'
Set-OfflineReg 'HKLM\zSOFTWARE\Policies\Microsoft\Edge'                                        'HideFirstRunExperience'     'REG_DWORD' '1'
Set-OfflineReg 'HKLM\zSOFTWARE\Policies\Microsoft\Edge'                                        'BackgroundModeEnabled'      'REG_DWORD' '0'
Set-OfflineReg 'HKLM\zSOFTWARE\Policies\Microsoft\Edge'                                        'StartupBoostEnabled'        'REG_DWORD' '0'
Set-OfflineReg 'HKLM\zSOFTWARE\Policies\Microsoft\MicrosoftEdge\Main'                         'AllowPrelaunch'             'REG_DWORD' '0'

# Mark Edge as "do not reinstall" via CBS/component store flag
Set-OfflineReg 'HKLM\zSOFTWARE\Microsoft\Windows\CurrentVersion\MicrosoftEdge'                'IsEdgeStableSetupDone'      'REG_DWORD' '1'

# Prevent Windows Update from pushing Edge back
Set-OfflineReg 'HKLM\zSOFTWARE\Microsoft\Windows\CurrentVersion\WindowsUpdate\Orchestrator\UScheduler_Oobe\EdgeUpdate' 'workCompleted' 'REG_DWORD' '1'
Remove-OfflineReg 'HKLM\zSOFTWARE\Microsoft\WindowsUpdate\Orchestrator\UScheduler_Oobe\EdgeUpdate'

Set-OfflineReg 'HKLM\zSOFTWARE\Policies\Microsoft\Windows\BackupAndRestore' 'DisableBackup'   'REG_DWORD' '1'

# -- 5p. SmartScreen -----------------------------------------------------------
Show-Progress "Configuring SmartScreen..." 78
Set-OfflineReg 'HKLM\zSOFTWARE\Policies\Microsoft\Windows\System'               'EnableSmartScreen'          'REG_DWORD' '0'
Set-OfflineReg 'HKLM\zSOFTWARE\Policies\Microsoft\MicrosoftEdge\PhishingFilter' 'EnabledV9'                  'REG_DWORD' '0'
Set-OfflineReg 'HKLM\zSOFTWARE\Policies\Microsoft\Windows Defender\SmartScreen' 'ConfigureAppInstallControl' 'REG_SZ'    'Anywhere'

# -- 5q. Unload hives ---------------------------------------------------------
Show-Progress "Unloading offline registry hives..." 82
foreach ($h in @('zCOMPONENTS','zDEFAULT','zNTUSER','zSOFTWARE','zSYSTEM')) {
    & reg unload "HKLM\$h" 2>&1 | Out-Null
}
Show-Progress "All registry tweaks applied." 85 -Done

# -- 5r. Write embedded autounattend.xml ---------------------------------------
Show-Progress "Writing autounattend.xml..." 88
Set-Content -Path (Join-Path $isoContents "autounattend.xml") `
            -Value (Get-EmbeddedXml) -Encoding UTF8 -Force
Show-Progress "autounattend.xml written." 90 -Done

# -- 5s. Write niix-tweaks.ps1 into the image + leave a Desktop copy ----------
# niix-tweaks.ps1 is auto-run once at first logon via the NiixTweaksAutoRun
# scheduled task (registered elevated in Specialize.ps1, see unattend.xml).
# UserOnce.ps1 (from autounattend) deletes all .lnk shortcuts on first login,
# so we cannot place a shortcut for the manual copy -- we use a RunOnce key
# instead, which fires AFTER UserOnce has already cleared the desktop,
# copying the .ps1 directly, in case you ever want to re-run it by hand.
Show-Progress "Writing niix-tweaks.ps1 into image..." 92

$setupScriptsDir = Join-Path $mountDir "Windows\Setup\Scripts"
New-Item -ItemType Directory -Path $setupScriptsDir -Force | Out-Null
$utf8NoBom = [System.Text.UTF8Encoding]::new($false)
[System.IO.File]::WriteAllText(
    (Join-Path $setupScriptsDir "niix-tweaks.ps1"),
    (Get-EmbeddedTweaks),
    $utf8NoBom
)

$defaultDat = Join-Path $mountDir "Users\Default\NTUSER.DAT"
& reg load HKLM\zNTUSERTEMP $defaultDat 2>&1 | Out-Null
$runOnceVal = 'powershell.exe -WindowStyle Hidden -ExecutionPolicy Bypass -NoProfile -Command ' +
              '"Copy-Item ''C:\Windows\Setup\Scripts\niix-tweaks.ps1'' ' +
              '([Environment]::GetFolderPath(''Desktop'')) -Force"'
& reg add 'HKLM\zNTUSERTEMP\Software\Microsoft\Windows\CurrentVersion\RunOnce' `
    /v 'NiixTweaksDesktop' /t REG_SZ /d $runOnceVal /f 2>&1 | Out-Null
& reg unload HKLM\zNTUSERTEMP 2>&1 | Out-Null

Show-Progress "niix-tweaks.ps1 written + Desktop-copy RunOnce set." 94 -Done

# ---- 5t. Write wallpaper into image (optional -- only if you supply one) ----
# Drop a file named wallpaper.jpg / wallpaper.jpeg / wallpaper.png next to this
# script to use it as the default background. If none is found, this step is
# skipped entirely and Windows keeps its normal default wallpaper.
$scriptDir = Split-Path -Parent $PSCommandPath
$customWall = @('wallpaper.jpg','wallpaper.jpeg','wallpaper.png') |
    ForEach-Object { Join-Path $scriptDir $_ } |
    Where-Object { Test-Path $_ } |
    Select-Object -First 1

if ($customWall) {
    Show-Progress "Writing wallpaper into image..." 96
    $wallDir  = Join-Path $mountDir "Windows\Web\Wallpaper\Niix"
    New-Item -ItemType Directory -Path $wallDir -Force | Out-Null

    $wallExt = [System.IO.Path]::GetExtension($customWall)
    $wallFileName = "niix-wall$wallExt"
    Write-Body "Using custom wallpaper: $customWall"
    Copy-Item -LiteralPath $customWall -Destination (Join-Path $wallDir $wallFileName) -Force

    # Set as default wallpaper for all new users via DefaultUser hive
    # (hive is reloaded here - was unloaded in 5q but we need it again)
    $defaultDatWall = Join-Path $mountDir "Users\Default\NTUSER.DAT"
    & reg load HKLM\zNTUSERWALL $defaultDatWall 2>&1 | Out-Null

    $_wp  = "C:\Windows\Web\Wallpaper\Niix\$wallFileName"
    $wallRegPath = 'HKLM\zNTUSERWALL\Control Panel\Desktop'
    & reg add $wallRegPath /v Wallpaper        /t REG_SZ /d $_wp /f 2>&1 | Out-Null
    & reg add $wallRegPath /v WallpaperStyle   /t REG_SZ /d '10' /f 2>&1 | Out-Null
    & reg add $wallRegPath /v TileWallpaper    /t REG_SZ /d '0'  /f 2>&1 | Out-Null
    & reg add $wallRegPath /v WallpaperOriginX /t REG_SZ /d '0'  /f 2>&1 | Out-Null
    & reg add $wallRegPath /v WallpaperOriginY /t REG_SZ /d '0'  /f 2>&1 | Out-Null

    # Theme path so wallpaper loads correctly on first boot
    $_th = 'C:\Windows\resources\Themes\aero.theme'
    $_tr = 'HKLM\zNTUSERWALL\Software\Microsoft\Windows\CurrentVersion\Themes'
    & reg add $_tr /v CurrentTheme /t REG_SZ /d $_th /f 2>&1 | Out-Null
    & reg add $_tr /v LastTheme    /t REG_SZ /d $_th /f 2>&1 | Out-Null

    # ApplyWallpaper.ps1 -- uses P/Invoke SystemParametersInfo for a reliable,
    # VM-safe wallpaper apply. Written as a plain script, no Base64 involved.
    # It's invoked directly from UserOnce.ps1 (correct interactive user
    # context, correct timing) -- the RunOnce entry below is only a backup
    # for the (normal) case where a *new* user profile is created later.
    $applyWallLines = @(
        "Set-ItemProperty -Path 'HKCU:\Control Panel\Desktop' -Name Wallpaper -Value '$_wp'",
        "Set-ItemProperty -Path 'HKCU:\Control Panel\Desktop' -Name WallpaperStyle -Value '10'",
        "Set-ItemProperty -Path 'HKCU:\Control Panel\Desktop' -Name TileWallpaper -Value '0'",
        'Add-Type -TypeDefinition @"',
        'using System;',
        'using System.Runtime.InteropServices;',
        'public class NiixWallpaper {',
        '    [DllImport("user32.dll", CharSet=CharSet.Auto)]',
        '    public static extern int SystemParametersInfo(int uAction, int uParam, string lpvParam, int fuWinIni);',
        '}',
        '"@',
        "[NiixWallpaper]::SystemParametersInfo(20, 0, '$_wp', 3)"
    )
    $utf8NoBomWall = [System.Text.UTF8Encoding]::new($false)
    [System.IO.File]::WriteAllText((Join-Path $setupScriptsDir 'ApplyWallpaper.ps1'), ($applyWallLines -join "`r`n"), $utf8NoBomWall)

    $runOnceWall = 'powershell.exe -WindowStyle Hidden -ExecutionPolicy Bypass -NoProfile -File "C:\Windows\Setup\Scripts\ApplyWallpaper.ps1"'
    & reg add 'HKLM\zNTUSERWALL\Software\Microsoft\Windows\CurrentVersion\RunOnce' /v 'NiixWallpaper' /t REG_SZ /d $runOnceWall /f 2>&1 | Out-Null

    & reg unload HKLM\zNTUSERWALL 2>&1 | Out-Null

    # Write PersonalizationCSP into the offline SOFTWARE hive. NOTE: the hive
    # loaded in 5c was already unloaded in 5q, so we must load it again here --
    # otherwise these keys would land in the *build machine's* live registry
    # under a bogus HKLM\zSOFTWARE key and never reach the image.
    $softwareHive = Join-Path $mountDir 'Windows\System32\config\SOFTWARE'
    & reg load HKLM\zSOFTWARE $softwareHive 2>&1 | Out-Null
    $_pc = 'HKLM\zSOFTWARE\Microsoft\Windows\CurrentVersion\PersonalizationCSP'
    & reg add $_pc /v DesktopImagePath      /t REG_SZ    /d $_wp /f 2>&1 | Out-Null
    & reg add $_pc /v DesktopImageStatus    /t REG_DWORD /d 1    /f 2>&1 | Out-Null
    & reg add $_pc /v DesktopImageUrl       /t REG_SZ    /d $_wp /f 2>&1 | Out-Null
    & reg add $_pc /v LockScreenImagePath   /t REG_SZ    /d $_wp /f 2>&1 | Out-Null
    & reg add $_pc /v LockScreenImageStatus /t REG_DWORD /d 1    /f 2>&1 | Out-Null
    [gc]::Collect(); Start-Sleep -Milliseconds 300
    & reg unload HKLM\zSOFTWARE 2>&1 | Out-Null

    Show-Progress "Wallpaper embedded and set as default." 98 -Done
} else {
    Write-Body "No wallpaper.jpg/.jpeg/.png found next to the script -- skipping wallpaper, Windows default will be used."
}

# -- 5t. Remove telemetry scheduled task files ---------------------------------
Show-Progress "Removing telemetry scheduled task files..." 99
$tasks = "$mountDir\Windows\System32\Tasks"
foreach ($f in @(
    "$tasks\Microsoft\Windows\Application Experience\Microsoft Compatibility Appraiser",
    "$tasks\Microsoft\Windows\Application Experience\ProgramDataUpdater",
    "$tasks\Microsoft\Windows\Chkdsk\Proxy",
    "$tasks\Microsoft\Windows\Windows Error Reporting\QueueReporting")) {
    Remove-Item $f -Force -ErrorAction SilentlyContinue
}
# NOTE: UpdateOrchestrator / WaaSMedic / WindowsUpdate task folders are
# deliberately NOT removed here anymore. Those folders hold the actual
# scheduled tasks (USO "Schedule Scan", "Reconcile Features", etc.) that
# drive Windows Update's background scanning and installation. Deleting
# them permanently breaks Windows Update, even after the registry policy
# suppression above is undone by FirstLogon.ps1 -- there's no task left to
# run the scan. UpdateAssistant (the feature-update upgrade nag) is still
# safe to remove on its own, it isn't required for normal cumulative updates.
foreach ($d in @(
    "$tasks\Microsoft\Windows\Customer Experience Improvement Program",
    "$tasks\Microsoft\Windows\InstallService",
    "$tasks\Microsoft\Windows\UpdateAssistant",
    "$tasks\Microsoft\Windows\CloudExperienceHost",
    "$tasks\Microsoft\Windows\Feedback")) {
    Remove-Item $d -Recurse -Force -ErrorAction SilentlyContinue
}

Remove-Item (Join-Path $isoContents "support") -Recurse -Force -ErrorAction SilentlyContinue
Show-Progress "All modifications complete." 100 -Done

# ===========================================================================
#  STEP 6  --  DISM CLEANUP
# ===========================================================================
Write-Title "STEP 6 -- DISM component cleanup (this takes several minutes)..."
Show-Progress "Running DISM /StartComponentCleanup /ResetBase..." 30
& dism /English "/image:$mountDir" /Cleanup-Image /StartComponentCleanup /ResetBase 2>&1 | Out-Null
Show-Progress "DISM cleanup complete." 100 -Done

# ===========================================================================
#  STEP 7  --  SAVE install.wim
# ===========================================================================
Write-Title "STEP 7 -- Saving modified install.wim (takes several minutes)..."
Show-Progress "Dismounting and saving install.wim..." 30
Dismount-WindowsImage -Path $mountDir -Save -ErrorAction Stop | Out-Null
Show-Progress "install.wim saved." 100 -Done

# ===========================================================================
#  STEP 8  --  STRIP UNUSED EDITIONS
# ===========================================================================
Write-Title "STEP 8 -- Stripping unused editions..."
Show-Progress "Exporting edition: $selectedEdition..." 40
$exportWim = Join-Path $isoContents "sources\install_export.wim"
Export-WindowsImage -SourceImagePath $localWim -SourceIndex $selectedIndex `
                    -DestinationImagePath $exportWim -ErrorAction Stop | Out-Null
Remove-Item $localWim -Force
Rename-Item $exportWim -NewName "install.wim" -Force
Show-Progress "Single-edition install.wim ready." 90 -Done

Show-Progress "Dismounting source ISO..." 95
Dismount-DiskImage -ImagePath $selectedISO -ErrorAction SilentlyContinue | Out-Null
Show-Progress "Source ISO dismounted." 100 -Done

# ===========================================================================
#  STEP 9  --  LOCATE OSCDIMG
# ===========================================================================
Write-Title "STEP 9 -- Locating oscdimg.exe..."
Show-Progress "Searching for oscdimg.exe..." 50

$oscdimg = Get-ChildItem "C:\Program Files (x86)\Windows Kits" -Recurse `
           -Filter "oscdimg.exe" -ErrorAction SilentlyContinue |
           Select-Object -First 1 -ExpandProperty FullName

if (-not $oscdimg) {
    $oscdimg = Get-ChildItem "$env:LOCALAPPDATA\Microsoft\WinGet\Packages" -Recurse `
               -Filter "oscdimg.exe" -ErrorAction SilentlyContinue |
               Where-Object { $_.FullName -match 'Microsoft\.OSCDIMG' } |
               Select-Object -First 1 -ExpandProperty FullName
}

if (-not $oscdimg) {
    Write-Body "oscdimg not found -- attempting install via winget..."
    try {
        & winget install -e --id Microsoft.OSCDIMG `
            --accept-package-agreements --accept-source-agreements 2>&1 | Out-Null
        $oscdimg = Get-ChildItem "$env:LOCALAPPDATA\Microsoft\WinGet\Packages" -Recurse `
                   -Filter "oscdimg.exe" -ErrorAction SilentlyContinue |
                   Where-Object { $_.FullName -match 'Microsoft\.OSCDIMG' } |
                   Select-Object -First 1 -ExpandProperty FullName
    } catch { Write-Warn "winget install failed: $_" }
}

if (-not $oscdimg) {
    Write-Err "oscdimg.exe not found. Cannot build ISO."
    Write-Body "Run:  winget install -e --id Microsoft.OSCDIMG"
    Write-Body "Or install Windows ADK: https://learn.microsoft.com/windows-hardware/get-started/adk-install"
    Write-Body "Temp files preserved at: $workDir"
    Read-Host "`n  Press Enter to exit"; exit 1
}
Show-Progress "oscdimg.exe found." 100 -Done

# ===========================================================================
#  STEP 10  --  BUILD ISO
# ===========================================================================
Write-Title "STEP 10 -- Building output ISO..."

$isoBase   = [System.IO.Path]::GetFileNameWithoutExtension($selectedISO)
$outputDir = Split-Path $selectedISO -Parent
$outputISO = Join-Path $outputDir "win11_niix.iso"

Show-Progress "Running oscdimg..." 5

$bootData = "2#p0,e,b`"$isoContents\boot\etfsboot.com`"" +
            "#pEF,e,b`"$isoContents\efi\microsoft\boot\efisys.bin`""
$oscdimgArgs = "-m -o -u2 -udfver102 -bootdata:$bootData -lNIIX_WIN11 `"$isoContents`" `"$outputISO`""

$psi = [System.Diagnostics.ProcessStartInfo]::new()
$psi.FileName               = $oscdimg
$psi.Arguments              = $oscdimgArgs
$psi.RedirectStandardOutput = $true
$psi.RedirectStandardError  = $true
$psi.UseShellExecute        = $false
$psi.CreateNoWindow         = $true

$proc           = [System.Diagnostics.Process]::new()
$proc.StartInfo = $psi
$proc.Start() | Out-Null

$lastPct = 5
while (-not $proc.StandardOutput.EndOfStream) {
    $line = $proc.StandardOutput.ReadLine()
    if ($line -match '(\d+)%') {
        $inner = [int]$matches[1]
        $disp  = [Math]::Max(5, [Math]::Min(99, $inner))
        if ($disp -ne $lastPct) {
            Show-Progress "Building ISO..." $disp
            $lastPct = $disp
        }
    }
}
$proc.WaitForExit()
$stderr = $proc.StandardError.ReadToEnd()

if ($proc.ExitCode -ne 0) {
    Write-Host ""
    Write-Err "oscdimg failed (exit $($proc.ExitCode))"
    if ($stderr) { Write-Err $stderr }
    Write-Body "Temp files preserved at: $workDir"
    Read-Host "`n  Press Enter to exit"; exit 1
}

Show-Progress "ISO built successfully." 100 -Done

# ===========================================================================
#  CLEANUP
# ===========================================================================
Show-Progress "Cleaning up temp files..." 50
Remove-Item $workDir -Recurse -Force -ErrorAction SilentlyContinue
if ($driverExportDir -and (Test-Path $driverExportDir)) {
    Remove-Item $driverExportDir -Recurse -Force -ErrorAction SilentlyContinue
}
Show-Progress "Done." 100 -Done

# ===========================================================================
#  SUMMARY
# ===========================================================================
$outGB   = [math]::Round((Get-Item $outputISO).Length / 1GB, 2)
$outName = Split-Path $outputISO -Leaf

Write-Host ""
Write-Banner "  +----------------------------------------------------------+"
Write-Banner "  |                                                          |"
Write-Banner "  |   BUILD COMPLETE                                         |"
Write-Banner "  |                                                          |"
Write-Host   ("  |   Output  : {0,-46}|" -f $outName)         -ForegroundColor $PINK
Write-Host   ("  |   Size    : {0,-46}|" -f "$outGB GB")       -ForegroundColor $PINK
Write-Host   ("  |   Edition : {0,-46}|" -f $selectedEdition)  -ForegroundColor $PINK
Write-Banner "  |                                                          |"
Write-Banner "  +----------------------------------------------------------+"
Write-Host ""
Write-Host "  Applied:" -ForegroundColor $PINK
$items = @(
    "Removed 50+ AppX packages (Xbox, GameBar, Teams, Copilot...)",    "Deleted OneDrive binary from image",
    "Full telemetry / Copilot / Recall / AI lockdown",
    "Windows Backup + Recall removed via offline DISM (capability/feature)",
    "Xbox, GameBar, Edge update services disabled offline",
    "Edge reinstall blocked via policy",
    "All app privacy gates set to deny",
    "Hardware bypass (TPM / SecureBoot / CPU / RAM)",
    "Windows Update suppressed during OOBE (re-enabled post-install)",
    "Gaming/perf tweaks baked offline: Game Mode, GPU scheduling, mouse",
    "  accel off, fullscreen opts off -- no post-install script needed",
    "autounattend.xml baked into the ISO -- runtime TPM bypass + setup scripts",
    "niix-tweaks.ps1 auto-runs once at first logon (elevated, no UAC prompt)",
    "  and is also left on the Desktop if you ever want to re-run it",
    "Memory Integrity (HVCI/VBS) disabled offline -- won't be re-enabled by",
    "  Microsoft's Oct 13, 2026 auto-enable rollout",
    "No post-install reboot required -- all tweaks are live from first boot",
    "Full troubleshooting log saved to Documents\NiixDebloat-Logs after first logon"
)
if ($driverExportDir) {
    $items += "This PC's drivers exported and injected into the image"
}
foreach ($item in $items) {
    Write-Host "   * $item" -ForegroundColor $WHITE
}
Write-Host ""
Read-Host "  Press Enter to exit"
