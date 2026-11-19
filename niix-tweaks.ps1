param([switch]$Background)

$_isAdmin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
if ($Background -and (-not $_isAdmin -or $PSVersionTable.PSEdition -eq 'Core')) { exit 1 }
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

Unregister-ScheduledTask -TaskName 'NiixTweaksAutoRun' -Confirm:$false -ErrorAction SilentlyContinue

try {
    Set-ExecutionPolicy -ExecutionPolicy RemoteSigned -Scope LocalMachine -Force -ErrorAction Stop
    Write-Host "  [OK] Execution policy set to RemoteSigned (local scripts will always run from now on)" -ForegroundColor Green
} catch {
    Write-Host "  [WARN] Set-ExecutionPolicy: $_" -ForegroundColor Yellow
}

$logDir = Join-Path ([Environment]::GetFolderPath('MyDocuments')) 'NiixDebloat-Logs'
New-Item -ItemType Directory -Path $logDir -Force -ErrorAction SilentlyContinue | Out-Null
if ($Background) {
    $logFile = Join-Path $logDir 'niix-tweaks_background.log'
} else {
    $logFile = Join-Path $logDir ("niix-tweaks_{0:yyyy-MM-dd_HH-mm-ss}.log" -f (Get-Date))
}
try { Start-Transcript -Path $logFile -Force | Out-Null } catch { }

$PINK  = 'Magenta'
$GREEN = 'Green'
$WHITE = 'White'
$RED   = 'Red'
$warnings = [System.Collections.Generic.List[string]]::new()

function Write-Title   { param($t) Write-Host ""; Write-Host "  $t" -ForegroundColor $PINK; Write-Host "" }
function Write-Body    { param($t) Write-Host "  $t" -ForegroundColor $WHITE }
function Write-Ok      { param($t) Write-Host "  [OK] $t" -ForegroundColor $GREEN }
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
    try {
        if (-not (Test-Path $Path)) { New-Item -Path $Path -Force -ErrorAction Stop | Out-Null }
        Set-ItemProperty -Path $Path -Name $Name -Type $Type -Value $Value -Force -ErrorAction Stop
        return
    } catch { }
    Enable-RegPrivileges
    $adminSid = [System.Security.Principal.SecurityIdentifier]::new('S-1-5-32-544')
    try {
        $hive = $Path.Split(':\')[0]
        $sub  = $Path.Substring($Path.IndexOf(':\') + 2)
        $hiveMap = @{
            'HKLM' = [Microsoft.Win32.Registry]::LocalMachine
            'HKCU' = [Microsoft.Win32.Registry]::CurrentUser
            'HKCR' = [Microsoft.Win32.Registry]::ClassesRoot
        }
        $root = $hiveMap[$hive]
        $key = $root.OpenSubKey($sub,
            [Microsoft.Win32.RegistryKeyPermissionCheck]::ReadWriteSubTree,
            [System.Security.AccessControl.RegistryRights]::TakeOwnership)
        if ($key) {
            $acl = $key.GetAccessControl(
                [System.Security.AccessControl.AccessControlSections]::None)
            $acl.SetOwner($adminSid)
            $key.SetAccessControl($acl)
            $key.Close()
        }
        $key2 = $root.OpenSubKey($sub,
            [Microsoft.Win32.RegistryKeyPermissionCheck]::ReadWriteSubTree,
            [System.Security.AccessControl.RegistryRights]::ChangePermissions)
        if ($key2) {
            $acl2 = $key2.GetAccessControl()
            $rule = [System.Security.AccessControl.RegistryAccessRule]::new(
                $adminSid,
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

function Set-RegUnblocked {
    param([string]$Path, [string]$Name, [string]$Type, [string]$Value, [switch]$Quiet)
    $src = Join-Path $env:SystemRoot 'System32\reg.exe'
    $dst = Join-Path $env:TEMP ("niix-reg-{0}.exe" -f [guid]::NewGuid().ToString('N').Substring(0, 8))
    try {
        Copy-Item -LiteralPath $src -Destination $dst -Force -ErrorAction Stop
        $r = Invoke-Quiet $dst ("add `"$Path`" /v `"$Name`" /t $Type /d `"$Value`" /f")
        if ($r.ExitCode -ne 0 -and -not $Quiet) { Write-Warn "Reg $Path\$Name : $(("$($r.Error)$($r.Output)").Trim())" }
    } catch { if (-not $Quiet) { Write-Warn "Reg $Path\$Name : $_" } }
    finally { Remove-Item -LiteralPath $dst -Force -ErrorAction SilentlyContinue }
}

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

function Grant-AdminFullControl {
    param([string]$Path)
    if (-not (Test-Path -LiteralPath $Path)) { return }
    $recurse = if (Test-Path -LiteralPath $Path -PathType Container) { ' /R' } else { '' }
    Invoke-Quiet 'takeown.exe' ("/F `"$Path`" /A$recurse") | Out-Null
    Invoke-Quiet 'icacls.exe'  ("`"$Path`" /grant *S-1-5-32-544:(F) /T /C /Q") | Out-Null
}

function Disable-Svc {
    param([string]$Name)
    if (-not (Get-Service -Name $Name -ErrorAction SilentlyContinue)) { return }
    Stop-Service -Name $Name -Force -ErrorAction SilentlyContinue
    try {
        Set-Service -Name $Name -StartupType Disabled -ErrorAction Stop
    } catch {
        Write-Warn "Could not disable service $Name : $($_.Exception.Message)"
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

$script:IsLaptop = $false
try {
    if (Get-CimInstance -ClassName Win32_Battery -ErrorAction SilentlyContinue) {
        $script:IsLaptop = $true
    } else {
        $chassis = (Get-CimInstance -ClassName Win32_SystemEnclosure -ErrorAction SilentlyContinue).ChassisTypes
        if ($chassis | Where-Object { $_ -in 8,9,10,11,12,14,30,31,32 }) { $script:IsLaptop = $true }
    }
} catch { }

Clear-Host
Write-Host ""
Write-Host "  +----------------------------------------------------------+" -ForegroundColor $PINK
Write-Host "  |   niix-tweaks  --  Post-Install Hardening Script         |" -ForegroundColor $PINK
Write-Host "  |   Running as Administrator. Restart when done.           |" -ForegroundColor $PINK
Write-Host "  +----------------------------------------------------------+" -ForegroundColor $PINK
Write-Host ""

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

Remove-AppXByName 'Microsoft.WindowsBackup'

Disable-Svc 'SDRSVC'
Disable-Svc 'wbengine'
Set-Reg 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\BackupAndRestore' 'DisableBackup' 'DWord' 1

Write-Ok "Windows Backup disabled"

Write-Title "3. Removing Microsoft Edge completely..."

$edgeSetups = @(Get-ChildItem "C:\Program Files (x86)\Microsoft\Edge\Application\*\Installer\setup.exe" -ErrorAction SilentlyContinue)
if ($edgeSetups.Count -gt 0) {
    Write-Body "Edge install found - running official uninstaller..."
    try {
        $stubDir = "C:\Windows\SystemApps\Microsoft.MicrosoftEdge_8wekyb3d8bbwe"
        if (-not (Test-Path -LiteralPath $stubDir)) { New-Item -Path $stubDir -ItemType Directory -Force -ErrorAction Stop | Out-Null }
        New-Item -Path "$stubDir\MicrosoftEdge.exe" -ItemType File -Force -ErrorAction Stop | Out-Null

        $proc = Start-Process -FilePath $edgeSetups[0].FullName `
            -ArgumentList '--uninstall --system-level --force-uninstall --delete-profile' `
            -Wait -PassThru -NoNewWindow -ErrorAction Stop
        if ($proc.ExitCode -in 0, 19) { Write-Ok "Edge uninstaller completed successfully" }
        else { Write-Warn "Edge uninstaller exit code: $($proc.ExitCode) - continuing with manual removal" }
    } catch { Write-Warn "Uninstaller error: $_ - continuing with manual removal" }
} else {
    Write-Body "Edge installer not found - likely removed offline already"
}

Write-Body "Force-deleting remaining Edge files..."
$edgeDirs = @(
    "C:\Program Files (x86)\Microsoft\Edge",
    "C:\Program Files (x86)\Microsoft\EdgeCore",
    "C:\Windows\SystemApps\Microsoft.MicrosoftEdge_8wekyb3d8bbwe",
    "C:\Windows\SystemApps\Microsoft.MicrosoftEdgeDevToolsClient_8wekyb3d8bbwe"
)
foreach ($dir in $edgeDirs) {
    if (Test-Path $dir) {
        try {
            Grant-AdminFullControl $dir
            Remove-Item -LiteralPath $dir -Recurse -Force -ErrorAction Stop
            Write-Body "Deleted: $dir"
        } catch { Write-Warn "Could not fully delete $dir : $_" }
    }
}

Remove-Item "$env:PUBLIC\Desktop\Microsoft Edge.lnk"      -Force -ErrorAction SilentlyContinue
Remove-Item "$env:USERPROFILE\Desktop\Microsoft Edge.lnk" -Force -ErrorAction SilentlyContinue
Remove-Item "$env:APPDATA\Microsoft\Windows\Start Menu\Programs\Microsoft Edge.lnk" -Force -ErrorAction SilentlyContinue

'MicrosoftEdgeElevationService' | ForEach-Object { Disable-Svc $_ }

Set-Reg 'HKLM:\SOFTWARE\Microsoft\EdgeUpdate'          'DoNotUpdateToEdgeWithChromium' 'DWord'  1
Set-Reg 'HKLM:\SOFTWARE\Policies\Microsoft\EdgeUpdate' 'UpdateDefault'                 'DWord'  0
Set-Reg 'HKLM:\SOFTWARE\Policies\Microsoft\EdgeUpdate' 'InstallDefault'                'DWord'  0
Set-Reg 'HKLM:\SOFTWARE\Policies\Microsoft\EdgeUpdate' 'Install{56EB18F8-B008-4CBD-B6D2-8C97FE7E9062}' 'DWord' 0
Set-Reg 'HKLM:\SOFTWARE\Policies\Microsoft\EdgeUpdate' 'Update{56EB18F8-B008-4CBD-B6D2-8C97FE7E9062}'  'DWord' 0
Set-Reg 'HKLM:\SOFTWARE\Policies\Microsoft\EdgeUpdate' 'Install{F3017226-FE2A-4295-8BDF-00C3A9A7E4C5}' 'DWord' 1
Set-Reg 'HKLM:\SOFTWARE\Policies\Microsoft\EdgeUpdate' 'Update{F3017226-FE2A-4295-8BDF-00C3A9A7E4C5}'  'DWord' 1
Set-Reg 'HKLM:\SOFTWARE\Policies\Microsoft\Edge'       'HideFirstRunExperience'        'DWord'  1
Set-Reg 'HKLM:\SOFTWARE\Policies\Microsoft\Edge'       'BackgroundModeEnabled'         'DWord'  0
Set-Reg 'HKLM:\SOFTWARE\Policies\Microsoft\Edge'       'StartupBoostEnabled'           'DWord'  0
Set-RegOwned 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\MicrosoftEdge' 'IsEdgeStableSetupDone' 'DWord' 1

Set-Service -Name 'edgeupdate'  -StartupType Automatic -ErrorAction SilentlyContinue
Set-Service -Name 'edgeupdatem' -StartupType Manual    -ErrorAction SilentlyContinue

Remove-Item -LiteralPath 'HKLM:\SOFTWARE\Microsoft\WindowsUpdate\Orchestrator\UScheduler_Oobe\EdgeUpdate' `
    -Recurse -Force -ErrorAction SilentlyContinue

Write-Ok "Edge browser removed and blocked (WebView2 Runtime kept)"

Write-Title "4. Disabling Xbox and GameBar services..."

'XblAuthManager','XblGameSave','XboxGipSvc','XboxNetApiSvc' | ForEach-Object { Disable-Svc $_ }

Set-Reg 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\GameDVR'   'AllowGameDVR'              'DWord' 0
Set-Reg 'HKCU:\System\GameConfigStore'                         'GameDVR_Enabled'           'DWord' 0
Set-Reg 'HKCU:\System\GameConfigStore'                         'GameDVR_FSEBehaviorMode'   'DWord' 2
Set-Reg 'HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\GameDVR' 'AppCaptureEnabled'     'DWord' 0
Set-Reg 'HKCU:\SOFTWARE\Microsoft\GameBar'                    'UseNexusForGameBarEnabled' 'DWord' 0
Set-Reg 'HKCU:\SOFTWARE\Microsoft\GameBar'                    'AllowAutoGameMode'         'DWord' 0

Write-Ok "Xbox and GameBar disabled"

Write-Title "5. Disabling privacy-invasive services..."

@('DiagTrack','dmwappushservice','RemoteRegistry','WerSvc',
  'WMPNetworkSvc','WpcMonSvc','wisvc','RetailDemo') | ForEach-Object { Disable-Svc $_ }

Write-Ok "Telemetry/tracking services disabled (app-critical services left enabled)"

$telemetryTasks = @(
    @('\Microsoft\Windows\Application Experience\', 'Microsoft Compatibility Appraiser'),
    @('\Microsoft\Windows\Application Experience\', 'Microsoft Compatibility Appraiser Exp'),
    @('\Microsoft\Windows\Application Experience\', 'ProgramDataUpdater'),
    @('\Microsoft\Windows\Application Experience\', 'MareBackup'),
    @('\Microsoft\Windows\Autochk\',                'Proxy'),
    @('\Microsoft\Windows\Customer Experience Improvement Program\', 'Consolidator'),
    @('\Microsoft\Windows\Customer Experience Improvement Program\', 'UsbCeip'),
    @('\Microsoft\Windows\DiskDiagnostic\',         'Microsoft-Windows-DiskDiagnosticDataCollector'),
    @('\Microsoft\Windows\Feedback\Siuf\',         'DmClient'),
    @('\Microsoft\Windows\Feedback\Siuf\',         'DmClientOnScenarioDownload'),
    @('\Microsoft\Windows\Windows Error Reporting\','QueueReporting')
)
foreach ($t in $telemetryTasks) {
    $task = Get-ScheduledTask -TaskPath $t[0] -TaskName $t[1] -ErrorAction SilentlyContinue
    if ($task -and $task.State -ne 'Disabled') {
        try { $task | Disable-ScheduledTask -ErrorAction Stop | Out-Null }
        catch { Write-Warn "Could not disable task $($t[0])$($t[1]) : $($_.Exception.Message)" }
    }
}
Write-Ok "Telemetry scheduled tasks disabled"

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
Set-Reg 'HKCU:\Software\Microsoft\InputPersonalization'                           'RestrictImplicitInkCollection'               'DWord' 1
Set-Reg 'HKCU:\Software\Microsoft\InputPersonalization'                           'RestrictImplicitTextCollection'              'DWord' 1
Set-Reg 'HKCU:\Software\Microsoft\InputPersonalization\TrainedDataStore'          'HarvestContacts'                             'DWord' 0
Set-Reg 'HKCU:\Software\Microsoft\Personalization\Settings'                       'AcceptedPrivacyPolicy'                       'DWord' 0
Set-Reg 'HKCU:\Software\Microsoft\Speech_OneCore\Settings\OnlineSpeechPrivacy'    'HasAccepted'                                 'DWord' 0
Set-Reg 'HKCU:\Software\Microsoft\Input\TIPC'                                     'Enabled'                                     'DWord' 0
Set-Reg 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\Windows Error Reporting'       'Disabled'                                    'DWord' 1

$ap = 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\AppPrivacy'
Set-Reg $ap 'LetAppsGetDiagnosticInfo' 'DWord' 2

Write-Ok "Telemetry and privacy tweaks applied"

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

Write-Title "8. Disabling Copilot, Recall, Bing and AI features..."

Set-Reg 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\WindowsCopilot' 'TurnOffWindowsCopilot'      'DWord' 1
Set-Reg 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\WindowsAI'      'DisableAIDataAnalysis'      'DWord' 1
Set-Reg 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\WindowsAI'      'TurnOffSavingSnapshots'     'DWord' 1
Set-Reg 'HKCU:\Software\Policies\Microsoft\Windows\Explorer'        'DisableSearchBoxSuggestions' 'DWord' 1
Set-Reg 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\Explorer'        'DisableSearchBoxSuggestions' 'DWord' 1

Write-Ok "Copilot, Recall and AI features disabled (Recall neutralized by policy, not removed)"

Write-Title "9. Cleaning up Taskbar and UI..."

$adv = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\Advanced'
Set-RegUnblocked 'HKCU\Software\Microsoft\Windows\CurrentVersion\Explorer\Advanced' 'TaskbarMn' 'REG_DWORD' '0'
Set-RegUnblocked 'HKCU\Software\Microsoft\Windows\CurrentVersion\Explorer\Advanced' 'TaskbarDa' 'REG_DWORD' '0' -Quiet
Set-Reg $adv 'ShowTaskViewButton'     'DWord' 0
Set-Reg $adv 'TaskbarAl'              'DWord' 0
Set-Reg $adv 'HideFileExt'            'DWord' 0
Set-Reg $adv 'Hidden'                 'DWord' 1
Set-Reg $adv 'Start_TrackProgs'       'DWord' 0
Set-Reg $adv 'Start_TrackDocs'        'DWord' 0
Set-Reg $adv 'EnableSnapAssistFlyout' 'DWord' 0
Set-Reg $adv 'Start_IrisRecommendations'   'DWord' 0
Set-Reg $adv 'Start_AccountNotifications'  'DWord' 0
Set-Reg $adv 'HideRecommendedSection' 'DWord' 1
Set-Reg 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\Explorer' 'HideRecommendedSection' 'DWord' 1
Set-Reg $adv 'ShowSecondsInSystemClock' 'DWord' 1
Set-Reg 'HKCU:\Software\Classes\CLSID\{86ca1aa0-34aa-4e8b-a509-50c905bae2a2}\InprocServer32' '' 'String' ''
if ((Get-ItemProperty -Path 'HKLM:\SOFTWARE\Policies\Microsoft\Dsh' -Name 'AllowNewsAndInterests' -ErrorAction SilentlyContinue).AllowNewsAndInterests -ne 0) {
    Set-RegUnblocked 'HKLM\SOFTWARE\Policies\Microsoft\Dsh' 'AllowNewsAndInterests' 'REG_DWORD' '0'
}
Set-Reg 'HKLM:\SOFTWARE\Microsoft\PolicyManager\current\device\Start'             'ConfigureStartPins' 'String' '{"pinnedList":[]}'
Set-Reg 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Search'                  'SearchboxTaskbarMode'    'DWord'  0
Set-Reg 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Start'                   'ShowRecentList'          'DWord'  0
Set-Reg 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Start'                   'ShowFrequentList'        'DWord'  0

try {
    $storeApp = @(Get-StartApps | Where-Object { $_.AppID -like '*WindowsStore*' })[0]
    if ($storeApp) {
        $shellApp = New-Object -ComObject Shell.Application
        $folder = $shellApp.NameSpace('shell:::{4234d49b-0245-4df3-b780-3893943456e1}')
        $item = @(@($folder.Items()) | Where-Object { $_.Path -eq $storeApp.AppID })[0]
        if ($item) {
            $verb = @(@($item.Verbs()) | Where-Object { ($_.Name -replace '&','') -match 'unpin.*taskbar' })[0]
            if ($verb) { $verb.DoIt() }
        }
    }
} catch { Write-Warn "Unpinning Microsoft Store from taskbar: $_" }

@('Windows.SystemToast.Suggested','Windows.SystemToast.StartupApp',
  'Microsoft.SkyDrive.Desktop','Windows.SystemToast.AccountHealth') | ForEach-Object {
    Set-Reg "HKCU:\Software\Microsoft\Windows\CurrentVersion\Notifications\Settings\$_" 'Enabled' 'DWord' 0
}

Write-Ok "Taskbar and UI cleaned up"

Write-Title "10. Applying dark theme..."

$themePath = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Themes\Personalize'
Set-Reg $themePath 'SystemUsesLightTheme' 'DWord' 0
Set-Reg $themePath 'AppsUseLightTheme'    'DWord' 0
Set-Reg $themePath 'EnableTransparency'   'DWord' 1
Set-Reg $themePath 'ColorPrevalence'      'DWord' 0

Set-Reg 'HKCU:\Software\Microsoft\Windows\DWM' 'ColorPrevalence' 'DWord' 0

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

if (-not $Background) {
    Write-Body "Restarting Explorer to apply theme..."
    Stop-Process -Name explorer -Force -ErrorAction SilentlyContinue
    Start-Sleep -Seconds 2
    if (-not (Get-Process explorer -ErrorAction SilentlyContinue)) {
        Start-Process explorer
    }
}

Write-Ok "Dark theme applied"

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

Write-Title "12. Configuring Windows Update..."

'NoAutoUpdate','AUOptions','UseWUServer' | ForEach-Object {
    Remove-ItemProperty 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\WindowsUpdate\AU' $_ -Force -ErrorAction SilentlyContinue
}
'DisableWindowsUpdateAccess','WUServer','WUStatusServer' | ForEach-Object {
    Remove-ItemProperty 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\WindowsUpdate' $_ -Force -ErrorAction SilentlyContinue
}

Set-Reg 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\WindowsUpdate\AU' 'NoAutoUpdate'                  'DWord' 0
Set-Reg 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\WindowsUpdate\AU' 'AUOptions'                     'DWord' 3
Set-Reg 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\WindowsUpdate\AU' 'NoAutoRebootWithLoggedOnUsers' 'DWord' 1
Set-Reg 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\DeliveryOptimization' 'DODownloadMode' 'DWord' 0

try {
    Set-Service -Name 'wuauserv' -StartupType Manual -ErrorAction Stop
} catch { Write-Warn "wuauserv startup type: $($_.Exception.Message)" }

try {
    Stop-Service -Name wuauserv -Force -ErrorAction SilentlyContinue
    Start-Service -Name BITS      -ErrorAction SilentlyContinue
    Start-Service -Name wuauserv  -ErrorAction SilentlyContinue
    Start-Service -Name UsoSvc    -ErrorAction SilentlyContinue
} catch { Write-Warn "Restarting WU services: $_" }

if ((Get-Service -Name 'wuauserv' -ErrorAction SilentlyContinue).StartType -eq 'Disabled') {
    Write-Warn "Windows Update service is still disabled -- set it to Manual in services.msc"
}
Write-Ok "Windows Update configured (auto-download, notify to install, no auto-restart, no P2P)"

Write-Title "13. Checking BitLocker..."

if ($Background) {
    Write-Body "Background mode: BitLocker state left as-is"
} else { try {
    $bl = Get-BitLockerVolume -MountPoint $env:SystemDrive -ErrorAction SilentlyContinue
    if ($bl -and $bl.ProtectionStatus -eq 'On') {
        Disable-BitLocker -MountPoint $env:SystemDrive -ErrorAction Stop | Out-Null
        Write-Ok "BitLocker disabled"
    } else {
        Write-Body "BitLocker not active"
    }
} catch { Write-Warn "BitLocker: $_" } }
Set-Reg 'HKLM:\SYSTEM\CurrentControlSet\Control\BitLocker' 'PreventDeviceEncryption' 'DWord' 1

Write-Title "14. Miscellaneous hardening..."

Set-Reg 'HKLM:\SYSTEM\CurrentControlSet\Control\FileSystem' 'LongPathsEnabled'                 'DWord' 1
Set-Reg 'HKCU:\Control Panel\Accessibility\StickyKeys'      'Flags'                            'String' '10'
Set-Reg 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\System'  'EnableSmartScreen'                'DWord' 0
net.exe accounts /maxpwage:UNLIMITED 2>&1 | Out-Null

try {
    if (@(bcdedit.exe | Select-String 'path').Count -eq 2) {
        bcdedit.exe /set '{bootmgr}' timeout 0 2>&1 | Out-Null
    }
} catch {}

Write-Ok "Miscellaneous hardening done"

Write-Title "15. Additional privacy tweaks..."

Set-Reg 'HKLM:\SOFTWARE\Policies\Microsoft\Windows Defender\Spynet' 'SubmitSamplesConsent' 'DWord' 2
Remove-ItemProperty -LiteralPath 'HKLM:\SOFTWARE\Policies\Microsoft\Windows Defender\Spynet' -Name 'SpynetReporting' -Force -ErrorAction SilentlyContinue

Set-Reg 'HKCU:\Software\Microsoft\Clipboard'                                     'CloudClipboardAutomaticUpload' 'DWord' 0
Set-Reg 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\System'                       'AllowCrossDeviceClipboard'     'DWord' 0
Set-Reg 'HKCU:\Software\Microsoft\Windows\CurrentVersion\SmartActionPlatform\SmartClipboard' 'Disabled' 'DWord' 1

Write-Ok "Privacy extras applied (Defender sample submission, clipboard cloud sync/suggestions)"

if ($script:IsLaptop) {
    Write-Title "16. Performance tweaks (laptop detected -- battery-safe profile)..."
} else {
    Write-Title "16. Performance and power tweaks (desktop detected)..."
}

try {
    Set-WindowsReservedStorageState -State Disabled -ErrorAction Stop
    Write-Ok "Reserved Storage disabled (~7GB reclaimed)"
} catch { Write-Warn "Reserved Storage: $_" }

fsutil.exe behavior set disablelastaccess 1 2>&1 | Out-Null
if ($LASTEXITCODE -eq 0) { Write-Ok "NTFS last-access timestamps disabled" }
else { Write-Warn "fsutil disablelastaccess failed (exit $LASTEXITCODE)" }

$mmcss = 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Multimedia\SystemProfile'
Set-Reg $mmcss                              'SystemResponsiveness'   'DWord' 0
Set-Reg $mmcss                              'NetworkThrottlingIndex' 'DWord' 0xffffffff
$mmcssGames = "$mmcss\Tasks\Games"
Set-Reg $mmcssGames 'Priority'              'DWord' 6
Set-Reg $mmcssGames 'Scheduling Category'   'String' 'High'
Set-Reg $mmcssGames 'SFIO Priority'         'String' 'High'
Write-Ok "Network throttling disabled, Games task priority raised"

if (-not $script:IsLaptop) {

    powercfg.exe /hibernate off 2>&1 | Out-Null
    if ($LASTEXITCODE -eq 0) { Write-Ok "Hibernation disabled, Fast Startup off (disk space reclaimed)" }
    else { Write-Warn "Disabling hibernation failed (exit $LASTEXITCODE)" }

    $highPerfGuid = '8c5e7fda-e8bf-4a96-9a85-a6e23a8c635c'
    powercfg.exe /setactive $highPerfGuid 2>&1 | Out-Null
    if ($LASTEXITCODE -ne 0) {
        $dup = (powercfg.exe /duplicatescheme $highPerfGuid 2>&1 | Out-String)
        if ($dup -match '([0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12})') {
            powercfg.exe /setactive $Matches[1] 2>&1 | Out-Null
        }
    }
    if ($LASTEXITCODE -eq 0) { Write-Ok "Power plan set to High performance" }
    else { Write-Warn "High performance power plan is not available on this system (Modern Standby devices only offer Balanced)" }

    $activeOut = (powercfg.exe /getactivescheme 2>&1 | Out-String)
    if ($activeOut -match '([0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12})') {
        $activeScheme = $Matches[1]
        powercfg.exe /setacvalueindex $activeScheme 2a737441-1930-4402-8d77-b2bebba308a3 48e6b7a6-50f5-4782-a5d4-53bb8f07e226 0 2>&1 | Out-Null
        $usbOk = ($LASTEXITCODE -eq 0)
        powercfg.exe /setactive $activeScheme 2>&1 | Out-Null
        if ($usbOk) { Write-Ok "USB selective suspend disabled" } else { Write-Warn "USB selective suspend setting not available" }
    } else {
        Write-Warn "Could not read the active power scheme"
    }

    Write-Ok "Desktop performance/power tweaks done"
} else {
    Write-Body "Laptop detected: hibernation, USB power management and the battery-aware power plan left intact."
    Write-Ok "Laptop-safe performance tweaks done (gaming/latency tweaks applied, battery settings preserved)"
}

Write-Title "17. Configuring automatic time sync (Cloudflare, re-synced at every login)..."

$timeSyncScript = @'
param([int]$Attempts = 12, [int]$DelaySeconds = 10)

$ErrorActionPreference = 'SilentlyContinue'
$w32tm   = Join-Path $env:SystemRoot 'System32\w32tm.exe'
$logFile = Join-Path $env:SystemRoot 'Setup\Scripts\NiixTimeSync.log'
$log     = [System.Collections.Generic.List[string]]::new()
function Log($m) { $log.Add(('{0:yyyy-MM-dd HH:mm:ss}  {1}' -f (Get-Date), $m)) }

$svcKey = 'HKLM:\SYSTEM\CurrentControlSet\Services\W32Time'
$ntpKey = "$svcKey\TimeProviders\NtpClient"
$cfgKey = "$svcKey\Config"

Set-ItemProperty -Path $ntpKey -Name 'Enabled'             -Type DWord -Value 1
Set-ItemProperty -Path $ntpKey -Name 'SpecialPollInterval' -Type DWord -Value 3600
Set-ItemProperty -Path $cfgKey -Name 'MaxPosPhaseCorrection' -Type DWord -Value -1
Set-ItemProperty -Path $cfgKey -Name 'MaxNegPhaseCorrection' -Type DWord -Value -1
Set-ItemProperty -Path $cfgKey -Name 'UtilizeSslTimeData'    -Type DWord -Value 0

if ((Get-Service W32Time).Status -ne 'Running') { Start-Service W32Time }

& $w32tm /config /syncfromflags:NO /update | Out-Null
Log "Auto time sync switched OFF (exit $LASTEXITCODE)"
Start-Sleep -Seconds 2

& $w32tm /config /manualpeerlist:"time.cloudflare.com,0x9" /syncfromflags:manual /reliable:no /update | Out-Null
Log "Auto time sync switched ON with time.cloudflare.com (exit $LASTEXITCODE)"

Restart-Service W32Time -Force
(Get-Service W32Time).WaitForStatus('Running', [TimeSpan]::FromSeconds(30))

$synced = $false
for ($i = 1; $i -le $Attempts; $i++) {
    $out = & $w32tm /resync /rediscover 2>&1 | Out-String
    if ($LASTEXITCODE -eq 0) { $synced = $true; Log "Resync OK on attempt $i"; break }
    Log ("Resync attempt $i failed: " + $out.Trim())
    if ($i -lt $Attempts) { Start-Sleep -Seconds $DelaySeconds }
}

$status = & $w32tm /query /status 2>&1 | Out-String
Log ("Status:`r`n" + $status.Trim())
Set-Content -Path $logFile -Value $log -Encoding ASCII
if ($synced) { exit 0 } else { exit 1 }
'@

$w32tm = Join-Path $env:SystemRoot 'System32\w32tm.exe'
$scExe = Join-Path $env:SystemRoot 'System32\sc.exe'

if (-not (Get-Service -Name 'W32Time' -ErrorAction SilentlyContinue)) {
    $r = Invoke-Quiet $w32tm '/register'
    if ($r.ExitCode -ne 0) { Write-Warn "w32tm /register failed (exit $($r.ExitCode))" }
}

Set-Reg 'HKLM:\SYSTEM\CurrentControlSet\Control\TimeZoneInformation' 'RealTimeIsUniversal' 'QWord' 1
Write-Ok "Hardware clock treated as UTC (fixes dual-boot clock offset)"

$timeSvc = Get-Service -Name 'W32Time' -ErrorAction SilentlyContinue
if (-not $timeSvc) {
    Write-Warn "Windows Time service (W32Time) is missing -- clock sync not configured"
} else {
    $r = Invoke-Quiet $scExe 'triggerinfo W32Time delete'
    if ($r.ExitCode -ne 0) { Write-Warn "W32Time trigger removal failed (exit $($r.ExitCode))" }

    $r = Invoke-Quiet $scExe 'config W32Time start= delayed-auto'
    if ($r.ExitCode -ne 0) { Write-Warn "W32Time start type failed (exit $($r.ExitCode))" }

    $r = Invoke-Quiet $scExe 'failure W32Time reset= 86400 actions= restart/60000/restart/60000/restart/60000'
    if ($r.ExitCode -ne 0) { Write-Warn "W32Time recovery actions failed (exit $($r.ExitCode))" }

    $syncTask = Get-ScheduledTask -TaskPath '\Microsoft\Windows\Time Synchronization\' -TaskName 'SynchronizeTime' -ErrorAction SilentlyContinue
    if ($syncTask -and $syncTask.State -eq 'Disabled') {
        try { $syncTask | Enable-ScheduledTask -ErrorAction Stop | Out-Null }
        catch { Write-Warn "Could not enable SynchronizeTime task: $($_.Exception.Message)" }
    }

    $tsDir  = Join-Path $env:SystemRoot 'Setup\Scripts'
    $tsPath = Join-Path $tsDir 'NiixTimeSync.ps1'
    try {
        New-Item -ItemType Directory -Path $tsDir -Force -ErrorAction Stop | Out-Null
        [System.IO.File]::WriteAllText($tsPath, ($timeSyncScript -replace "`r?`n", "`r`n"), [System.Text.Encoding]::ASCII)
    } catch { Write-Warn "Could not write $tsPath : $($_.Exception.Message)" }

    try {
        $tsAction    = New-ScheduledTaskAction -Execute 'powershell.exe' `
                         -Argument "-NoProfile -NonInteractive -ExecutionPolicy Bypass -WindowStyle Hidden -File `"$tsPath`""
        $tsTrigger   = New-ScheduledTaskTrigger -AtLogOn
        $tsTrigger.Delay = 'PT10S'
        $tsPrincipal = New-ScheduledTaskPrincipal -UserId 'SYSTEM' -LogonType ServiceAccount -RunLevel Highest
        $tsSettings  = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries `
                         -StartWhenAvailable -MultipleInstances IgnoreNew `
                         -ExecutionTimeLimit (New-TimeSpan -Minutes 10)
        Register-ScheduledTask -TaskName 'NiixTimeSync' -TaskPath '\' -Action $tsAction -Trigger $tsTrigger `
            -Principal $tsPrincipal -Settings $tsSettings `
            -Description 'Toggles automatic time sync off/on and resyncs with time.cloudflare.com at every login (niix-debloat).' `
            -Force -ErrorAction Stop | Out-Null
        Write-Ok "NiixTimeSync task registered (runs at every login)"
    } catch { Write-Warn "Could not register NiixTimeSync task: $($_.Exception.Message)" }

    if ($Background) {
        Write-Ok "Time sync settings re-applied (NiixTimeSync task handles the resync)"
    } elseif (Test-Path $tsPath) {
        $psExe = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
        $r = Invoke-Quiet $psExe "-NoProfile -NonInteractive -ExecutionPolicy Bypass -File `"$tsPath`" -Attempts 3 -DelaySeconds 5"
        if ($r.ExitCode -eq 0) {
            Write-Ok "Clock synced now with time.cloudflare.com; re-syncs hourly and at every login"
        } else {
            Write-Body "Cloudflare time server not reachable right now -- the clock will sync at next login / within the hour."
            Write-Ok "Time sync configured (Cloudflare only, hourly + at every login)"
        }
    }
}

Write-Title "18. Adding hosts file blocks..."

$hostsBlock = @(
    @('127.0.0.1', 'localhost'),
    @('::1',       'localhost'),
    @('127.0.0.1', 'data.microsoft.com'),
    @('127.0.0.1', 'msftconnecttest.com'),
    @('127.0.0.1', 'azureedge.net'),
    @('127.0.0.1', 'activity.windows.com'),
    @('127.0.0.1', 'bingapis.com'),
    @('127.0.0.1', 'msedge.net'),
    @('127.0.0.1', 'assets.msn.com'),
    @('127.0.0.1', 'scorecardresearch.com'),
    @('127.0.0.1', 'edge.microsoft.com'),
    @('127.0.0.1', 'data.msn.com')
)
$hostsPath   = Join-Path $env:SystemRoot 'System32\drivers\etc\hosts'
$markerStart = '# >>> niix-debloat blocks (managed by niix-tweaks.ps1) >>>'
$markerEnd   = '# <<< niix-debloat blocks <<<'

try {
    $existing = @()
    if (Test-Path -LiteralPath $hostsPath) {
        $item = Get-Item -LiteralPath $hostsPath -Force
        if ($item.IsReadOnly) { $item.IsReadOnly = $false }
        $existing = @([System.IO.File]::ReadAllLines($hostsPath))
    }

    $kept = [System.Collections.Generic.List[string]]::new()
    $inBlock = $false
    foreach ($line in $existing) {
        if ($line.Trim() -eq $markerStart) { $inBlock = $true;  continue }
        if ($line.Trim() -eq $markerEnd)   { $inBlock = $false; continue }
        if (-not $inBlock) { $kept.Add($line) }
    }
    while ($kept.Count -gt 0 -and $kept[$kept.Count - 1].Trim() -eq '') { $kept.RemoveAt($kept.Count - 1) }

    $present = @{}
    foreach ($line in $kept) {
        $l = ($line -replace '#.*$', '').Trim()
        if ($l) {
            $parts = $l -split '\s+'
            foreach ($n in $parts[1..($parts.Count - 1)]) { $present["$($parts[0])|$($n.ToLower())"] = $true }
        }
    }

    $block = [System.Collections.Generic.List[string]]::new()
    $block.Add($markerStart)
    foreach ($e in $hostsBlock) {
        if (-not $present["$($e[0])|$($e[1])"]) { $block.Add(('{0,-15} {1}' -f $e[0], $e[1])) }
    }
    $block.Add($markerEnd)

    $out = @($kept) + @('') + @($block)
    [System.IO.File]::WriteAllText($hostsPath, (($out -join "`r`n") + "`r`n"), [System.Text.Encoding]::ASCII)

    $null = Invoke-Quiet (Join-Path $env:SystemRoot 'System32\ipconfig.exe') '/flushdns'
    Write-Ok "Hosts file updated ($($block.Count - 2) entries) and DNS cache flushed"
} catch {
    Write-Warn "Could not update hosts file: $($_.Exception.Message)"
}

if (-not $Background) {
    Write-Title "19. Scheduling background re-apply at every login..."

    $maintDir  = Join-Path $env:SystemRoot 'Setup\Scripts'
    $maintPath = Join-Path $maintDir 'niix-tweaks.ps1'
    try {
        New-Item -ItemType Directory -Path $maintDir -Force -ErrorAction Stop | Out-Null
        if ($PSCommandPath -and ((Resolve-Path -LiteralPath $PSCommandPath).Path -ne $maintPath)) {
            Copy-Item -LiteralPath $PSCommandPath -Destination $maintPath -Force -ErrorAction Stop
        }
    } catch { Write-Warn "Could not copy script to $maintPath : $($_.Exception.Message)" }

    if (Test-Path -LiteralPath $maintPath) {
        try {
            $maintAction = New-ScheduledTaskAction -Execute (Join-Path $env:SystemRoot 'System32\conhost.exe') `
                -Argument ("--headless `"$env:SystemRoot\System32\WindowsPowerShell\v1.0\powershell.exe`" " +
                           "-NoProfile -NonInteractive -ExecutionPolicy Bypass -WindowStyle Hidden " +
                           "-File `"$maintPath`" -Background")
            $maintTrigger = New-ScheduledTaskTrigger -AtLogOn
            $maintTrigger.Delay = 'PT1M'
            $maintPrincipal = New-ScheduledTaskPrincipal -GroupId 'BUILTIN\Administrators' -RunLevel Highest
            $maintSettings  = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries `
                                -StartWhenAvailable -MultipleInstances IgnoreNew `
                                -ExecutionTimeLimit (New-TimeSpan -Minutes 30)
            Register-ScheduledTask -TaskName 'NiixTweaksMaintain' -TaskPath '\' -Action $maintAction `
                -Trigger $maintTrigger -Principal $maintPrincipal -Settings $maintSettings `
                -Description 'Silently re-applies niix-tweaks at every login so Windows updates cannot undo them.' `
                -Force -ErrorAction Stop | Out-Null
            Write-Ok "NiixTweaksMaintain task registered (silent re-apply 1 min after every login)"
        } catch { Write-Warn "Could not register NiixTweaksMaintain task: $($_.Exception.Message)" }
    }
}

Write-Host ""
Write-Host "  +----------------------------------------------------------+" -ForegroundColor $PINK

if ($warnings.Count -eq 0) {
    Write-Host "  |   [OK]  All tweaks applied with no warnings.             |" -ForegroundColor $GREEN
} else {
    Write-Host ("  |   {0,-55}|" -f "Done with $($warnings.Count) warning(s):") -ForegroundColor Yellow
    foreach ($warnItem in $warnings) {
        $short = $warnItem.Substring(0, [Math]::Min(53, $warnItem.Length))
        Write-Host ("  |   ! {0,-53}|" -f $short) -ForegroundColor Yellow
    }
}

Write-Host "  |                                                          |" -ForegroundColor $PINK
Write-Host "  |   A restart is required to fully apply all changes.      |" -ForegroundColor $PINK
Write-Host "  +----------------------------------------------------------+" -ForegroundColor $PINK
Write-Host ""

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

if ($Background) { exit 0 }

$resp = Read-Host "  Restart now? [Y/N]"
if ($resp -match '^[Yy]') { Restart-Computer -Force }
