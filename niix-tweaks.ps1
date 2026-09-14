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
    'Microsoft.MixedReality.Portal','Microsoft.Office.OneNote',
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
$edgeDirs = @(
    "C:\Program Files (x86)\Microsoft\Edge",
    "C:\Program Files (x86)\Microsoft\EdgeUpdate",
    "C:\Program Files (x86)\Microsoft\EdgeCore",
    "C:\Program Files (x86)\Microsoft\EdgeWebView",
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

# Step 4: Disable Edge services
'edgeupdate','edgeupdatem','MicrosoftEdgeElevationService' | ForEach-Object { Disable-Svc $_ }

# Step 5: Apply every registry block to prevent Edge ever coming back
Set-Reg 'HKLM:\SOFTWARE\Microsoft\EdgeUpdate'          'DoNotUpdateToEdgeWithChromium' 'DWord'  1
Set-Reg 'HKLM:\SOFTWARE\Policies\Microsoft\EdgeUpdate' 'UpdateDefault'                 'DWord'  0
Set-Reg 'HKLM:\SOFTWARE\Policies\Microsoft\EdgeUpdate' 'InstallDefault'                'DWord'  0
Set-Reg 'HKLM:\SOFTWARE\Policies\Microsoft\Edge'       'HideFirstRunExperience'        'DWord'  1
Set-Reg 'HKLM:\SOFTWARE\Policies\Microsoft\Edge'       'BackgroundModeEnabled'         'DWord'  0
Set-Reg 'HKLM:\SOFTWARE\Policies\Microsoft\Edge'       'StartupBoostEnabled'           'DWord'  0
Set-RegOwned 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\MicrosoftEdge' 'IsEdgeStableSetupDone' 'DWord' 1

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
Set-Reg 'HKCU:\Software\Classes\CLSID\{86ca1aa0-34aa-4e8b-a509-50c905bae2a2}\InprocServer32' '' 'String' ''
# HKLM\...\Dsh is ACL-protected like TaskbarMn/Da above -- reg.exe bypasses the .NET registry check
& reg add 'HKLM\SOFTWARE\Policies\Microsoft\Dsh' /v AllowNewsAndInterests /t REG_DWORD /d 0 /f 2>&1 | Out-Null
# PolicyManager\current\device\* is CSP/MDM-managed and often ACL-locked the same way -- use reg.exe
& reg add 'HKLM\SOFTWARE\Microsoft\PolicyManager\current\device\Start' /v ConfigureStartPins /t REG_SZ /d '{"pinnedList":[]}' /f 2>&1 | Out-Null
Set-Reg 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Search'                  'SearchboxTaskbarMode'    'DWord'  0
Set-Reg 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Start'                   'ShowRecentList'          'DWord'  0
Set-Reg 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Start'                   'ShowFrequentList'        'DWord'  0

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
Set-Reg $themePath 'EnableTransparency'   'DWord' 0
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
#  14. GAMING / SYSTEM PERFORMANCE TWEAKS
# ============================================================
Write-Title "14. Applying gaming / system performance tweaks..."

# --- Windows Game Mode: ON ---
# Lets Windows prioritize the foreground game process and throttle
# background activity at the OS level. This is a different setting from
# "AllowAutoGameMode" (set to 0 in step 4 above, which only stops the
# Game Bar overlay from auto-launching) - Game Mode itself stays enabled.
Set-Reg 'HKCU:\SOFTWARE\Microsoft\GameBar' 'AutoGameModeEnabled' 'DWord' 1
Set-Reg 'HKCU:\SOFTWARE\Microsoft\GameBar' 'AllowAutoGameMode'   'DWord' 1
Write-Ok "Game Mode enabled"

# --- Xbox Game Bar: DISABLED ---
# Stops the Game Bar overlay from popping up on the Guide button (Win+G).
# (Services + AllowGameDVR policy already handled in step 4 above.)
Set-Reg 'HKCU:\SOFTWARE\Microsoft\GameBar' 'ShowStartupPanel'           'DWord' 0
Set-Reg 'HKCU:\SOFTWARE\Microsoft\GameBar' 'GamePanelStartupTipIndex'   'DWord' 3
Set-Reg 'HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\GameDVR' 'AppCaptureEnabled' 'DWord' 0
Write-Ok "Xbox Game Bar disabled"

# --- Mouse Acceleration: DISABLED ---
# Turns off "Enhance Pointer Precision" so cursor movement is 1:1 with
# physical mouse movement. These are REG_SZ (string) values, not DWORD.
Set-Reg 'HKCU:\Control Panel\Mouse' 'MouseSpeed'      'String' '0'
Set-Reg 'HKCU:\Control Panel\Mouse' 'MouseThreshold1'  'String' '0'
Set-Reg 'HKCU:\Control Panel\Mouse' 'MouseThreshold2'  'String' '0'
Write-Ok "Mouse acceleration disabled"

# --- Fullscreen Optimizations: DISABLED (system-wide exclusive fullscreen) ---
Set-Reg 'HKCU:\System\GameConfigStore' 'GameDVR_FSEBehavior'                  'DWord' 2
Set-Reg 'HKCU:\System\GameConfigStore' 'GameDVR_FSEBehaviorMode'              'DWord' 2
Set-Reg 'HKCU:\System\GameConfigStore' 'GameDVR_HonorUserFSEBehaviorMode'     'DWord' 1
Set-Reg 'HKCU:\System\GameConfigStore' 'GameDVR_DXGIHonorFSEWindowsCompatible' 'DWord' 1
Write-Ok "Fullscreen optimizations disabled (exclusive fullscreen forced)"

# --- Hardware-Accelerated GPU Scheduling: ON ---
# Requires a WDDM 2.7+ driver; harmless no-op on hardware that doesn't support it.
Set-Reg 'HKLM:\SYSTEM\CurrentControlSet\Control\GraphicsDrivers' 'HwSchMode' 'DWord' 2
Write-Ok "Hardware-accelerated GPU scheduling enabled (reboot required)"

# --- Core Isolation / Memory Integrity (VBS): DISABLED ---
# Reclaims the CPU overhead VBS/HVCI taxes on some systems.
# WARNING: reduces hypervisor-based system protection.
# NOTE: Microsoft's 2026-10-13 update auto-enables Memory Integrity on
# eligible PCs, but only where it hasn't been EXPLICITLY disabled via Group
# Policy, Intune, or Registry. We set both the runtime keys and the
# policy-equivalent keys below so this stays off through that rollout.
Set-Reg 'HKLM:\SYSTEM\CurrentControlSet\Control\DeviceGuard' 'EnableVirtualizationBasedSecurity' 'DWord' 0
Set-Reg 'HKLM:\SYSTEM\CurrentControlSet\Control\DeviceGuard\Scenarios\HypervisorEnforcedCodeIntegrity' 'Enabled' 'DWord' 0
Set-Reg 'HKLM:\SYSTEM\CurrentControlSet\Control\DeviceGuard\Scenarios\CredentialGuard'                 'Enabled' 'DWord' 0
Set-Reg 'HKLM:\SYSTEM\CurrentControlSet\Control\Lsa' 'LsaCfgFlags' 'DWord' 0
Set-Reg 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\DeviceGuard' 'EnableVirtualizationBasedSecurity' 'DWord' 0
Set-Reg 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\DeviceGuard' 'HypervisorEnforcedCodeIntegrity'   'DWord' 0
Set-Reg 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\DeviceGuard' 'RequirePlatformSecurityFeatures'   'DWord' 1
Set-Reg 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\DeviceGuard' 'LsaCfgFlags'                       'DWord' 0
Write-Warn "Core Isolation (VBS) disabled - reduces hypervisor-based system protection"

Write-Ok "Gaming / performance tweaks applied (reboot required for GPU scheduling + VBS)"

# ============================================================
#  15. MISCELLANEOUS
# ============================================================
Write-Title "15. Miscellaneous hardening..."

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

$resp = Read-Host "  Restart now? [Y/N]"
if ($resp -match '^[Yy]') { Restart-Computer -Force }
