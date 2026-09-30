<#
.SYNOPSIS
    niixdebloat.ps1  -  All-in-one Windows 11 ISO Debloat & Privacy Hardener
.DESCRIPTION
    Reads unattend.xml and niix-tweaks.ps1 (plain text, no Base64) from the
    same folder as this script and bakes them into a customized Windows 11 ISO.
    Drop next to (or browse for) a Win11 ISO and run.
.NOTES
    Based on WinUtil by Chris Titus (@christitustech) -- customised by niix
    Runs under Windows PowerShell 5.1 (built into Windows). If started from
    PowerShell 7 or without admin rights it relaunches itself correctly.
#>

# ===========================================================================
#  SELF-ELEVATE / FORCE WINDOWS POWERSHELL 5.1
#  (DISM, Storage and AppX modules are only fully native in 5.1)
# ===========================================================================
if (-not $PSCommandPath) {
    Write-Host "Save this script to a file and run it with -File; it cannot be pasted into a console." -ForegroundColor Red
    exit 1
}
$_isAdmin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
if (-not $_isAdmin -or $PSVersionTable.PSEdition -eq 'Core') {
    $_winPS   = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
    $_argList = "-NoProfile -ExecutionPolicy Bypass -File `"$PSCommandPath`""
    if ($_isAdmin) {
        Start-Process -FilePath $_winPS -ArgumentList $_argList -NoNewWindow -Wait
    } else {
        Start-Process -FilePath $_winPS -ArgumentList $_argList -Verb RunAs
    }
    exit
}

$PINK  = 'Magenta'
$GREEN = 'Green'
$WHITE = 'White'
$RED   = 'Red'

function Write-Banner  { param([string]$t) Write-Host $t -ForegroundColor $PINK }
function Write-Title   { param([string]$t) Write-Host ""; Write-Host "  $t" -ForegroundColor $PINK; Write-Host "" }
function Write-Body    { param([string]$t) Write-Host "  $t" -ForegroundColor $WHITE }
function Write-Success { param([string]$t) Write-Host "  [OK] $t" -ForegroundColor $GREEN }
function Write-Err     { param([string]$t) Write-Host "  [ERROR] $t" -ForegroundColor $RED }
function Write-Warn    { param([string]$t) Write-Host "  [WARN] $t" -ForegroundColor Yellow }

$script:_barPct = 0

function Show-Progress {
    param([string]$Activity, [int]$Pct, [switch]$Done)
    $width = 46
    if ($Done) {
        for ($p = $script:_barPct; $p -le 100; $p += 2) {
            $f   = [int](($p / 100) * $width)
            $bar = '[' + ('#' * $f) + ('-' * ($width - $f)) + ']'
            Write-Host ("`r  $bar {0,3}%  $Activity{1}" -f $p, (' ' * 30)) -NoNewline -ForegroundColor $GREEN
            Start-Sleep -Milliseconds 6
        }
        $bar = '[' + ('#' * $width) + ']'
        Write-Host ("`r  $bar 100%  $Activity" + (' ' * 30)) -ForegroundColor $GREEN
        $script:_barPct = 0
        return
    }
    $target = [Math]::Max(0, [Math]::Min(99, $Pct))
    for ($p = $script:_barPct; $p -le $target; $p += 1) {
        $f   = [int](($p / 100) * $width)
        $bar = '[' + ('#' * $f) + ('-' * ($width - $f)) + ']'
        Write-Host ("`r  $bar {0,3}%  $Activity{1}" -f $p, (' ' * 30)) -NoNewline -ForegroundColor $GREEN
        Start-Sleep -Milliseconds 4
    }
    $script:_barPct = $target
}

function Read-Index {
    param([string]$Prompt, [int]$Count, [int]$Default = -1)
    while ($true) {
        $raw = "$(Read-Host $Prompt)".Trim()
        if ($raw -eq '' -and $Default -ge 0) { return $Default }
        $n = 0
        if ([int]::TryParse($raw, [ref]$n) -and $n -ge 1 -and $n -le $Count) { return ($n - 1) }
        Write-Warn "Enter a number between 1 and $Count."
    }
}

# Runs a console tool with stdin closed (so it can never block on a prompt)
# and stdout/stderr drained asynchronously (so it can never deadlock).
function Invoke-Quiet {
    param([string]$FilePath, [string]$Arguments)
    $psi = [System.Diagnostics.ProcessStartInfo]::new($FilePath, $Arguments)
    $psi.UseShellExecute        = $false
    $psi.CreateNoWindow         = $true
    $psi.RedirectStandardInput  = $true
    $psi.RedirectStandardOutput = $true
    $psi.RedirectStandardError  = $true
    $p = [System.Diagnostics.Process]::Start($psi)
    $p.StandardInput.Close()
    $out = $p.StandardOutput.ReadToEndAsync()
    $err = $p.StandardError.ReadToEndAsync()
    $p.WaitForExit()
    [pscustomobject]@{ ExitCode = $p.ExitCode; Output = $out.Result; Error = $err.Result }
}

# Locale-independent ownership + full control for BUILTIN\Administrators.
function Grant-AdminFullControl {
    param([string]$Path)
    if (-not (Test-Path -LiteralPath $Path)) { return }
    $recurse = if (Test-Path -LiteralPath $Path -PathType Container) { ' /R' } else { '' }
    Invoke-Quiet 'takeown.exe' ("/F `"$Path`" /A$recurse") | Out-Null
    Invoke-Quiet 'icacls.exe'  ("`"$Path`" /grant *S-1-5-32-544:(F) /T /C /Q") | Out-Null
}

# ===========================================================================
#  OFFLINE REGISTRY HELPERS
#  Values are written through the .NET registry API, not reg.exe: Windows
#  PowerShell 5.1 silently drops empty-string arguments and does not escape
#  embedded double quotes when calling native programs, which corrupted
#  several values (classic context menu, Start pins JSON, RunOnce commands).
# ===========================================================================
$script:RegWarnings = [System.Collections.Generic.List[string]]::new()
$script:LoadedHives = [System.Collections.Generic.List[string]]::new()
$script:HiveFiles   = [ordered]@{
    'NIIX_DEFAULT'  = 'Windows\System32\config\DEFAULT'
    'NIIX_NTUSER'   = 'Users\Default\NTUSER.DAT'
    'NIIX_SOFTWARE' = 'Windows\System32\config\SOFTWARE'
    'NIIX_SYSTEM'   = 'Windows\System32\config\SYSTEM'
}

function Get-RegSubPath {
    param([string]$Path)
    if ($Path -notmatch '^HKLM\\(.+)$') { throw "Unsupported registry path: $Path" }
    return $Matches[1]
}

function Set-OfflineReg {
    param([string]$p, [string]$n, [string]$t, [string]$v)
    $key = $null
    try {
        $key = [Microsoft.Win32.Registry]::LocalMachine.CreateSubKey((Get-RegSubPath $p))
        if (-not $key) { throw 'key could not be created' }
        switch ($t) {
            'REG_DWORD'     { $key.SetValue($n, [BitConverter]::ToInt32([BitConverter]::GetBytes([uint32]$v), 0), [Microsoft.Win32.RegistryValueKind]::DWord) }
            'REG_SZ'        { $key.SetValue($n, $v, [Microsoft.Win32.RegistryValueKind]::String) }
            'REG_EXPAND_SZ' { $key.SetValue($n, $v, [Microsoft.Win32.RegistryValueKind]::ExpandString) }
            default         { throw "Unsupported value type: $t" }
        }
    } catch {
        $script:RegWarnings.Add("$p\$n : $($_.Exception.Message)")
    } finally {
        if ($key) { $key.Close() }
    }
}

function Remove-OfflineReg {
    param([string]$p)
    try {
        [Microsoft.Win32.Registry]::LocalMachine.DeleteSubKeyTree((Get-RegSubPath $p), $false)
    } catch {
        $script:RegWarnings.Add("delete $p : $($_.Exception.Message)")
    }
}

function Test-OfflineKey {
    param([string]$Path)
    $k = [Microsoft.Win32.Registry]::LocalMachine.OpenSubKey((Get-RegSubPath $Path))
    if ($k) { $k.Close(); return $true }
    return $false
}

function Test-HiveLoaded {
    param([string]$Name)
    $k = [Microsoft.Win32.Registry]::LocalMachine.OpenSubKey($Name)
    if ($k) { $k.Close(); return $true }
    return $false
}

function Invoke-HiveUnload {
    param([string]$Name)
    for ($i = 0; $i -lt 10; $i++) {
        [GC]::Collect()
        [GC]::WaitForPendingFinalizers()
        $r = Invoke-Quiet 'reg.exe' "unload `"HKLM\$Name`""
        if ($r.ExitCode -eq 0) { return $true }
        Start-Sleep -Seconds 1
    }
    return $false
}

function Mount-OfflineHives {
    param([string]$ImageRoot)
    foreach ($name in $script:HiveFiles.Keys) {
        $file = Join-Path $ImageRoot $script:HiveFiles[$name]
        if (-not (Test-Path -LiteralPath $file)) { throw "Registry hive not found in image: $file" }
        $r = Invoke-Quiet 'reg.exe' "load `"HKLM\$name`" `"$file`""
        if ($r.ExitCode -ne 0) { throw "Failed to load hive $file : $($r.Error.Trim())" }
        $script:LoadedHives.Add($name)
    }
}

function Dismount-OfflineHives {
    $failed = @()
    foreach ($name in @($script:LoadedHives)) {
        if (Invoke-HiveUnload $name) { [void]$script:LoadedHives.Remove($name) } else { $failed += $name }
    }
    if ($failed.Count -gt 0) { throw "Could not unload registry hive(s): $($failed -join ', ')" }
}

# ===========================================================================
#  STATE + CLEANUP (runs on success, failure and Ctrl+C)
# ===========================================================================
$script:SelectedISO     = $null
$script:IsoMountedByUs  = $false
$script:WimMounted      = $false
$script:MountDir        = $null
$script:WorkDir         = $null
$script:DriverExportDir = $null

function Invoke-Cleanup {
    if ($script:LoadedHives.Count -gt 0) {
        try { Dismount-OfflineHives } catch { Write-Warn "$_" }
    }
    if ($script:WimMounted) {
        Write-Body "Discarding mounted image..."
        try {
            Dismount-WindowsImage -Path $script:MountDir -Discard -ErrorAction Stop | Out-Null
        } catch {
            Write-Warn "Dismount failed: $($_.Exception.Message) -- running DISM /Cleanup-Wim"
            Invoke-Quiet 'dism.exe' '/English /Cleanup-Wim' | Out-Null
        }
        $script:WimMounted = $false
    }
    if ($script:IsoMountedByUs -and $script:SelectedISO) {
        Dismount-DiskImage -ImagePath $script:SelectedISO -ErrorAction SilentlyContinue | Out-Null
        $script:IsoMountedByUs = $false
    }
    if ($script:WorkDir -and (Test-Path -LiteralPath $script:WorkDir)) {
        Remove-Item -LiteralPath $script:WorkDir -Recurse -Force -ErrorAction SilentlyContinue
    }
    if ($script:DriverExportDir -and (Test-Path -LiteralPath $script:DriverExportDir)) {
        Remove-Item -LiteralPath $script:DriverExportDir -Recurse -Force -ErrorAction SilentlyContinue
    }
}

$exitCode = 0
try {

# ===========================================================================
#  INPUT FILES (plain text, validated before anything is touched)
# ===========================================================================
$scriptDir   = Split-Path -Parent $PSCommandPath
$_xmlPath    = Join-Path $scriptDir 'unattend.xml'
$_tweaksPath = Join-Path $scriptDir 'niix-tweaks.ps1'

foreach ($req in @($_xmlPath, $_tweaksPath)) {
    if (-not (Test-Path -LiteralPath $req)) {
        throw "Required file not found: $req -- keep niixdebloat.ps1, unattend.xml and niix-tweaks.ps1 together in the same folder."
    }
}
try {
    $null = [xml](Get-Content -LiteralPath $_xmlPath -Raw -Encoding UTF8)
} catch {
    throw "unattend.xml is not valid XML: $($_.Exception.Message)"
}
$_tok = $null; $_perr = $null
[System.Management.Automation.Language.Parser]::ParseFile($_tweaksPath, [ref]$_tok, [ref]$_perr) | Out-Null
if ($_perr -and $_perr.Count -gt 0) {
    throw "niix-tweaks.ps1 has a syntax error on line $($_perr[0].Extent.StartLineNumber): $($_perr[0].Message)"
}

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
Write-Banner "  |   NN   NN  IIIII  IIIII  XX   XX  DEBLOAT  v2.1          |"
Write-Banner "  |                                                          |"
Write-Banner "  |      Windows 11 ISO Debloat & Privacy Hardener           |"
Write-Banner "  |      unattend.xml + niix-tweaks.ps1 (plain text, no B64) |"
Write-Banner "  |                                                          |"
Write-Banner "  +----------------------------------------------------------+"
Write-Banner ""

# ---- Clean up leftovers from a previous run that crashed or was closed ----
foreach ($name in $script:HiveFiles.Keys) {
    if (Test-HiveLoaded $name) { [void](Invoke-HiveUnload $name) }
}
Get-WindowsImage -Mounted -ErrorAction SilentlyContinue |
    Where-Object { $_.Path -like '*\niixdebloat_*\wim_mount' } |
    ForEach-Object { Dismount-WindowsImage -Path $_.Path -Discard -ErrorAction SilentlyContinue | Out-Null }
Invoke-Quiet 'dism.exe' '/English /Cleanup-Wim' | Out-Null
Get-ChildItem -LiteralPath $env:TEMP -Directory -Filter 'niixdebloat_*' -ErrorAction SilentlyContinue |
    Remove-Item -Recurse -Force -ErrorAction SilentlyContinue

# ---- Free space check (source export + work image + output ISO) ----
$_tempRoot = [System.IO.Path]::GetPathRoot([System.IO.Path]::GetFullPath($env:TEMP))
$_freeGB   = [math]::Round(([System.IO.DriveInfo]::new($_tempRoot)).AvailableFreeSpace / 1GB, 1)
if ($_freeGB -lt 25) {
    Write-Warn "Only $_freeGB GB free on $_tempRoot -- at least 25 GB is recommended."
    if ("$(Read-Host '  Continue anyway? [y/N]')" -notmatch '^[Yy]') { throw "Aborted: not enough free disk space." }
}

# ===========================================================================
#  STEP 0  --  DRIVER INJECTION PROMPT
# ===========================================================================
Write-Title "STEP 0 -- Driver options..."
Write-Body "Add this PC's current drivers to the ISO? Useful if the target machine is"
Write-Body "the same PC (or identical hardware) and you want networking/storage/GPU"
Write-Body "drivers working immediately after install, with no separate driver install."
Write-Host ""
$injectDrivers = "$(Read-Host '  Inject this system''s drivers into the ISO? [y/N]')" -match '^[Yy]'
if ($injectDrivers) {
    Write-Success "Drivers will be exported from this PC and injected into the image."
} else {
    Write-Body "Skipping driver injection."
}
Write-Host ""

if ($injectDrivers) {
    Show-Progress "Exporting drivers from this PC..." 5
    $script:DriverExportDir = Join-Path $env:TEMP 'niix_drivers_export'
    if (Test-Path -LiteralPath $script:DriverExportDir) { Remove-Item -LiteralPath $script:DriverExportDir -Recurse -Force -ErrorAction SilentlyContinue }
    New-Item -ItemType Directory -Path $script:DriverExportDir -Force | Out-Null
    $r = Invoke-Quiet 'dism.exe' "/English /Online /Export-Driver `"/Destination:$($script:DriverExportDir)`""
    $exportedCount = @(Get-ChildItem -LiteralPath $script:DriverExportDir -Filter '*.inf' -Recurse -File -ErrorAction SilentlyContinue).Count
    if ($r.ExitCode -eq 0 -and $exportedCount -gt 0) {
        Show-Progress "Exported $exportedCount driver package(s)." 8 -Done
    } else {
        Write-Host ""
        Write-Body "No third-party drivers exported (this PC may only use inbox drivers)."
        Remove-Item -LiteralPath $script:DriverExportDir -Recurse -Force -ErrorAction SilentlyContinue
        $script:DriverExportDir = $null
    }
}

# ===========================================================================
#  STEP 1  --  LOCATE ISO
# ===========================================================================
Write-Title "STEP 1 -- Locating ISO file..."

$isoFiles = @(Get-ChildItem -LiteralPath $scriptDir -Filter '*.iso' -File -ErrorAction SilentlyContinue |
              Where-Object { $_.Name -notlike 'win11_niix*.iso' } |
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
    $dlg.Filter           = 'ISO files (*.iso)|*.iso'
    $dlg.InitialDirectory = [Environment]::GetFolderPath('Desktop')
    if ($dlg.ShowDialog() -ne [System.Windows.Forms.DialogResult]::OK) {
        throw "No ISO selected. Get the official Windows 11 ISO at https://www.microsoft.com/software-download/windows11"
    }
    $script:SelectedISO = $dlg.FileName
} elseif ($isoFiles.Count -eq 1) {
    $script:SelectedISO = $isoFiles[0].FullName
    Write-Body "Found: $($isoFiles[0].Name)"
} else {
    Write-Body "Multiple ISOs found -- please choose:"
    Write-Host ""
    for ($i = 0; $i -lt $isoFiles.Count; $i++) {
        $gb = [math]::Round($isoFiles[$i].Length / 1GB, 2)
        Write-Host ("  [{0}]  {1}  ({2} GB)" -f ($i + 1), $isoFiles[$i].Name, $gb) -ForegroundColor $WHITE
    }
    Write-Host ""
    $script:SelectedISO = $isoFiles[(Read-Index '  Enter number' $isoFiles.Count)].FullName
}

$isoGB = [math]::Round((Get-Item -LiteralPath $script:SelectedISO).Length / 1GB, 2)
Write-Success "Selected: $(Split-Path $script:SelectedISO -Leaf)  ($isoGB GB)"

# ===========================================================================
#  STEP 2  --  MOUNT & VERIFY
# ===========================================================================
Write-Title "STEP 2 -- Mounting and verifying ISO..."
Show-Progress "Mounting ISO..." 20

$diskImage = Get-DiskImage -ImagePath $script:SelectedISO -ErrorAction Stop
if (-not $diskImage.Attached) {
    Mount-DiskImage -ImagePath $script:SelectedISO -StorageType ISO -ErrorAction Stop | Out-Null
    $script:IsoMountedByUs = $true
}
$driveLetter = $null
for ($i = 0; $i -lt 30 -and -not $driveLetter; $i++) {
    $vol = Get-DiskImage -ImagePath $script:SelectedISO | Get-Volume -ErrorAction SilentlyContinue | Select-Object -First 1
    $dl  = if ($vol) { "$($vol.DriveLetter)" } else { '' }
    if ($dl -match '^[A-Za-z]$') { $driveLetter = "$($dl):\" } else { Start-Sleep -Milliseconds 500 }
}
if (-not $driveLetter) { throw "The ISO was mounted but Windows did not assign it a drive letter." }

Show-Progress "Scanning editions..." 60

$srcWim = Join-Path $driveLetter 'sources\install.wim'
$srcEsd = Join-Path $driveLetter 'sources\install.esd'
if     (Test-Path -LiteralPath $srcWim) { $sourceImage = $srcWim }
elseif (Test-Path -LiteralPath $srcEsd) { $sourceImage = $srcEsd }
else   { throw "install.wim / install.esd not found -- not a valid Windows ISO." }

$imageInfo = @(Get-WindowsImage -ImagePath $sourceImage -ErrorAction Stop)
$win11Only = @($imageInfo | Where-Object { $_.ImageName -match 'Windows 11' })
if ($win11Only.Count -eq 0) { throw "No Windows 11 editions found. Only Windows 11 ISOs are supported." }

Show-Progress "ISO verified." 100 -Done
Write-Host ""
Write-Body "Available Windows 11 editions:"
Write-Host ""
for ($i = 0; $i -lt $win11Only.Count; $i++) {
    Write-Host ("  [{0}]  {1}" -f ($i + 1), $win11Only[$i].ImageName) -ForegroundColor $WHITE
}

$defaultIdx = -1
for ($i = 0; $i -lt $win11Only.Count; $i++) {
    if ($win11Only[$i].ImageName -match 'Pro for Workstations') { $defaultIdx = $i; break }
}
if ($defaultIdx -lt 0) {
    for ($i = 0; $i -lt $win11Only.Count; $i++) {
        if ($win11Only[$i].ImageName -match 'Windows 11 Pro(?![\w ])') { $defaultIdx = $i; break }
    }
}

Write-Host ""
if ($defaultIdx -ge 0) {
    Write-Host ("  Auto-selected: [{0}] {1}" -f ($defaultIdx + 1), $win11Only[$defaultIdx].ImageName) -ForegroundColor $GREEN
    Write-Host "  Press Enter to confirm, or type a different number to change." -ForegroundColor $WHITE
    $defaultIdx = Read-Index '  Selection' $win11Only.Count $defaultIdx
} else {
    Write-Host "  No preferred edition found -- please choose:" -ForegroundColor $WHITE
    $defaultIdx = Read-Index '  Enter number' $win11Only.Count
}

$selectedIndex   = $win11Only[$defaultIdx].ImageIndex
$selectedEdition = $win11Only[$defaultIdx].ImageName

$editionDetail = Get-WindowsImage -ImagePath $sourceImage -Index $selectedIndex -ErrorAction Stop
if ("$($editionDetail.Architecture)" -match '^(12|arm64)$') {
    throw "ARM64 images are not supported: unattend.xml targets amd64 (x64) only."
}
Write-Success "Edition: $selectedEdition  (Index $selectedIndex)"

# ===========================================================================
#  STEP 3  --  WORKSPACE
# ===========================================================================
Write-Title "STEP 3 -- Preparing workspace..."
Show-Progress "Creating temp directories..." 10

$script:WorkDir  = Join-Path $env:TEMP ("niixdebloat_{0:yyyyMMdd_HHmmss}" -f (Get-Date))
$isoContents     = Join-Path $script:WorkDir 'iso_contents'
$script:MountDir = Join-Path $script:WorkDir 'wim_mount'
New-Item -ItemType Directory -Path $isoContents, $script:MountDir -Force | Out-Null

Show-Progress "Copying ISO contents (may take a few minutes)..." 30
$rc = Invoke-Quiet 'robocopy.exe' "$driveLetter `"$isoContents`" /E /R:2 /W:2 /A-:R /XF install.wim install.esd /NFL /NDL /NJH /NJS /NP"
if ($rc.ExitCode -ge 8) { throw "robocopy failed (exit $($rc.ExitCode)): $($rc.Output.Trim())" }
Show-Progress "ISO contents copied." 100 -Done

# ===========================================================================
#  STEP 4  --  EXPORT SELECTED EDITION + MOUNT
#  Exporting first works for both install.wim and install.esd (ESD files
#  cannot be mounted directly) and strips every other edition.
# ===========================================================================
Write-Title "STEP 4 -- Exporting and mounting $selectedEdition..."

$workWim  = Join-Path $isoContents 'sources\install_work.wim'
$finalWim = Join-Path $isoContents 'sources\install.wim'

Show-Progress "Exporting edition (several minutes, longer for .esd sources)..." 30
Export-WindowsImage -SourceImagePath $sourceImage -SourceIndex $selectedIndex `
                    -DestinationImagePath $workWim -CompressionType max -ErrorAction Stop | Out-Null
Show-Progress "Edition exported." 100 -Done

if ($script:IsoMountedByUs) {
    Dismount-DiskImage -ImagePath $script:SelectedISO -ErrorAction SilentlyContinue | Out-Null
    $script:IsoMountedByUs = $false
}

Show-Progress "Mounting image..." 30
Mount-WindowsImage -ImagePath $workWim -Index 1 -Path $script:MountDir -ErrorAction Stop | Out-Null
$script:WimMounted = $true
$mountDir = $script:MountDir
Show-Progress "Image mounted." 100 -Done

# ===========================================================================
#  STEP 4b  --  INJECT DRIVERS (if requested in STEP 0)
# ===========================================================================
if ($script:DriverExportDir) {
    Write-Title "STEP 4b -- Injecting this PC's drivers into the image..."
    Show-Progress "Adding drivers to image (this can take a few minutes)..." 40
    $r = Invoke-Quiet 'dism.exe' "/English `"/Image:$mountDir`" /Add-Driver `"/Driver:$($script:DriverExportDir)`" /Recurse"
    if ($r.ExitCode -eq 0) {
        Show-Progress "Drivers injected." 100 -Done
    } else {
        Write-Host ""
        Write-Warn "Some drivers could not be injected (DISM exit $($r.ExitCode)) -- continuing."
    }
}

# ===========================================================================
#  STEP 5  --  APPLY ALL MODIFICATIONS
# ===========================================================================
Write-Title "STEP 5 -- Applying debloat and privacy hardening..."

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
    'Microsoft.MixedReality.Portal','Microsoft.MSPaint',
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
    'Microsoft.MicrosoftEdge','MicrosoftEdge'
)

$pkgList = Invoke-Quiet 'dism.exe' "/English `"/Image:$mountDir`" /Get-ProvisionedAppxPackages"
$allPkgs = @($pkgList.Output -split "`r?`n" | ForEach-Object { if ($_ -match '^PackageName\s*:\s*(.+)$') { $Matches[1].Trim() } })

$removed = 0
foreach ($pkg in $allPkgs) {
    $hit = $false
    foreach ($pre in $pkgPrefixes) { if ($pkg -like "*$pre*") { $hit = $true; break } }
    if ($hit) {
        $r = Invoke-Quiet 'dism.exe' "/English `"/Image:$mountDir`" /Remove-ProvisionedAppxPackage `"/PackageName:$pkg`""
        if ($r.ExitCode -eq 0) { $removed++ }
    }
}
Show-Progress "Removed $removed AppX packages." 10 -Done

# -- 5a2. Remove Windows Backup capability (offline) ---------------------------
Show-Progress "Removing Windows Backup capability..." 11
$capList = Invoke-Quiet 'dism.exe' "/English `"/Image:$mountDir`" /Get-Capabilities"
$allCaps = @($capList.Output -split "`r?`n" | ForEach-Object { if ($_ -match '^Capability Identity\s*:\s*(.+)$') { $Matches[1].Trim() } })
foreach ($cap in $allCaps) {
    if ($cap -like '*WindowsBackup*' -or $cap -like '*BackupAndRestore*') {
        Invoke-Quiet 'dism.exe' "/English `"/Image:$mountDir`" /Remove-Capability `"/CapabilityName:$cap`"" | Out-Null
    }
}
# Recall is neutralized by policy (DisableAIDataAnalysis + TurnOffSavingSnapshots
# in step 5g). The Recall optional feature is NOT removed: on Windows 11 24H2,
# removing it also breaks the modern File Explorer UI.

# -- 5b. Remove OneDrive -------------------------------------------------------
Show-Progress "Removing OneDrive..." 12
foreach ($od in @("$mountDir\Windows\System32\OneDriveSetup.exe", "$mountDir\Windows\SysWOW64\OneDriveSetup.exe")) {
    if (Test-Path -LiteralPath $od) {
        Grant-AdminFullControl $od
        Remove-Item -LiteralPath $od -Force -ErrorAction SilentlyContinue
    }
}
Show-Progress "OneDrive removed." 15 -Done

# -- 5b2. Remove Microsoft Edge (browser) from the image -----------------------
# EdgeWebView (WebView2 Runtime) and EdgeUpdate are intentionally kept.
# Microsoft.Win32WebViewHost ("Desktop App Web Viewer") is also kept.
Show-Progress "Removing Edge files from image..." 17
$ep = @(
    "$mountDir\Program Files (x86)\Microsoft\Edge",
    "$mountDir\Program Files (x86)\Microsoft\EdgeCore",
    "$mountDir\Windows\SystemApps\Microsoft.MicrosoftEdge_8wekyb3d8bbwe",
    "$mountDir\Windows\SystemApps\Microsoft.MicrosoftEdgeDevToolsClient_8wekyb3d8bbwe",
    "$mountDir\Windows\System32\MicrosoftEdgeCP.exe",
    "$mountDir\Windows\System32\MicrosoftEdgeSH.exe",
    "$mountDir\Users\Public\Desktop\Microsoft Edge.lnk",
    "$mountDir\ProgramData\Microsoft\Windows\Start Menu\Programs\Microsoft Edge.lnk"
)
foreach ($e in $ep) {
    if (Test-Path -LiteralPath $e) {
        Grant-AdminFullControl $e
        Remove-Item -LiteralPath $e -Recurse -Force -ErrorAction SilentlyContinue
    }
}
Show-Progress "Edge files removed from image." 20 -Done

# -- 5c. Load offline hives ----------------------------------------------------
Show-Progress "Loading offline registry hives..." 22
Mount-OfflineHives -ImageRoot $mountDir

$DF = 'HKLM\NIIX_DEFAULT'
$NU = 'HKLM\NIIX_NTUSER'
$SW = 'HKLM\NIIX_SOFTWARE'
$_cs = 1
$_sel = [Microsoft.Win32.Registry]::LocalMachine.OpenSubKey('NIIX_SYSTEM\Select')
if ($_sel) {
    $_cur = $_sel.GetValue('Current')
    $_sel.Close()
    if ($_cur) { $_cs = [int]$_cur }
}
$SY  = 'HKLM\NIIX_SYSTEM\ControlSet{0:D3}' -f $_cs
$SYR = 'HKLM\NIIX_SYSTEM'

# -- 5d. Hardware bypass -------------------------------------------------------
Show-Progress "Hardware requirement bypass..." 25
Set-OfflineReg "$DF\Control Panel\UnsupportedHardwareNotificationCache" 'SV1' 'REG_DWORD' '0'
Set-OfflineReg "$DF\Control Panel\UnsupportedHardwareNotificationCache" 'SV2' 'REG_DWORD' '0'
Set-OfflineReg "$NU\Control Panel\UnsupportedHardwareNotificationCache" 'SV1' 'REG_DWORD' '0'
Set-OfflineReg "$NU\Control Panel\UnsupportedHardwareNotificationCache" 'SV2' 'REG_DWORD' '0'
foreach ($n in @('BypassCPUCheck','BypassRAMCheck','BypassSecureBootCheck','BypassStorageCheck','BypassTPMCheck')) {
    Set-OfflineReg "$SYR\Setup\LabConfig" $n 'REG_DWORD' '1'
}
Set-OfflineReg "$SYR\Setup\MoSetup" 'AllowUpgradesWithUnsupportedTPMOrCPU' 'REG_DWORD' '1'

# -- 5d2. Disable Core Isolation / Memory Integrity (VBS/HVCI) ----------------
# Deliberate gaming-performance trade-off. Written both as runtime state and
# as policy so the device is never in a "not yet configured" state that an
# automatic enablement could pick up.
Set-OfflineReg "$SY\Control\DeviceGuard"                                            'EnableVirtualizationBasedSecurity' 'REG_DWORD' '0'
Set-OfflineReg "$SY\Control\DeviceGuard\Scenarios\HypervisorEnforcedCodeIntegrity"  'Enabled'                           'REG_DWORD' '0'
Set-OfflineReg "$SY\Control\DeviceGuard\Scenarios\CredentialGuard"                  'Enabled'                           'REG_DWORD' '0'
Set-OfflineReg "$SY\Control\Lsa"                                                    'LsaCfgFlags'                       'REG_DWORD' '0'
Set-OfflineReg "$SW\Policies\Microsoft\Windows\DeviceGuard" 'EnableVirtualizationBasedSecurity' 'REG_DWORD' '0'
Set-OfflineReg "$SW\Policies\Microsoft\Windows\DeviceGuard" 'HypervisorEnforcedCodeIntegrity'   'REG_DWORD' '0'
Set-OfflineReg "$SW\Policies\Microsoft\Windows\DeviceGuard" 'RequirePlatformSecurityFeatures'   'REG_DWORD' '1'
Set-OfflineReg "$SW\Policies\Microsoft\Windows\DeviceGuard" 'LsaCfgFlags'                       'REG_DWORD' '0'

# -- 5e. Content delivery / sponsored apps ------------------------------------
Show-Progress "Disabling sponsored apps and content delivery..." 30
$cdm = "$NU\Software\Microsoft\Windows\CurrentVersion\ContentDeliveryManager"
foreach ($k in @('OemPreInstalledAppsEnabled','PreInstalledAppsEnabled',
  'SilentInstalledAppsEnabled','ContentDeliveryAllowed','FeatureManagementEnabled',
  'PreInstalledAppsEverEnabled','SoftLandingEnabled','SubscribedContentEnabled',
  'SubscribedContent-310093Enabled','SubscribedContent-338388Enabled',
  'SubscribedContent-338389Enabled','SubscribedContent-338393Enabled',
  'SubscribedContent-353694Enabled','SubscribedContent-353696Enabled',
  'SystemPaneSuggestionsEnabled')) { Set-OfflineReg $cdm $k 'REG_DWORD' '0' }

Set-OfflineReg "$SW\Policies\Microsoft\Windows\CloudContent" 'DisableWindowsConsumerFeatures'     'REG_DWORD' '1'
Set-OfflineReg "$SW\Policies\Microsoft\Windows\CloudContent" 'DisableConsumerAccountStateContent' 'REG_DWORD' '1'
Set-OfflineReg "$SW\Policies\Microsoft\Windows\CloudContent" 'DisableCloudOptimizedContent'       'REG_DWORD' '1'
Set-OfflineReg "$SW\Microsoft\PolicyManager\current\device\Start" 'ConfigureStartPins' 'REG_SZ' '{"pinnedList":[]}'
Set-OfflineReg "$SW\Policies\Microsoft\PushToInstall" 'DisablePushToInstall' 'REG_DWORD' '1'
Remove-OfflineReg "$cdm\Subscriptions"
Remove-OfflineReg "$cdm\SuggestedApps"

# -- 5f. Telemetry & privacy ---------------------------------------------------
Show-Progress "Disabling telemetry and data collection..." 38
Set-OfflineReg "$NU\Software\Microsoft\Windows\CurrentVersion\AdvertisingInfo"          'Enabled'                                      'REG_DWORD' '0'
Set-OfflineReg "$NU\Software\Microsoft\Windows\CurrentVersion\Privacy"                  'TailoredExperiencesWithDiagnosticDataEnabled' 'REG_DWORD' '0'
Set-OfflineReg "$NU\Software\Microsoft\Speech_OneCore\Settings\OnlineSpeechPrivacy"     'HasAccepted'                                  'REG_DWORD' '0'
Set-OfflineReg "$NU\Software\Microsoft\Input\TIPC"                                      'Enabled'                                      'REG_DWORD' '0'
Set-OfflineReg "$NU\Software\Microsoft\InputPersonalization"                            'RestrictImplicitInkCollection'                'REG_DWORD' '1'
Set-OfflineReg "$NU\Software\Microsoft\InputPersonalization"                            'RestrictImplicitTextCollection'               'REG_DWORD' '1'
Set-OfflineReg "$NU\Software\Microsoft\InputPersonalization\TrainedDataStore"           'HarvestContacts'                              'REG_DWORD' '0'
Set-OfflineReg "$NU\Software\Microsoft\Personalization\Settings"                        'AcceptedPrivacyPolicy'                        'REG_DWORD' '0'
Set-OfflineReg "$SW\Policies\Microsoft\Windows\DataCollection"                          'AllowTelemetry'                               'REG_DWORD' '0'
Set-OfflineReg "$SW\Policies\Microsoft\Windows\DataCollection"                          'DoNotShowFeedbackNotifications'               'REG_DWORD' '1'
Set-OfflineReg "$SW\Policies\Microsoft\Windows\DataCollection"                          'LimitDiagnosticLogCollection'                 'REG_DWORD' '1'
Set-OfflineReg "$SW\Policies\Microsoft\Windows\DataCollection"                          'DisableOneSettingsDownloads'                  'REG_DWORD' '1'
Set-OfflineReg "$SW\Policies\Microsoft\Windows\AdvertisingInfo"                         'DisabledByGroupPolicy'                        'REG_DWORD' '1'
Set-OfflineReg "$SW\Policies\Microsoft\Windows\System"                                  'EnableActivityFeed'                           'REG_DWORD' '0'
Set-OfflineReg "$SW\Policies\Microsoft\Windows\System"                                  'PublishUserActivities'                        'REG_DWORD' '0'
Set-OfflineReg "$SW\Policies\Microsoft\Windows\System"                                  'UploadUserActivities'                         'REG_DWORD' '0'
# Location, camera, microphone etc. stay user-controlled in Settings. Only
# apps' access to system DIAGNOSTIC INFO is denied (a telemetry vector).
Set-OfflineReg "$SW\Policies\Microsoft\Windows\AppPrivacy" 'LetAppsGetDiagnosticInfo' 'REG_DWORD' '2'

# -- 5g. Copilot / AI / Bing / Recall -----------------------------------------
Show-Progress "Disabling Copilot, Recall, Bing and AI features..." 45
Set-OfflineReg "$SW\Policies\Microsoft\Windows\WindowsCopilot"  'TurnOffWindowsCopilot'       'REG_DWORD' '1'
Set-OfflineReg "$NU\Software\Policies\Microsoft\Windows\WindowsCopilot" 'TurnOffWindowsCopilot' 'REG_DWORD' '1'
Set-OfflineReg "$SW\Policies\Microsoft\Edge"                    'HubsSidebarEnabled'          'REG_DWORD' '0'
Set-OfflineReg "$SW\Policies\Microsoft\Windows\Explorer"        'DisableSearchBoxSuggestions' 'REG_DWORD' '1'
Set-OfflineReg "$NU\Software\Policies\Microsoft\Windows\Explorer" 'DisableSearchBoxSuggestions' 'REG_DWORD' '1'
Set-OfflineReg "$SW\Policies\Microsoft\Windows\WindowsAI"       'DisableAIDataAnalysis'       'REG_DWORD' '1'
Set-OfflineReg "$SW\Policies\Microsoft\Windows\WindowsAI"       'TurnOffSavingSnapshots'      'REG_DWORD' '1'

# -- 5h. UI / Taskbar ---------------------------------------------------------
Show-Progress "Applying UI and Taskbar tweaks..." 52
$adv = "$NU\Software\Microsoft\Windows\CurrentVersion\Explorer\Advanced"
Set-OfflineReg "$SW\Policies\Microsoft\Windows\Windows Chat" 'ChatIcon' 'REG_DWORD' '3'
Set-OfflineReg $adv 'TaskbarMn'                'REG_DWORD' '0'
Set-OfflineReg $adv 'TaskbarDa'                'REG_DWORD' '0'
Set-OfflineReg $adv 'ShowTaskViewButton'       'REG_DWORD' '0'
Set-OfflineReg $adv 'HideFileExt'              'REG_DWORD' '0'
Set-OfflineReg $adv 'Hidden'                   'REG_DWORD' '1'
Set-OfflineReg $adv 'Start_TrackProgs'         'REG_DWORD' '0'
Set-OfflineReg $adv 'EnableSnapAssistFlyout'   'REG_DWORD' '0'
Set-OfflineReg $adv 'TaskbarAl'                'REG_DWORD' '0'
Set-OfflineReg $adv 'ShowSecondsInSystemClock' 'REG_DWORD' '1'
Set-OfflineReg $adv 'HideRecommendedSection'   'REG_DWORD' '1'
Set-OfflineReg "$NU\Software\Microsoft\Windows\CurrentVersion\Search" 'SearchboxTaskbarMode' 'REG_DWORD' '0'
Set-OfflineReg "$NU\Software\Microsoft\Windows\CurrentVersion\Search" 'BingSearchEnabled'    'REG_DWORD' '0'
Set-OfflineReg "$NU\Software\Microsoft\Windows\CurrentVersion\Search" 'CortanaConsent'       'REG_DWORD' '0'
Set-OfflineReg "$SW\Policies\Microsoft\Windows\Explorer" 'HideRecommendedSection' 'REG_DWORD' '1'
Set-OfflineReg "$NU\Software\Classes\CLSID\{86ca1aa0-34aa-4e8b-a509-50c905bae2a2}\InprocServer32" '' 'REG_SZ' ''
Set-OfflineReg "$SW\Policies\Microsoft\Dsh" 'AllowNewsAndInterests' 'REG_DWORD' '0'

# Dark theme baked into the Default user hive (avoids SetColorTheme race)
$pers = "$NU\Software\Microsoft\Windows\CurrentVersion\Themes\Personalize"
Set-OfflineReg $pers 'SystemUsesLightTheme' 'REG_DWORD' '0'
Set-OfflineReg $pers 'AppsUseLightTheme'    'REG_DWORD' '0'
Set-OfflineReg $pers 'EnableTransparency'   'REG_DWORD' '1'
Set-OfflineReg $pers 'ColorPrevalence'      'REG_DWORD' '0'
Set-OfflineReg "$NU\Software\Microsoft\Windows\DWM" 'ColorPrevalence' 'REG_DWORD' '0'

# -- 5i. OneDrive sync policies ------------------------------------------------
Show-Progress "Disabling OneDrive sync policies..." 55
Set-OfflineReg "$SW\Policies\Microsoft\Windows\OneDrive" 'DisableFileSyncNGSC'                   'REG_DWORD' '1'
Set-OfflineReg "$SW\Policies\Microsoft\Windows\OneDrive" 'DisableLibrariesDefaultSaveToOneDrive' 'REG_DWORD' '1'
$_runKey = [Microsoft.Win32.Registry]::LocalMachine.OpenSubKey('NIIX_NTUSER\Software\Microsoft\Windows\CurrentVersion\Run', $true)
if ($_runKey) {
    try { $_runKey.DeleteValue('OneDriveSetup', $false) } catch { } finally { $_runKey.Close() }
}

# -- 5j. Suppress Windows Update during OOBE ----------------------------------
# Only wuauserv is disabled offline: its key is writable by Administrators,
# so FirstLogon.ps1 and niix-tweaks.ps1 can both reliably restore it.
# (WaaSMedicSvc/UsoSvc are ACL-protected and are deliberately left alone --
# disabling them can make Windows Update impossible to restore.)
# No NoAutoUpdate/AUOptions/UseWUServer policy is written here.
Show-Progress "Suppressing Windows Update during OOBE..." 58
Set-OfflineReg "$SW\Microsoft\Windows\CurrentVersion\WindowsUpdate\Orchestrator\UScheduler_Oobe\WindowsUpdate" 'workCompleted' 'REG_DWORD' '1'
Remove-OfflineReg "$SW\Microsoft\WindowsUpdate\Orchestrator\UScheduler_Oobe\WindowsUpdate"
Set-OfflineReg "$SW\Policies\Microsoft\Windows\DeliveryOptimization" 'DODownloadMode' 'REG_DWORD' '0'
Set-OfflineReg "$SY\Services\wuauserv" 'Start' 'REG_DWORD' '4'

# -- 5k. Block Teams / Outlook / DevHome auto-install -------------------------
Show-Progress "Blocking Teams, Outlook, DevHome auto-install..." 61
Set-OfflineReg "$SW\Policies\Microsoft\Teams"                'DisableInstallation' 'REG_DWORD' '1'
Set-OfflineReg "$SW\Policies\Microsoft\Windows\Windows Mail" 'PreventRun'          'REG_DWORD' '1'
foreach ($k in @('OutlookUpdate','DevHomeUpdate')) {
    Set-OfflineReg "$SW\Microsoft\Windows\CurrentVersion\WindowsUpdate\Orchestrator\UScheduler_Oobe\$k" 'workCompleted' 'REG_DWORD' '1'
    Set-OfflineReg "$SW\Microsoft\Windows\CurrentVersion\WindowsUpdate\Orchestrator\UScheduler\$k"      'workCompleted' 'REG_DWORD' '1'
    Remove-OfflineReg "$SW\Microsoft\WindowsUpdate\Orchestrator\UScheduler_Oobe\$k"
}

# -- 5l. BitLocker / reserved storage -----------------------------------------
Show-Progress "Disabling BitLocker auto-encryption and reserved storage..." 64
Set-OfflineReg "$SY\Control\BitLocker" 'PreventDeviceEncryption' 'REG_DWORD' '1'
Set-OfflineReg "$SW\Microsoft\Windows\CurrentVersion\ReserveManager" 'ShippedWithReserves' 'REG_DWORD' '0'

# -- 5m. Local account OOBE bypass --------------------------------------------
Show-Progress "Enabling local account OOBE bypass..." 66
Set-OfflineReg "$SW\Microsoft\Windows\CurrentVersion\OOBE" 'BypassNRO' 'REG_DWORD' '1'
Set-OfflineReg "$SW\Policies\Microsoft\Windows\System" 'NoLocalPasswordResetQuestions' 'REG_DWORD' '1'
Set-OfflineReg "$SW\Microsoft\Windows NT\CurrentVersion\PasswordRecovery" 'Enabled' 'REG_DWORD' '0'

# -- 5n. Privacy-invasive services --------------------------------------------
# DPS, SysMain, PcaSvc, lfsvc, PhoneSvc, MapsBroker, TrkWks are deliberately
# NOT disabled so apps and built-in diagnostics keep working.
Show-Progress "Disabling privacy-invasive services..." 70
foreach ($s in @('DiagTrack','dmwappushservice','RemoteRegistry','WerSvc','SDRSVC','wbengine')) {
    if (Test-OfflineKey "$SY\Services\$s") {
        Set-OfflineReg "$SY\Services\$s" 'Start' 'REG_DWORD' '4'
    }
}
Set-OfflineReg "$SW\Policies\Microsoft\Windows\Windows Error Reporting" 'Disabled' 'REG_DWORD' '1'

# -- 5o. GameBar / Xbox / Edge services ----------------------------------------
Show-Progress "Disabling GameBar, Xbox and Edge browser services..." 74
Set-OfflineReg "$SW\Policies\Microsoft\Windows\GameDVR"                         'AllowGameDVR'              'REG_DWORD' '0'
Set-OfflineReg "$NU\System\GameConfigStore"                                     'GameDVR_Enabled'           'REG_DWORD' '0'
Set-OfflineReg "$NU\System\GameConfigStore"                                     'GameDVR_FSEBehaviorMode'   'REG_DWORD' '2'
Set-OfflineReg "$NU\Software\Microsoft\Windows\CurrentVersion\GameDVR"          'AppCaptureEnabled'         'REG_DWORD' '0'
Set-OfflineReg "$NU\Software\Microsoft\GameBar"                                 'UseNexusForGameBarEnabled' 'REG_DWORD' '0'
Set-OfflineReg "$NU\Software\Microsoft\GameBar"                                 'AllowAutoGameMode'         'REG_DWORD' '0'
# edgeupdate / edgeupdatem are NOT disabled: WebView2 Runtime needs them.
foreach ($s in @('XblAuthManager','XblGameSave','XboxGipSvc','XboxNetApiSvc','MicrosoftEdgeElevationService')) {
    if (Test-OfflineKey "$SY\Services\$s") {
        Set-OfflineReg "$SY\Services\$s" 'Start' 'REG_DWORD' '4'
    }
}
[GC]::Collect()
[GC]::WaitForPendingFinalizers()

# -- 5o2. Gaming / system performance tweaks -----------------------------------
Show-Progress "Applying gaming/performance tweaks (Game Mode, GPU scheduling)..." 75
Set-OfflineReg "$NU\Software\Microsoft\GameBar" 'AutoGameModeEnabled'      'REG_DWORD' '1'
Set-OfflineReg "$NU\Software\Microsoft\GameBar" 'ShowStartupPanel'         'REG_DWORD' '0'
Set-OfflineReg "$NU\Software\Microsoft\GameBar" 'GamePanelStartupTipIndex' 'REG_DWORD' '3'
Set-OfflineReg "$NU\Control Panel\Mouse" 'MouseSpeed'      'REG_SZ' '0'
Set-OfflineReg "$NU\Control Panel\Mouse" 'MouseThreshold1' 'REG_SZ' '0'
Set-OfflineReg "$NU\Control Panel\Mouse" 'MouseThreshold2' 'REG_SZ' '0'
Set-OfflineReg "$NU\System\GameConfigStore" 'GameDVR_FSEBehavior'                   'REG_DWORD' '2'
Set-OfflineReg "$NU\System\GameConfigStore" 'GameDVR_HonorUserFSEBehaviorMode'      'REG_DWORD' '1'
Set-OfflineReg "$NU\System\GameConfigStore" 'GameDVR_DXGIHonorFSEWindowsCompatible' 'REG_DWORD' '1'
Set-OfflineReg "$SY\Control\GraphicsDrivers" 'HwSchMode' 'REG_DWORD' '2'

# -- 5o3. Edge browser block (WebView2 explicitly allowed) --------------------
# {56EB18F8-B008-4CBD-B6D2-8C97FE7E9062} = Edge Stable browser
# {F3017226-FE2A-4295-8BDF-00C3A9A7E4C5} = WebView2 Runtime
$eu = "$SW\Policies\Microsoft\EdgeUpdate"
Set-OfflineReg "$SW\Microsoft\EdgeUpdate" 'DoNotUpdateToEdgeWithChromium' 'REG_DWORD' '1'
Set-OfflineReg $eu 'UpdateDefault'                                  'REG_DWORD' '0'
Set-OfflineReg $eu 'InstallDefault'                                 'REG_DWORD' '0'
Set-OfflineReg $eu 'Install{56EB18F8-B008-4CBD-B6D2-8C97FE7E9062}' 'REG_DWORD' '0'
Set-OfflineReg $eu 'Update{56EB18F8-B008-4CBD-B6D2-8C97FE7E9062}'  'REG_DWORD' '0'
Set-OfflineReg $eu 'Install{F3017226-FE2A-4295-8BDF-00C3A9A7E4C5}' 'REG_DWORD' '1'
Set-OfflineReg $eu 'Update{F3017226-FE2A-4295-8BDF-00C3A9A7E4C5}'  'REG_DWORD' '1'
Set-OfflineReg "$SW\Policies\Microsoft\Edge"                'HideFirstRunExperience' 'REG_DWORD' '1'
Set-OfflineReg "$SW\Policies\Microsoft\Edge"                'BackgroundModeEnabled'  'REG_DWORD' '0'
Set-OfflineReg "$SW\Policies\Microsoft\Edge"                'StartupBoostEnabled'    'REG_DWORD' '0'
Set-OfflineReg "$SW\Policies\Microsoft\MicrosoftEdge\Main"  'AllowPrelaunch'         'REG_DWORD' '0'
Set-OfflineReg "$SW\Microsoft\Windows\CurrentVersion\MicrosoftEdge" 'IsEdgeStableSetupDone' 'REG_DWORD' '1'
Set-OfflineReg "$SW\Microsoft\Windows\CurrentVersion\WindowsUpdate\Orchestrator\UScheduler_Oobe\EdgeUpdate" 'workCompleted' 'REG_DWORD' '1'
Remove-OfflineReg "$SW\Microsoft\WindowsUpdate\Orchestrator\UScheduler_Oobe\EdgeUpdate"

Set-OfflineReg "$SW\Policies\Microsoft\Windows\BackupAndRestore" 'DisableBackup' 'REG_DWORD' '1'

# -- 5p. SmartScreen -----------------------------------------------------------
# Deliberate trade-off of this build (see README "Notes & caveats").
Show-Progress "Configuring SmartScreen..." 78
Set-OfflineReg "$SW\Policies\Microsoft\Windows\System"               'EnableSmartScreen' 'REG_DWORD' '0'
Set-OfflineReg "$SW\Policies\Microsoft\MicrosoftEdge\PhishingFilter" 'EnabledV9'         'REG_DWORD' '0'

# -- 5q. niix-tweaks.ps1 into the image + Desktop-copy RunOnce ---------------
# niix-tweaks.ps1 auto-runs once at first logon via the NiixTweaksAutoRun
# scheduled task (registered elevated in Specialize.ps1). UserOnce.ps1
# deletes *.lnk from the desktop, so a plain copy of the .ps1 is placed on
# each new user's Desktop via RunOnce instead, for manual re-runs.
Show-Progress "Writing niix-tweaks.ps1 into image..." 82
$setupScriptsDir = Join-Path $mountDir 'Windows\Setup\Scripts'
New-Item -ItemType Directory -Path $setupScriptsDir -Force | Out-Null
Copy-Item -LiteralPath $_tweaksPath -Destination (Join-Path $setupScriptsDir 'niix-tweaks.ps1') -Force

$runOnce = "$NU\Software\Microsoft\Windows\CurrentVersion\RunOnce"
Set-OfflineReg $runOnce 'NiixTweaksDesktop' 'REG_SZ' ('powershell.exe -WindowStyle Hidden -ExecutionPolicy Bypass -NoProfile -Command "' +
    "Copy-Item -LiteralPath 'C:\Windows\Setup\Scripts\niix-tweaks.ps1' -Destination ([Environment]::GetFolderPath('Desktop')) -Force" + '"')

# -- 5q2. Bundled .exe files (optional) -> Public Desktop ----------------------
# Every .exe placed next to this script (e.g. a browser installer, since Edge
# is removed) is copied to C:\Users\Public\Desktop in the image, so it shows
# on every user's desktop from the first boot. Files keep their Mark-of-the-Web
# (if any), so Windows still shows its "run this file?" prompt for downloads.
$bundledExes = @(Get-ChildItem -LiteralPath $scriptDir -Filter '*.exe' -File -ErrorAction SilentlyContinue |
                 Where-Object { $_.Extension -eq '.exe' } |
                 Sort-Object Name)
if ($bundledExes.Count -gt 0) {
    Show-Progress "Adding $($bundledExes.Count) .exe file(s) to the Public Desktop..." 84
    $publicDesktop = Join-Path $mountDir 'Users\Public\Desktop'
    New-Item -ItemType Directory -Path $publicDesktop -Force | Out-Null
    foreach ($exe in $bundledExes) {
        Copy-Item -LiteralPath $exe.FullName -Destination (Join-Path $publicDesktop $exe.Name) -Force -ErrorAction Stop
    }
    Show-Progress "$($bundledExes.Count) .exe file(s) added to the Public Desktop." 85 -Done
    foreach ($exe in $bundledExes) {
        $sig = Get-AuthenticodeSignature -LiteralPath $exe.FullName -ErrorAction SilentlyContinue
        if ($sig -and $sig.Status -eq 'Valid') {
            Write-Body "$($exe.Name)  (signed by: $($sig.SignerCertificate.GetNameInfo('SimpleName', $false)))"
        } else {
            $status = if ($sig) { $sig.Status } else { 'Unknown' }
            Write-Warn "$($exe.Name) has no valid digital signature ($status) -- only keep it if you trust its source."
        }
    }
} else {
    Write-Host ""
    Write-Body "No .exe files next to the script -- nothing added to the desktop."
}

# -- 5r. Wallpaper (optional -- only if you supply one) ------------------------
# Sets the DEFAULT wallpaper for new profiles; users can still change it.
$customWall = @('wallpaper.jpg','wallpaper.jpeg','wallpaper.png') |
    ForEach-Object { Join-Path $scriptDir $_ } |
    Where-Object { Test-Path -LiteralPath $_ } |
    Select-Object -First 1

if ($customWall) {
    Show-Progress "Writing wallpaper into image..." 86
    $wallDir = Join-Path $mountDir 'Windows\Web\Wallpaper\Niix'
    New-Item -ItemType Directory -Path $wallDir -Force | Out-Null
    $wallFileName = 'niix-wall' + [System.IO.Path]::GetExtension($customWall).ToLowerInvariant()
    Copy-Item -LiteralPath $customWall -Destination (Join-Path $wallDir $wallFileName) -Force
    $_wp = "C:\Windows\Web\Wallpaper\Niix\$wallFileName"

    $desk = "$NU\Control Panel\Desktop"
    Set-OfflineReg $desk 'Wallpaper'        'REG_SZ' $_wp
    Set-OfflineReg $desk 'WallpaperStyle'   'REG_SZ' '10'
    Set-OfflineReg $desk 'TileWallpaper'    'REG_SZ' '0'
    Set-OfflineReg $desk 'WallpaperOriginX' 'REG_SZ' '0'
    Set-OfflineReg $desk 'WallpaperOriginY' 'REG_SZ' '0'

    # ApplyWallpaper.ps1 is invoked by UserOnce.ps1 (interactive user context)
    # and by a RunOnce entry for any profile created later.
    $applyWallLines = @(
        "`$wp = '$_wp'",
        "if (-not (Test-Path -LiteralPath `$wp)) { return }",
        "Set-ItemProperty -LiteralPath 'HKCU:\Control Panel\Desktop' -Name Wallpaper -Value `$wp",
        "Set-ItemProperty -LiteralPath 'HKCU:\Control Panel\Desktop' -Name WallpaperStyle -Value '10'",
        "Set-ItemProperty -LiteralPath 'HKCU:\Control Panel\Desktop' -Name TileWallpaper -Value '0'",
        'if (-not ([System.Management.Automation.PSTypeName]''NiixWallpaper'').Type) {',
        'Add-Type -TypeDefinition @"',
        'using System;',
        'using System.Runtime.InteropServices;',
        'public class NiixWallpaper {',
        '    [DllImport("user32.dll", CharSet=CharSet.Unicode, SetLastError=true)]',
        '    public static extern bool SystemParametersInfo(int uAction, int uParam, string lpvParam, int fuWinIni);',
        '}',
        '"@',
        '}',
        '[void][NiixWallpaper]::SystemParametersInfo(20, 0, $wp, 3)'
    )
    $utf8Bom = [System.Text.UTF8Encoding]::new($true)
    [System.IO.File]::WriteAllText((Join-Path $setupScriptsDir 'ApplyWallpaper.ps1'), ($applyWallLines -join "`r`n"), $utf8Bom)

    Set-OfflineReg $runOnce 'NiixWallpaper' 'REG_SZ' 'powershell.exe -WindowStyle Hidden -ExecutionPolicy Bypass -NoProfile -File "C:\Windows\Setup\Scripts\ApplyWallpaper.ps1"'
    Show-Progress "Wallpaper embedded and set as default." 88 -Done
} else {
    Write-Host ""
    Write-Body "No wallpaper.jpg/.jpeg/.png next to the script -- Windows default wallpaper will be used."
}

# -- 5s. Unload hives ----------------------------------------------------------
Show-Progress "Unloading offline registry hives..." 90
Dismount-OfflineHives
Show-Progress "All registry tweaks applied." 92 -Done
if ($script:RegWarnings.Count -gt 0) {
    Write-Warn "$($script:RegWarnings.Count) registry value(s) could not be written:"
    foreach ($w in $script:RegWarnings) { Write-Host "     - $w" -ForegroundColor Yellow }
}

# -- 5t. autounattend.xml (copied byte-for-byte) -------------------------------
Show-Progress "Writing autounattend.xml..." 95
Copy-Item -LiteralPath $_xmlPath -Destination (Join-Path $isoContents 'autounattend.xml') -Force
Remove-Item -LiteralPath (Join-Path $isoContents 'support') -Recurse -Force -ErrorAction SilentlyContinue
Show-Progress "All modifications complete." 100 -Done

# ===========================================================================
#  STEP 6  --  DISM CLEANUP
# ===========================================================================
Write-Title "STEP 6 -- DISM component cleanup (this takes several minutes)..."
Show-Progress "Running DISM /StartComponentCleanup /ResetBase..." 30
$r = Invoke-Quiet 'dism.exe' "/English `"/Image:$mountDir`" /Cleanup-Image /StartComponentCleanup /ResetBase"
if ($r.ExitCode -eq 0) {
    Show-Progress "DISM cleanup complete." 100 -Done
} else {
    Write-Host ""
    Write-Warn "DISM cleanup returned $($r.ExitCode) -- continuing (image is still valid, just larger)."
}

# ===========================================================================
#  STEP 7  --  SAVE IMAGE
# ===========================================================================
Write-Title "STEP 7 -- Saving modified image (takes several minutes)..."
Show-Progress "Dismounting and saving..." 30
Dismount-WindowsImage -Path $mountDir -Save -ErrorAction Stop | Out-Null
$script:WimMounted = $false
Show-Progress "Image saved." 100 -Done

# ===========================================================================
#  STEP 8  --  COMPACT INTO FINAL install.wim
#  Re-exporting drops the space of every file deleted above.
# ===========================================================================
Write-Title "STEP 8 -- Building final install.wim..."
Show-Progress "Exporting compacted image..." 40
Export-WindowsImage -SourceImagePath $workWim -SourceIndex 1 `
                    -DestinationImagePath $finalWim -CompressionType max -ErrorAction Stop | Out-Null
Remove-Item -LiteralPath $workWim -Force
Show-Progress "Single-edition install.wim ready." 100 -Done

# ===========================================================================
#  STEP 9  --  LOCATE OSCDIMG
# ===========================================================================
Write-Title "STEP 9 -- Locating oscdimg.exe..."

function Find-Oscdimg {
    $arch = switch ($env:PROCESSOR_ARCHITECTURE) { 'ARM64' { 'arm64' } 'x86' { 'x86' } default { 'amd64' } }
    $found = [System.Collections.Generic.List[string]]::new()
    $cmd = Get-Command 'oscdimg.exe' -CommandType Application -ErrorAction SilentlyContinue | Select-Object -First 1
    if ($cmd) { $found.Add($cmd.Source) }
    foreach ($kits in @("${env:ProgramFiles(x86)}\Windows Kits", "$env:ProgramFiles\Windows Kits")) {
        if ($kits -and (Test-Path -LiteralPath $kits)) {
            Get-ChildItem -LiteralPath $kits -Recurse -Filter 'oscdimg.exe' -File -ErrorAction SilentlyContinue |
                Where-Object { $_.DirectoryName -match "\\$arch\\Oscdimg$" } |
                ForEach-Object { $found.Add($_.FullName) }
        }
    }
    $wg = Join-Path $env:LOCALAPPDATA 'Microsoft\WinGet'
    $link = Join-Path $wg 'Links\oscdimg.exe'
    if (Test-Path -LiteralPath $link) { $found.Add($link) }
    $pkgs = Join-Path $wg 'Packages'
    if (Test-Path -LiteralPath $pkgs) {
        $all = @(Get-ChildItem -LiteralPath $pkgs -Recurse -Filter 'oscdimg.exe' -File -ErrorAction SilentlyContinue |
                 Where-Object { $_.FullName -match 'Microsoft\.OSCDIMG' })
        $pref = @($all | Where-Object { $_.FullName -match "\\$arch\\" })
        foreach ($f in ($pref + $all)) { $found.Add($f.FullName) }
    }
    $found | Where-Object { $_ -and (Test-Path -LiteralPath $_) } | Select-Object -First 1
}

Show-Progress "Searching for oscdimg.exe..." 50
$oscdimg = Find-Oscdimg
if (-not $oscdimg) {
    Write-Host ""
    Write-Body "oscdimg not found -- installing the latest version via winget..."
    if (Get-Command 'winget.exe' -ErrorAction SilentlyContinue) {
        & winget.exe install -e --id Microsoft.OSCDIMG --source winget --accept-package-agreements --accept-source-agreements --disable-interactivity | Out-Host
        $oscdimg = Find-Oscdimg
    } else {
        Write-Warn "winget is not available on this PC."
    }
}
if (-not $oscdimg) {
    throw "oscdimg.exe not found. Run 'winget install -e --id Microsoft.OSCDIMG' or install the Windows ADK Deployment Tools (https://learn.microsoft.com/windows-hardware/get-started/adk-install), then run this script again."
}
Show-Progress "oscdimg.exe found." 100 -Done
Write-Body $oscdimg

# ===========================================================================
#  STEP 10  --  BUILD ISO
# ===========================================================================
Write-Title "STEP 10 -- Building output ISO..."

$outputDir = Split-Path $script:SelectedISO -Parent
try {
    $probe = Join-Path $outputDir ('.niix_write_test_' + [guid]::NewGuid().ToString('N'))
    [System.IO.File]::WriteAllText($probe, '')
    Remove-Item -LiteralPath $probe -Force
} catch {
    $outputDir = $scriptDir
}
$outputISO = Join-Path $outputDir 'win11_niix.iso'
if (Test-Path -LiteralPath $outputISO) {
    try {
        Remove-Item -LiteralPath $outputISO -Force -ErrorAction Stop
    } catch {
        $outputISO = Join-Path $outputDir ("win11_niix_{0:yyyyMMdd_HHmmss}.iso" -f (Get-Date))
    }
}

$etfs   = Join-Path $isoContents 'boot\etfsboot.com'
$efisys = Join-Path $isoContents 'efi\microsoft\boot\efisys.bin'
foreach ($bf in @($etfs, $efisys)) {
    if (-not (Test-Path -LiteralPath $bf)) { throw "Boot file missing from ISO contents: $bf" }
}
$bootData    = "2#p0,e,b`"$etfs`"#pEF,e,b`"$efisys`""
$oscdimgArgs = "-m -o -u2 -udfver102 -lNIIX_WIN11 -bootdata:$bootData `"$isoContents`" `"$outputISO`""

$proc = Start-Process -FilePath $oscdimg -ArgumentList $oscdimgArgs -NoNewWindow -Wait -PassThru
if ($proc.ExitCode -ne 0 -or -not (Test-Path -LiteralPath $outputISO)) {
    throw "oscdimg failed (exit $($proc.ExitCode))."
}
Write-Host ""
Show-Progress "ISO built successfully." 100 -Done

# ===========================================================================
#  SUMMARY
# ===========================================================================
$outGB   = [math]::Round((Get-Item -LiteralPath $outputISO).Length / 1GB, 2)
$outName = Split-Path $outputISO -Leaf

Write-Host ""
Write-Banner "  +----------------------------------------------------------+"
Write-Banner "  |                                                          |"
Write-Banner "  |   BUILD COMPLETE                                         |"
Write-Banner "  |                                                          |"
Write-Host   ("  |   Output  : {0,-45}|" -f $outName)         -ForegroundColor $PINK
Write-Host   ("  |   Size    : {0,-45}|" -f "$outGB GB")       -ForegroundColor $PINK
Write-Host   ("  |   Edition : {0,-45}|" -f $selectedEdition)  -ForegroundColor $PINK
Write-Banner "  |                                                          |"
Write-Banner "  +----------------------------------------------------------+"
Write-Host ""
Write-Body "Saved to: $outputISO"
Write-Host ""
Write-Host "  Applied:" -ForegroundColor $PINK
$items = @(
    "Removed $removed provisioned AppX packages (Xbox, GameBar, Teams, Copilot...)",
    "OneDrive setup and Edge browser files deleted from the image",
    "Telemetry / Copilot / Recall / AI disabled by policy",
    "Windows Backup capability removed offline",
    "Xbox, GameBar and Edge browser services disabled (WebView2 kept)",
    "Edge browser reinstall blocked via EdgeUpdate policy",
    "Apps denied access to diagnostic info (other permissions user-controlled)",
    "Hardware bypass (TPM / Secure Boot / CPU / RAM / storage)",
    "Windows Update paused during OOBE only (restored at first logon)",
    "Gaming tweaks baked in: Game Mode, GPU scheduling, mouse accel off,",
    "  fullscreen optimizations off, Memory Integrity (HVCI/VBS) off",
    "autounattend.xml added to the ISO root",
    "niix-tweaks.ps1 auto-runs once at first logon (elevated, no UAC prompt)",
    "  and a copy is placed on the Desktop for manual re-runs",
    "Logs saved to Documents\NiixDebloat-Logs after first logon"
)
if ($script:DriverExportDir) { $items += "This PC's drivers exported and injected into the image" }
if ($customWall)             { $items += "Custom wallpaper set as the default background" }
if ($bundledExes.Count -gt 0) { $items += "$($bundledExes.Count) .exe file(s) placed on the Public Desktop: $(($bundledExes | ForEach-Object Name) -join ', ')" }
foreach ($item in $items) { Write-Host "   * $item" -ForegroundColor $WHITE }
Write-Host ""

} catch {
    $exitCode = 1
    Write-Host ""
    Write-Err "$($_.Exception.Message)"
    Write-Body "Cleaning up (temporary files, mounted image and ISO)..."
} finally {
    Invoke-Cleanup
}

Read-Host "  Press Enter to exit" | Out-Null
exit $exitCode
