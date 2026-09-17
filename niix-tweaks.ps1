#Requires -RunAsAdministrator
<#
.SYNOPSIS
    niix-tweaks.ps1 - Post-install privacy hardening, debloat and service tweaks
.DESCRIPTION
    Run once on a fresh Windows 11 install. Removes Edge, Windows Backup,
    applies all privacy/service tweaks and dark theme correctly.
#>

# ---- Self-elevate ----
if (-not ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()
    ).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
    Start-Process powershell -ArgumentList "-ExecutionPolicy Bypass -NoProfile -File `"$PSCommandPath`"" -Verb RunAs
    exit
}

# ---- Only run once: unregister the auto-run scheduled task if present ----
# (harmless no-op if it doesn't exist, e.g. when double-clicked manually)
Unregister-ScheduledTask -TaskName 'NiixTweaksAutoRun' -Confirm:$false -ErrorAction SilentlyContinue

# ---- Fix the execution policy permanently, once, so this never blocks a
# manual re-run of this (or any other local) script again. RemoteSigned still
# requires downloaded/remote scripts to be signed -- it only stops blocking
# scripts that already exist locally on this machine, which is what the
# default "Restricted" policy was doing to you just now.
try {
    Set-ExecutionPolicy -ExecutionPolicy RemoteSigned -Scope LocalMachine -Force -ErrorAction Stop
    Write-Host "  [OK] Execution policy set to RemoteSigned (local scripts will always run from now on)" -ForegroundColor Cyan
} catch {
    Write-Host "  [WARN] Set-ExecutionPolicy: $_" -ForegroundColor Yellow
}

# ---- Full transcript log, saved to this user's Documents for troubleshooting ----
$logDir = Join-Path ([Environment]::GetFolderPath('MyDocuments')) 'NiixDebloat-Logs'
New-Item -ItemType Directory -Path $logDir -Force -ErrorAction SilentlyContinue | Out-Null
$logFile = Join-Path $logDir ("niix-tweaks_{0:yyyy-MM-dd_HH-mm-ss}.log" -f (Get-Date))
try { Start-Transcript -Path $logFile -Force | Out-Null } catch { }

$C = 'Cyan'; $G = 'Green'; $W = 'White'; $R = 'Red'
$warnings = [System.Collections.Generic.List[string]]::new()

function Write-Title   { param($t) Write-Host "`n  $t" -ForegroundColor $G }
function Write-Body    { param($t) Write-Host "  $t"   -ForegroundColor $W }
function Write-Ok      { param($t) Write-Host "  [OK] $t" -ForegroundColor $C }
function Write-Warn    { param($t) Write-Host "  [WARN] $t" -ForegroundColor Yellow; $script:warnings.Add($t) }

function Set-Reg {
    param([string]$Path, [string]$Name, [string]$Type, $Value)
    try {
        if (-not (Test-Path $Path)) { New-Item -Path $Path -Force | Out-Null }
        if ($Name -eq '') {
            Set-Item -Path $Path -Value $Value -Force
        } else {
            Set-ItemProperty -Path $Path -Name $Name -Type $Type -Value $Value -Force
        }
    } catch { Write-Warn "Reg $Path\$Name : $_" }
}

# P/Invoke: enable SeRestorePrivilege + SeBackupPrivilege so we can
# take ownership of system-protected registry keys
$script:_privEnabled = $false
function Enable-RegPrivileges {
    if ($script:_privEnabled) { return }
    try {
        Add-Type -TypeDefinition @'
using System;
using System.Runtime.InteropServices;
public class TokenPriv {
    [DllImport("advapi32.dll", ExactSpelling=true, SetLastError=true)]
    static extern bool AdjustTokenPrivileges(IntPtr htok, bool disall,
        ref TokPriv1Luid newst, int len, IntPtr prev, IntPtr relen);
    [DllImport("advapi32.dll", ExactSpelling=true, SetLastError=true)]
    static extern bool OpenProcessToken(IntPtr h, int acc, ref IntPtr phtok);
    [DllImport("advapi32.dll", SetLastError=true)]
    static extern bool LookupPrivilegeValue(string host, string name, ref long pluid);
    [StructLayout(LayoutKind.Sequential, Pack=1)]
    struct TokPriv1Luid { public int Count; public long Luid; public int Attr; }
    const int SE_PRIVILEGE_ENABLED = 2;
    const int TOKEN_QUERY = 8; const int TOKEN_ADJUST_PRIVILEGES = 32;
    public static void Enable(string privilege) {
        IntPtr hproc = System.Diagnostics.Process.GetCurrentProcess().Handle;
        IntPtr htok  = IntPtr.Zero;
        OpenProcessToken(hproc, TOKEN_ADJUST_PRIVILEGES | TOKEN_QUERY, ref htok);
        TokPriv1Luid tp; tp.Count=1; tp.Luid=0; tp.Attr=SE_PRIVILEGE_ENABLED;
        LookupPrivilegeValue(null, privilege, ref tp.Luid);
        AdjustTokenPrivileges(htok, false, ref tp, 0, IntPtr.Zero, IntPtr.Zero);
    }
}
'@ -ErrorAction SilentlyContinue
        [TokenPriv]::Enable('SeRestorePrivilege')
        [TokenPriv]::Enable('SeBackupPrivilege')
        [TokenPriv]::Enable('SeTakeOwnershipPrivilege')
        $script:_privEnabled = $true
    } catch { Write-Warn "Enable-RegPrivileges: $_" }
}

function Set-RegOwned {
    param([string]$Path, [string]$Name, [string]$Type, $Value)
    Enable-RegPrivileges
    try {
        $hive = $Path.Split(':\')[0]
        $sub  = $Path.Substring($Path.IndexOf(':\') + 2)
        $hiveMap = @{
            'HKLM' = [Microsoft.Win32.Registry]::LocalMachine
            'HKCU' = [Microsoft.Win32.Registry]::CurrentUser
            'HKCR' = [Microsoft.Win32.Registry]::ClassesRoot
        }
        $root = $hiveMap[$hive]
        # Open with TakeOwnership right (requires SeTakeOwnershipPrivilege)
        $key = $root.OpenSubKey($sub,
            [Microsoft.Win32.RegistryKeyPermissionCheck]::ReadWriteSubTree,
            [System.Security.AccessControl.RegistryRights]::TakeOwnership)
        if ($key) {
            $acl = $key.GetAccessControl(
                [System.Security.AccessControl.AccessControlSections]::None)
            $acl.SetOwner([System.Security.Principal.NTAccount]'Administrators')
            $key.SetAccessControl($acl)
            $key.Close()
        }
        # Re-open with ChangePermissions to grant full control
        $key2 = $root.OpenSubKey($sub,
            [Microsoft.Win32.RegistryKeyPermissionCheck]::ReadWriteSubTree,
            [System.Security.AccessControl.RegistryRights]::ChangePermissions)
        if ($key2) {
            $acl2 = $key2.GetAccessControl()
            $rule = [System.Security.AccessControl.RegistryAccessRule]::new(
                'Administrators',
                [System.Security.AccessControl.RegistryRights]::FullControl,
                [System.Security.AccessControl.InheritanceFlags]::ContainerInherit,
                [System.Security.AccessControl.PropagationFlags]::None,
                [System.Security.AccessControl.AccessControlType]::Allow)
            $acl2.SetAccessRule($rule)
            $key2.SetAccessControl($acl2)
            $key2.Close()
        }
    } catch { Write-Warn "TakeOwn $Path : $_" }
    Set-Reg $Path $Name $Type $Value
}

function Disable-Svc {
    param([string]$Name)
    try {
        $svc = Get-Service -Name $Name -ErrorAction Stop
        Stop-Service  -Name $Name -Force -ErrorAction SilentlyContinue
        Set-Service   -Name $Name -StartupType Disabled
    } catch {
        # Service doesn't exist - that's fine
    }
}

function Remove-AppXByName {
    param([string]$Name)
    try {
        Get-AppxPackage -Name "*$Name*" -AllUsers -ErrorAction SilentlyContinue |
            Remove-AppxPackage -AllUsers -ErrorAction SilentlyContinue
        Get-AppxProvisionedPackage -Online -ErrorAction SilentlyContinue |
            Where-Object { $_.DisplayName -like "*$Name*" } |
            Remove-AppxProvisionedPackage -Online -ErrorAction SilentlyContinue
    } catch {}
}

Clear-Host
Write-Host ""
Write-Host "  +----------------------------------------------------------+" -ForegroundColor $C
Write-Host "  |   niix-tweaks  --  Post-Install Hardening Script         |" -ForegroundColor $C
Write-Host "  |   Running as Administrator. Restart when done.           |" -ForegroundColor $C
Write-Host "  +----------------------------------------------------------+" -ForegroundColor $C
Write-Host ""

# ============================================================
#  1. REMOVE APPX BLOATWARE
# ============================================================
Write-Title "1. Removing AppX bloatware..."

$bloat = @(
    'Microsoft.XboxIdentityProvider','Microsoft.XboxSpeechToTextOverlay',
    'Microsoft.GamingApp','Microsoft.Xbox.TCUI','Microsoft.XboxGamingOverlay',
    'Microsoft.XboxGameOverlay','Microsoft.XboxApp',
    'MicrosoftWindows.GameBar','MicrosoftWindows.Client.GameBar',
    'Microsoft.BingNews','Microsoft.BingSearch','Microsoft.BingWeather',
    'Microsoft.Copilot','Microsoft.Windows.CrossDevice','Microsoft.GetHelp',
    'Microsoft.Getstarted','Microsoft.Microsoft3DViewer','Microsoft.MicrosoftOfficeHub',
    'Microsoft.MicrosoftSolitaireCollection','Microsoft.MicrosoftStickyNotes',
    'Microsoft.MixedReality.Portal','Microsoft.MSPaint','Microsoft.Office.OneNote',
    'Microsoft.OfficePushNotificationUtility','Microsoft.OutlookForWindows',
    'Microsoft.People','Microsoft.PowerAutomateDesktop','Microsoft.SkypeApp',
    'Microsoft.StartExperiencesApp','Microsoft.Todos','Microsoft.Wallet',
    'Microsoft.Windows.DevHome','Microsoft.Windows.Copilot','Microsoft.Windows.Teams',
    'Microsoft.WindowsAlarms','Microsoft.WindowsCamera',
    'microsoft.windowscommunicationsapps','Microsoft.WindowsFeedbackHub',
    'Microsoft.WindowsMaps','Microsoft.WindowsSoundRecorder',
    'Microsoft.ZuneMusic','Microsoft.ZuneVideo',
    'MicrosoftCorporationII.MicrosoftFamily','MicrosoftCorporationII.QuickAssist',
    'MSTeams','MicrosoftTeams','Clipchamp.Clipchamp'
)

foreach ($pkg in $bloat) { Remove-AppXByName $pkg }
Write-Ok "AppX removal pass complete"

# ============================================================
#  2. REMOVE WINDOWS BACKUP (WindowsCapability, not AppX)
# ============================================================
Write-Title "2. Removing Windows Backup..."

try {
    $cap = Get-WindowsCapability -Online -ErrorAction SilentlyContinue |
           Where-Object { $_.Name -like '*WindowsBackup*' -or $_.Name -like '*BackupAndRestore*' }
    if ($cap) {
        $cap | Remove-WindowsCapability -Online -ErrorAction SilentlyContinue | Out-Null
        Write-Ok "Windows Backup capability removed"
    } else {
        Write-Body "Windows Backup capability not found (may already be removed)"
    }
} catch { Write-Warn "Windows Backup removal: $_" }

# Also remove the AppX entry if present
Remove-AppXByName 'Microsoft.WindowsBackup'

# Disable backup service and policy
Disable-Svc 'SDRSVC'   # Windows Backup service
Disable-Svc 'wbengine' # Block Level Backup Engine
Set-Reg 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\BackupAndRestore' 'DisableBackup' 'DWord' 1

Write-Ok "Windows Backup disabled"

# ============================================================
#  3. REMOVE MICROSOFT EDGE
# ============================================================
Write-Title "3. Removing Microsoft Edge completely..."

# Step 1: Run the official uninstaller if Edge is still present (it may have been
# removed offline already by niixdebloat.ps1, but run it anyway to be sure)
$edgeSetups = @(Get-ChildItem "C:\Program Files (x86)\Microsoft\Edge\Application\*\Installer\setup.exe" -ErrorAction SilentlyContinue)
if ($edgeSetups.Count -gt 0) {
    Write-Body "Edge install found - running official uninstaller..."
    try {
        # Stub file unlocks the uninstaller (winutil method)
        $stubDir = "C:\Windows\SystemApps\Microsoft.MicrosoftEdge_8wekyb3d8bbwe"
        if (-not (Test-Path $stubDir)) { New-Item -Path $stubDir -ItemType Directory -Force | Out-Null }
        New-Item -Path "$stubDir\MicrosoftEdge.exe" -Force | Out-Null

        $proc = Start-Process -FilePath $edgeSetups[0].FullName `
            -ArgumentList '--uninstall --system-level --force-uninstall --delete-profile' `
            -Wait -PassThru -NoNewWindow -ErrorAction Stop
        if ($proc.ExitCode -eq 0) { Write-Ok "Edge uninstaller exited cleanly" }
        else { Write-Warn "Edge uninstaller exit code: $($proc.ExitCode) - continuing with manual removal" }
    } catch { Write-Warn "Uninstaller error: $_ - continuing with manual removal" }
} else {
    Write-Body "Edge installer not found - likely removed offline already"
}

# Step 2: Force-delete all remaining Edge directories and files
Write-Body "Force-deleting remaining Edge files..."
# EdgeUpdate and EdgeWebView are deliberately kept -- WebView2 Runtime shares
# both with the Edge browser, and apps like Stremio, WhatsApp Desktop, and
# many other Electron/webview-based apps depend on WebView2 even with the
# Edge browser itself removed.
$edgeDirs = @(
    "C:\Program Files (x86)\Microsoft\Edge",
    "C:\Program Files (x86)\Microsoft\EdgeCore",
    "C:\Windows\SystemApps\Microsoft.MicrosoftEdge_8wekyb3d8bbwe",
    "C:\Windows\SystemApps\Microsoft.MicrosoftEdgeDevToolsClient_8wekyb3d8bbwe"
)
foreach ($dir in $edgeDirs) {
    if (Test-Path $dir) {
        try {
            & takeown /f $dir /r /d y 2>&1 | Out-Null
            & icacls $dir /grant "Administrators:(F)" /T /C /Q 2>&1 | Out-Null
            Remove-Item $dir -Recurse -Force -ErrorAction Stop
            Write-Body "Deleted: $dir"
        } catch { Write-Warn "Could not fully delete $dir : $_" }
    }
}

# Step 3: Remove Edge shortcuts
Remove-Item "$env:PUBLIC\Desktop\Microsoft Edge.lnk"      -Force -ErrorAction SilentlyContinue
Remove-Item "$env:USERPROFILE\Desktop\Microsoft Edge.lnk" -Force -ErrorAction SilentlyContinue
Remove-Item "$env:APPDATA\Microsoft\Windows\Start Menu\Programs\Microsoft Edge.lnk" -Force -ErrorAction SilentlyContinue

# Step 4: Disable Edge-browser-only services (leave edgeupdate/edgeupdatem
# running -- WebView2 needs the updater service to install/repair itself)
'MicrosoftEdgeElevationService' | ForEach-Object { Disable-Svc $_ }

# Step 5: Apply registry blocks to prevent the Edge *browser* coming back,
# while explicitly re-allowing the WebView2 Runtime (separate product, same
# updater) so apps that depend on it keep working.
Set-Reg 'HKLM:\SOFTWARE\Microsoft\EdgeUpdate'          'DoNotUpdateToEdgeWithChromium' 'DWord'  1
Set-Reg 'HKLM:\SOFTWARE\Policies\Microsoft\EdgeUpdate' 'UpdateDefault'                 'DWord'  0
Set-Reg 'HKLM:\SOFTWARE\Policies\Microsoft\EdgeUpdate' 'InstallDefault'                'DWord'  0
Set-Reg 'HKLM:\SOFTWARE\Policies\Microsoft\EdgeUpdate' 'Install{F3017226-FE2A-4295-8BDF-00C3A9A7E4C5}' 'DWord' 1
Set-Reg 'HKLM:\SOFTWARE\Policies\Microsoft\EdgeUpdate' 'Update{F3017226-FE2A-4295-8BDF-00C3A9A7E4C5}'  'DWord' 1
Set-Reg 'HKLM:\SOFTWARE\Policies\Microsoft\Edge'       'HideFirstRunExperience'        'DWord'  1
Set-Reg 'HKLM:\SOFTWARE\Policies\Microsoft\Edge'       'BackgroundModeEnabled'         'DWord'  0
Set-Reg 'HKLM:\SOFTWARE\Policies\Microsoft\Edge'       'StartupBoostEnabled'           'DWord'  0
Set-RegOwned 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\MicrosoftEdge' 'IsEdgeStableSetupDone' 'DWord' 1

# Make sure the updater service WebView2 relies on is actually running
foreach ($svc in 'edgeupdate','edgeupdatem') {
    try {
        Set-Service -Name $svc -StartupType Manual -ErrorAction SilentlyContinue
    } catch {}
}

# Block Windows Update from pushing Edge back
Remove-ItemProperty 'HKLM:\SOFTWARE\Microsoft\WindowsUpdate\Orchestrator\UScheduler_Oobe' `
    -Name 'EdgeUpdate' -Force -ErrorAction SilentlyContinue

Write-Ok "Edge fully removed and permanently blocked"

# ============================================================
#  4. DISABLE XBOX / GAMEBAR SERVICES
# ============================================================
Write-Title "4. Disabling Xbox and GameBar services..."

'XblAuthManager','XblGameSave','XboxGipSvc','XboxNetApiSvc' | ForEach-Object { Disable-Svc $_ }

Set-Reg 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\GameDVR'   'AllowGameDVR'              'DWord' 0
Set-Reg 'HKCU:\System\GameConfigStore'                         'GameDVR_Enabled'           'DWord' 0
Set-Reg 'HKCU:\System\GameConfigStore'                         'GameDVR_FSEBehaviorMode'   'DWord' 2
Set-Reg 'HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\GameDVR' 'AppCaptureEnabled'     'DWord' 0
Set-Reg 'HKCU:\SOFTWARE\Microsoft\GameBar'                    'UseNexusForGameBarEnabled' 'DWord' 0
Set-Reg 'HKCU:\SOFTWARE\Microsoft\GameBar'                    'AllowAutoGameMode'         'DWord' 0

Write-Ok "Xbox and GameBar disabled"

# ============================================================
#  5. DISABLE PRIVACY-INVASIVE SERVICES
# ============================================================
Write-Title "5. Disabling privacy-invasive services..."

@('DiagTrack','dmwappushservice','SysMain','RemoteRegistry','WerSvc','DPS',
  'MapsBroker','lfsvc','TrkWks','WMPNetworkSvc','WpcMonSvc','wisvc',
  'RetailDemo','PhoneSvc','PcaSvc') | ForEach-Object { Disable-Svc $_ }

Write-Ok "Privacy-invasive services disabled"

# ============================================================
#  6. TELEMETRY & DATA COLLECTION
# ============================================================
Write-Title "6. Applying telemetry and privacy tweaks..."

Set-Reg 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\DataCollection'                'AllowTelemetry'                              'DWord' 0
Set-Reg 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\DataCollection'                'DoNotShowFeedbackNotifications'              'DWord' 1
Set-Reg 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\DataCollection'                'LimitDiagnosticLogCollection'                'DWord' 1
Set-Reg 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\DataCollection'                'DisableOneSettingsDownloads'                 'DWord' 1
Set-Reg 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Policies\DataCollection' 'AllowTelemetry'                              'DWord' 0
Set-Reg 'HKCU:\Software\Microsoft\Windows\CurrentVersion\AdvertisingInfo'         'Enabled'                                     'DWord' 0
Set-Reg 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\AdvertisingInfo'               'DisabledByGroupPolicy'                       'DWord' 1
Set-Reg 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\System'                        'EnableActivityFeed'                          'DWord' 0
Set-Reg 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\System'                        'PublishUserActivities'                       'DWord' 0
Set-Reg 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\System'                        'UploadUserActivities'                        'DWord' 0
Set-Reg 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\LocationAndSensors'            'DisableLocation'                             'DWord' 1
Set-Reg 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\LocationAndSensors'            'DisableLocationScripting'                    'DWord' 1
Set-Reg 'HKCU:\Software\Microsoft\InputPersonalization'                           'RestrictImplicitInkCollection'               'DWord' 1
Set-Reg 'HKCU:\Software\Microsoft\InputPersonalization'                           'RestrictImplicitTextCollection'              'DWord' 1
Set-Reg 'HKCU:\Software\Microsoft\InputPersonalization\TrainedDataStore'          'HarvestContacts'                             'DWord' 0
Set-Reg 'HKCU:\Software\Microsoft\Personalization\Settings'                       'AcceptedPrivacyPolicy'                       'DWord' 0
Set-Reg 'HKCU:\Software\Microsoft\Speech_OneCore\Settings\OnlineSpeechPrivacy'    'HasAccepted'                                 'DWord' 0
Set-Reg 'HKCU:\Software\Microsoft\Input\TIPC'                                     'Enabled'                                     'DWord' 0
Set-Reg 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\Windows Error Reporting'       'Disabled'                                    'DWord' 1

$ap = 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\AppPrivacy'
@('LetAppsGetDiagnosticInfo','LetAppsRunInBackground','LetAppsAccessLocation',
  'LetAppsAccessCamera','LetAppsAccessMicrophone','LetAppsAccessContacts',
  'LetAppsAccessCalendar','LetAppsAccessCallHistory','LetAppsAccessEmail',
  'LetAppsAccessMessaging','LetAppsAccessMotion','LetAppsAccessAccountInfo',
  'LetAppsAccessTasks','LetAppsAccessBackgroundSpatialPerception') |
  ForEach-Object { Set-Reg $ap $_ 'DWord' 2 }

Write-Ok "Telemetry and privacy tweaks applied"

# ============================================================
#  7. CONTENT DELIVERY / SPONSORED APPS
# ============================================================
Write-Title "7. Disabling sponsored apps and content delivery..."

$cdm = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\ContentDeliveryManager'
@('OemPreInstalledAppsEnabled','PreInstalledAppsEnabled','SilentInstalledAppsEnabled',
  'ContentDeliveryAllowed','FeatureManagementEnabled','PreInstalledAppsEverEnabled',
  'SoftLandingEnabled','SubscribedContentEnabled','SystemPaneSuggestionsEnabled',
  'SubscribedContent-310093Enabled','SubscribedContent-338388Enabled',
  'SubscribedContent-338389Enabled','SubscribedContent-338393Enabled',
  'SubscribedContent-353694Enabled','SubscribedContent-353696Enabled') |
  ForEach-Object { Set-Reg $cdm $_ 'DWord' 0 }

Set-Reg 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\CloudContent' 'DisableWindowsConsumerFeatures'     'DWord' 1
Set-Reg 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\CloudContent' 'DisableConsumerAccountStateContent' 'DWord' 1
Set-Reg 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\CloudContent' 'DisableCloudOptimizedContent'       'DWord' 1
Set-Reg 'HKLM:\SOFTWARE\Policies\Microsoft\PushToInstall'        'DisablePushToInstall'               'DWord' 1

Write-Ok "Content delivery and sponsored apps disabled"

# ============================================================
#  8. COPILOT / AI / RECALL / BING
# ============================================================
Write-Title "8. Disabling Copilot, Recall, Bing and AI features..."

Set-Reg 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\WindowsCopilot' 'TurnOffWindowsCopilot'      'DWord' 1
Set-Reg 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\WindowsAI'      'DisableAIDataAnalysis'      'DWord' 1
Set-Reg 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\WindowsAI'      'TurnOffSavingSnapshots'     'DWord' 1
Set-Reg 'HKCU:\Software\Policies\Microsoft\Windows\Explorer'        'DisableSearchBoxSuggestions' 'DWord' 1
Set-Reg 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\Explorer'        'DisableSearchBoxSuggestions' 'DWord' 1

try {
    $recall = Get-WindowsOptionalFeature -Online -ErrorAction SilentlyContinue |
              Where-Object { $_.FeatureName -like 'Recall' -and $_.State -eq 'Enabled' }
    if ($recall) { Disable-WindowsOptionalFeature -Online -FeatureName 'Recall' -Remove -NoRestart -ErrorAction SilentlyContinue }
} catch {}

Write-Ok "Copilot, Recall and AI features disabled"

# ============================================================
#  9. TASKBAR / UI
# ============================================================
Write-Title "9. Cleaning up Taskbar and UI..."

$adv = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\Advanced'
# TaskbarDa and some Explorer\Advanced keys are ACL-protected -- take ownership first
# TaskbarMn/Da are ACL-protected -- reg.exe bypasses .NET registry check
& reg add 'HKCU\Software\Microsoft\Windows\CurrentVersion\Explorer\Advanced' /v TaskbarMn /t REG_DWORD /d 0 /f 2>&1 | Out-Null
& reg add 'HKCU\Software\Microsoft\Windows\CurrentVersion\Explorer\Advanced' /v TaskbarDa /t REG_DWORD /d 0 /f 2>&1 | Out-Null
Set-Reg $adv 'ShowTaskViewButton'     'DWord' 0
Set-Reg $adv 'TaskbarAl'              'DWord' 0
Set-Reg $adv 'HideFileExt'            'DWord' 0
Set-Reg $adv 'Hidden'                 'DWord' 1
Set-Reg $adv 'Start_TrackProgs'       'DWord' 0
Set-Reg $adv 'Start_TrackDocs'        'DWord' 0
Set-Reg $adv 'EnableSnapAssistFlyout' 'DWord' 0
Set-Reg $adv 'Start_IrisRecommendations'   'DWord' 0
Set-Reg $adv 'Start_AccountNotifications'  'DWord' 0
# "Recommended" section on the Start menu (Windows 11 24H2+ needs this key
# too, Start_IrisRecommendations alone isn't enough to fully hide it)
Set-Reg $adv 'HideRecommendedSection' 'DWord' 1
Set-Reg 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\Explorer' 'HideRecommendedSection' 'DWord' 1
# Show seconds in the taskbar clock
Set-Reg $adv 'ShowSecondsInSystemClock' 'DWord' 1
Set-Reg 'HKCU:\Software\Classes\CLSID\{86ca1aa0-34aa-4e8b-a509-50c905bae2a2}\InprocServer32' '' 'String' ''
Set-Reg 'HKLM:\SOFTWARE\Policies\Microsoft\Dsh'                                   'AllowNewsAndInterests'   'DWord'  0
Set-Reg 'HKLM:\SOFTWARE\Microsoft\PolicyManager\current\device\Start'             'ConfigureStartPins' 'String' '{"pinnedList":[]}'
Set-Reg 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Search'                  'SearchboxTaskbarMode'    'DWord'  0
Set-Reg 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Start'                   'ShowRecentList'          'DWord'  0
Set-Reg 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Start'                   'ShowFrequentList'        'DWord'  0

# Unpin Microsoft Store from the taskbar. The layout-XML mechanism in the
# unattend answer file already tries to ship an empty taskbar pin list, but
# it only applies cleanly to brand-new profiles created after imaging; this
# is a direct, always-works fallback that runs against whatever is pinned
# right now, using the same "Unpin from taskbar" verb the shell itself uses.
try {
    $storeApp = Get-StartApps | Where-Object { $_.AppID -like '*WindowsStore*' } | Select-Object -First 1
    if ($storeApp) {
        $shellApp = New-Object -ComObject Shell.Application
        $folder = $shellApp.NameSpace('shell:::{4234d49b-0245-4df3-b780-3893943456e1}') # Apps folder
        $item = $folder.ParseName($storeApp.AppID)
        $verb = $item.Verbs() | Where-Object { ($_.Name -replace '&','') -match 'unpin.*taskbar' }
        if ($verb) { $verb.DoIt() }
    }
} catch { Write-Warn "Unpinning Microsoft Store from taskbar: $_" }

@('Windows.SystemToast.Suggested','Windows.SystemToast.StartupApp',
  'Microsoft.SkyDrive.Desktop','Windows.SystemToast.AccountHealth') | ForEach-Object {
    Set-Reg "HKCU:\Software\Microsoft\Windows\CurrentVersion\Notifications\Settings\$_" 'Enabled' 'DWord' 0
}

Write-Ok "Taskbar and UI cleaned up"

# ============================================================
#  10. DARK THEME
#  Must restart Explorer after setting to take effect properly
# ============================================================
Write-Title "10. Applying dark theme..."

$themePath = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Themes\Personalize'
Set-Reg $themePath 'SystemUsesLightTheme' 'DWord' 0
Set-Reg $themePath 'AppsUseLightTheme'    'DWord' 0
Set-Reg $themePath 'EnableTransparency'   'DWord' 1
Set-Reg $themePath 'ColorPrevalence'      'DWord' 0

# Accent colour (Windows blue #0078D4)
Set-Reg 'HKCU:\Software\Microsoft\Windows\DWM' 'ColorPrevalence' 'DWord' 0

# Broadcast theme change to all windows so it takes effect immediately
try {
    Add-Type -TypeDefinition @"
using System;
using System.Runtime.InteropServices;
public class NiixWin32 {
    [DllImport("user32.dll", CharSet = CharSet.Auto, SetLastError = false)]
    public static extern IntPtr SendMessageTimeout(IntPtr hWnd, uint Msg, IntPtr wParam,
        string lParam, uint fuFlags, uint uTimeout, out IntPtr lpdwResult);
}
"@ -ErrorAction SilentlyContinue
    $result = [IntPtr]::Zero
    [NiixWin32]::SendMessageTimeout([IntPtr]0xffff, 0x1A, [IntPtr]::Zero, 'ImmersiveColorSet', 0x2, 5000, [ref]$result) | Out-Null
} catch {}

# Restart Explorer so theme applies visually right now
Write-Body "Restarting Explorer to apply theme..."
Stop-Process -Name explorer -Force -ErrorAction SilentlyContinue
Start-Sleep -Seconds 2
# Explorer auto-restarts; if not, force it
if (-not (Get-Process explorer -ErrorAction SilentlyContinue)) {
    Start-Process explorer
}

Write-Ok "Dark theme applied"

# ============================================================
#  11. ONEDRIVE
# ============================================================
Write-Title "11. Removing OneDrive..."

try {
    Stop-Process -Name OneDrive -Force -ErrorAction SilentlyContinue
    Start-Sleep -Milliseconds 500
    $ods = @("$env:SystemRoot\System32\OneDriveSetup.exe","$env:SystemRoot\SysWOW64\OneDriveSetup.exe") |
           Where-Object { Test-Path $_ } | Select-Object -First 1
    if ($ods) {
        Start-Process $ods -ArgumentList '/uninstall' -Wait -NoNewWindow
        Write-Ok "OneDrive uninstalled"
    } else {
        Write-Body "OneDriveSetup.exe not found (likely already removed from ISO)"
    }
} catch { Write-Warn "OneDrive: $_" }

Set-Reg 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\OneDrive' 'DisableFileSyncNGSC'                   'DWord' 1
Set-Reg 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\OneDrive' 'DisableLibrariesDefaultSaveToOneDrive' 'DWord' 1

# ============================================================
#  12. WINDOWS UPDATE POLICY
# ============================================================
Write-Title "12. Configuring Windows Update..."

# Remove the OOBE-time suppression keys (they were written to prevent updates during setup)
'NoAutoUpdate','AUOptions','UseWUServer' | ForEach-Object {
    Remove-ItemProperty 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\WindowsUpdate\AU' $_ -Force -ErrorAction SilentlyContinue
}
'DisableWindowsUpdateAccess','WUServer','WUStatusServer' | ForEach-Object {
    Remove-ItemProperty 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\WindowsUpdate' $_ -Force -ErrorAction SilentlyContinue
}

# No auto-restart, notify only, no P2P delivery
Set-Reg 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\WindowsUpdate\AU' 'NoAutoRebootWithLoggedOnUsers' 'DWord' 1
Set-Reg 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\WindowsUpdate\AU' 'AUOptions'                     'DWord' 3
Set-Reg 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\DeliveryOptimization\Config' 'DODownloadMode' 'DWord' 0

Set-Service -Name 'BITS'         -StartupType Manual    -ErrorAction SilentlyContinue
Set-Service -Name 'wuauserv'     -StartupType Manual    -ErrorAction SilentlyContinue
Set-Service -Name 'UsoSvc'       -StartupType Automatic -ErrorAction SilentlyContinue
Set-Service -Name 'WaaSMedicSvc' -StartupType Manual    -ErrorAction SilentlyContinue

# Actually start them now rather than waiting for next reboot, and reset the
# WU client's local state in case it's stuck from the offline suppression
try {
    Stop-Service -Name wuauserv -Force -ErrorAction SilentlyContinue
    Start-Service -Name BITS      -ErrorAction SilentlyContinue
    Start-Service -Name wuauserv  -ErrorAction SilentlyContinue
    Start-Service -Name UsoSvc    -ErrorAction SilentlyContinue
} catch { Write-Warn "Restarting WU services: $_" }

Write-Ok "Windows Update configured (notify-only, no auto-restart, no P2P)"

# ============================================================
#  13. BITLOCKER
# ============================================================
Write-Title "13. Checking BitLocker..."

try {
    $bl = Get-BitLockerVolume -MountPoint $env:SystemDrive -ErrorAction SilentlyContinue
    if ($bl -and $bl.ProtectionStatus -eq 'On') {
        Disable-BitLocker -MountPoint $env:SystemDrive -ErrorAction Stop | Out-Null
        Write-Ok "BitLocker disabled"
    } else {
        Write-Body "BitLocker not active"
    }
} catch { Write-Warn "BitLocker: $_" }
Set-Reg 'HKLM:\SYSTEM\CurrentControlSet\Control\BitLocker' 'PreventDeviceEncryption' 'DWord' 1

# ============================================================
#  14. MISCELLANEOUS
# ============================================================
Write-Title "14. Miscellaneous hardening..."

Set-Reg 'HKLM:\SYSTEM\CurrentControlSet\Control\FileSystem' 'LongPathsEnabled'                 'DWord' 1
Set-Reg 'HKCU:\Control Panel\Accessibility\StickyKeys'      'Flags'                            'String' '10'
Set-Reg 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\System'  'EnableSmartScreen'                'DWord' 0
net.exe accounts /maxpwage:UNLIMITED 2>&1 | Out-Null

try {
    if ((bcdedit | Select-String 'path').Count -eq 2) {
        bcdedit /set '{bootmgr}' timeout 0 2>&1 | Out-Null
    }
} catch {}

Write-Ok "Miscellaneous hardening done"

# ============================================================
#  15. PRIVACY EXTRAS
# ============================================================
Write-Title "15. Additional privacy tweaks..."

# Stop Defender auto-uploading suspicious files to Microsoft for analysis.
# Trade-off: this is Microsoft's cloud-assisted detection for brand-new
# (zero-day) malware samples -- turning it off means Defender still protects
# you with its local signatures/heuristics, just without that cloud lookup
# on unknown files. Real-time protection itself is left fully enabled.
Set-Reg 'HKLM:\SOFTWARE\Policies\Microsoft\Windows Defender\Spynet' 'SpynetReporting'  'DWord' 0
Set-Reg 'HKLM:\SOFTWARE\Policies\Microsoft\Windows Defender\Spynet' 'SubmitSamplesConsent' 'DWord' 2

# Clipboard: stop clipboard history syncing to your Microsoft account across
# devices, and stop the "suggested actions" popup (phone numbers/dates in
# copied text triggering app suggestions) from scanning what you copy.
Set-Reg 'HKCU:\Software\Microsoft\Clipboard'                                     'CloudClipboardAutomaticUpload' 'DWord' 0
Set-Reg 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\System'                       'AllowCrossDeviceClipboard'     'DWord' 0
Set-Reg 'HKCU:\Software\Microsoft\Windows\CurrentVersion\SmartActionPlatform\SmartClipboard' 'Disabled' 'DWord' 1

Write-Ok "Privacy extras applied (Defender sample submission, clipboard cloud sync/suggestions)"

# ============================================================
#  16. PERFORMANCE & POWER (gaming desktop)
# ============================================================
Write-Title "16. Performance and power tweaks for a gaming desktop..."

# Reclaim the ~7GB Windows sets aside for itself ("Reserved Storage"). Small
# risk: on a nearly-full drive, a future cumulative update could occasionally
# fail without this space reserved -- not a concern with normal free space.
try {
    Set-WindowsReservedStorageState -State Disabled -ErrorAction Stop
    Write-Ok "Reserved Storage disabled (~7GB reclaimed)"
} catch { Write-Warn "Reserved Storage: $_" }

# Turn off hibernation entirely -- reclaims disk space equal to your installed
# RAM (hiberfil.sys). This also disables Fast Startup as a side effect (Fast
# Startup relies on hibernation); on an SSD gaming rig that isn't a real loss,
# full cold boots are already fast. Skip this tweak if you rely on Sleep ->
# Hibernate for long power-off periods.
try {
    powercfg /hibernate off 2>&1 | Out-Null
    Write-Ok "Hibernation disabled, Fast Startup off (disk space reclaimed)"
} catch { Write-Warn "Disabling hibernation: $_" }

# Stop Windows updating NTFS "last accessed" timestamps on every file touch --
# a small, free reduction in disk writes with no real downside for a desktop.
try {
    fsutil behavior set disablelastaccess 1 | Out-Null
    Write-Ok "NTFS last-access timestamps disabled"
} catch { Write-Warn "fsutil disablelastaccess: $_" }

# MMCSS network/multimedia scheduling: stop Windows throttling background
# network and audio processing in favor of foreground apps. Standard,
# well-known low-latency tweak for gaming/streaming rigs.
$mmcss = 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Multimedia\SystemProfile'
Set-Reg $mmcss                              'SystemResponsiveness'   'DWord' 0
Set-Reg $mmcss                              'NetworkThrottlingIndex' 'DWord' 0xffffffff
$mmcssGames = "$mmcss\Tasks\Games"
Set-Reg $mmcssGames 'Priority'              'DWord' 6
Set-Reg $mmcssGames 'Scheduling Category'   'String' 'High'
Set-Reg $mmcssGames 'SFIO Priority'         'String' 'High'
Write-Ok "Network throttling disabled, Games task priority raised"

# USB selective suspend off -- stops mice/audio interfaces/controllers from
# power-cycling when briefly idle (fixes "input wakes up a beat late").
# Irrelevant for battery since this is a desktop.
try {
    $activeScheme = (powercfg /getactivescheme) -replace '.*: ([a-f0-9-]+).*','$1'
    powercfg /setacvalueindex $activeScheme 2a737441-1930-4402-8d77-b2bebba308a3 48e6b7a6-50f5-4782-a5d4-53bb8f07e226 0 2>&1 | Out-Null
    powercfg /setactive $activeScheme 2>&1 | Out-Null
    Write-Ok "USB selective suspend disabled"
} catch { Write-Warn "USB selective suspend: $_" }

# Power plan -> High performance. On a gaming desktop (no battery to manage)
# this removes CPU park/parking and frequency-scaling latency that the
# Balanced plan introduces to save power you don't need to save here.
try {
    $highPerfGuid = '8c5e7fda-e8bf-4a96-9a85-a6e23a8c635c'
    powercfg /setactive $highPerfGuid 2>&1 | Out-Null
    Write-Ok "Power plan set to High performance"
} catch { Write-Warn "Setting High performance power plan: $_" }

Write-Ok "Gaming desktop performance/power tweaks done"

# ============================================================
#  DONE
# ============================================================
Write-Host ""
Write-Host "  +----------------------------------------------------------+" -ForegroundColor $C

if ($warnings.Count -eq 0) {
    Write-Host "  |   [OK]  All tweaks applied with no warnings.             |" -ForegroundColor $C
} else {
    Write-Host ("  |   Done with {0} warning(s):                               |" -f $warnings.Count) -ForegroundColor Yellow
    foreach ($w in $warnings) {
        $short = $w.Substring(0, [Math]::Min(52, $w.Length))
        Write-Host ("  |   ! {0,-54}|" -f $short) -ForegroundColor Yellow
    }
}

Write-Host "  |                                                          |" -ForegroundColor $C
Write-Host "  |   A restart is required to fully apply all changes.      |" -ForegroundColor $C
Write-Host "  +----------------------------------------------------------+" -ForegroundColor $C
Write-Host ""

# Pull the OOBE-phase logs (Specialize/UserOnce/DefaultUser/FirstLogon) into
# the same folder as this transcript, so everything needed to troubleshoot
# is in one place under Documents\NiixDebloat-Logs.
try {
    $phaseLogs = @(
        'C:\Windows\Setup\Scripts\Specialize.log',
        'C:\Windows\Setup\Scripts\UserOnce.log',
        "$env:TEMP\UserOnce.log",
        'C:\Windows\Setup\Scripts\DefaultUser.log',
        'C:\Windows\Setup\Scripts\FirstLogon.log'
    )
    foreach ($pl in $phaseLogs) {
        if (Test-Path -LiteralPath $pl) {
            Copy-Item -LiteralPath $pl -Destination $logDir -Force -ErrorAction SilentlyContinue
        }
    }
    Write-Body "Logs saved to: $logDir"
} catch { Write-Warn "Copying phase logs: $_" }

try { Stop-Transcript | Out-Null } catch { }

$resp = Read-Host "  Restart now? [Y/N]"
if ($resp -match '^[Yy]') { Restart-Computer -Force }
