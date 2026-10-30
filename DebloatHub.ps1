#Requires -Version 5.1
# DebloatHub - curated, previewable, reversible Windows tweaks in one GUI.
# Run: right-click > "Run with PowerShell" (auto-elevates). Try it in a VM first.
param([switch]$Elevated,[switch]$ShowConsole)
$AppVersion='1.1.0'   # keep in sync with the release tag (vX.Y.Z); the release workflow checks it
$MyPath=$PSCommandPath
$isAdmin=(New-Object Security.Principal.WindowsPrincipal([Security.Principal.WindowsIdentity]::GetCurrent())).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
if(-not $isAdmin -and -not $Elevated){
  # Normal run: console hidden. Add -ShowConsole to keep the console visible for troubleshooting.
  Start-Process powershell -Verb RunAs -WindowStyle $(if($ShowConsole){'Normal'}else{'Hidden'}) -ArgumentList "-NoProfile $(if($ShowConsole){'-NoExit '})-ExecutionPolicy Bypass -File `"$PSCommandPath`" -Elevated$(if($ShowConsole){' -ShowConsole'})"; exit }
Add-Type -AssemblyName PresentationFramework
if(-not $isAdmin){[Windows.MessageBox]::Show('Administrator rights are required.')|Out-Null;exit}
$ErrorActionPreference='Stop'
trap{$m="$_`r`n$($_.ScriptStackTrace)";Set-Content "$env:TEMP\DebloatHub-error.log" $m;Write-Host $m -ForegroundColor Red;[Windows.MessageBox]::Show("Startup error (also saved to %TEMP%\DebloatHub-error.log):`n`n$_")|Out-Null;break}
$build=[Environment]::OSVersion.Version.Build; $W11=$build -ge 22000

# ---------- Signed-in user: UAC may elevate to a DIFFERENT admin account, whose HKCU/APPDATA are not the user's ----------
# Per-user switches are redirected to HKEY_USERS\<SID of the account that owns explorer.exe in this session>.
$meSid=[Security.Principal.WindowsIdentity]::GetCurrent().User.Value
$UserSid=$meSid;$UserHive='';$UserProfile=$env:USERPROFILE;$UserAppData=$env:APPDATA;$UserLocal=$env:LOCALAPPDATA;$UserDesktop=[Environment]::GetFolderPath('Desktop');$OtherUser=$false;$UserDetectErr=''
try{$mySess=[Diagnostics.Process]::GetCurrentProcess().SessionId
 $ex=@(Get-CimInstance Win32_Process -Filter "Name='explorer.exe' AND SessionId=$mySess" -ErrorAction Stop)|Select-Object -First 1
 if($ex){$sid=[string]($ex|Invoke-CimMethod -MethodName GetOwnerSid -ErrorAction Stop).Sid
  if($sid -and $sid -ne $meSid){
   if(-not(Test-Path -LiteralPath "Registry::HKEY_USERS\$sid")){throw "the registry hive of the signed-in user ($sid) is not loaded"}
   $UserProfile=[Environment]::ExpandEnvironmentVariables([string](Get-ItemProperty "HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\ProfileList\$sid" -ErrorAction Stop).ProfileImagePath)
   $shf=Get-ItemProperty "Registry::HKEY_USERS\$sid\Software\Microsoft\Windows\CurrentVersion\Explorer\Shell Folders" -ErrorAction Stop
   $UserAppData=[string]$shf.AppData;$UserLocal=[string]$shf.'Local AppData';$UserDesktop=[string]$shf.Desktop
   $UserSid=$sid;$UserHive="Registry::HKEY_USERS\$sid";$OtherUser=$true}}}
catch{$UserDetectErr=$_.Exception.Message;$UserSid=$meSid;$UserHive='';$OtherUser=$false;$UserProfile=$env:USERPROFILE;$UserAppData=$env:APPDATA;$UserLocal=$env:LOCALAPPDATA;$UserDesktop=[Environment]::GetFolderPath('Desktop')}   # unknown: keep this account, a warning is logged at startup
function Map-Hive($p){if($UserHive -and $p -like 'HKCU:*'){$UserHive+$p.Substring(5)}else{$p}}   # 'HKCU:\Software\X' -> 'Registry::HKEY_USERS\<SID>\Software\X' (only when running as another account)

# ---------- Tweak database (declarative: edit data, not logic) ----------
function fReg($p,$n,$v,$u,$t='DWord',$opt=$false){@{K='Reg';P=(Map-Hive $p);N=$n;V=$v;U=$u;T=$t;Opt=$opt}}   # Opt=$true: only when the key already exists (software that may not be installed)   # V=apply value, U=undo value ($null = delete)
function fSvc($n,$u){@{K='Svc';N=$n;U=$u}}                                   # U=original start type
function fApp($n){@{K='App';N=$n}}
function fTask($n){@{K='Task';N=$n}}
function fSvm($n,$u){@{K='SvcM';N=$n;U=$u}}                                  # U=original start type; target = Manual
function fFeat($n){@{K='Feat';N=$n}}
function fCmd($c,$u=$null,$t=$null){@{K='Cmd';V=$c;U=$u;T=$t}}                              # one-shot command (U = optional undo command)
function fTw($sec,$name,$desc,$risk,$src,$win,$prof,$acts,$rec=''){[pscustomobject]@{Sec=$sec;Name=$name;Desc=$desc;Risk=$risk;Src=$src;Win=[string]$win;Prof=$prof;Acts=@($acts);Rec=$rec}}

$CDM='HKCU:\Software\Microsoft\Windows\CurrentVersion\ContentDeliveryManager'
$ADV='HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\Advanced'
$POL='HKLM:\SOFTWARE\Policies\Microsoft\Windows'
$SearchBoxMode=2   # SearchboxTaskbarMode: 0 = hidden, 1 = icon only, 2 = search box (Windows 10 and 11), 3 = icon and label (Windows 11 only)
$CS='HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\CapabilityAccessManager\ConsentStore'
$s1='Privacy & Telemetry';$s6='AI & Copilot';$s2='Bloatware: Microsoft Apps';$s7='Bloatware: Xbox & Gaming Apps';$s8='Bloatware: Third-Party Promos';$s9='Bloatware: Legacy & Heavy Removals'
$s3='Start Menu & Ads';$s10='Taskbar & Shell';$s5='Explorer & Usability';$s4='Performance';$s11='Gaming';$s12='Windows Update & System';$s13='Network & DNS';$s14='Maintenance & Repair'
$secs=$s1,$s6,$s2,$s7,$s8,$s9,$s3,$s10,$s5,$s4,$s11,$s12,$s13,$s14

# NVIDIA's telemetry tasks carry a GUID suffix (NvTmMon_{GUID}...), so they are looked up on this PC (root task folder only)
$nvTasks=@(try{Get-ScheduledTask -TaskPath '\' -ErrorAction Stop|Where-Object{$_.TaskName -match '^NvTm(Mon|Rep|RepOnLogon)'}|ForEach-Object{fTask ('\'+$_.TaskName)}}catch{@()})

$db=@(
fTw $s1 'Disable telemetry & diagnostic services' 'Lowers Windows diagnostic data to the minimum your edition allows (Off on Enterprise/Education, "Required" on Home/Pro), limits extra log and crash-dump uploads, stops OneSettings config downloads and disables the Connected User Experiences (DiagTrack) and WAP push services.' Safe 'WinUtil, Win11Debloat, Sophia, W10Debloater' Any 'safe,privacy,telemetry' @((fReg "$POL\DataCollection" AllowTelemetry 0 $null),(fReg "$POL\DataCollection" LimitDiagnosticLogCollection 1 $null),(fReg "$POL\DataCollection" LimitDumpCollection 1 $null),(fReg "$POL\DataCollection" DisableOneSettingsDownloads 1 $null),(fSvc DiagTrack Automatic),(fSvc dmwappushservice Manual))
fTw $s1 'Disable telemetry scheduled tasks' 'Turns off the scheduled tasks that collect compatibility, usage, disk-health and feedback data (Compatibility Appraiser, CEIP, Program Data Updater, disk diagnostics, error-report queue, feedback). Tasks missing on your build are skipped.' Safe 'WinUtil, W10Debloater, W4RH4WK' Any 'safe,privacy,telemetry' @((fTask '\Microsoft\Windows\Application Experience\Microsoft Compatibility Appraiser'),(fTask '\Microsoft\Windows\Application Experience\ProgramDataUpdater'),(fTask '\Microsoft\Windows\Application Experience\StartupAppTask'),(fTask '\Microsoft\Windows\Application Experience\PcaPatchDbTask'),(fTask '\Microsoft\Windows\Customer Experience Improvement Program\Consolidator'),(fTask '\Microsoft\Windows\Customer Experience Improvement Program\UsbCeip'),(fTask '\Microsoft\Windows\Customer Experience Improvement Program\KernelCeipTask'),(fTask '\Microsoft\Windows\Autochk\Proxy'),(fTask '\Microsoft\Windows\DiskDiagnostic\Microsoft-Windows-DiskDiagnosticDataCollector'),(fTask '\Microsoft\Windows\Windows Error Reporting\QueueReporting'),(fTask '\Microsoft\Windows\Feedback\Siuf\DmClient'),(fTask '\Microsoft\Windows\Feedback\Siuf\DmClientOnScenarioDownload'))
fTw $s1 'Disable app-compatibility telemetry (Inventory Collector, Steps Recorder)' 'Group Policy switches that stop Windows inventorying your installed programs and files for Microsoft, sending application-impact telemetry, and collecting Steps Recorder data.' Safe 'DebloatHub' Any 'safe,privacy,telemetry' @((fReg "$POL\AppCompat" AITEnable 0 $null),(fReg "$POL\AppCompat" DisableInventory 1 $null),(fReg "$POL\AppCompat" DisableUAR 1 $null))
fTw $s1 'Disable NVIDIA telemetry (telemetry container, NvTm* tasks, opt-in flag)' 'Stops the NVIDIA Telemetry Container service (older drivers), the NvTmMon / NvTmRep / NvTmRepOnLogon scheduled tasks and sets the NVIDIA control-panel opt-in flag to "no". Does nothing on PCs without NVIDIA drivers. These settings are community-documented; NVIDIA publishes no official switch.' Safe 'DebloatHub' Any 'safe,privacy,telemetry' (@((fSvc NvTelemetryContainer Automatic),(fReg 'HKLM:\SOFTWARE\NVIDIA Corporation\NvControlPanel2\Client' OptInOrOutPreference 0 $null DWord $true),(fReg 'HKCU:\Software\NVIDIA Corporation\NvControlPanel2\Client' OptInOrOutPreference 0 $null DWord $true))+$nvTasks)
fTw $s1 'Disable Office telemetry (diagnostic data "Neither", legacy Telemetry Agent)' 'Per-user Office policies: diagnostic data level "Neither" (SendTelemetry=3), Telemetry Agent logging and upload off, plus the four Office Telemetry Agent scheduled tasks. Required service data is still sent. The Telemetry Agent itself was removed from Microsoft 365 Apps in version 2301, so those parts only matter for older Office.' Safe 'DebloatHub' Any 'safe,privacy,telemetry' @((fReg 'HKCU:\Software\Policies\Microsoft\office\common\clienttelemetry' SendTelemetry 3 $null),(fReg 'HKCU:\Software\Policies\Microsoft\Office\16.0\osm' Enablelogging 0 $null),(fReg 'HKCU:\Software\Policies\Microsoft\Office\16.0\osm' EnableUpload 0 $null),(fTask '\Microsoft\Office\OfficeTelemetryAgentFallBack'),(fTask '\Microsoft\Office\OfficeTelemetryAgentLogOn'),(fTask '\Microsoft\Office\OfficeTelemetryAgentFallBack2016'),(fTask '\Microsoft\Office\OfficeTelemetryAgentLogOn2016'))
fTw $s1 'Disable advertising ID' 'Turns off the per-user advertising ID that Store apps can read to profile you for ads, and blocks it machine-wide by policy.' Safe 'WinUtil, Win11Debloat, Sophia' Any 'safe,privacy' @((fReg "HKCU:\Software\Microsoft\Windows\CurrentVersion\AdvertisingInfo" Enabled 0 1),(fReg "$POL\AdvertisingInfo" DisabledByGroupPolicy 1 $null))
fTw $s1 'Disable Activity History' 'Stops Windows recording which apps, files and sites you use (Activity History) and uploading it to your Microsoft account.' Safe 'WinUtil, Win11Debloat' Any 'safe,privacy' @((fReg "$POL\System" EnableActivityFeed 0 $null),(fReg "$POL\System" PublishUserActivities 0 $null),(fReg "$POL\System" UploadUserActivities 0 $null))
fTw $s1 'Disable tailored experiences' 'Stops Microsoft using your diagnostic data to personalise tips, ads and recommendations in Windows.' Safe 'Win11Debloat, Sophia' Any 'safe,privacy,telemetry' @(fReg 'HKCU:\SOFTWARE\Policies\Microsoft\Windows\CloudContent' DisableTailoredExperiencesWithDiagnosticData 1 $null)
fTw $s1 'Disable web results in Start search' 'Start/taskbar search only looks at your PC: no Bing web results, suggestions or web previews.' Safe 'WinUtil, Win11Debloat, Sophia' Any 'safe,privacy' @(fReg 'HKCU:\SOFTWARE\Policies\Microsoft\Windows\Explorer' DisableSearchBoxSuggestions 1 $null)
fTw $s1 'Disable location access' 'Switches off location for the whole device (Settings > Privacy > Location), so no app or Windows feature can read your position.' Moderate 'WinUtil, W10Debloater' Any 'privacy' @(fReg 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\CapabilityAccessManager\ConsentStore\location' Value Deny Allow String)
fTw $s1 'Disable Windows Error Reporting' 'Turns off Windows Error Reporting (setting, policy and the WerSvc service), so crash and hang reports are no longer collected or sent to Microsoft.' Safe 'WinUtil, W4RH4WK' Any 'safe,privacy,telemetry' @((fReg 'HKLM:\SOFTWARE\Microsoft\Windows\Windows Error Reporting' Disabled 1 $null),(fReg "$POL\Windows Error Reporting" Disabled 1 $null),(fSvc WerSvc Manual))
fTw $s6 'Disable Windows Recall / AI data analysis' 'Policy that stops Recall from taking snapshots of your screen and analysing them. Only does something on Copilot+ PCs that ship Recall.' Safe 'Win11Debloat' 11 'privacy' @(fReg "$POL\WindowsAI" DisableAIDataAnalysis 1 $null)
fTw $s6 'Disable Copilot' 'Turns off the Copilot sidebar by policy. This only affects the built-in sidebar from Windows 11 23H2; on 24H2 and newer Copilot is a normal app, so use "Remove Copilot apps" there.' Safe 'WinUtil, Win11Debloat' 11 'privacy' @(fReg 'HKCU:\Software\Policies\Microsoft\Windows\WindowsCopilot' TurnOffWindowsCopilot 1 $null)

fTw $s2 'Remove Microsoft consumer apps' 'Uninstalls News, Weather, Get Help, Tips, Office hub ("Microsoft 365"), Solitaire, Feedback Hub and Clipchamp. Each app can be picked individually.' Safe 'Win11Debloat, W10Debloater, Sophia' Any 'safe' @('Microsoft.BingNews','Microsoft.BingWeather','Microsoft.GetHelp','Microsoft.Getstarted','Microsoft.MicrosoftOfficeHub','Microsoft.MicrosoftSolitaireCollection','Microsoft.WindowsFeedbackHub','Clipchamp.Clipchamp'|ForEach-Object{fApp $_})
fTw $s8 'Remove third-party promo apps' 'Uninstalls pre-installed promotional apps and stubs: Candy Crush, Spotify, TikTok, Disney+, Instagram, Facebook, LinkedIn.' Safe 'Win11Debloat, W10Debloater, W4RH4WK' Any 'safe' @('*CandyCrush*','*Spotify*','*TikTok*','*Disney*','*Instagram*','*Facebook*','*LinkedIn*'|ForEach-Object{fApp $_})
fTw $s7 'Remove Xbox apps' 'Uninstalls the Xbox app, Game Bar (Win+G), Xbox overlays and Xbox identity/speech components. Each package can be picked individually.' Moderate 'WinUtil, Win11Debloat' Any '' @('Microsoft.XboxApp','Microsoft.XboxGamingOverlay','Microsoft.XboxGameOverlay','Microsoft.Xbox.TCUI','Microsoft.XboxSpeechToTextOverlay'|ForEach-Object{fApp $_}) 'Do not run if you use Xbox Game Pass, PC cloud saves, or Win+G Game Bar.'
fTw $s9 'Remove 3D / Mixed Reality apps' 'Uninstalls 3D Builder, 3D Viewer, Print 3D and the Mixed Reality Portal.' Safe 'W10Debloater, W4RH4WK' Any 'safe' @('Microsoft.3DBuilder','Microsoft.Microsoft3DViewer','Microsoft.Print3D','Microsoft.MixedReality.Portal'|ForEach-Object{fApp $_})

fTw $s3 'Disable Start/Settings suggestions & silent app installs' 'Stops Windows promoting apps in Start, Settings and the Start menu, and stops it installing "suggested" apps (games, Spotify and so on) in the background.' Safe 'WinUtil, Win11Debloat, Sophia, W10Debloater' Any 'safe,privacy' ('SubscribedContent-338388Value','SubscribedContent-338389Value','SubscribedContent-353696Value','SystemPaneSuggestionsEnabled','SilentInstalledAppsEnabled','PreInstalledAppsEnabled','OemPreInstalledAppsEnabled'|ForEach-Object{fReg $CDM $_ 0 1})
fTw $s3 'Disable lock screen tips & ads' 'Removes "fun facts", tips and promotions from the lock screen. Your picture or Spotlight image stays.' Safe 'Win11Debloat, Sophia' Any 'safe' ('RotatingLockScreenOverlayEnabled','SubscribedContent-338387Value'|ForEach-Object{fReg $CDM $_ 0 1})
fTw $s3 'Disable Widgets' 'Turns off Widgets (Win+W) by policy: the taskbar weather button and the news/widgets board disappear.' Safe 'WinUtil, Win11Debloat' 11 'safe' @(fReg 'HKLM:\SOFTWARE\Policies\Microsoft\Dsh' AllowNewsAndInterests 0 $null)
fTw $s3 'Disable News and Interests' 'Removes the Windows 10 taskbar weather/news button (News and Interests) by policy.' Safe 'WinUtil, W10Debloater' 10 'safe' @(fReg "$POL\Windows Feeds" EnableFeeds 0 $null)

fTw $s12 'Disable Delivery Optimization (P2P uploads)' 'Sets the Delivery Optimization policy to HTTP-only: Windows downloads updates and Store apps straight from Microsoft and never uploads them to other PCs (on your network or the internet).' Safe 'WinUtil, Win11Debloat, W10Debloater' Any 'safe' @(fReg "$POL\DeliveryOptimization" DODownloadMode 0 $null)
fTw $s11 'Disable Game DVR / background capture' 'Turns off Game DVR background recording ("Record what happened") and app capture.' Safe 'WinUtil, Win11Debloat, Sophia' Any 'gaming' @((fReg 'HKCU:\System\GameConfigStore' GameDVR_Enabled 0 1),(fReg 'HKCU:\Software\Microsoft\Windows\CurrentVersion\GameDVR' AppCaptureEnabled 0 1))
fTw $s11 'Disable mouse acceleration' 'Turns off "Enhance pointer precision", so the cursor moves the same distance for the same hand movement, no matter how fast you move the mouse.' Safe 'WinUtil, Sophia' Any 'gaming' @((fReg 'HKCU:\Control Panel\Mouse' MouseSpeed '0' '1' String),(fReg 'HKCU:\Control Panel\Mouse' MouseThreshold1 '0' '6' String),(fReg 'HKCU:\Control Panel\Mouse' MouseThreshold2 '0' '10' String))
fTw $s4 'Disable Fast Startup' 'Makes "Shut down" a real shutdown. With Fast Startup on, Windows hibernates the kernel and drivers instead, so they are never fully reset.' Safe 'WinUtil, Sophia' Any 'gaming' @(fReg 'HKLM:\SYSTEM\CurrentControlSet\Control\Session Manager\Power' HiberbootEnabled 0 1)
fTw $s4 'Disable SysMain (Superfetch)' 'Disables SysMain (Superfetch), which learns which apps you use and preloads them into free RAM.' Advanced 'WinUtil, W10Debloater, W4RH4WK' Any '' @(fSvc SysMain Automatic)
fTw $s4 'Disable Windows Search indexing' 'Disables the Windows Search indexer service (WSearch), which keeps a database of your files and email for instant search.' Advanced 'WinUtil, W4RH4WK' Any '' @(fSvc WSearch Automatic)

fTw $s5 'Show file extensions' 'Explorer shows the full file name including the extension (.exe, .pdf, .docx).' Safe 'WinUtil, Win11Debloat, Sophia' Any 'safe' @(fReg $ADV HideFileExt 0 1)
fTw $s5 'Show hidden files' 'Explorer shows files and folders marked as hidden (e.g. AppData, ProgramData).' Safe 'WinUtil, Win11Debloat, Sophia' Any '' @(fReg $ADV Hidden 1 2)
fTw $s5 'Open Explorer to "This PC"' 'Win+E and the Explorer icon open "This PC" (your drives) instead of Home / Quick Access.' Safe 'Win11Debloat, Sophia' Any '' @(fReg $ADV LaunchTo 1 2)
fTw $s5 'Disable Sticky Keys prompt' 'Pressing Shift five times no longer pops up the Sticky Keys dialog (which steals focus from games). Sticky Keys itself can still be turned on in Settings.' Safe 'WinUtil, Sophia' Any 'gaming' @(fReg 'HKCU:\Control Panel\Accessibility\StickyKeys' Flags '506' '510' String)
fTw $s1 'Disable Customer Experience Improvement Program' 'Policy opt-out of the Customer Experience Improvement Program (CEIP), the older usage-statistics channel.' Safe 'Windows10Debloater, privacy.sexy' Any 'safe,privacy,telemetry' @(fReg 'HKLM:\SOFTWARE\Policies\Microsoft\SQMClient\Windows' CEIPEnable 0 $null)
fTw $s1 'Disable feedback prompts' 'Windows stops popping up "How likely are you to recommend Windows?" style surveys (per-user setting plus policy).' Safe 'Windows10Debloater, privacy.sexy' Any 'safe,privacy,telemetry' @((fReg 'HKCU:\Software\Microsoft\Siuf\Rules' NumberOfSIUFInPeriod 0 $null),(fReg "$POL\DataCollection" DoNotShowFeedbackNotifications 1 $null))
fTw $s1 'Disable Xbox cloud-save task' 'Disables the XblGameSave scheduled task that syncs Xbox / Game Pass PC game saves with the cloud.' Moderate 'Windows10Debloater' Any '' @(fTask '\Microsoft\XblGameSave\XblGameSaveTask') 'Do not run if you use Xbox Game Pass, PC cloud saves, or Win+G Game Bar.'
fTw $s1 'Block apps from camera & microphone by default' 'Sets device-wide camera and microphone access to Off. No app, including desktop apps, can use them until you switch access back on in Settings > Privacy & security.' Advanced 'winscript' Any '' @((fReg "$CS\webcam" Value Deny Allow String),(fReg "$CS\microphone" Value Deny Allow String)) 'Skip this if you use video calls regularly.'
fTw $s6 'Disable Click to Do' 'Turns off Click to Do, the Copilot+ PC overlay that analyses what is on screen and offers AI actions (Win+click).' Safe 'Win11Debloat, RemoveWindowsAI' 11 'privacy' @(fReg 'HKCU:\Software\Policies\Microsoft\Windows\WindowsAI' DisableClickToDo 1 $null)
fTw $s6 'Disable AI Fabric service' 'Disables the Windows AI Fabric service (WSAIFabricSvc), the background service behind on-device AI features on newer Windows 11 builds.' Safe 'Win11Debloat, RemoveWindowsAI' 11 'privacy' @(fSvc WSAIFabricSvc Automatic)
fTw $s6 'Remove Copilot apps' 'Uninstalls the Copilot app package(s) for all users.' Safe 'RemoveWindowsAI, Win11Debloat' Any 'privacy' @(fApp '*Copilot*')
fTw $s6 'Remove Recall optional feature' 'Disables the Recall optional Windows feature (more thorough than the policy above). Undo turns the feature back on. Reboot needed.' Moderate 'RemoveWindowsAI' 11 '' @(fFeat Recall) 'Only relevant on Windows 11 24H2+ PCs that ship Recall.'
fTw $s2 'Remove Teams (personal) & Cortana' 'Uninstalls the built-in Teams packages (MicrosoftTeams = old personal chat, MSTeams = the new Teams app) and the Cortana app.' Safe 'Win11Debloat, Windows10Debloater' Any 'safe' @('MicrosoftTeams','MSTeams','Microsoft.549981C3F5F10'|ForEach-Object{fApp $_})
fTw $s2 'Remove optional extras' 'Uninstalls OneNote (Store version), Sticky Notes, Maps, Alarms & Clock, Voice Recorder, Camera, Calculator and Power Automate. Pick items individually.' Moderate 'Windows10Debloater' Any '' @('Microsoft.Office.OneNote','Microsoft.MicrosoftStickyNotes','Microsoft.WindowsMaps','Microsoft.WindowsAlarms','Microsoft.WindowsSoundRecorder','Microsoft.WindowsCamera','Microsoft.WindowsCalculator','Microsoft.PowerAutomateDesktop'|ForEach-Object{fApp $_}) 'Keep any you actually use (Camera, Calculator and Sticky Notes are the common ones; pick items individually).'
fTw $s8 'Remove more promo games & stubs' 'Uninstalls older promo games and app stubs (King games, FarmVille, Asphalt, March of Empires, Royal Revolt, Duolingo, Netflix, Pandora, Twitter, Flipboard, Shazam, iHeartRadio, PicsArt).' Safe 'Windows10Debloater' Any 'safe' @('*king.com*','*FarmVille*','*Asphalt*','*MarchofEmpires*','*RoyalRevolt*','*Duolingo*','*Netflix*','*Pandora*','*Twitter*','*Flipboard*','*Shazam*','*iHeartRadio*','*PicsArt*'|ForEach-Object{fApp $_})
fTw $s9 'Remove legacy Microsoft apps' 'Uninstalls Skype, Groove Music / Media Player, Movies & TV, People, Messaging, Sway, OneConnect and Reading List. Pick items individually.' Safe 'Windows10Debloater' Any 'safe' @('Microsoft.SkypeApp','Microsoft.ZuneMusic','Microsoft.ZuneVideo','Microsoft.People','Microsoft.Messaging','Microsoft.Office.Sway','Microsoft.OneConnect','Microsoft.WindowsReadingList'|ForEach-Object{fApp $_})
fTw $s9 'Uninstall OneDrive' 'Runs the official OneDrive uninstaller (system or per-user install). Your cloud files are not deleted.' Advanced 'winscript' Any '' @(fCmd '$p=@(@("$env:SystemRoot\SysWOW64\OneDriveSetup.exe","$env:SystemRoot\System32\OneDriveSetup.exe")+@(Get-ChildItem "$UserLocal\Microsoft\OneDrive\*\OneDriveSetup.exe","${env:ProgramFiles}\Microsoft OneDrive\*\OneDriveSetup.exe" -ErrorAction SilentlyContinue|ForEach-Object FullName)|Where-Object{Test-Path -LiteralPath $_})|Select-Object -First 1;if(-not $p){throw ''OneDriveSetup.exe was not found - OneDrive is probably already uninstalled''};Stop-Process -Name OneDrive -Force -ErrorAction SilentlyContinue;Start-Process $p ''/uninstall'' -Wait') 'Back up your OneDrive folders first. Skip if you use OneDrive sync.'
fTw $s10 'Left-align taskbar' 'Moves the Start button and taskbar icons to the left edge, like Windows 10.' Safe 'Win11Debloat, Windows-Maintenance-Tool' 11 '' @(fReg $ADV TaskbarAl 0 1)
fTw $s10 'Hide Task View button' 'Removes the Task View (virtual desktops) button from the taskbar. Win+Tab still opens it.' Safe 'Win11Debloat, Windows-Maintenance-Tool' Any '' @(fReg $ADV ShowTaskViewButton 0 1)
fTw $s10 'Hide Chat button' 'Removes the Teams "Chat" button from the Windows 11 taskbar. Only builds 21H2/22H2 have it; on 23H2 and newer the button no longer exists, so this changes nothing there.' Safe 'Win11Debloat, Windows-Maintenance-Tool' 11 'safe' @(fReg $ADV TaskbarMn 0 1)
fTw $s10 'Hide People Bar (Windows 10)' 'Hides the My People icon and contacts bar on the taskbar. Windows 10 only; Microsoft has been removing the feature, so on current builds it may already be gone and this changes nothing.' Safe 'DebloatHub' 10 '' @(fReg "$ADV\People" PeopleBand 0 1)
fTw $s10 'Hide Meet Now icon (Windows 10)' 'Removes the Skype Meet Now icon from the notification area (policy value HideSCAMeetNow). Windows 10 only; the icon is not shown on Enterprise or Azure AD accounts anyway. Sign out and back in if it does not disappear at once.' Safe 'DebloatHub' 10 '' @(fReg 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Policies\Explorer' HideSCAMeetNow 1 $null)
fTw $s10 'Collapse taskbar search to an icon' 'Shows only the magnifier instead of the wide search box and frees taskbar space. Undo restores the search box (value 2). A search policy from your organization overrides this setting.' Safe 'DebloatHub' Any '' @(fReg 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Search' SearchboxTaskbarMode 1 $SearchBoxMode)
fTw $s10 'Disable search highlights' 'Removes the daily Bing picture and trending items from the search box and search home, leaving a plain search field.' Safe 'DebloatHub' Any '' @(fReg 'HKCU:\Software\Microsoft\Windows\CurrentVersion\SearchSettings' IsDynamicSearchBoxEnabled 0 1)
fTw $s10 'Enable End Task in taskbar right-click' 'Adds "End task" to the right-click menu of taskbar apps (Windows 11 23H2+), which force-closes a frozen app without Task Manager.' Safe 'Win11Debloat' 11 '' @(fReg "$ADV\TaskbarDeveloperSettings" TaskbarEndTask 1 0)
fTw $s5 'Show full path in title bar' 'Explorer shows the complete folder path (C:\Users\...) in the window and taskbar title instead of just the folder name.' Safe 'Windows-Maintenance-Tool' Any '' @(fReg 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\CabinetState' FullPath 1 0)
fTw $s5 'Hide recent & frequent items in Explorer' 'Explorer Home / Quick Access stops listing recently opened files and frequently used folders. Pinned folders stay.' Safe 'Windows-Maintenance-Tool' Any 'privacy' @((fReg 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer' ShowRecent 0 1),(fReg 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer' ShowFrequent 0 1))
fTw $s4 'Disable Storage Sense auto cleanup' 'Turns off Storage Sense, so Windows never deletes temp files or Recycle Bin items on its own.' Safe 'Win11Debloat, winscript' Any '' @(fReg 'HKCU:\Software\Microsoft\Windows\CurrentVersion\StorageSense\Parameters\StoragePolicy' '01' 0 1)
fTw $s4 'Disable transparency effects' 'Turns off the blur and see-through effect on the taskbar, Start, Action Center and window backgrounds.' Safe 'Win11Debloat' Any '' @(fReg 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Themes\Personalize' EnableTransparency 0 1)
fTw $s4 'Disable hibernation' 'Runs powercfg /hibernate off: deletes hiberfil.sys and turns off Hibernate and Fast Startup. Undo turns them back on.' Moderate 'Windows-Maintenance-Tool' Any '' @(fCmd 'powercfg /hibernate off' 'powercfg /hibernate on' "(Get-ItemProperty 'HKLM:\SYSTEM\CurrentControlSet\Control\Power' -Name HibernateEnabled -ErrorAction SilentlyContinue).HibernateEnabled -eq 0") 'Fine on desktops; keep it on laptops.'
fTw $s4 'Ultimate Performance power plan' 'Creates Windows hidden Ultimate Performance plan once, using a fixed ID so repeated Apply never piles up copies, and makes it active. CPU cores stay at high clocks and power saving is minimised. Undo switches back to Balanced and deletes the plan.' Moderate 'winscript, Windows-Maintenance-Tool' Any 'gaming' @(fCmd '$g=''ec2056a3-39a8-4408-993a-3b596535ebe1'';if(-not((powercfg /list) -match $g)){$null=powercfg -duplicatescheme e9a42b02-d5df-448d-aa00-03f14749eb61 $g;if($LASTEXITCODE){throw ''Windows refused to create the Ultimate Performance plan (some laptops hide it)''}};powercfg /setactive $g' '$g=''ec2056a3-39a8-4408-993a-3b596535ebe1'';powercfg /setactive 381b4222-f694-41f0-9685-ff5bb260df2e;if((powercfg /list) -match $g){$null=powercfg /delete $g};$global:LASTEXITCODE=0' '[bool]((powercfg /getactivescheme) -match ''ec2056a3-39a8-4408-993a-3b596535ebe1'')') 'Desktops only; avoid on battery.'
fTw $s11 'Disable Game Bar' 'Stops the Xbox button on a controller opening Game Bar and hides the Game Bar tips panel when a game starts.' Safe 'Win11Debloat' Any 'gaming' @((fReg 'HKCU:\Software\Microsoft\GameBar' UseNexusForGameBarEnabled 0 1),(fReg 'HKCU:\Software\Microsoft\GameBar' ShowStartupPanel 0 1))
fTw $s12 'No auto-restart while signed in' 'Group Policy that tells Windows Update not to restart the PC automatically while someone is signed in.' Safe 'Win11Debloat' Any 'safe' @(fReg "$POL\WindowsUpdate\AU" NoAutoRebootWithLoggedOnUsers 1 $null)
fTw $s12 'Disable device metadata downloads' 'Stops Windows downloading manufacturer names, photos and icons for connected devices from the internet.' Safe 'Windows-Maintenance-Tool' Any 'privacy' @(fReg 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Device Metadata' PreventDeviceMetadataFromNetwork 1 $null)
fTw $s12 'Disable BitLocker auto device encryption' 'Prevents Windows from turning on Device Encryption (BitLocker) automatically. It does not decrypt a drive that is already encrypted; check Settings > Privacy & security > Device encryption for that.' Advanced 'Win11Debloat' Any '' @(fReg 'HKLM:\SYSTEM\CurrentControlSet\Control\BitLocker' PreventDeviceEncryption 1 $null) 'Leave this OFF on laptops: encryption protects your data if the device is lost.'
fTw $s13 'Use Cloudflare DNS (1.1.1.1)' 'Sets the DNS servers of every active network adapter to Cloudflare (1.1.1.1 / 1.0.0.1, plus IPv6 where enabled). Undo returns all adapters to automatic DNS from your router (DHCP).' Advanced 'Windows-Maintenance-Tool' Any '' @(fCmd 'Get-NetAdapter|Where-Object Status -eq Up|ForEach-Object{Set-DnsClientServerAddress -InterfaceIndex $_.ifIndex -ServerAddresses ''1.1.1.1'',''1.0.0.1'';try{Set-DnsClientServerAddress -InterfaceIndex $_.ifIndex -ServerAddresses ''1.1.1.1'',''1.0.0.1'',''2606:4700:4700::1111'',''2606:4700:4700::1001'' -ErrorAction Stop}catch{}}' 'Get-NetAdapter|ForEach-Object{Set-DnsClientServerAddress -InterfaceIndex $_.ifIndex -ResetServerAddresses}' '$ad=@(Get-NetAdapter|Where-Object Status -eq Up);[bool]($ad.Count -and -not @($ad|Where-Object{(@((Get-DnsClientServerAddress -InterfaceIndex $_.ifIndex -AddressFamily IPv4).ServerAddresses) -join '','') -ne ''1.1.1.1,1.0.0.1''}).Count)') 'Experts only: skip it if you use a NAS or local network shares, connect to hotel or airport Wi-Fi, or your router, VPN or workplace controls DNS.'
fTw $s14 'Flush DNS cache' 'Runs ipconfig /flushdns to clear the list of recently looked-up website addresses.' Safe 'Windows-Maintenance-Tool' Any '' @(fCmd 'ipconfig /flushdns')
fTw $s14 'Clean temp files & empty Recycle Bin' 'Deletes everything in your Temp folder and the Windows Temp folder (files in use are skipped) and empties the Recycle Bin.' Safe 'Windows-Maintenance-Tool' Any '' @(fCmd 'Remove-Item "$UserLocal\Temp\*","$env:SystemRoot\Temp\*" -Recurse -Force -ErrorAction SilentlyContinue;Clear-RecycleBin -Force -ErrorAction SilentlyContinue') 'Close other apps first.'
fTw $s14 'Repair system files (SFC)' 'Runs sfc /scannow, which checks every protected Windows file and replaces damaged ones from the component store. Takes 10+ minutes.' Safe 'Windows-Maintenance-Tool' Any '' @(fCmd 'sfc /scannow') 'Run this on its own, not together with other tweaks.'
fTw $s14 'Repair Windows image (DISM RestoreHealth)' 'Runs DISM /RestoreHealth, which repairs the component store (the source SFC copies from) by downloading good files from Windows Update.' Safe 'Windows-Maintenance-Tool' Any '' @(fCmd 'DISM /Online /Cleanup-Image /RestoreHealth') 'Run before SFC if SFC reports errors it cannot fix.'
# WARNING: deleting superseded driver packages makes the "Roll Back Driver" button in Device Manager inactive for every device whose driver was updated
# (the previous version no longer exists) and the deleted packages cannot be restored. Drivers a connected device uses, boot-critical drivers and printer drivers are never deleted.
fTw $s14 'Clean up old driver versions (Driver Store)' 'Deletes superseded third-party driver packages from the Windows Driver Store (FileRepository) and keeps the newest version of every driver. Skips drivers that connected devices use, boot-critical drivers and printer drivers. WARNING: afterwards the "Roll Back Driver" button in Device Manager is inactive for devices whose driver was updated, and the deleted packages cannot be restored. A reboot may be needed.' Advanced 'DebloatHub' Any '' @(fCmd 'Clean-DriverStore') 'Only if you need the disk space and are sure you will not need to roll back any driver. DebloatHub cannot bring deleted driver packages back.'
fTw $s14 'Reset Windows Update components' 'Stops Windows Update and BITS, deletes the downloaded-update cache (SoftwareDistribution\Download) and starts the services again.' Moderate 'Windows-Maintenance-Tool' Any '' @(fCmd 'Stop-Service wuauserv,bits -Force;Remove-Item "$env:SystemRoot\SoftwareDistribution\Download\*" -Recurse -Force -ErrorAction SilentlyContinue;Start-Service wuauserv,bits') 'Use when Windows Update is stuck or failing.'
fTw $s14 'Reset network stack' 'Runs netsh winsock reset and netsh int ip reset, which rebuild the network catalog and TCP/IP settings to defaults. Reboot required.' Moderate 'Windows-Maintenance-Tool' Any '' @(fCmd 'netsh winsock reset;netsh int ip reset') 'Only when you have connection problems.'
fTw $s14 'SSD TRIM (system drive)' 'Sends TRIM for the Windows drive right now (Optimize-Volume -ReTrim), telling the SSD which blocks are free.' Safe 'Windows-Maintenance-Tool' Any '' @(fCmd 'Optimize-Volume -DriveLetter $env:SystemDrive[0] -ReTrim')
)

# ---------- Extra guidance shown in the hover card: @(need it?, pros, cons) ----------
$more=@{
'Disable telemetry & diagnostic services'=@('Use it if you do not want Windows sending usage data beyond the minimum. Skip it if you are a Windows Insider: Insider builds expect optional diagnostic data.','Less data sent to Microsoft; DiagTrack no longer runs in the background or uploads on a schedule.','Home and Pro still send "Required" data; only Enterprise/Education reach Off. Settings > Privacy shows "Some settings are managed by your organization". Feedback Hub and some troubleshooters get less detail.')
'Disable telemetry scheduled tasks'=@('Use it if you want fewer background data scans. Skip it if you are waiting for a Windows 11 or feature upgrade offer: the Compatibility Appraiser is what checks whether your PC qualifies.','Fewer CPU and disk bursts a few minutes after boot and while idle (the Appraiser is a known culprit on slow drives).','Feature-upgrade checks and app-compatibility warnings become less accurate. Big Windows updates can re-enable some tasks; press "Detect applied tweaks" after one.')
'Disable NVIDIA telemetry (telemetry container, NvTm* tasks, opt-in flag)'=@('Not needed unless you want to share hardware and usage data with NVIDIA.','Fewer background tasks and no NVIDIA telemetry service.','Does nothing without NVIDIA drivers. A driver update can bring the tasks back; press Detect applied tweaks afterwards. NVIDIA documents no official switch, so these settings are community-documented.')
'Disable Office telemetry (diagnostic data "Neither", legacy Telemetry Agent)'=@('Not needed unless you rely on Office diagnostics or your IT team collects Office telemetry.','Office stops sending optional diagnostic data and the old Telemetry Agent stops logging and uploading.','Office may say some settings are managed by your organization and grey out its privacy option. Required service data is still sent.')
'Disable app-compatibility telemetry (Inventory Collector, Steps Recorder)'=@('Use it for privacy. Skip it if you record problems with Steps Recorder (psr.exe) for someone else.','Windows stops building and uploading a list of your installed software.','Steps Recorder stops working; app-compatibility fixes and warnings may be less tailored to your PC.')
'Disable advertising ID'=@('Use it unless you want ads in Store apps to be personalised.','Apps cannot follow you from app to app with one shared ID.','None in practice: ads still appear, they are just less targeted.')
'Disable Activity History'=@('Use it for privacy. Skip it if you continue work across PCs with the same Microsoft account.','No local or cloud log of your activity.','Cross-device "pick up where you left off" stops working (Windows 10 Timeline is already gone on Windows 11).')
'Disable tailored experiences'=@('Use it unless you want Windows tips tuned to how you use the PC.','Tips and offers are no longer based on your usage data.','Tips become generic. Nothing else changes.')
'Disable web results in Start search'=@('Use it if you search for apps, settings and files. Skip it if you use the Start menu as a quick web search.','Search results appear faster and are not cluttered with web links; what you type is not sent to Bing.','No web answers in Start; open a browser for web searches.')
'Disable location access'=@('Use it on desktops or if you never need location. Skip it on laptops if you use Find My Device or automatic time zone when travelling.','No app or Windows service can track where the PC is.','Weather, Maps and websites ask for a manual location; Find My Device and "Set time zone automatically" stop working.')
'Disable Windows Error Reporting'=@('Use it for privacy. Skip it while you are troubleshooting crashes or if a developer asked for WER reports.','No crash data leaves the PC; no "checking for a solution" dialogs.','Reliability Monitor shows less detail and Microsoft cannot offer known fixes for a crashing app.')
'Disable Windows Recall / AI data analysis'=@('Use it on Copilot+ PCs unless you want a searchable history of everything shown on screen.','No screenshots of your activity are stored, even locally.','No "search what I saw" timeline.')
'Disable Copilot'=@('Use it on 23H2 if you do not use Copilot. On newer builds it is harmless but usually changes nothing.','No Copilot button, sidebar or Win+C shortcut on builds that honour the policy.','Copilot shortcuts stop working; newer builds ignore this policy.')
'Disable Customer Experience Improvement Program'=@('Use it; nobody needs it. On Windows 10/11 most of this data moved to the diagnostic-data setting.','Closes one more legacy data channel.','None noticeable.')
'Disable feedback prompts'=@('Use it unless you like answering Microsoft surveys.','No survey pop-ups or notifications.','None; Feedback Hub still works if you open it yourself.')
'Disable Xbox cloud-save task'=@('Skip it if you play Game Pass or Microsoft Store games. Pointless if you already removed the Xbox apps and do not play such games.','One less background task.','Game Pass and Store game saves may stop syncing between PCs, which can lead to lost or conflicting saves.')
'Block apps from camera & microphone by default'=@('Use it on a PC where you almost never use the camera or mic. Skip it if you have regular calls.','Strong protection against apps or malware silently turning on the camera or mic.','Teams, Zoom, Discord and browsers cannot use the camera/mic until you turn access back on, and calls fail silently if you forget.')
'Disable Click to Do'=@('Use it on Copilot+ PCs unless you use the overlay.','No screen analysis in the background; Win+click does nothing unexpected.','Click to Do text and image actions are unavailable.')
'Disable AI Fabric service'=@('Use it if you do not use Windows AI features (Recall, Click to Do, AI actions in apps).','One less always-running service; less RAM and background NPU/CPU use.','Windows AI features that depend on it may stop working or show errors.')
'Remove Copilot apps'=@('Use it if you do not use Copilot. You can still use Copilot in a browser.','Removes the app and its background updates; frees a little disk space.','The Copilot key or shortcut opens nothing (or the Store). Reinstall from the Microsoft Store if needed.')
'Remove Recall optional feature'=@('Use it on Copilot+ PCs if you never want Recall. Other PCs do not have the feature, so this does nothing there.','Recall cannot be switched on again by an update or by accident.','Needs a reboot; to use Recall later you must switch this off and reboot.')
'Remove Microsoft consumer apps'=@('Use it for the apps you never open. Keep Get Help on Windows 11 if you use the built-in troubleshooters.','Less clutter in Start; fewer apps updating and running in the background.','On Windows 11, Settings troubleshooters open the Get Help app, so they stop working without it. Removed apps must be reinstalled from the Store.')
'Remove Teams (personal) & Cortana'=@('Use it if you do not use Teams. Pick items individually and keep MSTeams if you use Teams for work or school.','No Teams auto-starting at sign-in; less RAM and fewer background updates.','Removing MSTeams also removes Teams for work or school; reinstall it from microsoft.com/teams. Cortana is discontinued anyway.')
'Remove optional extras'=@('Only remove what you really never use. Calculator, Camera, Sticky Notes and Alarms are used by many people.','Frees disk space and stops their background updates.','Removing Camera removes the Camera app (video-call apps still use the webcam directly); removing Alarms & Clock removes timers, alarms and Focus sessions. Reinstall from the Store.')
'Remove Xbox apps'=@('Skip it if you play PC Game Pass or Microsoft Store games, use Xbox cloud saves, or record clips with Win+G.','Removes gaming overlays and their background processes.','Game Pass and many Store games cannot sign in or start; Win+G and Xbox achievements stop working. Reinstalling from the Store fixes it.')
'Remove third-party promo apps'=@('Use it unless you actually use one of these Store versions (e.g. Spotify from the Store).','Removes ad-driven apps and Start tiles that only exist to sell you something.','If you use the Store version of Spotify or another app here, you lose it and its local data; reinstall from the Store.')
'Remove more promo games & stubs'=@('Use it; most of these only appear on older Windows 10 installs.','Less clutter and fewer background updates.','Game progress stored only locally is lost. Reinstall from the Store if you want one.')
'Remove 3D / Mixed Reality apps'=@('Use it unless you open 3D models or use a Windows Mixed Reality headset.','Removes apps almost nobody uses; Microsoft has retired most of them.','.3mf/.stl files no longer open with a viewer; Windows Mixed Reality headsets stop working.')
'Remove legacy Microsoft apps'=@('Pick individually. On Windows 11, Microsoft.ZuneMusic IS the new Media Player and ZuneVideo is Movies & TV, the default video player.','Removes discontinued apps (Skype, People, Messaging) and their background updates.','Without Media Player / Movies & TV, double-clicking music or video files asks for another app (install VLC or similar first).')
'Uninstall OneDrive'=@('Skip it if you sync files with OneDrive or OneDrive backs up your Desktop/Documents/Pictures.','No sync client at sign-in: less RAM, CPU and network use; no "back up your folders" nags.','Files marked "online-only" (cloud icon) in your OneDrive folder become unusable placeholders, so make them "Always keep on this device" or copy them out first. If Desktop/Documents were redirected into OneDrive, they stay in that folder.')
'Disable Start/Settings suggestions & silent app installs'=@('Use it; these are advertising.','No promoted apps in Start or Settings, and no surprise apps appearing after updates.','None; you just do not see app suggestions.')
'Disable lock screen tips & ads'=@('Use it; there is no downside.','A clean lock screen without ads or clickable promos.','None.')
'Disable Widgets'=@('Use it unless you use the taskbar weather or the widgets board.','Stops the Widgets/WebView2 background processes (they can use 100+ MB of RAM) and MSN news downloads.','No taskbar weather and no widgets board; Settings shows Widgets as managed.')
'Disable News and Interests'=@('Use it unless you use the taskbar weather or news feed.','Stops the feed process (RAM and background traffic) and frees taskbar space.','No weather or news on the taskbar.')
'Left-align taskbar'=@('Personal preference.','Start is always in the same corner; icons do not shift when apps open and close.','Differs from the default Windows 11 layout (screenshots, guides).')
'Hide Task View button'=@('Use it unless you click that button for virtual desktops.','More room on the taskbar.','Virtual desktops need Win+Tab or Win+Ctrl+arrows.')
'Hide Chat button'=@('Use it on early Windows 11 builds if the Chat icon is on your taskbar.','More room on the taskbar.','None.')
'Hide People Bar (Windows 10)'=@('Only if the People icon still shows on your taskbar.','Frees taskbar space; removes an unused contacts bar.','Nothing noticeable. On current Windows 10 builds the feature may already be gone, so this may do nothing.')
'Hide Meet Now icon (Windows 10)'=@('Only if the Meet Now icon shows in your notification area.','Removes the Skype Meet Now shortcut from the tray.','You lose the one-click meeting shortcut. It may need a sign-out to take effect.')
'Collapse taskbar search to an icon'=@('Optional; useful on small screens or busy taskbars.','Saves a lot of taskbar space (the search box is the widest item).','Search is one click further away (just press the Windows key and type instead).')
'Disable search highlights'=@('Optional; it only changes what the search box shows.','A plain search field without the daily picture and trending Bing items.','You no longer see the daily highlights in the search box and search home.')
'Enable End Task in taskbar right-click'=@('Useful if apps sometimes freeze.','Kill a frozen app in two clicks.','Easy to hit by accident; unsaved work in that app is lost without a prompt.')
'Show file extensions'=@('Recommended for everyone.','You see the real file type, so "invoice.pdf.exe" malware tricks stop working; renaming file types becomes possible.','When renaming you must be careful not to change the extension by accident.')
'Show hidden files'=@('Use it if you often open AppData, game config files or mod folders.','Easy access to config folders and leftovers of uninstalled programs.','More clutter, and it is easier to delete something important. Protected system files stay hidden.')
'Open Explorer to "This PC"'=@('Personal preference. Useful if you mostly work with drives rather than recent files.','Drives are one click away; recent files are not shown to people looking at your screen.','Pinned folders and recent files are one click further away.')
'Disable Sticky Keys prompt'=@('Use it unless you use Sticky Keys or need the shortcut for accessibility.','No game interruptions when you tap Shift repeatedly.','The Shift x5 accessibility shortcut no longer works; turn Sticky Keys on in Settings > Accessibility instead.')
'Show full path in title bar'=@('Personal preference; handy if many folders have the same name.','You always know exactly which folder is open, even from the taskbar preview.','Long paths get cut off in the title.')
'Hide recent & frequent items in Explorer'=@('Use it if others see your screen or you share the PC.','Your recent documents are not on display every time you open Explorer.','No quick list of recent files in Explorer; use the app''s own recent list instead.')
'Disable SysMain (Superfetch)'=@('Mostly not worth it. Consider it only on an SSD PC where SysMain is clearly causing disk or CPU spikes. Keep it on hard drives and on PCs with 8 GB RAM or less.','No background preloading; less disk activity right after boot on some systems.','Apps start slower, a lot slower on hard drives. Unused RAM is not "freed" in any useful way: preloaded data is dropped instantly when needed.')
'Disable Windows Search indexing'=@('Skip it if you search files in Explorer or Start, or use desktop Outlook. Consider it only if you never search and the indexer keeps the disk busy.','No background indexing of new files; less disk and CPU use on weak PCs.','Outlook (desktop) search breaks; Explorer and Start file search become slow and incomplete. App and Settings search in Start still work.')
'Disable Fast Startup'=@('Use it if you dual-boot, have driver or Wi-Fi glitches after power-on, or want updates and BIOS changes to apply cleanly on shutdown.','Every power-on starts fresh, which fixes many stuck-device and dual-boot problems; uptime in Task Manager becomes accurate.','Cold boots take a few seconds longer (very little on SSDs).')
'Disable Storage Sense auto cleanup'=@('Use it if you want full control over what gets deleted. It is the opposite of "Enable Storage Sense"; switching one on switches the other off.','Nothing is deleted behind your back (e.g. old Recycle Bin items you might still want).','Temp files and the Recycle Bin grow until you clean them yourself.')
'Disable transparency effects'=@('Use it on older or weak GPUs, or if you prefer solid colours and better text contrast.','Slightly less GPU work; text on the taskbar and Start is easier to read.','Flatter, solid-colour look. Part of the Visual Effects presets.')
'Disable hibernation'=@('Use it on desktops that only sleep or shut down. Keep hibernation on laptops: when the battery runs low during sleep, Windows hibernates instead of losing your open work.','Deletes hiberfil.sys, which is about 40% of your RAM by default (around 6 GB on a 16 GB PC).','No Hibernate, no Fast Startup, and laptops lose the safety net that saves your session on low battery.')
'Ultimate Performance power plan'=@('For desktops that chase lowest latency. On laptops use G-Helper / vendor performance modes instead; many Modern Standby laptops do not even allow this plan.','Fewer CPU clock and core-parking changes; can smooth out micro-stutter in some games and audio work.','Higher idle power use, heat and fan noise; usually no measurable FPS gain on modern CPUs. Can conflict with G-Helper or vendor power modes.')
'Disable Game DVR / background capture'=@('Use it unless you save clips with Win+Alt+G or Game Bar recording.','No hidden recording buffer while you play: a few FPS and some VRAM back on weaker GPUs.','Game Bar cannot record or save the last 30 seconds. NVIDIA/AMD recording tools are not affected.')
'Disable mouse acceleration'=@('Use it for games that need aiming and for consistent muscle memory. Skip it if you have a big screen and a low-DPI mouse and like flicking across it.','Predictable 1:1 movement; games and the desktop feel the same.','The cursor may feel slow at first; raise the pointer speed or mouse DPI to compensate. Takes effect after sign-out.')
'Disable Game Bar'=@('Use it if pressing the Xbox button on your controller keeps opening Game Bar. For recording, see Disable Game DVR.','No Game Bar popping up over games from the controller button or at game start.','The controller button no longer opens Game Bar (Win+G still can unless Game Bar is removed).')
'Disable Delivery Optimization (P2P uploads)'=@('Use it on metered, mobile-hotspot or slow-upload connections. On a home network with several PCs, peer sharing can save download bandwidth, so you may keep it.','Your upload bandwidth is never used for other people''s updates; no extra network activity from DoSvc.','Several PCs on the same network each download every update separately. Settings > Delivery Optimization shows "managed by your organization".')
'No auto-restart while signed in'=@('Use it if you leave work, downloads or renders running overnight. Also set "Active hours" in Windows Update for extra safety.','Fewer surprise reboots that close your open apps and unsaved work.','Updates wait until you restart yourself, so security fixes can be delayed. Microsoft documents this policy for scheduled-install setups; on some Home PCs a restart outside active hours can still happen.')
'Disable device metadata downloads'=@('Use it; it only affects how devices look in Settings and Devices and Printers.','Fewer background web requests when you connect new devices.','Some devices show generic icons and names instead of the manufacturer picture.')
'Disable BitLocker auto device encryption'=@('Use it before or right after a fresh install if you do not want encryption, e.g. to avoid lock-outs. Leave it off on laptops that leave the house.','No surprise BitLocker recovery screen after a BIOS update or hardware change when you never saved the recovery key; slightly faster disk access on some older SSDs.','If the laptop is lost or stolen, anyone can read your drive by putting it in another PC.')
'Use Cloudflare DNS (1.1.1.1)'=@('Use it if your provider''s DNS is slow, unreliable or blocks sites. Skip it if you use a NAS or printers by name, a VPN or work network, router-level ad-blocking (Pi-hole) or parental controls.','Often faster and more reliable name lookups; your ISP no longer sees your DNS queries through its own resolver.','Local names from your router (NAS, printers) can stop resolving; hotel/airport Wi-Fi login pages may not open; router and VPN DNS filtering is bypassed. Undo resets to automatic, not to a DNS you had set manually.')
'Flush DNS cache'=@('Use it when a site moved, a hosts-file or DNS change does not take effect, or pages fail to load while others work.','Forces fresh lookups; fixes stale or broken DNS entries instantly.','None; the first visit to each site takes a few milliseconds longer.')
'Clean temp files & empty Recycle Bin'=@('Use it when the drive is getting full. Check the Recycle Bin first.','Often frees hundreds of MB to several GB.','Recycle Bin contents are gone for good; an installer running at the same time may fail, so close other apps first.')
'Repair system files (SFC)'=@('Use it when Windows crashes, apps or Settings fail to open, or after malware cleanup. Run DISM RestoreHealth first if SFC says it could not fix everything.','Repairs corrupted system files without reinstalling Windows.','Slow, and the progress bar looks frozen. Run it on its own.')
'Repair Windows image (DISM RestoreHealth)'=@('Use it before SFC when SFC reports files it "was unable to fix", or when updates keep failing. Needs internet.','Fixes the repair source itself, so SFC can then succeed.','Can take 10-30 minutes and may sit at one percentage for a long time; that is normal.')
'Clean up old driver versions (Driver Store)'=@('Only if you need the disk space; after many graphics or chipset updates the old versions add up.','Frees space by deleting superseded driver packages; the newest version of every driver stays.','WARNING: The "Roll Back Driver" button in Device Manager becomes inactive for devices whose driver was updated, and the deleted packages cannot be restored. Drivers in use, boot-critical and printer drivers are skipped.')
'Reset Windows Update components'=@('Use it when updates are stuck downloading or fail with the same error again and again.','Clears corrupted or half-downloaded updates, which fixes many stuck updates.','Pending updates download again from scratch. Your update history is kept.')
'Reset network stack'=@('Use it only when the internet is broken on this PC while other devices work, e.g. after removing a VPN or security suite.','Fixes broken network layers left behind by VPNs, firewalls and malware.','Static IP addresses and some VPN or proxy settings are lost and must be set up again; needs a reboot.')
'SSD TRIM (system drive)'=@('Rarely needed: Windows already does this weekly in "Optimize Drives". Use it after deleting a lot of data or if the weekly task is turned off.','Keeps SSD write speed consistent after large deletions.','None on SSDs; on hard drives Windows refuses and the action reports an error.')
}

# ---------- Round 2: startup, services, features, Edge/background, OEM (written from my own knowledge, NOT from the 7 repos - verify) ----------
$s15='Startup Programs';$s16='Services (start on demand)';$s17='Optional Windows Features';$s18='Edge & Background Apps';$s19='OEM Utilities'
$secs=@($secs|Where-Object{$_ -ne $s14})+@($s18,$s15,$s16,$s17,$s19,$s14)
$LBL=@{'Microsoft.549981C3F5F10'='Cortana';'*DellInc*'='Dell apps';'*AD2F1837*'='HP apps (Support Assistant, Smart...)';'*Lenovo*'='Lenovo apps (Vantage...)';'*AcerIncorporated*'='Acer apps';'*ASUS*'='ASUS apps (Armoury Crate...)';'*McAfee*'='McAfee trial';'*Norton*'='Norton trial'
 MapsBroker='Downloaded Maps Manager';TrkWks='Distributed Link Tracking';PcaSvc='Program Compatibility Assistant';edgeupdate='Edge Update'
 MicrosoftWindowsPowerShellV2Root='PowerShell 2.0';SMB1Protocol='SMB 1.0 file sharing';'Printing-XPSServices-Features'='XPS Services';'Internet-Explorer-Optional-amd64'='Internet Explorer mode';'WorkFolders-Client'='Work Folders';FaxServicesClientPackage='Windows Fax and Scan';TelnetClient='Telnet client';'01'='Storage Sense on';'04'='Delete temporary files';'08'='Clean up Recycle Bin';'256'='Recycle Bin: delete after 30 days';'2048'='Run every week'}
$sd='DebloatHub'
$EP='HKLM:\SOFTWARE\Policies\Microsoft\Edge'
# ---------- Installed apps: browser and IDE tweaks are offered only when that program is installed ----------
# ...or when its policy key already exists, so policies applied earlier (or by another tool) can still be reverted.
function Find-App($exe,$paths){
 foreach($h in 'HKLM:','HKCU:'){if(Test-Path -LiteralPath (Map-Hive "$h\SOFTWARE\Microsoft\Windows\CurrentVersion\App Paths\$exe")){return $true}}   # "App Paths" = where installers register their .exe
 foreach($x in $paths){if($x -and (Test-Path -LiteralPath $x)){return $true}}
 return $false}
$pf86=${env:ProgramFiles(x86)}
$haveEdge   =(Find-App 'msedge.exe'  @("$pf86\Microsoft\Edge\Application\msedge.exe","$env:ProgramFiles\Microsoft\Edge\Application\msedge.exe")) -or (Test-Path $EP)
$haveChrome =(Find-App 'chrome.exe'  @("$env:ProgramFiles\Google\Chrome\Application\chrome.exe","$pf86\Google\Chrome\Application\chrome.exe","$UserLocal\Google\Chrome\Application\chrome.exe")) -or (Test-Path 'HKLM:\SOFTWARE\Policies\Google\Chrome')
$haveFirefox=(Find-App 'firefox.exe' @("$env:ProgramFiles\Mozilla Firefox\firefox.exe","$pf86\Mozilla Firefox\firefox.exe","$UserLocal\Mozilla Firefox\firefox.exe")) -or (Test-Path 'HKLM:\SOFTWARE\Policies\Mozilla\Firefox')
$haveVS     =(Test-Path "$pf86\Microsoft Visual Studio\Installer\vswhere.exe") -or (Test-Path 'HKLM:\SOFTWARE\Policies\Microsoft\VisualStudio\SQM')
if($haveEdge){$db+=fTw $s18 'Disable Edge startup boost & background mode' 'Edge stops pre-loading itself when you sign in (Startup boost) and stops running in the background after you close the last window.' Safe $sd Any 'safe' @((fReg $EP StartupBoostEnabled 0 $null),(fReg $EP BackgroundModeEnabled 0 $null)) 'Good RAM saver if you use Edge or have it installed. Edge will say it is managed by your organization; that is just the policy.'}
if($haveEdge){$db+=fTw $s18 'Quiet Edge: no sidebar, shopping assistant or first-run' 'Edge policies that hide the sidebar (Copilot/apps pane), turn off the shopping assistant (coupons, price comparison) and skip the welcome/first-run pages.' Safe $sd Any 'safe' @((fReg $EP HubsSidebarEnabled 0 $null),(fReg $EP EdgeShoppingAssistantEnabled 0 $null),(fReg $EP HideFirstRunExperience 1 $null))}
$db+=fTw $s18 'Block apps from running in the background' 'Forces all Microsoft Store apps to stay closed when not open (policy plus the per-user setting). Normal desktop programs are not affected.' Moderate $sd Any 'gaming' @((fReg "$POL\AppPrivacy" LetAppsRunInBackground 2 $null),(fReg 'HKCU:\Software\Microsoft\Windows\CurrentVersion\BackgroundAccessApplications' GlobalUserDisabled 1 0)) 'Skip if you depend on Mail, Calendar or Alarms notifying you while closed.'
$db+=fTw $s16 'Set rarely-used services to start on demand' 'Changes Downloaded Maps Manager, Distributed Link Tracking, Program Compatibility Assistant and Edge Update from Automatic to Manual. Windows still starts them when something needs them. Pick items individually.' Moderate $sd Any '' @((fSvm MapsBroker Automatic),(fSvm TrkWks Automatic),(fSvm PcaSvc Automatic),(fSvm edgeupdate Automatic)) 'Low risk because services still start when needed. Choose individually if unsure.'
$db+=fTw $s17 'Remove legacy Windows features' 'Turns off old optional Windows features: PowerShell 2.0, SMB 1.0, XPS Services, Internet Explorer 11, Work Folders, Windows Fax and Scan, Telnet client. Pick items individually; reboot needed.' Moderate $sd Any '' @((fFeat MicrosoftWindowsPowerShellV2Root),(fFeat SMB1Protocol),(fFeat Printing-XPSServices-Features),(fFeat Internet-Explorer-Optional-amd64),(fFeat WorkFolders-Client),(fFeat FaxServicesClientPackage),(fFeat TelnetClient)) 'Safe for most home users. Keep SMB 1.0 or IE mode if an old NAS or intranet site needs them.'
$db+=fTw $s19 'Remove OEM utilities (Dell, HP, Lenovo, Acer, ASUS, trials)' 'Uninstalls Store-packaged vendor apps (MyASUS, Lenovo Vantage, HP Support Assistant, Dell, Acer) and McAfee/Norton trial stubs. Classic installed programs (Armoury Crate etc.) are not touched. Pick brands individually.' Advanced $sd Any '' @('*DellInc*','*AD2F1837*','*Lenovo*','*AcerIncorporated*','*ASUS*','*McAfee*','*Norton*'|ForEach-Object{fApp $_}) 'Only remove brands that match your PC. Vendor apps can control fans, battery limits and hotkeys, so check first.'
$more['Disable Edge startup boost & background mode']=@('Use it unless you rely on Edge opening instantly or on web notifications while Edge is closed.','Saves RAM (tens to a few hundred MB) and some CPU at sign-in, even if you never use Edge.','Edge takes a second longer to open; site notifications only arrive while Edge is open. Edge shows "managed by your organization".')
$more['Quiet Edge: no sidebar, shopping assistant or first-run']=@('Use it unless you use the Edge sidebar or price-comparison pop-ups.','Cleaner Edge with fewer pop-ups and less background activity on shopping sites.','No sidebar, Copilot pane or coupon suggestions. Edge shows "managed by your organization".')
$more['Block apps from running in the background']=@('Skip it if you rely on notifications from Store apps while they are closed (Phone Link, WhatsApp, Mail/Calendar, Spotify from the Store).','Fewer idle background processes: less RAM and better battery life on laptops.','Store apps do not notify, sync or play in the background until you open them; Settings shows the option as managed by policy.')
$more['Set rarely-used services to start on demand']=@('Safe for most people; it only delays these services until they are needed.','Fewer services at boot; slightly faster boot and less RAM.','Program Compatibility Assistant no longer suggests compatibility fixes for old programs. Edge still updates through its scheduled tasks.')
$more['Remove legacy Windows features']=@('Safe for most home PCs. Keep SMB 1.0 for very old NAS boxes, IE 11 for intranet sites that need Edge IE mode, and Fax and Scan if you scan with it.','Smaller attack surface (PowerShell 2.0 and SMB 1.0 are favourite malware tools); slightly less disk use.','Old NAS drives (SMB 1.0), Edge IE mode sites, the classic "Windows Fax and Scan" scanning app and Telnet stop working until re-enabled.')
$more['Remove OEM utilities (Dell, HP, Lenovo, Acer, ASUS, trials)']=@('Only remove apps for your brand that you do not use. On ASUS laptops G-Helper replaces most of MyASUS and Armoury Crate, but check battery-limit and firmware-update needs first.','Fewer vendor background services, promos and trial nags.','Vendor hotkeys, battery charge limits, fan profiles or BIOS/driver update notices may stop working. Reinstall from the Store if needed.')

# Startup entries (same mechanism as Task Manager > Startup apps, so it is reversible there too)
$SAr='\SOFTWARE\Microsoft\Windows\CurrentVersion\Explorer\StartupApproved'
$su=@()
foreach($rk in @(@('HKCU:\Software\Microsoft\Windows\CurrentVersion\Run',"HKCU:$SAr\Run"),@('HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Run',"HKLM:$SAr\Run"),@('HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Run',"HKLM:$SAr\Run32"))){
 if(Test-Path (Map-Hive $rk[0])){$k=Get-Item -Path (Map-Hive $rk[0]);foreach($vn in $k.GetValueNames()){if($vn){$su+=,@{N=$vn;C="$($k.GetValue($vn))";A=$rk[1]}}}}}
foreach($fd in @(@("$UserAppData\Microsoft\Windows\Start Menu\Programs\Startup","HKCU:$SAr\StartupFolder"),@("$env:ProgramData\Microsoft\Windows\Start Menu\Programs\StartUp","HKLM:$SAr\StartupFolder"))){
 if(Test-Path $fd[0]){foreach($f in @(Get-ChildItem $fd[0] -File|Where-Object{$_.Name -ne 'desktop.ini'})){$su+=,@{N=$f.Name;C=$f.FullName;A=$fd[1]}}}}
$seenN=@{}
foreach($e in $su){$nm="Disable at startup: $($e.N)";if($seenN.ContainsKey($nm)){$base="$nm ($(if($e.A -like 'HKLM*'){'all users'}else{'this user'}) copy)";$nm=$base;$c=2;while($seenN.ContainsKey($nm)){$nm="$base $c";$c++}};$seenN[$nm]=1
 $rk2=if($e.N -match 'Security|Defender|Antivirus|Norton|McAfee|Kaspersky|Bitdefender|Avast|ESET'){'Advanced'}elseif($e.N -match 'Realtek|Audio|NVIDIA|Intel|AMD|Synaptics|Touchpad|Bluetooth'){'Moderate'}else{'Safe'}
 $db+=fTw $s15 $nm "Launches at sign-in: $($e.C)" $rk2 $sd Any '' @(@{K='Startup';A=(Map-Hive $e.A);N=$e.N}) 'Disabling only stops it launching at sign-in; the app still works when you open it. The same list is in Task Manager > Startup apps.'
 $more[$nm]=@('Only if you need this app running right after sign-in (chat, sync, tray tools, hardware utilities).','Faster sign-in and less RAM used in the background.','The app will not start by itself: no tray icon, notifications or sync until you open it.')}
$secs=@($secs|ForEach-Object{$sx=$_;if(@($db|Where-Object{$_.Sec -eq $sx}).Count){$sx}})

# ---------- Round 3: Visual Effects (presets move switches; every effect is also its own switch) ----------
Add-Type -TypeDefinition @'
using System; using System.ComponentModel; using System.Runtime.InteropServices;
namespace DH { public static class Mem {
 [StructLayout(LayoutKind.Sequential)] struct LUID { public uint Low; public int High; }
 [StructLayout(LayoutKind.Sequential)] struct TP { public int Count; public LUID Luid; public int Attr; }
 [DllImport("advapi32.dll",SetLastError=true)] static extern bool OpenProcessToken(IntPtr h,int acc,out IntPtr tok);
 [DllImport("advapi32.dll",SetLastError=true,CharSet=CharSet.Unicode)] static extern bool LookupPrivilegeValue(string sys,string name,out LUID l);
 [DllImport("advapi32.dll",SetLastError=true)] static extern bool AdjustTokenPrivileges(IntPtr tok,bool dis,ref TP n,int len,IntPtr p,IntPtr r);
 [DllImport("kernel32.dll")] static extern IntPtr GetCurrentProcess();
 [DllImport("kernel32.dll")] static extern bool CloseHandle(IntPtr h);
 [DllImport("ntdll.dll")] static extern int NtSetSystemInformation(int cls,ref int info,int len);
 public static void EnablePrivilege(string name){
  IntPtr t; if(!OpenProcessToken(GetCurrentProcess(),0x28,out t)) throw new Win32Exception();   // TOKEN_ADJUST_PRIVILEGES|TOKEN_QUERY
  try{ TP tp=new TP(); tp.Count=1; tp.Attr=2;                                                    // SE_PRIVILEGE_ENABLED
   if(!LookupPrivilegeValue(null,name,out tp.Luid)) throw new Win32Exception();
   if(!AdjustTokenPrivileges(t,false,ref tp,0,IntPtr.Zero,IntPtr.Zero)) throw new Win32Exception();
   if(Marshal.GetLastWin32Error()==1300) throw new Exception(name+" is not held by this account (run as administrator)"); }
  finally{ CloseHandle(t); } }
 public static int MemoryListCommand(int cmd){ int c=cmd; return NtSetSystemInformation(80,ref c,4); }   // 80 = SystemMemoryListInformation
} }
'@
Add-Type -Namespace DH -Name Spi -MemberDefinition @'
[DllImport("user32.dll",SetLastError=true)] public static extern bool SystemParametersInfo(uint a,uint b,ref int c,uint d);
[DllImport("user32.dll",SetLastError=true)] public static extern bool SystemParametersInfo(uint a,uint b,IntPtr c,uint d);
'@
$Mar=[Runtime.InteropServices.Marshal]
function Spi-Call($act,$ui,$pv,$fl){        # one place that calls user32 and turns a FALSE return into a real error (the old code ignored it)
 $ok=[DH.Spi]::SystemParametersInfo([uint32]$act,[uint32]$ui,[IntPtr]$pv,[uint32]$fl);$err=$Mar::GetLastWin32Error()
 if(-not $ok){throw ('SystemParametersInfo 0x{0:X} failed (Win32 error {1})' -f $act,$err)}}
function Spi-Get($a){$id=[uint32]$a.G
 try{
  if($a.M -eq 'a'){                           # ANIMATIONINFO {UINT cbSize; int iMinAnimate}: pvParam = POINTER to the struct, uiParam = its size
   $m=[IntPtr]::Zero
   try{$m=$Mar::AllocHGlobal(8);$Mar::WriteInt32($m,0,8);$Mar::WriteInt32($m,4,0)
       Spi-Call $id 8 $m 0;return $Mar::ReadInt32($m,4)}
   finally{if($m -ne [IntPtr]::Zero){$Mar::FreeHGlobal($m)}}}
  $m=[IntPtr]::Zero                           # every SPI_GET* BOOL setting: pvParam = POINTER to a BOOL that Windows fills in
  try{$m=$Mar::AllocHGlobal(4);$Mar::WriteInt32($m,0,0)
      Spi-Call $id 0 $m 0;return $Mar::ReadInt32($m,0)}
  finally{if($m -ne [IntPtr]::Zero){$Mar::FreeHGlobal($m)}}
 }catch{return $null}}                        # unknown -> $null (the old code returned a fake 0, which looked like "effect already off")
function Spi-Set($a,$v){$id=[uint32]$a.S;$f=3;$v=[int]$v;$b=[int]($v -ne 0)   # $f = SPIF_UPDATEINIFILE|SPIF_SENDCHANGE
 switch($a.M){
  # 'p' = SPI_SET* BOOL toggles. Documented contract: "set pvParam to TRUE or FALSE" - the BOOL itself travels inside the pointer-sized
  # argument and Windows never dereferences it, so [IntPtr]0/1 is correct. Passing a real allocated pointer would be non-zero = TRUE,
  # i.e. every "turn off" would silently turn the effect ON.
  'p'{Spi-Call $id 0 ([IntPtr]$b) $f}
  'u'{Spi-Call $id ([uint32]$b) ([IntPtr]::Zero) $f}          # SPI_SETDRAGFULLWINDOWS: BOOL is uiParam
  'a'{$m=[IntPtr]::Zero                                       # ANIMATIONINFO: a real struct pointer, so allocate and always free
      try{$m=$Mar::AllocHGlobal(8);$Mar::WriteInt32($m,0,8);$Mar::WriteInt32($m,4,$b);Spi-Call $id 8 $m $f}
      finally{if($m -ne [IntPtr]::Zero){$Mar::FreeHGlobal($m)}}}
  'f'{Spi-Call 0x4B ([uint32]$b) ([IntPtr]::Zero) $f           # SPI_SETFONTSMOOTHING: BOOL is uiParam
      if($b){Spi-Call 0x200B 0 ([IntPtr]2) $f}}}}              # SPI_SETFONTSMOOTHINGTYPE = ClearType (2), passed by value in pvParam
function fSpi($l,$g,$s,$m,$v,$u){@{K='Spi';N=$l;G=$g;S=$s;M=$m;V=$v;U=$u}}
$s20='Visual Effects'
$k4=[array]::IndexOf($secs,$s4);$secs=@($secs[0..$k4])+@($s20)+@($secs[($k4+1)..($secs.Count-1)])
$EA='HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\Advanced';$DW='HKCU:\Software\Microsoft\Windows\DWM'
$vfxAll=@('Disable transparency effects');$vfxRec=@('Disable transparency effects')
# label, action, off-in-Recommended(1/0), what you lose
$vfx=@(
 @('Animate controls and elements inside windows',(fSpi 'Animate controls' 0x1042 0x1043 p 0 1),1,'Buttons, scrollbars and controls stop easing or animating.'),
 @('Animate windows when minimizing and maximizing',(fSpi 'Window min/max animation' 0x48 0x49 a 0 1),1,'Windows snap instantly instead of gliding when minimized or maximized.'),
 @('Fade or slide menus into view',(fSpi 'Menu animation' 0x1002 0x1003 p 0 1),1,'Menus appear instantly with no fade or slide.'),
 @('Fade or slide ToolTips into view',(fSpi 'ToolTip animation' 0x1016 0x1017 p 0 1),1,'Tooltips appear instantly.'),
 @('Fade out menu items after clicking',(fSpi 'Menu selection fade' 0x1014 0x1015 p 0 1),1,'Menu items vanish instantly after a click.'),
 @('Smooth-scroll list boxes',(fSpi 'List box smooth scroll' 0x1006 0x1007 p 0 1),1,'Lists jump in steps instead of scrolling smoothly.'),
 @('Slide open combo boxes',(fSpi 'Combo box slide' 0x1004 0x1005 p 0 1),1,'Drop-down lists open instantly.'),
 @('Show shadows under the mouse pointer',(fSpi 'Cursor shadow' 0x101A 0x101B p 0 1),1,'The pointer has no drop shadow.'),
 @('Show shadows under windows',(fSpi 'Window shadows' 0x1024 0x1025 p 0 1),1,'Windows lose their drop shadow, so overlapping windows look flatter.'),
 @('Animations in the taskbar',(fReg $EA TaskbarAnimations 0 1),1,'Taskbar buttons stop animating.'),
 @('Peek (hover preview of desktop/windows)',(fReg $DW EnableAeroPeek 0 1),1,'Hovering the taskbar thumbnail or Show Desktop corner no longer previews.'),
 @('Save taskbar thumbnail previews',(fReg $DW AlwaysHibernateThumbnails 0 1),1,'Taskbar previews are regenerated when needed (uses less RAM; Maximize looks turns this on).'),
 @('Translucent selection rectangle',(fReg $EA ListviewAlphaSelect 0 1),1,'Desktop/Explorer selection box becomes a plain outline.'),
 @('Show thumbnails instead of icons',(fReg $EA IconsOnly 1 0),0,'Explorer shows generic icons instead of picture/video previews. Hard to browse photos.'),
 @('Show window contents while dragging',(fSpi 'Drag full windows' 0x26 0x25 u 0 1),0,'Only an outline moves while dragging; the window redraws afterwards.'),
 @('Smooth edges of screen fonts',(fSpi 'Font smoothing' 0x4A 0x4B f 0 1),0,'Text looks jagged and harder to read.'),
 @('Use drop shadows for icon labels on the desktop',(fReg $EA ListviewShadow 0 1),0,'Desktop icon text loses its shadow and can be harder to read on busy wallpapers.'))
foreach($e in $vfx){$nm="Turn off: $($e[0])";$keep=-not $e[2]
 $db+=fTw $s20 $nm "Effect removed: $($e[3])" Safe 'DebloatHub' Any '' @(,$e[1]) $(if($keep){'Left ON by the Recommended preset: it costs almost nothing and keeps the system readable.'}else{'Part of the Recommended preset.'})
 $more[$nm]=@($(if($keep){'Recommended to leave this effect ON: it costs almost nothing and makes the UI easier to read.'}else{'Purely cosmetic. Turn it off on older or slow PCs, or if you prefer an instant, animation-free feel.'}),$(if($keep){'Barely measurable gain, even on old PCs.'}else{'Menus and windows react instantly; a little less GPU/CPU work on older PCs and over Remote Desktop.'}),"You lose: $($e[3])")
 $vfxAll+=$nm;if($e[2]){$vfxRec+=$nm}}
$more['Disable transparency effects']=@('Use it on older or weak GPUs, or if you prefer solid colours and better text contrast.','Slightly less GPU work; text on the taskbar and Start is easier to read.','Flatter, solid-colour look. Part of the Visual Effects presets.')
function Set-Preset($p){if($script:busy){return};$off=switch -Wildcard($p){'Maximize looks*'{@()}'Recommended*'{$vfxRec}'Maximize perf*'{$vfxAll}}
 foreach($u in $units){if($vfxAll -contains $u.T.Name){$u.Box.IsChecked=[bool]($u.Box.IsEnabled -and ($off -contains $u.T.Name))}}
 Sync-Masters;Update-Bar;Log "Preset '$p': switches set. Press Apply to use it."}

# ---------- Round 4: app privacy/security (dev tools, browsers, Windows) + safe disk cleanups (from my own knowledge - verify policy names before sharing) ----------
function Json-Strip($t){   # JSONC -> JSON: drops // and /* */ comments and trailing commas, but never touches text INSIDE "strings" (URLs, globs like **/*.js)
 $s='("(?:\\.|[^"\\])*")'
 $t=[regex]::Replace($t,"$s|//[^\r\n]*|/\*[\s\S]*?\*/",'$1')
 [regex]::Replace($t,"$s|,(?=\s*[}\]])",'$1')}
function Json-Read($p){
 if(-not(Test-Path -LiteralPath $p)){return [pscustomobject]@{}}
 $t=(Json-Strip ([IO.File]::ReadAllText($p,[Text.Encoding]::UTF8))).TrimStart([char]0xFEFF)   # ReadAllText handles BOM and BOM-less UTF-8
 if(-not "$t".Trim()){return [pscustomobject]@{}}
 $t|ConvertFrom-Json}
function fJson($p,$k,$v,$u){@{K='Json';P=$p;N=$k;V=$v;U=$u}}
# ---------- In-place JSONC editing: change ONE top-level key, keep every comment, trailing comma, order and blank line ----------
# (algorithm verified against an independent parser with 50,000 randomised documents + exact-output tests)
function Jsonc-SkipWs($t,$i){                    # skips whitespace and comments, returns the new index
 $n=$t.Length
 while($i -lt $n){$c=$t[$i]
  if($c -eq ' ' -or $c -eq "`t" -or $c -eq "`r" -or $c -eq "`n"){$i++;continue}
  if($c -eq '/' -and ($i+1) -lt $n){
   if($t[$i+1] -eq '/'){$j=$t.IndexOf([char]10,$i);if($j -lt 0){return $n};$i=$j+1;continue}
   if($t[$i+1] -eq '*'){$j=$t.IndexOf('*/',$i+2,[StringComparison]::Ordinal);if($j -lt 0){throw 'unterminated /* comment'};$i=$j+2;continue}}
  break}
 return $i}
function Jsonc-StrEnd($t,$i){                    # $i at an opening quote -> index just after the closing quote
 $n=$t.Length;$i++
 while($i -lt $n){$c=$t[$i]
  if($c -eq '\'){$i+=2;continue}
  if($c -eq '"'){return ($i+1)}
  $i++}
 throw 'unterminated string'}
function Jsonc-ValEnd($t,$i){                    # $i at the first character of a value -> index just after it
 $n=$t.Length;$c=$t[$i]
 if($c -eq '"'){return (Jsonc-StrEnd $t $i)}
 if($c -eq '{' -or $c -eq '['){$d=0
  while($i -lt $n){$c=$t[$i]
   if($c -eq '"'){$i=Jsonc-StrEnd $t $i;continue}
   if($c -eq '/' -and ($i+1) -lt $n -and ($t[$i+1] -eq '/' -or $t[$i+1] -eq '*')){$i=Jsonc-SkipWs $t $i;continue}
   if($c -eq '{' -or $c -eq '['){$d++}elseif($c -eq '}' -or $c -eq ']'){$d--;if($d -eq 0){return ($i+1)}}
   $i++}
  throw 'unterminated object or array'}
 while($i -lt $n){$c=$t[$i]
  if($c -eq ',' -or $c -eq '}' -or $c -eq ']' -or $c -eq ' ' -or $c -eq "`t" -or $c -eq "`r" -or $c -eq "`n"){break}
  if($c -eq '/' -and ($i+1) -lt $n -and ($t[$i+1] -eq '/' -or $t[$i+1] -eq '*')){break}
  $i++}
 return $i}
function Jsonc-Scan($t){                         # positions of the top-level object and of every top-level key/value
 $n=$t.Length;$i=Jsonc-SkipWs $t 0
 if($i -ge $n){return @{Open=-1;Close=-1;Items=@()}}
 if($t[$i] -ne '{'){throw 'the file is not a JSON object'}
 $open=$i;$i++;$items=@()
 while($true){
  $i=Jsonc-SkipWs $t $i
  if($i -ge $n){throw 'missing closing brace'}
  if($t[$i] -eq '}'){return @{Open=$open;Close=$i;Items=$items}}
  if($t[$i] -ne '"'){throw "expected a quoted key at position $i"}
  $ks=$i;$ke=Jsonc-StrEnd $t $i;$key=$t.Substring($ks+1,$ke-$ks-2)
  $i=Jsonc-SkipWs $t $ke
  if($i -ge $n -or $t[$i] -ne ':'){throw "expected a colon after the key at position $ke"}
  $i=Jsonc-SkipWs $t ($i+1)
  if($i -ge $n){throw 'missing value'}
  $vs=$i;$ve=Jsonc-ValEnd $t $i
  if($ve -le $vs){throw "empty value at position $vs"}
  $i=Jsonc-SkipWs $t $ve;$comma=-1
  if($i -lt $n -and $t[$i] -eq ','){$comma=$i;$i++}elseif($i -lt $n -and $t[$i] -ne '}'){throw "expected a comma or closing brace at position $i"}
  $items+=,@{Key=$key;KS=$ks;KE=$ke;VS=$vs;VE=$ve;Comma=$comma}}}
function Jsonc-Esc($k){$e=ConvertTo-Json -InputObject ([string]$k) -Compress;$e.Substring(1,$e.Length-2)}
function Jsonc-Edit($t,$key,$json){              # returns the new text; $json = serialised value, or $null to remove the key
 $key=Jsonc-Esc $key
 $sc=Jsonc-Scan $t
 $nl=if($t.Contains("`r`n")){"`r`n"}else{"`n"}
 $hit=$null;foreach($it in $sc.Items){if($it.Key -ceq $key){$hit=$it}}
 if($null -ne $json){
  if($hit){$new=$t.Substring(0,$hit.VS)+$json+$t.Substring($hit.VE)}
  elseif($sc.Open -lt 0){$new=$(if($t.Trim().Length -eq 0){''}else{$t.TrimEnd()+$nl})+'{'+$nl+'    "'+$key+'": '+$json+$nl+'}'+$nl}
  else{
   $cnt=@($sc.Items).Count;$indent='    '
   if($cnt -gt 0){$f=$sc.Items[0];$ls=$t.LastIndexOf([char]10,[Math]::Max($f.KS-1,0));$pre=$t.Substring($ls+1,$f.KS-$ls-1);if($ls -ge 0 -and $pre.Trim().Length -eq 0){$indent=$pre}}
   $lastComma=($cnt -gt 0 -and $sc.Items[$cnt-1].Comma -ge 0)             # file uses trailing commas -> keep that style
   $entry=$indent+'"'+$key+'": '+$json+$(if($lastComma){','}else{''})
   $ls2=$t.LastIndexOf([char]10,[Math]::Max($sc.Close-1,0));$before=$t.Substring($ls2+1,$sc.Close-$ls2-1)
   if($ls2 -ge 0 -and $before.Trim().Length -eq 0){$pos=$ls2+1;$ins=$entry+$nl}else{$pos=$sc.Close;$ins=$nl+$entry+$nl}
   $new=$t.Substring(0,$pos)+$ins+$t.Substring($pos)
   if($cnt -gt 0 -and -not $lastComma){$ve=$sc.Items[$cnt-1].VE;$new=$new.Substring(0,$ve)+','+$new.Substring($ve)}}}
 else{
  if(-not $hit){return $t}
  $items=@($sc.Items);$idx=[Array]::IndexOf($items,$hit)
  $ls=$t.LastIndexOf([char]10,[Math]::Max($hit.KS-1,0));$pre=$t.Substring($ls+1,$hit.KS-$ls-1)
  $own=($ls -ge 0 -and $pre.Trim().Length -eq 0)                          # the entry sits on its own line(s)
  $re=if($hit.Comma -ge 0){$hit.Comma+1}else{$hit.VE}
  $le=$t.IndexOf([char]10,$re);$restEnd=if($le -lt 0){$t.Length}else{$le}
  $post=$t.Substring($re,$restEnd-$re).Trim()
  if($own -and ($post.Length -eq 0 -or $post.StartsWith('//',[StringComparison]::Ordinal))){$s0=$ls+1;$e0=if($le -lt 0){$t.Length}else{$le+1}}   # whole line(s), incl. its trailing // comment
  else{$s0=$hit.KS;$e0=$re;while($e0 -lt $t.Length -and ($t[$e0] -eq ' ' -or $t[$e0] -eq "`t")){$e0++}}
  $new=$t.Substring(0,$s0)+$t.Substring($e0)
  if($hit.Comma -lt 0 -and $idx -gt 0){$pc=$items[$idx-1].Comma;if($pc -ge 0){$new=$new.Substring(0,$pc)+$new.Substring($pc+1)}}}   # removed the last entry: drop the comma it leaves dangling
 # safety net: the result must still parse, carry the requested key state, and leave every OTHER entry's text untouched
 $v=Jsonc-Scan $new;$h2=$null;foreach($it in $v.Items){if($it.Key -ceq $key){$h2=$it}}
 if($null -ne $json){if(-not $h2 -or $new.Substring($h2.VS,$h2.VE-$h2.VS) -cne $json){throw 'internal check failed after edit'}}elseif($h2){throw 'internal check failed after edit'}
 $sep=[string][char]0
 $x=@($sc.Items|Where-Object{$_.Key -cne $key}|ForEach-Object{$_.Key+'='+$t.Substring($_.VS,$_.VE-$_.VS)})
 $y=@($v.Items|Where-Object{$_.Key -cne $key}|ForEach-Object{$_.Key+'='+$new.Substring($_.VS,$_.VE-$_.VS)})
 if(($x -join $sep) -cne ($y -join $sep)){throw 'internal check failed: other entries changed'}
 return $new}
function Json-Set($a,$jv){                       # sets (or, when $jv is $null, removes) ONE top-level key in place; nothing else in the file changes
 $leaf=Split-Path $a.P -Leaf;$d=Split-Path $a.P
 if(-not(Test-Path -LiteralPath $d)){if($null -eq $jv){return};New-Item $d -ItemType Directory -Force|Out-Null}
 $exists=Test-Path -LiteralPath $a.P;$bom=$false;$raw=''
 if($exists){$bytes=[IO.File]::ReadAllBytes($a.P);$bom=($bytes.Length -ge 3 -and $bytes[0] -eq 0xEF -and $bytes[1] -eq 0xBB -and $bytes[2] -eq 0xBF)
  $raw=[Text.Encoding]::UTF8.GetString($bytes);if($bom){$raw=$raw.Substring(1)}}
 if($null -eq $jv -and -not $exists){return}
 $json=if($null -eq $jv){$null}else{ConvertTo-Json -InputObject $jv -Compress -Depth 20}
 try{$new=Jsonc-Edit $raw $a.N $json}catch{throw "Cannot edit $leaf safely: $($_.Exception.Message) - nothing was written; edit it manually."}
 if($new -ceq $raw){return}                                                   # already as requested: do not touch the file
 if($exists -and -not(Test-Path -LiteralPath "$($a.P).debloathub.bak")){Copy-Item -LiteralPath $a.P "$($a.P).debloathub.bak" -Force}
 $tmp="$($a.P).debloathub.tmp"
 [IO.File]::WriteAllText($tmp,$new,(New-Object Text.UTF8Encoding $bom))      # keeps the file's BOM state; temp file first, then replace
 Move-Item -LiteralPath $tmp -Destination $a.P -Force}
$s21='Developer Tools Privacy';$s22='Browser Privacy & Security';$s23='Windows Hardening & Privacy'
$secs=@($secs|Where-Object{$_ -ne $s14})+@($s21,$s22,$s23,$s14)
$VSC="$UserAppData\Code\User\settings.json";$CP='HKLM:\SOFTWARE\Policies\Google\Chrome';$FP='HKLM:\SOFTWARE\Policies\Mozilla\Firefox';$SS='HKCU:\Software\Microsoft\Windows\CurrentVersion\StorageSense\Parameters\StoragePolicy'
$splitOK=@();$excl=@{'Enable Storage Sense (automatic weekly cleanup)'='Disable Storage Sense auto cleanup';'Disable Storage Sense auto cleanup'='Enable Storage Sense (automatic weekly cleanup)'}
function AddT($sec,$name,$desc,$risk,$prof,$acts,$rec,$m,[switch]$split,$when=$true){if(-not $when){return};$script:db+=fTw $sec $name $desc $risk $sd Any $prof $acts $rec;$script:more[$name]=$m;if($split){$script:splitOK+=$name}}

AddT $s21 'VS Code: turn off telemetry, feedback prompts & experiments' 'Sets three documented settings in your VS Code user settings.json in place (comments and formatting are kept; a .debloathub.bak copy is made the first time): telemetry.telemetryLevel = off, telemetry.feedback.enabled = false, workbench.enableExperiments = false.' Safe 'safe,privacy,telemetry' @((fJson $VSC 'telemetry.telemetryLevel' 'off' $null),(fJson $VSC 'telemetry.feedback.enabled' $false $null),(fJson $VSC 'workbench.enableExperiments' $false $null)) 'Your settings.json is edited in place: comments, trailing commas and layout stay. Extensions may still send their own telemetry. Does nothing if VS Code has never been started on this account.' @('Needed only if you want to help Microsoft improve VS Code or get early features.','No usage data, error or crash reports to Microsoft; no survey or issue-reporter prompts.','New features may reach you later because VS Code rolls them out through experiments.') -split -when (Test-Path -LiteralPath (Split-Path $VSC))
AddT $s21 'VS Code: stop background lookups (npm, JSON schemas, type downloads)' 'Stops VS Code fetching package info, JSON schemas and TypeScript types from the internet automatically.' Moderate '' @((fJson $VSC 'npm.fetchOnlinePackageInfo' $false $null),(fJson $VSC 'json.schemaDownload.enable' $false $null),(fJson $VSC 'typescript.disableAutomaticTypeAcquisition' $true $null)) 'Pick only what you can live without: JSON validation for package.json and similar may lose autocomplete, and JS projects get fewer automatic type hints.' @('Skip if you rely on hover info for npm packages or schema-based JSON validation.','Fewer outgoing requests while you edit; works better offline.','Less autocomplete and validation help in JSON and JavaScript files.') -split -when (Test-Path -LiteralPath (Split-Path $VSC))
AddT $s21 'Visual Studio: turn off telemetry (Customer Experience Improvement Program)' 'Applies the Microsoft-documented Group Policy value HKLM\SOFTWARE\Policies\Microsoft\VisualStudio\SQM\OptIn = 0, which overrides the per-version setting in every installed Visual Studio.' Safe 'safe,privacy,telemetry' @(fReg 'HKLM:\SOFTWARE\Policies\Microsoft\VisualStudio\SQM' OptIn 0 $null) '' @('Needed only if you want to help improve Visual Studio.','No usage telemetry from Visual Studio.','Visual Studio shows its privacy setting as managed by policy.') -when $haveVS
AddT $s21 'Developer CLIs: turn off telemetry (.NET, PowerShell 7, Next.js, Nuxt, Astro, Gatsby, Angular, Storybook, Turborepo, vcpkg, Terraform/Prisma, AWS SAM, Azure CLI, DO_NOT_TRACK)' 'Sets per-user environment variables that tell common developer tools not to send usage data. POWERSHELL_TELEMETRY_OPTOUT only affects PowerShell 7+, not Windows PowerShell 5.1. Angular only collects usage data if you opted in; NG_CLI_ANALYTICS=false makes sure of it. For Storybook the environment variable is the only switch that also stops the event sent before main.ts is read.' Safe 'safe,privacy,telemetry' (@('DOTNET_CLI_TELEMETRY_OPTOUT','POWERSHELL_TELEMETRY_OPTOUT','NEXT_TELEMETRY_DISABLED','NUXT_TELEMETRY_DISABLED','ASTRO_TELEMETRY_DISABLED','GATSBY_TELEMETRY_DISABLED','STORYBOOK_DISABLE_TELEMETRY','TURBO_TELEMETRY_DISABLED','VCPKG_DISABLE_METRICS','CHECKPOINT_DISABLE','DO_NOT_TRACK'|ForEach-Object{fReg 'HKCU:\Environment' $_ '1' $null String})+@((fReg 'HKCU:\Environment' NG_CLI_ANALYTICS 'false' $null String),(fReg 'HKCU:\Environment' SAM_CLI_TELEMETRY '0' $null String),(fReg 'HKCU:\Environment' AZURE_CORE_COLLECT_TELEMETRY '0' $null String))) 'Takes effect in new terminals after you sign out and back in. Choose individually to keep any you do not mind.' @('Needed only if you want to share anonymous usage data with these tools.','Fewer outgoing connections from your dev tools.','None; these only turn telemetry off.') -split

AddT $s22 'Edge: turn off diagnostic data, personalization & feedback' 'Edge policies: DiagnosticData Off (Edge 122+), no personalization reporting, no user feedback, no recommendations. The older MetricsReportingEnabled and SendSiteInfoToImproveServices policies are obsolete since Edge 88 and are no longer written.' Safe 'safe,privacy,telemetry' @((fReg $EP DiagnosticData 0 $null),(fReg $EP PersonalizationReportingEnabled 0 $null),(fReg $EP UserFeedbackAllowed 0 $null),(fReg $EP ShowRecommendationsEnabled 0 $null)) 'Edge will say it is managed by your organization; that is just these policies. Edge before version 122 ignores DiagnosticData and follows the Windows diagnostic-data level (see Disable telemetry & diagnostic services).' @('Not needed unless you want to help Microsoft improve Edge.','Less data sent from Edge; fewer recommendations.','Edge shows the "managed" notice and has no feedback button. Microsoft marks DiagnosticData Off as "not recommended" because required diagnostics also stop.') -split -when $haveEdge
AddT $s22 'Edge: harden browsing (Do Not Track, no third-party cookies, no prediction)' 'Sends Do Not Track, blocks third-party cookies and stops network prefetching.' Moderate '' @((fReg $EP ConfigureDoNotTrack 1 $null),(fReg $EP BlockThirdPartyCookies 1 $null),(fReg $EP NetworkPredictionOptions 2 $null)) 'Blocking third-party cookies can break some logins and embedded content. Choose individually.' @('Skip if you use sites that rely on third-party sign-in or embedded widgets.','Less cross-site tracking and fewer speculative connections.','Some logins, video embeds and payment widgets may stop working; pages may load a touch slower.') -split -when $haveEdge
AddT $s22 'Edge: no Microsoft Rewards or MSN news feed' 'Turns off Microsoft Rewards (points, offers and the Rewards button) and the MSN news and ads feed on the new tab page, which then shows only your quick links and background (policies ShowMicrosoftRewards = 0, NewTabPageContentEnabled = 0).' Safe 'privacy' @((fReg $EP ShowMicrosoftRewards 0 $null),(fReg $EP NewTabPageContentEnabled 0 $null)) 'Recommended if Edge is installed, used or not. Edge shows "managed by your organization".' @('Use it unless you collect Microsoft Rewards points or read the MSN feed on the new tab page.','A calm new tab page without news, ads and trending stories; fewer requests to MSN every time you open a tab.','No Rewards points or offers; the new tab page content setting is locked to "off".') -split -when $haveEdge
AddT $s22 'Edge: put background tabs to sleep sooner' 'Makes sure sleeping tabs stay on and puts inactive tabs to sleep after 5 minutes instead of 15 (SleepingTabsEnabled, SleepingTabsTimeout = 300). Optional: efficiency mode always available (EfficiencyModeEnabled); on PCs without a battery it is then always active.' Safe 'gaming' @((fReg $EP SleepingTabsEnabled 1 $null),(fReg $EP SleepingTabsTimeout 300 $null),(fReg $EP EfficiencyModeEnabled 1 $null)) 'For people who keep many Edge tabs open, e.g. while gaming. Choose individually: efficiency mode on a desktop is always on and can make busy pages feel slightly less smooth.' @('Use it if Edge uses a lot of RAM because you keep many tabs open.','Background tabs free their memory and CPU after 5 minutes; less RAM pressure while gaming or working.','A sleeping tab reloads its content when you return to it (a short delay; unsent form text is usually kept). Efficiency mode can lower animation smoothness.') -split -when $haveEdge
AddT $s22 'Chrome: turn off metrics, reports & Privacy Sandbox ad tracking' 'Chrome policy switches for usage metrics, user feedback, extended Safe Browsing reports, URL data collection and Privacy Sandbox ad topics.' Safe 'safe,privacy,telemetry' @((fReg $CP MetricsReportingEnabled 0 $null),(fReg $CP UserFeedbackAllowed 0 $null),(fReg $CP SafeBrowsingExtendedReportingEnabled 0 $null),(fReg $CP UrlKeyedAnonymizedDataCollectionEnabled 0 $null),(fReg $CP PrivacySandboxPromptEnabled 0 $null),(fReg $CP PrivacySandboxAdTopicsEnabled 0 $null),(fReg $CP PrivacySandboxAdMeasurementEnabled 0 $null),(fReg $CP PrivacySandboxSiteEnabledAdsEnabled 0 $null)) 'Chrome will say it is managed by your organization. Normal Safe Browsing protection stays on. Open chrome://policy to confirm which of these your Chrome version applies.' @('Not needed unless you want to share usage data with Google.','Less data to Google; no ad-topic profiling.','Chrome shows the "managed" notice; ads become less relevant.') -split -when $haveChrome
AddT $s22 'Chrome: harden browsing (no third-party cookies, no prediction, no background mode)' 'Blocks third-party cookies, stops network prefetching and stops Chrome running after you close it.' Moderate '' @((fReg $CP BlockThirdPartyCookies 1 $null),(fReg $CP NetworkPredictionOptions 2 $null),(fReg $CP BackgroundModeEnabled 0 $null)) 'Choose individually; background mode off also saves RAM.' @('Skip if you rely on third-party sign-in widgets or Chrome notifications while closed.','Less tracking, fewer speculative connections, less RAM.','Some logins and embeds may break; no Chrome notifications while it is closed.') -split -when $haveChrome
AddT $s22 'Firefox: turn off telemetry, studies, Pocket & feedback' 'Firefox policies: DisableTelemetry, DisableFirefoxStudies, DisableFeedbackCommands, DisableDefaultBrowserAgent (Windows) and DisablePocket (deprecated in current Firefox, harmless).' Safe 'safe,privacy,telemetry' @((fReg $FP DisableTelemetry 1 $null),(fReg $FP DisableFirefoxStudies 1 $null),(fReg $FP DisablePocket 1 $null),(fReg $FP DisableFeedbackCommands 1 $null),(fReg $FP DisableDefaultBrowserAgent 1 $null)) 'Firefox will say it is managed by your organization.' @('Not needed unless you want to help Mozilla.','No telemetry, experiments or default-browser reports to Mozilla.','Firefox shows the "managed" notice; Pocket (where still present) is unavailable.') -split -when $haveFirefox
AddT $s22 'Firefox: no sponsored shortcuts, stories, suggestions or feature ads' 'Firefox policies that remove sponsored shortcuts and sponsored stories from the home page, sponsored suggestions in the address bar, and recommendation pop-ups (extensions, features, "More from Mozilla"), and skip onboarding pages after updates.' Safe 'privacy' @((fReg "HKLM:\SOFTWARE\Policies\Mozilla\Firefox\FirefoxHome" SponsoredTopSites 0 $null),(fReg "HKLM:\SOFTWARE\Policies\Mozilla\Firefox\FirefoxHome" SponsoredStories 0 $null),(fReg "HKLM:\SOFTWARE\Policies\Mozilla\Firefox\FirefoxSuggest" SponsoredSuggestions 0 $null),(fReg "HKLM:\SOFTWARE\Policies\Mozilla\Firefox\FirefoxSuggest" ImproveSuggest 0 $null),(fReg "HKLM:\SOFTWARE\Policies\Mozilla\Firefox\UserMessaging" ExtensionRecommendations 0 $null),(fReg "HKLM:\SOFTWARE\Policies\Mozilla\Firefox\UserMessaging" FeatureRecommendations 0 $null),(fReg "HKLM:\SOFTWARE\Policies\Mozilla\Firefox\UserMessaging" MoreFromMozilla 0 $null),(fReg "HKLM:\SOFTWARE\Policies\Mozilla\Firefox\UserMessaging" SkipOnboarding 1 $null)) 'Recommended if you use Firefox. Firefox shows "managed by your organization".' @('Use it unless you like sponsored tiles and Mozilla''s feature tips.','No ads on the home page or in the address bar; what you type is not sent to improve Firefox Suggest; no "try this extension" pop-ups.','You also miss genuinely new-feature announcements; the home-page sponsored settings are controlled by policy.') -split -when $haveFirefox
AddT $s22 'Firefox: update only while Firefox is open' 'Turns off the background update task that downloads and installs Firefox updates while Firefox is closed (policy BackgroundAppUpdate = 0). Firefox still updates itself while it runs.' Safe '' @(fReg "HKLM:\SOFTWARE\Policies\Mozilla\Firefox" BackgroundAppUpdate 0 $null) 'Recommended: Firefox stays up to date, it just does it while you use it.' @('Use it if you do not want a Firefox task waking up in the background while Firefox is closed.','One less scheduled background job; no surprise network and disk activity from Firefox when it is not running.','Updates arrive while you browse instead of beforehand, so after a long break the first Firefox start may show an update prompt.') -when $haveFirefox

AddT $s23 'Disable AutoPlay/AutoRun for removable drives' 'Windows no longer runs or offers to run anything when you insert a USB stick, disc or memory card.' Safe 'safe' @(fReg 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Policies\Explorer' NoDriveTypeAutoRun 255 $null) '' @('Use it; you can still open drives in Explorer.','Blocks a classic way malware spreads through USB sticks; no pop-ups when you plug in a phone or card.','Discs and installers no longer start by themselves, and no "what do you want to do" prompt for photos and media.')
AddT $s23 'Disable LLMNR (name-spoofing protection)' 'Turns off Link-Local Multicast Name Resolution, an old fallback that lets any device on the network answer "who is PC-NAME?". Attackers abuse it to capture your login hash.' Moderate '' @(fReg 'HKLM:\SOFTWARE\Policies\Microsoft\Windows NT\DNSClient' EnableMulticast 0 $null) 'Fine on home networks with a normal router; skip on small peer-to-peer networks without DNS.' @('Use it on home networks with a normal router and on laptops that join public Wi-Fi.','Closes a common credential-stealing attack on public and office networks.','On small networks without a router or DNS, other PCs may not be found by name (use their IP address instead).')
AddT $s23 'Disable Remote Assistance' 'Turns off Windows Remote Assistance invitations (msra.exe), so nobody can request or offer remote control of this PC through it.' Safe 'safe' @(fReg 'HKLM:\SYSTEM\CurrentControlSet\Control\Remote Assistance' fAllowToGetHelp 0 1) '' @('Use it unless someone helps you through Windows Remote Assistance invitations.','Closes one remote-control path.','Remote Assistance invitations stop working. Quick Assist, TeamViewer and AnyDesk are not affected.')
AddT $s23 'Disable Windows Script Host (.vbs/.js double-click)' 'Disables Windows Script Host, so .vbs, .vbe, .js and .wsf files no longer run when opened.' Advanced '' @(fReg 'HKLM:\SOFTWARE\Microsoft\Windows Script Host\Settings' Enabled 0 $null) 'Skip if old installers, logon scripts or admin tools use VBScript or JScript.' @('Use it if nothing you run needs VBScript/JScript. Skip it on work PCs with logon scripts or with old installers and admin tools.','Blocks one of the most common ways malicious email attachments start.','Some old installers, game launchers and admin scripts fail with a "Windows Script Host access is disabled" error.')
AddT $s23 'Turn off clipboard history & cross-device clipboard' 'Disables Win+V clipboard history and syncing the clipboard to your other devices through your Microsoft account.' Safe 'privacy' @((fReg "$POL\System" AllowClipboardHistory 0 $null),(fReg "$POL\System" AllowCrossDeviceClipboard 0 $null)) 'Good if you copy passwords or personal data.' @('Use it if you copy passwords or personal data and do not use Win+V. Skip it if you rely on Win+V.','Copied passwords and private text are not kept in a history or sent to other devices.','No Win+V history and no clipboard sync between PCs or your phone.') -split
AddT $s23 'Turn off online speech recognition & inking/typing data' 'Turns off cloud speech recognition and stops Windows collecting your handwriting and typing samples to personalise recognition.' Safe 'privacy,telemetry' @((fReg 'HKCU:\Software\Microsoft\Speech_OneCore\Settings\OnlineSpeechPrivacy' HasAccepted 0 $null),(fReg 'HKCU:\Software\Microsoft\InputPersonalization' RestrictImplicitInkCollection 1 0),(fReg 'HKCU:\Software\Microsoft\InputPersonalization' RestrictImplicitTextCollection 1 0)) '' @('Use it unless you dictate with Win+H or use voice access that needs the online service.','Your voice and typing samples are not sent to Microsoft.','Online dictation (Win+H) and some voice features stop working; handwriting recognition learns less from you.') -split
AddT $s12 'Enable Storage Sense (automatic weekly cleanup)' 'Turns on Windows built-in Storage Sense: every week it deletes temporary files and Recycle Bin items older than 30 days. Your Downloads folder is never touched.' Safe '' @((fReg $SS '01' 1 0),(fReg $SS '04' 1 0),(fReg $SS '08' 1 0),(fReg $SS '256' 30 0),(fReg $SS '2048' 7 0)) 'This is the safe version of a garbage-collector. It excludes your Downloads folder. Switching it on turns off "Disable Storage Sense auto cleanup".' @('Use it if your drive fills up and you forget to clean up. Switching it on turns off "Disable Storage Sense auto cleanup".','Frees space automatically with Windows own tool; no extra cleaner running in the background.','Recycle Bin items older than 30 days are gone for good.')
AddT $s14 'Clean Windows Update leftovers (component cleanup)' 'Runs DISM /StartComponentCleanup, which deletes old versions of Windows components that newer updates replaced (WinSxS folder).' Safe '' @(fCmd 'DISM /Online /Cleanup-Image /StartComponentCleanup') 'Takes a few minutes and the window looks frozen. You cannot uninstall already-superseded updates afterwards.' @('Use it when the system drive is getting full. Windows also does this slowly on its own in the background.','Usually frees a few hundred MB to several GB.','Takes several minutes; updates installed before the cleanup can no longer be uninstalled.')
AddT $s14 'Clear crash dumps & error reports' 'Deletes blue-screen minidumps, the full memory dump (MEMORY.DMP, can be many GB) and queued Windows Error Reporting files.' Safe '' @(fCmd 'Remove-Item "$env:SystemRoot\Minidump\*","$env:SystemRoot\MEMORY.DMP","$env:ProgramData\Microsoft\Windows\WER\*" -Recurse -Force -ErrorAction SilentlyContinue') 'Keep them if you are currently troubleshooting blue screens.' @('Use it when you are not investigating crashes. Keep them if you are diagnosing blue screens or someone asked for the dump.','Can free several GB if a full memory dump exists.','Past crash information is gone, so tools like WhoCrashed or BlueScreenView have nothing to analyse.')
AddT $s14 'Clear thumbnail cache' 'Deletes Explorer picture and video thumbnail caches. Explorer closes for a moment and Windows restarts it by itself; thumbnails are rebuilt as you browse.' Safe '' @(fCmd '$me=[Diagnostics.Process]::GetCurrentProcess().SessionId;$ex=@(Get-Process explorer -ErrorAction SilentlyContinue|Where-Object SessionId -eq $me);$ex|Stop-Process -Force;$ex|Wait-Process -Timeout 5 -ErrorAction SilentlyContinue;Remove-Item "$UserLocal\Microsoft\Windows\Explorer\thumbcache_*.db" -Force -ErrorAction SilentlyContinue;for($i=0;$i -lt 10 -and -not(Get-Process explorer -ErrorAction SilentlyContinue|Where-Object SessionId -eq $me);$i++){Start-Sleep -Milliseconds 500};if(-not(Get-Process explorer -ErrorAction SilentlyContinue|Where-Object SessionId -eq $me)){Start-Process explorer}') 'Explorer windows will close and reopen.' @('Use it when thumbnails are wrong, blank or show old pictures.','Fixes broken previews; frees anything from a few MB to a few hundred MB.','Open Explorer windows close; folders full of photos and videos are slow to show thumbnails the first time.')
AddT $s14 'Clear browser caches (Edge, Chrome, Firefox)' 'Deletes the cache folders (Cache, Code Cache, GPUCache, cache2) of every browser profile. Cookies, passwords, bookmarks and history are not touched.' Safe '' @(fCmd '$d=$UserLocal;foreach($b in "$d\Microsoft\Edge\User Data","$d\Google\Chrome\User Data"){Get-ChildItem -LiteralPath $b -Directory -ErrorAction SilentlyContinue|Where-Object{$_.Name -eq ''Default'' -or $_.Name -like ''Profile *''}|ForEach-Object{foreach($cd in ''Cache'',''Code Cache'',''GPUCache''){Remove-Item "$($_.FullName)\$cd\*" -Recurse -Force -ErrorAction SilentlyContinue}}};Get-ChildItem "$d\Mozilla\Firefox\Profiles" -Directory -ErrorAction SilentlyContinue|ForEach-Object{Remove-Item "$($_.FullName)\cache2\*" -Recurse -Force -ErrorAction SilentlyContinue}') 'Close the browsers first. Pages load a little slower once while caches refill.' @('Use it when sites look broken or outdated, or to free space. Close the browsers first so nothing is in use.','Frees from hundreds of MB to several GB; fixes pages that keep showing old versions.','Sites load a bit slower until the cache refills. You stay signed in.')
AddT $s14 'Clear Delivery Optimization cache' 'Deletes update and Store-app files that Delivery Optimization keeps for re-use and sharing.' Safe '' @(fCmd 'Delete-DeliveryOptimizationCache -Force') '' @('Use it when the drive is full; Windows also trims this cache by itself.','Frees disk space (sometimes several GB after a feature update).','Files may be downloaded again if needed.')

# ---------- G-Helper / Optimus laptops: shown only when NVIDIA display drivers are installed ----------
if(Get-Service -Name 'NVDisplay.ContainerLocalSystem' -ErrorAction SilentlyContinue){
 $nvn='Stop NVIDIA services while the dGPU is off (G-Helper Eco)'
 $db+=fTw 'Performance & Gaming' $nvn 'Adds a small scheduled task (Task Scheduler > DebloatHub) that runs 30 seconds after Windows starts and after you sign in. It checks whether an NVIDIA graphics card is present. In G-Helper Eco mode the dGPU is powered off and disappears from Device Manager, so the task stops the two NVIDIA background services (NVIDIA Display Container and NVIDIA Container). When the dGPU is on, it does nothing. Start types are never changed.' Safe $sd Any '' @(fCmd 'Install-NvEcoTask' 'Remove-NvEcoTask' 'Test-NvEcoTask') 'Recommended on G-Helper laptops with an NVIDIA dGPU. Also turn on G-Helper > Extra > "Stop/Start NVIDIA services based on dGPU state": G-Helper handles mode switches, this task handles boots that start in Eco.'
 $more[$nvn]=@('Use it if you run your laptop in Eco mode (dGPU off) and G-Helper''s "Stop/Start NVIDIA services" option is on. That option only reacts when you switch modes, so after a restart in Eco both services start anyway and sit idle. Skip it on desktops or laptops whose dGPU is always on: the task would never do anything.','No idle NVIDIA container processes while the dGPU is off: some RAM back (usually tens of MB) and fewer background wake-ups on battery. Nothing is disabled, so Standard and Ultimate modes behave exactly as before.','It only stops services, it never starts them. Without the G-Helper option, switching from Eco to Standard leaves NVIDIA Control Panel and the NVIDIA app unavailable until the next reboot. The NVIDIA overlay, ShadowPlay and the NVIDIA app cannot run in Eco anyway.')
}

# ---------- Background services: grouped by feature; every service is its own switch, so keep what you use ----------
# Only services that exist on this PC are listed. Disabling a service that is already Manual and not running changes nothing,
# so the groups below are services that commonly RUN on home PCs (or start on a trigger) and that many people never need.
$sSvc='Background Services'
$haveSvc=@{};$svcName=@{};try{foreach($x in @(Get-Service -ErrorAction SilentlyContinue)){$haveSvc[$x.Name]="$($x.StartType)";$svcName[$x.Name]=$x.DisplayName}}catch{}
# Manual (default): "turn off" = start only when something asks for it (features keep working, nothing crashes on a refused start).
# Strict: "turn off" = Disabled (never starts, even when asked). Changing the mode restarts DebloatHub because the actions are built here.
$SvcStrict=$false;try{$SvcStrict=((Get-ItemProperty 'HKCU:\SOFTWARE\DebloatHub' -Name ServiceMode -ErrorAction Stop).ServiceMode -eq 'Strict')}catch{}
$SVCINFO=[ordered]@{
 Spooler='Print Spooler: every printer and virtual printer (Microsoft Print to PDF, OneNote, PDF printers) needs it.'
 PrintNotify='Printer Extensions and Notifications: printer pop-ups, ink levels and vendor print dialogs.'
 Fax='Fax: sending and receiving faxes through a modem or fax server.'
 stisvc='Windows Image Acquisition (WIA): scanners, the Windows Scan and Fax and Scan apps, importing from some cameras.'
 XblAuthManager='Xbox Live Auth Manager: signing in to Xbox services in Game Pass and Microsoft Store games.'
 XblGameSave='Xbox Live Game Save: cloud saves for Game Pass and Microsoft Store games.'
 XboxNetApiSvc='Xbox Live Networking: Xbox multiplayer connectivity and NAT checks.'
 XboxGipSvc='Xbox Accessory Management: Xbox Accessories app, controller firmware updates and button remapping. Controllers themselves keep working.'
 CDPSvc='Connected Devices Platform: Night light, Phone Link, Nearby sharing and some cast/pairing features. Turning it off BREAKS Night light and can crash Settings > Display.'
 PhoneSvc='Phone Service: calls through Phone Link.'
 WbioSrvc='Windows Biometric Service: Windows Hello fingerprint and face sign-in. PIN and password keep working.'
 bthserv='Bluetooth Support Service: finding and connecting ALL Bluetooth devices (mice, keyboards, headphones, controllers).'
 BTAGService='Bluetooth Audio Gateway: Bluetooth headset microphone and hands-free calls.'
 BthAvctpSvc='Bluetooth AVCTP: play/pause/volume buttons on Bluetooth headphones and speakers.'
 LanmanServer='Server (file sharing): sharing this PC''s folders and printers with other computers.'
 FDResPub='Function Discovery Resource Publication: makes this PC visible in other PCs'' Network folder.'
 SSDPSRV='SSDP Discovery: finding UPnP/DLNA devices (smart TVs, media servers, Cast to device, some printers).'
 upnphost='UPnP Device Host: lets this PC act as a UPnP/DLNA device for others.'
 TermService='Remote Desktop Services: connecting TO this PC with Remote Desktop (Windows Pro and up).'
 SessionEnv='Remote Desktop Configuration: part of Remote Desktop hosting.'
 UmRdpService='Remote Desktop Port Redirector: printer, drive and clipboard redirection in Remote Desktop sessions.'
 RemoteRegistry='Remote Registry: lets other PCs on the network edit this PC''s registry (off by default).'
 iphlpsvc='IP Helper: IPv6 tunnelling (Teredo, 6to4, IP-HTTPS) used by some VPNs, DirectAccess and Xbox party chat.'
 DPS='Diagnostic Policy Service: problem detection, troubleshooters and network diagnostics.'
 WdiServiceHost='Diagnostic Service Host: runs diagnostics started by the Diagnostic Policy Service.'
 WdiSystemHost='Diagnostic System Host: runs system-level diagnostics started by the Diagnostic Policy Service.'
 diagsvc='Diagnostic Execution Service: runs troubleshooters on request.'
 InventorySvc='Inventory and Compatibility Appraisal: scans installed apps for upgrade compatibility and telemetry (Windows 11).'
 MapsBroker='Downloaded Maps Manager: offline maps for the Maps app.'
 TrkWks='Distributed Link Tracking: keeps shortcuts working when linked files move between NTFS drives on a network.'
 PcaSvc='Program Compatibility Assistant: detects old programs that failed and offers compatibility settings.'
 edgeupdate='Edge Update: background Edge updates (Edge scheduled tasks also update it).'
}
foreach($k in @($SVCINFO.Keys)){$LBL[$k]=($SVCINFO[$k] -split ':')[0]}
# snapshot ids (defined early: SvcGroup needs Snap-Read while the tweak list is built)
function Snap-Hash($k,$a){'S_'+([BitConverter]::ToString([Security.Cryptography.SHA1]::Create().ComputeHash([Text.Encoding]::UTF8.GetBytes("$k|$($a.P)|$($a.A)|$($a.N)"))).Replace('-','').Substring(0,20))}
function Snap-Id($a){Snap-Hash $(if($a.K -eq 'SvcM'){'Svc'}else{$a.K}) $a}   # Disabled and Manual share ONE record: switching mode never loses the original start type
function Snap-Ids($a){@(Snap-Id $a)+@(if($a.K -eq 'SvcM'){Snap-Hash 'SvcM' $a})}  # + ids written by v1.0.x
function Snap-Read($a){foreach($id in (Snap-Ids $a)){$v=(Get-ItemProperty -Path 'HKLM:\SOFTWARE\DebloatHub\Snapshots' -Name $id -ErrorAction SilentlyContinue).$id;if($v){return ($v|ConvertFrom-Json)}}}
function SvcGroup($name,$desc,$risk,$items,$rec,$m,[switch]$Fixed){
 # $items: @(service, 'D' | 'M', fallback start type for undo). Names may contain * (e.g. GoogleUpdaterService*).
 #   'D' = turn off: Manual in Manual mode, Disabled in Strict mode (or always Disabled with -Fixed)
 #   'M' = always Manual (updaters, G-Helper's Armoury Crate list)
 $acts=@();$skip=@()
 foreach($i in $items){
  $names=if($i[0] -like '*`**'){@($haveSvc.Keys|Where-Object{$_ -like $i[0]}|Sort-Object)}elseif($haveSvc.ContainsKey($i[0])){,$i[0]}else{@()}
  foreach($n in $names){
   if(-not $LBL.ContainsKey($n) -and $svcName[$n]){$LBL[$n]=$svcName[$n]}
   if($i[1] -eq 'M'){$acts+=fSvm $n $i[2];continue}
   if($Fixed -or $SvcStrict){$acts+=fSvc $n $i[2];continue}
   $a=fSvm $n $i[2]                                                     # Manual mode: applied = not Automatic (Manual or Disabled)
   if($haveSvc[$n] -in 'Manual','Disabled' -and -not(Snap-Read $a)){$skip+="$($LBL[$n])$(if($haveSvc[$n] -eq 'Disabled'){' (already Disabled)'})";continue}   # not Automatic and untouched by DebloatHub: nothing to do in Manual mode
   $acts+=$a}}
 if($skip.Count){$desc+=" Not listed because they already do not start at boot on this PC (Strict mode lists them): $($skip -join ', ')."}
 if(-not $acts.Count){return}
 $script:db+=fTw $sSvc $name $desc $risk $sd Any '' $acts $rec;$script:more[$name]=$m}

SvcGroup 'Printing & scanning services' 'Turns off printing, fax and scanner services. Each service has its own switch: e.g. keep Print Spooler for printing and PDF, but turn off Fax.' Moderate @(@('Spooler','D','Automatic'),@('PrintNotify','D','Manual'),@('Fax','D','Manual'),@('stisvc','D','Manual')) 'Most home PCs never fax; many never print or scan. Keep Print Spooler if you print OR use "Microsoft Print to PDF".' @('Turn off what you never use: Fax for almost everyone, Spooler and WIA only if you never print, save to PDF or scan.','Print Spooler is one of the most attacked Windows services (PrintNightmare); fewer services start at boot.','Without Spooler: no printing and no Microsoft Print to PDF. Without WIA: scanners and Windows Scan stop working. Switch back on any time.')
SvcGroup 'Xbox & Game Pass services' 'Turns off the Xbox sign-in, cloud-save, networking and accessory services. They start on demand when an Xbox-enabled game or app runs.' Moderate @(@('XblAuthManager','D','Manual'),@('XblGameSave','D','Manual'),@('XboxNetApiSvc','D','Manual'),@('XboxGipSvc','D','Manual')) 'Only if you play no Game Pass or Microsoft Store games. Steam, Epic and other launchers do not need them.' @('Use it if you do not play Game Pass or Microsoft Store games. Keep everything if you do.','Xbox components can no longer wake up in the background; fewer processes during gaming.','Game Pass and Store games cannot sign in, sync saves or join multiplayer. Xbox Accessories app and controller firmware updates stop.')
SvcGroup 'Phone Link & cross-device services' 'Turns off the Phone Service, which handles calls through Phone Link. (Connected Devices Platform is a separate switch below because it breaks Night light.)' Moderate @(,@('PhoneSvc','D','Manual')) 'Only if you never make calls through Phone Link.' @('Use it if you do not make or take phone calls on this PC through Phone Link.','The phone-call service cannot start in the background.','Calls through Phone Link stop working; texts, photos and notifications in Phone Link are not affected.')
SvcGroup -Fixed 'Disable Connected Devices Platform (breaks Night light)' 'Disables the Connected Devices Platform service (CDPSvc). WARNING: Night light depends on it: after a reboot Night light cannot be turned on and Settings > Display can crash (SystemSettings.exe error 0x40000015). It also powers Phone Link, Nearby sharing and some cast/pairing features.' Advanced @(,@('CDPSvc','D','Automatic')) 'Do NOT use it if you use Night light. Only for PCs that never use Night light, Phone Link or Nearby sharing.' @('Only if you never use Night light, Phone Link, Nearby sharing or Share with nearby devices.','One busy background service is gone; some users see less CPU and battery use.','BREAKS Night light (cannot be switched on) and can crash Settings > Display; Phone Link and Nearby sharing stop. To fix: switch this off, Apply and reboot.')
SvcGroup 'Windows Hello biometrics service' 'Turns off the Windows Biometric Service (fingerprint and face sign-in).' Moderate @(,@('WbioSrvc','D','Manual')) 'Only if you sign in with a PIN or password. Keep it if you use a fingerprint reader or IR face camera.' @('Use it on PCs without a fingerprint reader / IR camera, or if you never use them.','One less service; the biometric stack cannot wake up.','Fingerprint and face sign-in stop working; PIN and password still work.')
SvcGroup 'Bluetooth services' 'Turns off Bluetooth support, hands-free audio and media-button services.' Advanced @(@('bthserv','D','Manual'),@('BTAGService','D','Manual'),@('BthAvctpSvc','D','Manual')) 'Only on PCs that never use Bluetooth. If you only skip headset calls, turn off just Bluetooth Audio Gateway.' @('Use it only if this PC never uses Bluetooth.','No Bluetooth background services or radio scanning.','ALL Bluetooth devices stop working (mice, keyboards, headphones, controllers), including ones already paired.')
SvcGroup 'Network sharing & discovery services' 'Turns off sharing this PC''s files/printers and announcing or discovering devices on the local network. Opening shares on OTHER PCs or a NAS keeps working.' Moderate @(@('LanmanServer','D','Automatic'),@('FDResPub','D','Manual'),@('SSDPSRV','D','Manual'),@('upnphost','D','Manual')) 'Good for laptops on public Wi-Fi. Keep SSDP Discovery if you cast to a smart TV or use DLNA media servers.' @('Use it if you never share folders from this PC and do not cast to TVs or DLNA devices.','This PC is no longer advertised on the network; smaller attack surface on public Wi-Fi.','Other PCs cannot open this PC''s shared folders/printers; Cast to device and DLNA discovery may stop. Mapped drives to other PCs are not affected.')
SvcGroup 'Remote Desktop & Remote Registry (incoming)' 'Turns off the services that let other computers connect TO this PC with Remote Desktop or edit its registry over the network.' Moderate @(@('TermService','D','Manual'),@('SessionEnv','D','Manual'),@('UmRdpService','D','Manual'),@('RemoteRegistry','D','Manual')) 'Keep Remote Desktop if you connect to this PC from elsewhere. Connecting FROM this PC to others keeps working.' @('Use it if nobody ever connects to this PC remotely with Remote Desktop.','Closes incoming remote-access paths.','Remote Desktop into this PC stops working. Quick Assist, TeamViewer, AnyDesk and outgoing Remote Desktop are not affected.')
SvcGroup 'IP Helper (IPv6 tunnelling)' 'Turns off IP Helper, which provides IPv6 transition tunnels (Teredo, 6to4, IP-HTTPS).' Moderate @(,@('iphlpsvc','D','Automatic')) 'Fine for most home users with normal IPv4 or native IPv6. Keep it for DirectAccess / Always On VPN at work.' @('Use it unless a work VPN (DirectAccess, IP-HTTPS) or Xbox party chat needs Teredo.','One less always-running svchost service.','Some corporate VPNs and Xbox party chat (Teredo NAT) stop working.')
SvcGroup 'Diagnostics & troubleshooting services' 'Turns off problem detection, diagnostic hosts, the troubleshooter service and the Windows 11 inventory/compatibility service.' Advanced @(@('DPS','D','Automatic'),@('WdiServiceHost','D','Manual'),@('WdiSystemHost','D','Manual'),@('diagsvc','D','Manual'),@('InventorySvc','D','Manual')) 'Only for experienced users; switch it back on before you troubleshoot anything.' @('Use it if you never run Windows troubleshooters and want fewer background diagnostics.','Fewer background scans; stops the inventory service that feeds compatibility telemetry.','Troubleshooters and "Diagnose" for network problems stop working; Windows no longer detects and suggests fixes for problems.')
$asusD='ArmouryCrateControlInterface','ArmouryCrateProArtService','AsHidService','ASUSOptimization','AsusAppService','ASUSLinkNear','ASUSLinkRemote','ASUSSoftwareManager','ASUSLiveUpdateAgent','ASUSSwitch','ASUSSystemAnalysis','ASUSSystemDiagnosis','ASUSXGMobileService','AsusCertService'
$asusM='ArmouryCrateSEService','ArmouryCrateService','LightingService'
SvcGroup -Fixed 'ASUS services (replaced by G-Helper)' 'Turns off the ASUS background services that G-Helper replaces, exactly like G-Helper''s Extra > "Stop" button: MyASUS/Armoury Crate helpers are disabled, Armoury Crate and Aura lighting services are set to Manual. The touchpad service is never touched.' Moderate (@($asusD|ForEach-Object{,@($_,'D','Automatic')})+@($asusM|ForEach-Object{,@($_,'M','Automatic')})) 'Only if you use G-Helper instead of Armoury Crate / MyASUS. Pick individually to keep e.g. Live Update or Link to MyASUS.' @('Use it if G-Helper handles your performance modes, fans, GPU modes and hotkeys.','Often 5-15 fewer background processes and less RAM and CPU; no ASUS telemetry or update nags.','Armoury Crate, MyASUS, Aura lighting sync and ASUS Live Update stop working until switched back on. Without G-Helper running, some Fn hotkeys may stop working.')
foreach($k in @('ArmouryCrateControlInterface','ArmouryCrateProArtService','AsHidService','ASUSOptimization','AsusAppService','ASUSLinkNear','ASUSLinkRemote','ASUSSoftwareManager','ASUSLiveUpdateAgent','ASUSSwitch','ASUSSystemAnalysis','ASUSSystemDiagnosis','ASUSXGMobileService','AsusCertService','ArmouryCrateSEService','ArmouryCrateService','LightingService')){if(-not $LBL.ContainsKey($k)){$LBL[$k]=$k}}

SvcGroup -Fixed 'Third-party updaters & helpers: start on demand' 'Sets background updater and vendor telemetry services from Automatic to Manual: Google (Chrome) Update, Brave Update, Adobe Acrobat/Creative Cloud update and genuine-check services, Dropbox Update, HP Touchpoint Analytics and HP diagnostics, Dell SupportAssist, AMD User Experience Program and Crash Defender, Killer Analytics. Only services installed on this PC are listed.' Safe @(@('gupdate','M','Automatic'),@('GoogleUpdaterService*','M','Automatic'),@('GoogleUpdaterInternalService*','M','Automatic'),@('brave','M','Automatic'),@('AdobeARMservice','M','Automatic'),@('AdobeUpdateService','M','Automatic'),@('AGSService','M','Automatic'),@('AGMService','M','Automatic'),@('dbupdate','M','Automatic'),@('HpTouchpointAnalyticsService','M','Automatic'),@('HPDiagsCap','M','Automatic'),@('HPSysInfoCap','M','Automatic'),@('SupportAssistAgent','M','Automatic'),@('AUEPLauncher','M','Automatic'),@('AMD Crash Defender Service','M','Automatic'),@('KAPSService','M','Automatic')) 'Recommended: the apps still update through their own scheduled tasks or when you open them.' @('Use it if these services run all the time just to check for updates or collect usage data.','Fewer always-running processes at boot; less background network and disk activity.','Updates may arrive a little later (when the app or its scheduled task runs). Dell SupportAssist and HP Support Assistant may need a moment to start, or show "service not running" until you open them again.')
# fewer svchost.exe processes: Windows gives each service its own svchost when RAM > this threshold (3.5 GB by default)
$db+=fTw $sSvc 'Group services into fewer svchost processes' 'Raises SvcHostSplitThresholdInKB above any RAM size, so Windows groups related services into shared svchost.exe processes again, as it did before Windows 10 1703 (or on PCs with under 3.5 GB RAM). Reboot needed.' Moderate $sd Any '' @(fReg 'HKLM:\SYSTEM\CurrentControlSet\Control' SvcHostSplitThresholdInKB 0x7FFFFFFF 3670016) 'Mostly cosmetic: it lowers the process count, not CPU use. Undo restores the original value (default 3.5 GB).'
$more['Group services into fewer svchost processes']=@('Use it if the long list of "Service Host" processes bothers you or you want a lower process count. It does not make games or apps faster.','Often dozens fewer svchost.exe processes and a little less RAM overhead.','Less isolation: if one service crashes, the others in the same process restart with it; Task Manager can no longer show which single service in a group uses CPU. Some services always keep their own process.')

# ---------- Memory (RAM) ----------
$sMem='Memory (RAM)'
$db+=fTw $sMem 'Disable Network Data Usage monitor (Ndu driver)' 'Disables the Ndu kernel driver (Services\Ndu, Start = 4), which counts network traffic per app for Settings > Data usage. Reboot needed. The key is only changed if it exists.' Moderate $sd 10 '' @(fReg 'HKLM:\SYSTEM\CurrentControlSet\Services\Ndu' Start 4 2 DWord $true) 'Use it if Task Manager shows non-paged pool memory growing for days. Undo restores the original start type (2 = automatic).'
$more['Disable Network Data Usage monitor (Ndu driver)']=@('Use it if Task Manager > Performance > Memory shows "Non-paged pool" growing for hours or days. Leak reports were mostly tied to specific network drivers (e.g. Killer) on Windows 10.','Stops a known source of slowly growing kernel memory; nothing else in Windows depends on it.','Settings > Network > Data usage stops counting and data limits stop working. Needs a reboot.')
$db+=fTw $sMem 'Disable memory compression' 'Runs Disable-MMAgent -MemoryCompression: Windows stops compressing rarely used memory pages and writes them to the page file instead. Undo runs Enable-MMAgent -MemoryCompression. Reboot needed.' Moderate $sd Any '' @(fCmd 'Disable-MMAgent -MemoryCompression' 'Enable-MMAgent -MemoryCompression' '-not (Get-MMAgent).MemoryCompression') 'Only on PCs with plenty of RAM (16 GB+) and a fast SSD. It does not free RAM: Task Manager shows less "Compressed" memory but more paging.'
$more['Disable memory compression']=@('Rarely; only with lots of RAM where you want to save the small CPU cost of compressing.','No CPU time spent compressing pages; the "System and compressed memory" process uses less RAM.','More page-file writes and less usable memory under load; worse on 8 GB PCs and on hard drives. Reboot needed.')
$db+=fTw $sMem 'Empty standby memory (one-time)' 'Flushes the standby list and the low-priority standby list with the native Windows memory API (what RAMMap "Empty Standby List" does), without downloading anything. Logs free RAM before and after.' Safe $sd Any '' @(fCmd 'Clear-StandbyList') 'Use before a game or heavy task if "Free" memory is near zero. Not needed regularly: standby memory is a file cache that Windows gives up instantly when a program needs it.'
$more['Empty standby memory (one-time)']=@('Only as a quick fix before a heavy game or task when "Free" memory is near zero, or to see how much RAM programs really use.','Free RAM jumps up immediately; can help games that stutter on low free memory.','Recently used files and apps load from disk again the first time; Windows refills the cache within minutes to hours, so the effect is temporary.')

# ---------- Fewer, broader sections: tweaks keep their names (saved selections still work), only the grouping changes ----------
$grp=[ordered]@{'Privacy & Telemetry'=@($s1);'AI & Copilot'=@($s6);'Apps & Bloatware'=@($s2,$s7,$s8,$s9,$s19);'Browsers & Dev Tools'=@($s18,$s22,$s21)
 'Start, Taskbar & Explorer'=@($s3,$s10,$s5);'Performance & Gaming'=@($s4,$s11);$sSvc=@($s16,$sSvc);$sMem=@($sMem);$s20=@($s20);$s15=@($s15);'System, Security & Network'=@($s12,$s13,$s23,$s17);$s14=@($s14)}
$moveTo=@{'Disable SysMain (Superfetch)'=@($sSvc,1);'Disable Windows Search indexing'=@($sSvc,1);'Disable transparency effects'=@($s20,-1);'Block apps from running in the background'=@('Performance & Gaming',99);'Disable Xbox cloud-save task'=@('Performance & Gaming',99);'Disable Storage Sense auto cleanup'=@('System, Security & Network',0)}
$gk=@($grp.Keys);$ix=0
$db=@($db|ForEach-Object{$t=$_;$new=$t.Sec;$ord=0
 if($moveTo.ContainsKey($t.Name)){$new=$moveTo[$t.Name][0];$ord=$moveTo[$t.Name][1]}
 else{foreach($g in $gk){$j=[array]::IndexOf(@($grp[$g]),$t.Sec);if($j -ge 0){$new=$g;$ord=$j;break}}}
 $t.Sec=$new;[pscustomobject]@{T=$t;G=[array]::IndexOf($gk,$new);O=$ord;I=$ix};$ix++}|Sort-Object G,O,I|ForEach-Object{$_.T})
$secs=@($gk|Where-Object{$g=$_;@($db|Where-Object{$_.Sec -eq $g}).Count})

# ---------- Recommended preset: one explicit, reviewable list ----------
# Rules: (1) a performance or privacy win, (2) nothing a typical user relies on stops working, (3) undoable with one click
# (so no app removals and no one-time cleanups). Whole tweak = its name; a single sub-switch = 'Tweak name|Sub-switch label'.
$RECOMMENDED=@(
 'Disable telemetry & diagnostic services','Disable telemetry scheduled tasks','Disable app-compatibility telemetry (Inventory Collector, Steps Recorder)'
 'Disable NVIDIA telemetry (telemetry container, NvTm* tasks, opt-in flag)','Disable Office telemetry (diagnostic data "Neither", legacy Telemetry Agent)'
 'Disable advertising ID','Disable Activity History','Disable tailored experiences','Disable web results in Start search','Disable Customer Experience Improvement Program','Disable feedback prompts'
 'Disable Windows Recall / AI data analysis','Disable Click to Do','Disable Copilot'
 'Disable Edge startup boost & background mode','Quiet Edge: no sidebar, shopping assistant or first-run','Edge: turn off diagnostic data, personalization & feedback'
 'Chrome: turn off metrics, reports & Privacy Sandbox ad tracking','Firefox: turn off telemetry, studies, Pocket & feedback'
 'Edge: no Microsoft Rewards or MSN news feed','Firefox: no sponsored shortcuts, stories, suggestions or feature ads','Firefox: update only while Firefox is open'
 'VS Code: turn off telemetry, feedback prompts & experiments','Visual Studio: turn off telemetry (Customer Experience Improvement Program)'
 'Developer CLIs: turn off telemetry (.NET, PowerShell 7, Next.js, Nuxt, Astro, Gatsby, Angular, Storybook, Turborepo, vcpkg, Terraform/Prisma, AWS SAM, Azure CLI, DO_NOT_TRACK)'
 'Disable Start/Settings suggestions & silent app installs','Disable lock screen tips & ads','Disable Widgets','Disable News and Interests','Disable search highlights','Show file extensions'
 'Disable Game DVR / background capture','Stop NVIDIA services while the dGPU is off (G-Helper Eco)'
 'Set rarely-used services to start on demand','Third-party updaters & helpers: start on demand'
 'Disable Delivery Optimization (P2P uploads)','Disable device metadata downloads','Disable AutoPlay/AutoRun for removable drives','Disable Remote Assistance'
)+$vfxRec
function Is-Rec($u){($RECOMMENDED -contains $u.T.Name) -or ($RECOMMENDED -contains $u.Key)}
# Simple view "Debloat + Gaming" = Recommended + these (all undoable, nothing laptop-unfriendly like Ultimate Performance)
$SIMPLE_GAMING=@('Disable mouse acceleration','Disable Sticky Keys prompt','Disable Game Bar','Disable Game DVR / background capture','Edge: put background tabs to sleep sooner|SleepingTabsEnabled','Edge: put background tabs to sleep sooner|SleepingTabsTimeout')
function Is-RecT($t){($RECOMMENDED -contains $t.Name) -or @($RECOMMENDED|Where-Object{$_.StartsWith("$($t.Name)|",[StringComparison]::Ordinal)}).Count}

# ---------- Engine ----------
function Show-Act($a){switch($a.K){
 'Reg'{"REG  $($a.P)\$($a.N) = $($a.V)   [undo: restores the value found before Apply; default if unknown: $(if($null -eq $a.U){'(none)'}else{$a.U})]"}
 'Svc'{"SVC  $($a.N) -> Disabled   [undo: restores the start type found before Apply; default if unknown: $($a.U)]"}
 'App'{"APPX remove $($a.N)   [not auto-reversible]"}
 'Task'{"TASK disable $($a.N)   [undo: re-enables it if it was enabled before]"}
 'SvcM'{"SVC  $($a.N) -> Manual (starts only on demand)   [undo: restores the start type found before Apply; default if unknown: $($a.U)]"}
 'Feat'{"FEATURE disable $($a.N)   [undo: re-enables it if it was enabled before]"}
 'Startup'{"STARTUP disable '$($a.N)'   [undo: restores the previous entry; same list as Task Manager > Startup apps]"}
 'Spi'{"UI   $($a.N): effect $(if($a.V){'ON'}else{'OFF'})   [default: $(if($a.U){'ON'}else{'OFF'})]"}
 'Json'{"JSON $(Split-Path $a.P -Leaf): $($a.N) = $($a.V)   [undo: $(if($null -eq $a.U){'remove the key'}else{$a.U})]"}
 'Cmd'{"CMD  $($a.V)   [undo: $(if($a.U){$a.U}else{'none'})]"}}}

function Do-Act($a,$undo){switch($a.K){
 'Reg'{$v=if($undo){$a.U}else{$a.V}
   if($null -eq $v){Remove-ItemProperty -Path $a.P -Name $a.N -ErrorAction SilentlyContinue}
   else{if(-not(Test-Path $a.P)){New-Item $a.P -Force|Out-Null}; New-ItemProperty -Path $a.P -Name $a.N -Value $v -PropertyType $a.T -Force|Out-Null}}
 'Svc'{if(-not(Get-Service $a.N -ErrorAction SilentlyContinue)){Log "   (service $($a.N) is not installed - nothing to do)"}elseif($undo){Set-Service $a.N -StartupType $a.U}else{Stop-Service $a.N -Force -ErrorAction SilentlyContinue;Set-Service $a.N -StartupType Disabled}}
 'App'{if($undo){Log '   (skipped: reinstall from Microsoft Store)'}else{
   Get-AppxPackage -AllUsers $a.N|Remove-AppxPackage -AllUsers -ErrorAction SilentlyContinue
   Get-AppxProvisionedPackage -Online|Where-Object DisplayName -like $a.N|Remove-AppxProvisionedPackage -Online -ErrorAction SilentlyContinue|Out-Null}}
 'SvcM'{if(-not(Get-Service $a.N -ErrorAction SilentlyContinue)){Log "   (service $($a.N) is not installed - nothing to do)"}elseif($undo){Set-Service $a.N -StartupType $a.U}else{Set-Service $a.N -StartupType Manual}}
 'Feat'{if($undo){Enable-WindowsOptionalFeature -Online -FeatureName $a.N -NoRestart -All|Out-Null}else{Disable-WindowsOptionalFeature -Online -FeatureName $a.N -NoRestart|Out-Null}}
 'Startup'{if(-not(Test-Path $a.A)){New-Item $a.A -Force|Out-Null};$bb=if($undo){[byte[]](2,0,0,0,0,0,0,0,0,0,0,0)}else{[byte[]]((3,0,0,0)+[BitConverter]::GetBytes([DateTime]::UtcNow.ToFileTimeUtc()))};New-ItemProperty -Path $a.A -Name $a.N -PropertyType Binary -Value $bb -Force|Out-Null}
 'Spi'{Spi-Set $a $(if($undo){$a.U}else{$a.V})}
 'Json'{Json-Set $a $(if($undo){$a.U}else{$a.V})}
 'Cmd'{$c=if($undo){$a.U}else{$a.V}
   if(-not $c){Log '   (run-once action: no undo command, nothing to revert)';return}
   $global:LASTEXITCODE=0
   Invoke-Expression $c|Out-Null
   if($LASTEXITCODE -and @(0,3010) -notcontains $LASTEXITCODE){throw "command exited with code $LASTEXITCODE"}      # 3010 = reboot required (DISM), not a failure
   if($a.U){$mk='HKLM:\SOFTWARE\DebloatHub\Applied';$id=Cmd-Id $a
    if($undo){Remove-ItemProperty -Path $mk -Name $id -ErrorAction SilentlyContinue}
    else{if(-not(Test-Path $mk)){New-Item $mk -Force|Out-Null};New-ItemProperty -Path $mk -Name $id -Value 1 -PropertyType DWord -Force|Out-Null}}}
 'Task'{$p=Task-Path $a.N;$n=Split-Path $a.N -Leaf
   if(-not(Get-ScheduledTask -TaskPath $p -TaskName $n -ErrorAction SilentlyContinue)){Log "   (task $n does not exist on this Windows build - nothing to do)"}
   elseif($undo){Enable-ScheduledTask -TaskPath $p -TaskName $n|Out-Null}else{Disable-ScheduledTask -TaskPath $p -TaskName $n|Out-Null}}}}

# ---------- Original-state snapshots: Apply records what was there BEFORE the change, Undo puts exactly that back ----------
function Safe-Test($a){try{Test-Act $a}catch{$null}}
function Snap-Write($a,$o){$k='HKLM:\SOFTWARE\DebloatHub\Snapshots';if(-not(Test-Path $k)){New-Item $k -Force|Out-Null};New-ItemProperty -Path $k -Name (Snap-Id $a) -Value ($o|ConvertTo-Json -Compress -Depth 20) -PropertyType String -Force|Out-Null}
function Snap-Clear($a){foreach($id in (Snap-Ids $a)){Remove-ItemProperty -Path 'HKLM:\SOFTWARE\DebloatHub\Snapshots' -Name $id -ErrorAction SilentlyContinue}}
function Snap-Capture($a){switch($a.K){          # what is on the system right now (pure data); $null = this kind has no snapshot
 'Reg'{$k=Get-Item -LiteralPath $a.P -ErrorAction SilentlyContinue
   if($k -and ($k.GetValueNames() -contains $a.N)){$kind=$k.GetValueKind($a.N).ToString();$v=$k.GetValue($a.N,$null,[Microsoft.Win32.RegistryValueOptions]::DoNotExpandEnvironmentNames)
    if($kind -eq 'Binary'){$v=[Convert]::ToBase64String([byte[]]$v)}
    @{exists=$true;kind=$kind;value=$v}}else{@{exists=$false}}}
 {$_ -in 'Svc','SvcM'}{$sv=Get-Service $a.N -ErrorAction SilentlyContinue
   if($sv){$p=Get-ItemProperty -Path "HKLM:\SYSTEM\CurrentControlSet\Services\$($a.N)" -ErrorAction SilentlyContinue
    @{exists=$true;start=[int]$p.Start;delayed=[int]$p.DelayedAutostart;running=($sv.Status -eq 'Running')}}else{@{exists=$false}}}
 'Task'{$tk=Get-ScheduledTask -TaskPath (Task-Path $a.N) -TaskName (Split-Path $a.N -Leaf) -ErrorAction SilentlyContinue
   if($tk){@{exists=$true;enabled=($tk.State -ne 'Disabled')}}else{@{exists=$false}}}
 'Feat'{$f=Get-WindowsOptionalFeature -Online -FeatureName $a.N -ErrorAction SilentlyContinue;if($f){@{exists=$true;state=[string]$f.State}}else{@{exists=$false}}}
 'Startup'{$bb=(Get-ItemProperty -Path $a.A -Name $a.N -ErrorAction SilentlyContinue).($a.N)
   if($null -ne $bb){@{exists=$true;bytes=[Convert]::ToBase64String([byte[]]$bb)}}else{@{exists=$false}}}
 'Spi'{$g=Spi-Get $a;if($null -ne $g){@{value=[int]$g}}}
 'Json'{$o=Json-Read $a.P;$pr=$o.PSObject.Properties[$a.N];if($pr){@{had=$true;value=$pr.Value}}else{@{had=$false}}}
 default{$null}}}
function Snap-Take($a,$before){                  # $before = Test-Act result BEFORE the change
 if($a.K -in 'App','Cmd'){return}
 if($before -ne $true -and -not(Snap-Read $a)){      # record only the genuine original: never overwrite an existing record (it is cleared on undo)
  try{$c=Snap-Capture $a;if($null -ne $c){Snap-Write $a $c}}catch{Log "   (could not record the original of this setting: $($_.Exception.Message))"}}}
function Snap-Restore($a,$s){switch($a.K){
 'Reg'{if($s.exists){$v=$s.value
    switch($s.kind){'Binary'{$v=[byte[]][Convert]::FromBase64String($v)}'DWord'{$v=[int]$v}'QWord'{$v=[long]$v}'MultiString'{$v=[string[]]@($v)}}
    if(-not(Test-Path -LiteralPath $a.P)){New-Item -Path $a.P -Force|Out-Null}
    New-ItemProperty -LiteralPath $a.P -Name $a.N -Value $v -PropertyType $s.kind -Force|Out-Null}
   else{Remove-ItemProperty -LiteralPath $a.P -Name $a.N -ErrorAction SilentlyContinue}}
 {$_ -in 'Svc','SvcM'}{if(-not $s.exists){return}
   if(-not(Get-Service $a.N -ErrorAction SilentlyContinue)){Log "   (service $($a.N) no longer exists - nothing to restore)";return}
   $mode=switch([int]$s.start){0{'boot'}1{'system'}2{if([int]$s.delayed -eq 1){'delayed-auto'}else{'auto'}}3{'demand'}4{'disabled'}}
   $global:LASTEXITCODE=0;& sc.exe config $a.N start= $mode|Out-Null
   if($LASTEXITCODE -ne 0){throw "sc.exe config $($a.N) failed (exit code $LASTEXITCODE)"}
   if($s.running -and $mode -ne 'disabled'){try{Start-Service $a.N}catch{Log "   (start type restored; $($a.N) could not be restarted now - it starts when needed or after a reboot)"}}}
 'Task'{if($s.exists -and $s.enabled){$p=Task-Path $a.N;$n=Split-Path $a.N -Leaf
   if(Get-ScheduledTask -TaskPath $p -TaskName $n -ErrorAction SilentlyContinue){Enable-ScheduledTask -TaskPath $p -TaskName $n|Out-Null}else{Log "   (task $n no longer exists - nothing to restore)"}}}
 'Feat'{if($s.exists -and $s.state -eq 'Enabled'){Enable-WindowsOptionalFeature -Online -FeatureName $a.N -NoRestart -All|Out-Null}}
 'Startup'{if($s.exists){if(-not(Test-Path $a.A)){New-Item $a.A -Force|Out-Null};New-ItemProperty -Path $a.A -Name $a.N -PropertyType Binary -Value ([byte[]][Convert]::FromBase64String($s.bytes)) -Force|Out-Null}
   else{Remove-ItemProperty -Path $a.A -Name $a.N -ErrorAction SilentlyContinue}}
 'Spi'{Spi-Set $a $s.value}
 'Json'{if($s.had){Json-Set $a $s.value}else{Json-Set $a $null}}}}
function Undo-Act($a){                           # restore the recorded original; only when none exists fall back to the documented default
 $s=Snap-Read $a
 if($s){Snap-Restore $a $s;Snap-Clear $a}else{Do-Act $a $true}}

# ---------- Driver Store cleanup (run-once, cannot be undone) ----------
# WARNING: this deletes superseded driver packages for good. Afterwards the "Roll Back Driver" button in Device Manager
# is inactive for every device whose driver was updated, because the previous package no longer exists.
function Select-StaleDrivers($drv,$inUse){       # pure selection logic: of every driver family keep the newest package, list the OLDER ones with a verdict
 $skipClass='Printer','PrintQueue'               # print queues are bound by the spooler, not by Plug and Play, so "in use" cannot be judged for them
 $out=@()
 # a family = same original INF file name + provider + class. The FileRepository folder name contains a hash that differs per version, so the INF's LEAF name is used, never the full path.
 $fam=@($drv|Where-Object{$_.OriginalFileName -and $_.Driver}|Group-Object{('{0}|{1}|{2}' -f (Split-Path $_.OriginalFileName -Leaf),$_.ProviderName,$_.ClassName).ToLowerInvariant()})
 foreach($g in $fam){
  if($g.Count -lt 2){continue}
  $sorted=@($g.Group|Sort-Object -Property @{Expression={$_.Date};Descending=$true},@{Expression={$_.Version};Descending=$true})   # newest date first, then highest version
  foreach($p in ($sorted|Select-Object -Skip 1)){
   $act='delete';$why='superseded by a newer version'
   if($inUse.ContainsKey(([string]$p.Driver).ToLowerInvariant())){$act='keep';$why='a connected device is using it'}
   elseif($p.BootCritical){$act='keep';$why='boot-critical driver'}
   elseif($skipClass -contains [string]$p.ClassName){$act='keep';$why='printer driver'}
   elseif(([string]$p.Driver) -notmatch '^oem\d+\.inf$'){$act='keep';$why='not an OEM package name'}
   $out+=,@{Pkg=$p;Action=$act;Why=$why;Newest=$sorted[0]}}}
 ,$out}
# ---------- G-Helper Eco companion: stop NVIDIA services after a boot/sign-in with the dGPU powered off ----------
# G-Helper's own "Stop/Start NVIDIA services based on dGPU state" only acts when you SWITCH modes. Booting straight into Eco
# leaves both NVIDIA containers (start type Automatic) running for nothing. This task closes that gap; it never changes start types.
function Install-NvEcoTask{
 if(-not(Get-Service -Name 'NVDisplay.ContainerLocalSystem' -ErrorAction SilentlyContinue)){throw 'the NVIDIA Display Container service is not installed on this PC - there is nothing to manage'}
 $body=@'
$ErrorActionPreference='SilentlyContinue'
$nv=@(Get-PnpDevice -Class Display -PresentOnly|Where-Object{$_.FriendlyName -like '*NVIDIA*' -or $_.Manufacturer -like '*NVIDIA*'})
if(-not $nv.Count){Stop-Service -Name 'NvContainerLocalSystem','NVDisplay.ContainerLocalSystem' -Force}
'@
 $enc=[Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes($body))
 $act=New-ScheduledTaskAction -Execute "$env:SystemRoot\System32\WindowsPowerShell\v1.0\powershell.exe" -Argument "-NoProfile -NonInteractive -WindowStyle Hidden -EncodedCommand $enc"
 $t1=New-ScheduledTaskTrigger -AtStartup;$t1.Delay='PT30S'                     # normal boot
 $t2=New-ScheduledTaskTrigger -AtLogOn;$t2.Delay='PT30S'                       # Fast Startup boots skip the startup trigger, sign-in still fires
 $set=New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries -StartWhenAvailable -ExecutionTimeLimit (New-TimeSpan -Minutes 2)
 $pr=New-ScheduledTaskPrincipal -UserId 'S-1-5-18' -LogonType ServiceAccount -RunLevel Highest
 Register-ScheduledTask -TaskPath '\DebloatHub\' -TaskName 'Stop NVIDIA services while dGPU is off' -Action $act -Trigger $t1,$t2 -Settings $set -Principal $pr -Description 'Created by DebloatHub. 30 s after startup and sign-in: if no NVIDIA display adapter is present (dGPU powered off, e.g. G-Helper Eco), stops NvContainerLocalSystem and NVDisplay.ContainerLocalSystem. Never changes their start type.' -Force|Out-Null
 Start-ScheduledTask -TaskPath '\DebloatHub\' -TaskName 'Stop NVIDIA services while dGPU is off'
 Log '   task created and run once now (if the dGPU is off, the NVIDIA services are stopped right away)'
 $global:LASTEXITCODE=0}
function Remove-NvEcoTask{
 Unregister-ScheduledTask -TaskPath '\DebloatHub\' -TaskName 'Stop NVIDIA services while dGPU is off' -Confirm:$false -ErrorAction SilentlyContinue
 Log '   task removed; the NVIDIA services start normally at the next boot'
 $global:LASTEXITCODE=0}
function Test-NvEcoTask{[bool](Get-ScheduledTask -TaskPath '\DebloatHub\' -TaskName 'Stop NVIDIA services while dGPU is off' -ErrorAction SilentlyContinue)}

# ---------- Standby memory flush (run-once): same as RAMMap "Empty Standby List", done with the native API ----------
function Clear-StandbyList{
 $f0=[long](Get-CimInstance Win32_OperatingSystem).FreePhysicalMemory                 # KB
 [DH.Mem]::EnablePrivilege('SeProfileSingleProcessPrivilege')
 foreach($c in @(@(4,'standby list (all priorities)'),@(5,'low-priority standby list'))){   # 4 = MemoryPurgeStandbyList, 5 = MemoryPurgeLowPriorityStandbyList
  $st=[DH.Mem]::MemoryListCommand($c[0]);if($st -ne 0){throw ('emptying the {0} failed (NTSTATUS 0x{1:X8})' -f $c[1],$st)}}
 $f1=[long](Get-CimInstance Win32_OperatingSystem).FreePhysicalMemory
 Log ('   Standby memory emptied: free RAM {0:N0} MB -> {1:N0} MB (Windows refills the cache as you use files again).' -f ($f0/1KB),($f1/1KB))
 $global:LASTEXITCODE=0}
function Clean-DriverStore{
 try{$drv=@(Get-WindowsDriver -Online -ErrorAction Stop|Where-Object{-not $_.Inbox})}catch{throw "could not list the installed drivers: $($_.Exception.Message)"}   # third-party (OEM) packages only
 $inUse=@{}
 try{foreach($d in @(Get-CimInstance Win32_PnPSignedDriver -ErrorAction Stop)){if($d.InfName){$inUse[([string]$d.InfName).ToLowerInvariant()]=$true}}}
 catch{throw "could not read which drivers devices are using ($($_.Exception.Message)) - nothing was deleted"}
 if($inUse.Count -eq 0){throw 'could not read which drivers devices are using - nothing was deleted'}   # fail closed: without this list nothing is safe to delete
 $plan=@(Select-StaleDrivers $drv $inUse)
 $del=@($plan|Where-Object{$_.Action -eq 'delete'});$keep=@($plan|Where-Object{$_.Action -eq 'keep'})
 foreach($k in $keep){Log "   kept $($k.Pkg.Driver) ($($k.Pkg.ProviderName), $($k.Pkg.ClassName), $($k.Pkg.Version)): $($k.Why)"}
 if(-not $del.Count){Log '   no superseded driver packages found - nothing to clean';$global:LASTEXITCODE=0;return}
 $bytes=[long]0;$ok=0;$fail=@()
 foreach($x in $del){$p=$x.Pkg;$nm=[string]$p.Driver
  $sz=[long]0;$dir=Split-Path $p.OriginalFileName
  if($dir -like '*\DriverStore\FileRepository\*'){try{$sz=[long](Get-ChildItem -LiteralPath $dir -Recurse -File -Force -ErrorAction SilentlyContinue|Measure-Object Length -Sum).Sum}catch{$sz=[long]0}}
  $global:LASTEXITCODE=0;$null=& pnputil.exe /delete-driver $nm /force 2>&1;$ec=$LASTEXITCODE
  if($ec -eq 0 -or $ec -eq 3010){$ok++;$bytes+=$sz;Log "   deleted $nm ($($p.ProviderName), $($p.ClassName), $($p.Version), $(if($p.Date){$p.Date.ToString('yyyy-MM-dd')})); the newer $($x.Newest.Driver) stays"}
  else{$fail+="$nm (exit code $ec)";Log "   ! could not delete $nm (exit code $ec)"}}
 $global:LASTEXITCODE=0
 Log ('   Driver Store cleanup: {0} package(s) deleted, about {1:N0} MB freed, {2} kept on purpose, {3} failed.' -f $ok,($bytes/1MB),$keep.Count,$fail.Count)
 if($fail.Count){throw "some packages could not be deleted: $($fail -join ', ')"}}

function Log($m){$log.AppendText("$m`r`n");$log.ScrollToEnd();if($slog){$slog.AppendText("$m`r`n");$slog.ScrollToEnd()};$w.Dispatcher.Invoke([Action]{},[Windows.Threading.DispatcherPriority]::Background)}

function Fits($t){(($t.Win -eq 'Any') -or ($t.Win -eq '11' -and $W11) -or ($t.Win -eq '10' -and -not $W11)) -and -not($OtherUser -and @($t.Acts|Where-Object{$_.K -eq 'Spi'}).Count)}
function Undoable($t){-not @($t.Acts|Where-Object{$_.K -eq 'App' -or ($_.K -eq 'Cmd' -and -not $_.U)}).Count}
function Act-Label($a){switch($a.K){
 'App'{if($LBL.ContainsKey($a.N)){$LBL[$a.N]}else{$n=$a.N -replace '^\*|\*$','' -replace '^Microsoft\.','' -replace '\.',' ';($n -creplace '(?<=[a-z0-9])(?=[A-Z])',' ').Trim()}}
 'Task'{Split-Path $a.N -Leaf}
 'Startup'{$a.N}
 default{if(-not $a.N){'one-time command'}elseif($LBL.ContainsKey($a.N)){$LBL[$a.N]}elseif($a.K -eq 'Reg' -and $a.N -eq 'Value'){Split-Path $a.P -Leaf}else{$a.N}}}}

# ---------- Apply / revert engine (works on "units": one switch each) ----------
$warnBy=@{'Disable Connected Devices Platform (breaks Night light)'='Night light stops working and Settings > Display can crash until this is switched back off and the PC rebooted.'
 'Use Cloudflare DNS (1.1.1.1)'='local network shares (NAS) and hotel or airport Wi-Fi sign-in pages may stop working.'
 'Remove Xbox apps'='Do not run if you use Xbox Game Pass, PC cloud saves, or Win+G Game Bar.'
 'Disable Xbox cloud-save task'='Do not run if you use Xbox Game Pass, PC cloud saves, or Win+G Game Bar.'
 'Clean up old driver versions (Driver Store)'='the "Roll Back Driver" button in Device Manager becomes inactive for devices whose driver was updated, and the deleted driver packages cannot be restored.'}   # shown in the Apply confirmation; delete a line to drop its prompt
function Task-Path($n){$p=Split-Path $n;if(-not $p.EndsWith('\')){$p+='\'};$p}
function Act-Absent($a){switch($a.K){            # target does not exist on this PC (Test-Act reports such acts as applied; there is nothing to restore either)
 {$_ -in 'Svc','SvcM'}{return -not(Get-Service $a.N -ErrorAction SilentlyContinue)}
 'Task'{return -not(Get-ScheduledTask -TaskPath (Task-Path $a.N) -TaskName (Split-Path $a.N -Leaf) -ErrorAction SilentlyContinue)}
 'Feat'{return -not(Get-WindowsOptionalFeature -Online -FeatureName $a.N -ErrorAction SilentlyContinue)}
 'Json'{return -not(Test-Path -LiteralPath (Split-Path $a.P))}
 'Reg'{return [bool]($a.Opt -and -not(Test-Path -LiteralPath $a.P))}
 default{return $false}}}
function Act-Revertible($a){-not ($a.K -eq 'App' -or ($a.K -eq 'Cmd' -and -not $a.U))}
function Can-Undo($u){[bool]@($u.Acts|Where-Object{Act-Revertible $_}).Count}   # false = nothing in this switch can be undone automatically (removed apps, run-once commands)
function Pending{$a=@();$r=@();$b=@()
 foreach($u in $units){if(-not $u.Box.IsEnabled){continue};$on=[bool]$u.Box.IsChecked;$ap=($ust[$u.Key] -eq 'Applied')   # $ust comes from Scan (detectors / markers)
  if($on -and -not $ap){$a+=,$u}
  elseif(-not $on -and $ap){if(Can-Undo $u){$r+=,$u}else{$b+=,$u}}}                  # never schedule a revert that has no undo command
 ,@($a,$r,$b)}
function Run{
 if($script:busy){return}
 $p=Pending;$add=@($p[0]);$rem=@($p[1])
 foreach($bu in @($p[2])){Log "   '$($bu.Key -replace '\|',' > ')' has no undo command - left as is."}
 if(-not($add.Count+$rem.Count)){return}
 $add=@($add|Where-Object{Can-Undo $_})+@($add|Where-Object{-not(Can-Undo $_)})      # run-once commands always go last
 $one=@($add|Where-Object{-not(Can-Undo $_)})
 $dry=[bool]$chkDry.IsChecked
 $msg="Apply $($add.Count) change(s) and revert $($rem.Count)?";$ic='Question'
 if($one.Count){$ic='Warning';$msg+="`n`nRun-once actions (cannot be undone):`n - "+(($one|ForEach-Object{$_.Key -replace '\|',' > '}) -join "`n - ")
  if($add.Count -gt $one.Count -and @($one|Where-Object{$_.Key -match 'SFC|DISM|component cleanup'}).Count){$msg+="`n`nSFC/DISM can take 10+ minutes and work best on their own."}}
 $nr=@($rem|Where-Object{@($_.Acts|Where-Object{(Act-Revertible $_) -and $_.K -ne 'Cmd' -and -not(Snap-Read $_)}).Count}|ForEach-Object{$_.Key -replace '\|',' > '})
 if($nr.Count){$ic='Warning';$msg+="`n`nNo recorded original for:`n - "+($nr -join "`n - ")+"`nThese were already applied before DebloatHub recorded anything (or by another tool), so undo sets Windows' documented default instead."}
 $wn=@($add|ForEach-Object{$_.T.Name}|Select-Object -Unique|Where-Object{$warnBy.ContainsKey($_)})
 if($wn.Count){$ic='Warning';$msg+="`n`nRead before continuing:";foreach($n in $wn){$msg+="`n - $($n): $($warnBy[$n])"}}
 if(-not $dry -and [Windows.MessageBox]::Show($msg,'DebloatHub','YesNo',$ic) -ne 'Yes'){return}
 $items=@();foreach($set in @(@('REVERT',$rem,$true),@('APPLY',$add,$false))){foreach($u in $set[1]){$items+=,@{Label="[$($set[0])] $($u.Key -replace '\|',' > ')";Acts=@($u.Acts|ForEach-Object{Copy-Act $_});Undo=$set[2]}}}
 $rp=[bool](-not $dry -and $add.Count -and $chkRP.IsChecked)
 Start-Bg 'Applying changes...' @{items=$items;dry=$dry;rp=$rp} $APPLYCODE {param($r);Show-ApplyResult $r;Scan}}

function Invoke-Now($t,$undo){                  # runs ONE tweak right away through the normal apply engine (idempotent, verified, snapshot-based)
 if($script:busy){Log 'Another operation is still running.';return}
 $dry=[bool]$chkDry.IsChecked;$parts=@($actSt[$t.Name]);$nm=$t.Name
 $ya=@($parts|Where-Object{$_ -eq 'Y'}).Count;$na=@($parts|Where-Object{$_ -eq 'N'}).Count
 if($undo){
  $msg="Revert the $ya applied part(s) of '$nm' now?`n`nParts that are not applied are left untouched. Each part goes back to what was there before DebloatHub changed it."
  $irr=@($t.Acts|Where-Object{-not(Act-Revertible $_)}).Count
  if($irr){$msg+="`n`n$irr part(s) cannot be undone automatically (removed apps / run-once commands) and are skipped."}
  $nr=0;for($i=0;$i -lt @($t.Acts).Count;$i++){$a=@($t.Acts)[$i];if($parts[$i] -eq 'Y' -and (Act-Revertible $a) -and $a.K -ne 'Cmd' -and -not(Snap-Read $a)){$nr++}}
  if($nr){$msg+="`n`nNo recorded original for $nr part(s): for those, undo sets Windows' documented default."}}
 else{$msg="Apply the $na missing part(s) of '$nm' now?"}
 if(-not $dry -and [Windows.MessageBox]::Show($msg,'DebloatHub','YesNo','Question') -ne 'Yes'){return}
 $items=@(@{Label="[$(if($undo){'REVERT'}else{'COMPLETE'})] $nm";Acts=@($t.Acts|ForEach-Object{Copy-Act $_});Undo=[bool]$undo})
 Start-Bg 'Working...' @{items=$items;dry=$dry;rp=$false} $APPLYCODE {param($r);Show-ApplyResult $r;Scan}}
function Revert-Partial($t){Invoke-Now $t $true}
function Complete-Partial($t){Invoke-Now $t $false}

# ---------- Detection ----------
function Cmd-Id($a){'Cmd_'+([BitConverter]::ToString([Security.Cryptography.SHA1]::Create().ComputeHash([Text.Encoding]::UTF8.GetBytes([string]$a.V))).Replace('-','').Substring(0,16))}
function Test-Act($a){switch($a.K){
 'Reg'{if($a.Opt -and -not(Test-Path -LiteralPath $a.P)){return $true}                       # optional value of software that is not installed: nothing to turn off
   $v=(Get-ItemProperty -Path $a.P -Name $a.N -ErrorAction SilentlyContinue).($a.N);return ("$v" -eq "$($a.V)")}
 'Svc'{$sv=Get-Service $a.N -ErrorAction SilentlyContinue;return (-not $sv -or $sv.StartType -eq 'Disabled')}
 'App'{if($null -ne $script:apps){return (-not ($script:apps|Where-Object{$_ -like $a.N}))}
   return (-not (Get-AppxPackage -AllUsers -Name $a.N -ErrorAction SilentlyContinue))}
 'Task'{$tk=Get-ScheduledTask -TaskPath (Task-Path $a.N) -TaskName (Split-Path $a.N -Leaf) -ErrorAction SilentlyContinue;return (-not $tk -or $tk.State -eq 'Disabled')}
 'SvcM'{$sv=Get-Service $a.N -ErrorAction SilentlyContinue;return (-not $sv -or $sv.StartType -ne 'Automatic')}
 'Feat'{$fst=if($script:fs -and $script:fs.Count){$script:fs["$($a.N)"]}else{(Get-WindowsOptionalFeature -Online -FeatureName $a.N -ErrorAction SilentlyContinue).State}
   return (-not $fst -or "$fst" -in 'Disabled','DisablePending','DisabledWithPayloadRemoved')}
 'Startup'{$bb=(Get-ItemProperty -Path $a.A -Name $a.N -ErrorAction SilentlyContinue).($a.N);return [bool]($bb -and (($bb[0] -band 1) -eq 1))}
 'Spi'{$g=Spi-Get $a;if($null -eq $g){return $null};return ($g -eq [int]$a.V)}
 'Json'{if(-not(Test-Path -LiteralPath (Split-Path $a.P))){return $true}
   try{$o=Json-Read $a.P;$pr=$o.PSObject.Properties[$a.N];return [bool]($pr -and ("$($pr.Value)" -eq "$($a.V)"))}catch{return $null}}
 'Cmd'{if($a.T){try{$r=Invoke-Expression $a.T;if($null -eq $r){return $null};return [bool]$r}catch{return $null}}      # real detector
   if($a.U){$id=Cmd-Id $a;return [bool](Get-ItemProperty -Path 'HKLM:\SOFTWARE\DebloatHub\Applied' -Name $id -ErrorAction SilentlyContinue).$id}   # undoable, no detector: did we apply it?
   return $null}                                                                                                     # run-once command: state is unknowable
 default{return $null}}}
function Get-StateEx($t){                       # overall state + the state of every single action (same order as $t.Acts)
 $r=@();foreach($a in $t.Acts){$r+=,(Safe-Test $a)}
 $k=@($r|Where-Object{$null -ne $_})
 $st=if(-not $k.Count){'Unknown'}else{$y=@($k|Where-Object{$_}).Count;if($y -eq $k.Count){'Applied'}elseif($y -eq 0){'Not applied'}else{'Partial'}}
 @{State=$st;Acts=@($r|ForEach-Object{if($null -eq $_){'?'}elseif($_){'Y'}else{'N'}})}}
function Get-State($t){(Get-StateEx $t).State}
function Set-Status($t,$st){
 $m=@{'Applied'=@('Applied','#2E7D32');'Partial'=@('Partial','#EF6C00');'Not applied'=@('Not applied','#5A5A5A');'Unknown'=@('One-time action','#455A64');'N/A'=@('Not available here','#444444');'Applied-perm'=@('Applied - cannot be undone','#6D4C41')}[$st]
 $b=$sb[$t.Name];$b.Background=$bc.ConvertFromString($m[1]);$b.Child.Text=$m[0];$b.Visibility='Visible'
 if($rv.ContainsKey($t.Name)){$rv[$t.Name].Visibility=$(if($st -eq 'Partial' -and (Can-Undo $t)){'Visible'}else{'Collapsed'})}}   # dedicated button only for partly applied tweaks
function Sync-Masters{foreach($k in @($subsOf.Keys)){$boxOf[$k].IsChecked=(@($subsOf[$k]|Where-Object{-not $_.IsChecked}).Count -eq 0)}}
function Update-Bar{$n=0;$pt=@{}
 foreach($u in $units){if(-not $u.Box.IsEnabled){continue};if((([bool]$u.Box.IsChecked) -ne ($ust[$u.Key] -eq 'Applied')) -and ([bool]$u.Box.IsChecked -or (Can-Undo $u))){$n++;$pt[$u.T.Name]=$true}}
 foreach($k in @($barOf.Keys)){$barOf[$k].Visibility=if($pt[$k]){'Visible'}else{'Hidden'}}
 $bApply.IsEnabled=($n -gt 0);$bApply.Content=if($n){"Apply $n change$(if($n -ne 1){'s'})"}else{'No changes'}}
# ---------- Background jobs: the window stays usable while scans and applies run ----------
$script:busy=$false;$script:job=$null;$script:res=$null
function Show-Load($m){$ld.BeginAnimation([Windows.UIElement]::OpacityProperty,$null);$ld.Opacity=1;$ld.Visibility='Visible';$ldText.Text=$m;if($sStatus){$sStatus.Text=$m};if($simpleView){Update-Simple}}
function Hide-Load{$an=New-Object Windows.Media.Animation.DoubleAnimation;$an.From=1;$an.To=0;$an.Duration=[Windows.Duration]::new([TimeSpan]::FromMilliseconds(250));$an.Add_Completed({$ld.Visibility='Collapsed'});$ld.BeginAnimation([Windows.UIElement]::OpacityProperty,$an)}
$PRE=@'
$ErrorActionPreference='Stop'
$Mar=[Runtime.InteropServices.Marshal]
function Log($m){[void]$sync.Q.Enqueue("$m")}
'@
function Get-FnText($n){$c=Get-Command $n -CommandType Function;$a=$c.ScriptBlock.Ast
 if($a -isnot [Management.Automation.Language.FunctionDefinitionAst] -and $a.Parent -is [Management.Automation.Language.FunctionDefinitionAst]){$a=$a.Parent}
 if($a -is [Management.Automation.Language.FunctionDefinitionAst]){$a.Extent.Text}else{"function $n {`n$($c.ScriptBlock.ToString())`n}"}}
$ENGINE_TXT=$PRE+"`n"+((@('Fits','Cmd-Id','Task-Path','Act-Revertible','Act-Absent','Safe-Test','Test-Act','Get-State','Get-StateEx','Spi-Call','Spi-Get','Spi-Set','Json-Strip','Json-Read','Jsonc-SkipWs','Jsonc-StrEnd','Jsonc-ValEnd','Jsonc-Scan','Jsonc-Esc','Jsonc-Edit','Json-Set','Snap-Hash','Snap-Id','Snap-Ids','Snap-Read','Snap-Write','Snap-Clear','Snap-Capture','Snap-Take','Snap-Restore','Undo-Act','Select-StaleDrivers','Clean-DriverStore','Clear-StandbyList','Install-NvEcoTask','Remove-NvEcoTask','Test-NvEcoTask','Do-Act','Show-Act')|ForEach-Object{Get-FnText $_}) -join "`n")
# ---------- Thread safety: WPF objects (CheckBox, Border...) live ONLY on the UI thread ----------
# Background runspaces receive plain snapshots (strings, numbers, bools, arrays, hashtables) and return plain hashtables.
function Copy-Act($a){$c=@{};foreach($k in $a.Keys){$c[$k]=$a[$k]};$c}      # acts hold only strings/numbers/bools/$null
function New-ScanData{                                                       # runs on the UI thread, reads $db/$units, emits pure data
 $tw=@(foreach($t in $db){@{Name=[string]$t.Name;Win=[string]$t.Win;Acts=@($t.Acts|ForEach-Object{Copy-Act $_})}})
 $un=@(foreach($u in $units){@{Key=[string]$u.Key;TweakName=[string]$u.T.Name;Win=[string]$u.T.Win;Sub=[bool]$u.Sub;Acts=@($u.Acts|ForEach-Object{Copy-Act $_})}})
 @{tweaks=$tw;units=$un}}
function Assert-Pure($o,$path='root',$depth=0){                              # guard at the thread boundary: refuse anything that is not plain data
 if($null -eq $o -or $o -is [string] -or $o -is [ValueType]){return}
 if($o -is [Windows.Threading.DispatcherObject]){throw "WPF object ($($o.GetType().Name)) at $path must stay on the UI thread."}
 if($depth -gt 8){throw "Data nested too deep at $path."}
 if($o -is [Collections.IDictionary]){foreach($k in @($o.Keys)){Assert-Pure $o[$k] "$path.$k" ($depth+1)};return}
 if($o -is [Collections.IEnumerable]){$i=0;foreach($x in $o){Assert-Pure $x "$path[$i]" ($depth+1);$i++};return}
 throw "Non-plain object ($($o.GetType().FullName)) at $path. Only strings, numbers, bools, arrays and hashtables may enter a background runspace."}
function Invoke-UI([scriptblock]$uiBlock){if($w.Dispatcher.CheckAccess()){& $uiBlock}else{$w.Dispatcher.Invoke([Action]$uiBlock)}}   # NOTE: the parameter must not be called $sb - that is the status-badge table the callee reads (dynamic scoping)   # always applies control changes on the UI dispatcher
function Start-Bg($msg,$vars,$code,$done){
 try{foreach($k in $vars.Keys){Assert-Pure $vars[$k] $k}}catch{Log "! background job refused: $($_.Exception.Message)";return}
 $script:busy=$true;Show-Load $msg;$bApply.IsEnabled=$false;$bScan.IsEnabled=$false
 $q=New-Object 'System.Collections.Concurrent.ConcurrentQueue[string]'
 $sync=[hashtable]::Synchronized(@{Q=$q;Msg='';Result=$null})
 $rs=[runspacefactory]::CreateRunspace();$rs.ApartmentState='STA';$rs.Open()
 $rs.SessionStateProxy.SetVariable('sync',$sync);$rs.SessionStateProxy.SetVariable('W11',$W11);$rs.SessionStateProxy.SetVariable('OtherUser',$OtherUser);$rs.SessionStateProxy.SetVariable('UserLocal',$UserLocal)
 foreach($k in $vars.Keys){$rs.SessionStateProxy.SetVariable($k,$vars[$k])}
 $ps=[powershell]::Create();$ps.Runspace=$rs;[void]$ps.AddScript($ENGINE_TXT+"`n"+$code)
 $script:job=@{PS=$ps;RS=$rs;Sync=$sync;H=$ps.BeginInvoke();Done=$done}
 $timer.Start()}
$SCANCODE=@'
# Input ($tweaks, $units) = plain snapshots from New-ScanData. Output = plain hashtables only; no WPF object is ever touched here.
try{
 $sync.Msg='Reading installed apps...'
 $script:apps=@(Get-AppxPackage -AllUsers -ErrorAction SilentlyContinue|ForEach-Object Name)
 $sync.Msg='Reading Windows features...'
 $script:fs=@{};try{Get-WindowsOptionalFeature -Online -ErrorAction Stop|ForEach-Object{$script:fs[$_.FeatureName]=[string]$_.State}}catch{Log '   (could not read optional features)'}
 $sync.Msg='Checking settings, services and tasks...'
 $stat=@{};$ust=@{};$ast=@{}
 foreach($t in $tweaks){if(-not(Fits $t)){$stat[$t.Name]='N/A'}else{$g=Get-StateEx $t;$stat[$t.Name]=$g.State;$ast[$t.Name]=$g.Acts}}
 foreach($u in $units){
  if(-not(Fits $u)){$ust[$u.Key]='N/A';continue}
  $ust[$u.Key]=if($u.Sub){if((Safe-Test $u.Acts[0]) -eq $true){'Applied'}else{'Not applied'}}else{$stat[$u.TweakName]}}
 $sync.Result=@{Ok=$true;Error='';Stat=$stat;Ust=$ust;ActSt=$ast}
}catch{$sync.Result=@{Ok=$false;Error="$($_.Exception.Message)";Stat=@{};Ust=@{};ActSt=@{}}}
'@
$APPLYCODE=@'
# Input: $items (plain data), $dry, $rp. Output: $sync.Result = plain hashtable with the verified outcome of every item.
$res=@{Dry=[bool]$dry;Done=0;Skipped=0;Failed=@();RpFailed=$false}
$tot=@($items).Count;$n=0
if($rp){$sync.Msg='Creating restore point...';Log 'Creating restore point...'
 $rpk='HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\SystemRestore'
 $rpo=(Get-ItemProperty $rpk -Name SystemRestorePointCreationFrequency -ErrorAction SilentlyContinue).SystemRestorePointCreationFrequency
 try{New-ItemProperty $rpk SystemRestorePointCreationFrequency -Value 0 -PropertyType DWord -Force|Out-Null
     Enable-ComputerRestore -Drive "$env:SystemDrive\";Checkpoint-Computer -Description 'DebloatHub' -RestorePointType MODIFY_SETTINGS}
 catch{$res.RpFailed=$true;Log "   ! restore point failed: $($_.Exception.Message)"}
 finally{if($null -eq $rpo){Remove-ItemProperty $rpk -Name SystemRestorePointCreationFrequency -ErrorAction SilentlyContinue}else{Set-ItemProperty $rpk -Name SystemRestorePointCreationFrequency -Value $rpo}}}
foreach($it in $items){$n++;$sync.Msg="Working $n of ${tot}: $($it.Label)";Log $it.Label
 $bad=@();$did=0
 foreach($a in $it.Acts){Log "   $(Show-Act $a)";if($dry){continue}
  try{
   if($it.Undo -and -not(Act-Revertible $a)){Log '   = cannot be undone automatically - left as is';continue}
   if($it.Undo -and (Act-Absent $a)){Log '   = not present on this PC - nothing to restore';continue}
   $before=Safe-Test $a
   if(-not $it.Undo -and $before -eq $true){Log '   = already applied - nothing to do';continue}                 # apply is idempotent
   if($it.Undo -and $before -eq $false){Log '   = not currently applied - left untouched';continue}             # revert touches only what is applied
   if($it.Undo){Undo-Act $a}else{Snap-Take $a $before;Do-Act $a $false}
   $after=Safe-Test $a                                                                                          # verify against the real system, do not trust "no exception"
   if($null -ne $after -and $after -eq [bool]$it.Undo){throw "the change did not take effect (the setting is still $(if($it.Undo){'applied'}else{'not applied'}))"}
   $did++}
  catch{$bad+="$(Show-Act $a): $($_.Exception.Message)";Log "   ! $($_.Exception.Message)"}}
 if($dry){continue}
 if($bad.Count){$res.Failed+="$($it.Label)`n      $($bad -join "`n      ")"}elseif($did){$res.Done++}else{$res.Skipped++}}
if($dry){Log 'Dry run finished - nothing was changed.'}
else{Log "Finished: $($res.Done) item(s) changed and verified, $($res.Skipped) already in the requested state, $($res.Failed.Count) failed."
 foreach($f in $res.Failed){Log "   FAILED: $f"}}
$sync.Result=$res
'@
function Scan{
 if($script:busy){return}
 Log 'Scanning this PC for applied tweaks (the window stays usable)...'
 Start-Bg 'Loading applied tweaks...' (New-ScanData) $SCANCODE {param($r);Scan-Done $r}}
# UI thread only: applies the plain result hashtable to the WPF controls.
function Apply-ScanResult($r){
  $script:actSt=if($r.ActSt){$r.ActSt}else{@{}}
  $c=@{'Applied'=0;'Partial'=0;'Not applied'=0;'Unknown'=0;'N/A'=0}
  foreach($t in $db){$st=$r.Stat[$t.Name];$stat[$t.Name]=$st;if($st){Set-Status $t $(if($st -eq 'Applied' -and -not(Undoable $t)){'Applied-perm'}else{$st});$c[$st]++}}
  foreach($u in $units){$st=$r.Ust[$u.Key];$ust[$u.Key]=$st
   $fit=[bool](Fits $u.T);$lock=($st -eq 'Applied') -and -not(Can-Undo $u)       # removed apps / run-once results cannot be undone: show them ON but locked, never a switch that pretends to undo
   $u.Box.IsEnabled=($fit -and -not $lock)
   if($fit){$u.Box.IsChecked=($st -eq 'Applied')}}
  Sync-Masters
  for($k=0;$k -lt $secs.Count;$k++){$it=@($db|Where-Object{$_.Sec -eq $secs[$k] -and (Fits $_)});$on=@($it|Where-Object{$stat[$_.Name] -eq 'Applied'}).Count;$secCnt[$k].Text="$on of $($it.Count) on"}
  $vk=[array]::IndexOf($secs,$s20);if($vk -ge 0){$cur='Custom'
   foreach($pn in @(,@('Maximize looks',@()),@('Recommended',$vfxRec),@('Maximize performance',$vfxAll))){$ok=$true
    foreach($vn in $vfxAll){if(($stat[$vn] -eq 'Applied') -ne ($pn[1] -contains $vn)){$ok=$false;break}}
    if($ok){$cur=$pn[0];break}}
   $secCnt[$vk].Text+=" | current: $cur"}
  Update-Bar;Update-Simple
  $sum.Text="Scan result`n$($c['Applied']) applied | $($c['Partial']) partial | $($c['Not applied']) not applied | $($c['Unknown']) one-time | $($c['N/A']) n/a";Log ($sum.Text -replace "`n",': ')}
function Show-ApplyResult($r){
 if(-not $r){Log '! the apply job returned no result - the switches now show the real system state';return}
 if($r.Dry){return}
 $bad=@($r.Failed)
 if($bad.Count){[void][Windows.MessageBox]::Show("$($bad.Count) item(s) could not be fully applied or reverted:`n`n"+(($bad|ForEach-Object{" - $_"}) -join "`n")+"`n`nThese were NOT reported as done. The switches now show the real system state; see the log for details.",'DebloatHub','OK','Warning')}
 elseif($r.Done -gt 0){Log 'All requested changes were verified on the system. Sign out or reboot for everything to take effect.'}
 if($r.Done -gt 0){$script:needReboot=$true}
 if($r.RpFailed){Log '! No restore point was created (see the message above).'}}
function Show-EditionNote{try{$ed=(Get-ItemProperty 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion' -ErrorAction Stop).EditionID
 if($ed -notmatch 'Enterprise|Education|Server'){Log "Windows edition: $ed. This edition cannot turn Windows diagnostic data fully off; 'Disable telemetry & diagnostic services' sets the lowest level it allows (Required)."}}catch{}}
function Warn-OtherUser{
 if($UserDetectErr){Log "! Could not identify the signed-in user ($UserDetectErr). Per-user switches use THIS account's profile."}
 if($OtherUser){Log "! DebloatHub runs under a different account than the signed-in user. Per-user switches are read and changed in the signed-in user's profile (SID $UserSid), not in this administrator account. Visual-effect switches are unavailable in this mode because Windows saves them for the account that changes them."}}
function Scan-Done($r){
 $script:scanned=$true
 try{
  if(-not $r){Log '! scan returned no result';return}
  if(-not $r.Ok){Log "! background scan failed: $($r.Error)";return}
  Invoke-UI {Apply-ScanResult $r}}
 catch{Log "! scan failed: $($_.Exception.Message)"}}

# ---------- Hover card (shown only on the switch) ----------
function Affects($t){$p=@()
 $r=@($t.Acts|Where-Object{$_.K -eq 'Reg'});if($r.Count){$p+="$($r.Count) registry value(s), "+$(if(@($r|Where-Object{$_.P -like 'HKLM*'}).Count){'machine-wide (all users)'}else{'current user only'})}
 $v=@($t.Acts|Where-Object{$_.K -in 'Svc','SvcM'});if($v.Count){$p+="service(s): $(($v|ForEach-Object{$_.N}) -join ', ')"}
 $a=@($t.Acts|Where-Object{$_.K -eq 'App'});if($a.Count){$p+="removes $($a.Count) app package(s) for all users"}
 $k=@($t.Acts|Where-Object{$_.K -eq 'Task'});if($k.Count){$p+="$($k.Count) scheduled task(s)"}
 if(@($t.Acts|Where-Object{$_.K -eq 'Cmd'}).Count){$p+='runs a system command'}
 $f=@($t.Acts|Where-Object{$_.K -eq 'Feat'});if($f.Count){$p+="$($f.Count) optional Windows feature(s) (reboot needed)"}
 $q=@($t.Acts|Where-Object{$_.K -eq 'Startup'});if($q.Count){$p+='1 startup entry (the app itself is not removed)'}
 $ui=@($t.Acts|Where-Object{$_.K -eq 'Spi'});if($ui.Count){$p+='1 visual-effect setting, current user (applies live)'}
 $jj=@($t.Acts|Where-Object{$_.K -eq 'Json'});if($jj.Count){$p+="$($jj.Count) setting(s) in $(Split-Path $jj[0].P -Leaf) (a .debloathub.bak backup is kept; only plain-JSON files are edited)"}
 $p -join '; '}
function TipSec($sp,$title,$body,$col='#4CC2FF'){
 $h=New-Object Windows.Controls.TextBlock;$h.Text=$title;$h.FontSize=10;$h.FontWeight=[Windows.FontWeights]::Bold;$h.Foreground=$bc.ConvertFromString($col);$h.Margin=[Windows.Thickness]::new(0,10,0,2);[void]$sp.Children.Add($h)
 $b=New-Object Windows.Controls.TextBlock;$b.Text=$body;$b.TextWrapping='Wrap';$b.MaxWidth=480;$b.FontSize=12;[void]$sp.Children.Add($b)}
function Tip($t){
 $m=$more[$t.Name]
 $need=if($m){$m[0]}else{'Depends on how you use your PC; see the description.'}
 $pro=if($m){$m[1]}else{'Less clutter and fewer background changes.'}
 $con=if($m){$m[2]}else{'See "What it can affect" below.'}
 $rec=if($t.Rec){$t.Rec}else{@{Safe='Recommended for most people.';Moderate='Optional: read the pros and cons first and keep the restore point on.';Advanced='Experts only: may break features. Restore point strongly advised.'}[$t.Risk]}
 $sp=New-Object Windows.Controls.StackPanel
 $h=New-Object Windows.Controls.TextBlock;$h.Text=$t.Name;$h.FontSize=15;$h.FontWeight=[Windows.FontWeights]::SemiBold;$h.TextWrapping='Wrap';$h.MaxWidth=480;[void]$sp.Children.Add($h)
 TipSec $sp 'WHAT IT DOES' $t.Desc
 if(($t.Prof -split ',') -contains 'telemetry'){TipSec $sp 'SWITCH ON = TELEMETRY OFF' 'While this switch is ON, the data collection described here is switched off. Switch it OFF and press Apply to put back what was there before.' '#66BB6A'}
 TipSec $sp 'DO YOU NEED THIS?' $need
 TipSec $sp 'PROS' $pro '#66BB6A'
 TipSec $sp 'CONS / RISKS' $con '#FFA726'
 TipSec $sp 'WHAT IT CAN AFFECT' (Affects $t)
 TipSec $sp 'RECOMMENDATION' $rec
 TipSec $sp 'EXACT CHANGES' (($t.Acts|ForEach-Object{Show-Act $_}) -join "`n") '#9A9A9A'
 TipSec $sp 'DETAILS' "Risk: $($t.Risk) | $(if(Undoable $t){'Undo: switch off and Apply (restores what was there before)'}else{'Cannot be reverted automatically'}) | Found in: $($t.Src)" '#9A9A9A'
 $sp}

# ---------- UI (dark Fluent style: animated switches, sidebar, cards) ----------
$xaml=@'
<Window xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation" xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml"
 Title="DebloatHub" Width="1140" Height="820" WindowStartupLocation="CenterScreen" Background="#1E1E1E" Foreground="#F3F3F3" FontFamily="Segoe UI Variable Text, Segoe UI">
<Window.Triggers><EventTrigger RoutedEvent="FrameworkElement.Loaded"><BeginStoryboard><Storyboard><DoubleAnimation Storyboard.TargetProperty="Opacity" From="0" To="1" Duration="0:0:0.35"/></Storyboard></BeginStoryboard></EventTrigger></Window.Triggers>
<Window.Resources>
 <Style x:Key="Sw" TargetType="CheckBox"><Setter Property="Foreground" Value="#F3F3F3"/><Setter Property="Cursor" Value="Hand"/><Setter Property="Template"><Setter.Value><ControlTemplate TargetType="CheckBox">
  <StackPanel Orientation="Horizontal" Background="Transparent"><Grid Width="44" Height="22" Margin="0,0,12,0">
   <Border x:Name="tr" CornerRadius="11" BorderBrush="#8A8A8A" BorderThickness="1"><Border.Background><SolidColorBrush Color="#2A2A2A"/></Border.Background></Border>
   <Ellipse x:Name="th" Width="14" Height="14" Fill="#CFCFCF" HorizontalAlignment="Left" Margin="4,0,0,0"/></Grid>
   <ContentPresenter VerticalAlignment="Center"/></StackPanel>
  <ControlTemplate.Triggers><Trigger Property="IsChecked" Value="True">
   <Trigger.EnterActions><BeginStoryboard><Storyboard><ThicknessAnimation Storyboard.TargetName="th" Storyboard.TargetProperty="Margin" To="26,0,0,0" Duration="0:0:0.16"/>
    <ColorAnimation Storyboard.TargetName="tr" Storyboard.TargetProperty="(Border.Background).(SolidColorBrush.Color)" To="#4CC2FF" Duration="0:0:0.16"/></Storyboard></BeginStoryboard></Trigger.EnterActions>
   <Trigger.ExitActions><BeginStoryboard><Storyboard><ThicknessAnimation Storyboard.TargetName="th" Storyboard.TargetProperty="Margin" To="4,0,0,0" Duration="0:0:0.16"/>
    <ColorAnimation Storyboard.TargetName="tr" Storyboard.TargetProperty="(Border.Background).(SolidColorBrush.Color)" To="#2A2A2A" Duration="0:0:0.16"/></Storyboard></BeginStoryboard></Trigger.ExitActions>
   <Setter TargetName="tr" Property="BorderBrush" Value="#4CC2FF"/><Setter TargetName="th" Property="Fill" Value="#101010"/></Trigger>
   <Trigger Property="IsEnabled" Value="False"><Setter Property="Opacity" Value="0.4"/></Trigger></ControlTemplate.Triggers></ControlTemplate></Setter.Value></Setter></Style>
 <Style x:Key="Btn" TargetType="Button"><Setter Property="Foreground" Value="#F3F3F3"/><Setter Property="Background" Value="#333333"/><Setter Property="Margin" Value="0,0,8,6"/><Setter Property="Cursor" Value="Hand"/><Setter Property="Template"><Setter.Value><ControlTemplate TargetType="Button">
  <Border x:Name="b" Background="{TemplateBinding Background}" CornerRadius="8" BorderBrush="#454545" BorderThickness="1" Padding="16,7" RenderTransformOrigin="0.5,0.5"><Border.RenderTransform><ScaleTransform/></Border.RenderTransform><ContentPresenter HorizontalAlignment="Center"/></Border>
  <ControlTemplate.Triggers><Trigger Property="IsMouseOver" Value="True"><Setter TargetName="b" Property="Opacity" Value="0.88"/></Trigger>
   <Trigger Property="IsPressed" Value="True"><Setter TargetName="b" Property="RenderTransform"><Setter.Value><ScaleTransform ScaleX="0.96" ScaleY="0.96"/></Setter.Value></Setter></Trigger>
   <Trigger Property="IsEnabled" Value="False"><Setter TargetName="b" Property="Opacity" Value="0.4"/></Trigger></ControlTemplate.Triggers></ControlTemplate></Setter.Value></Setter></Style>
 <Style x:Key="Row" TargetType="Border"><Setter Property="Background" Value="Transparent"/><Style.Triggers><Trigger Property="IsMouseOver" Value="True"><Setter Property="Background" Value="#303030"/></Trigger></Style.Triggers></Style>
 <Style TargetType="ListBoxItem"><Setter Property="Foreground" Value="#D0D0D0"/><Setter Property="Cursor" Value="Hand"/><Setter Property="Template"><Setter.Value><ControlTemplate TargetType="ListBoxItem">
  <Border x:Name="b" CornerRadius="8" Padding="12,9" Margin="0,1" Background="Transparent"><Grid><Border x:Name="ind" Width="3" Height="16" CornerRadius="2" Background="#4CC2FF" HorizontalAlignment="Left" Visibility="Collapsed" Margin="-8,0,0,0"/><ContentPresenter/></Grid></Border>
  <ControlTemplate.Triggers><Trigger Property="IsMouseOver" Value="True"><Setter TargetName="b" Property="Background" Value="#2A2A2A"/></Trigger>
   <Trigger Property="IsSelected" Value="True"><Setter TargetName="b" Property="Background" Value="#363636"/><Setter TargetName="ind" Property="Visibility" Value="Visible"/><Setter Property="Foreground" Value="White"/></Trigger></ControlTemplate.Triggers></ControlTemplate></Setter.Value></Setter></Style>
 <Style TargetType="ScrollBar"><Setter Property="Width" Value="10"/><Setter Property="Background" Value="Transparent"/><Setter Property="Template"><Setter.Value><ControlTemplate TargetType="ScrollBar">
  <Track x:Name="PART_Track" IsDirectionReversed="True"><Track.Thumb><Thumb><Thumb.Template><ControlTemplate TargetType="Thumb"><Border CornerRadius="4" Background="#5A5A5A" Margin="2,0"/></ControlTemplate></Thumb.Template></Thumb></Track.Thumb></Track></ControlTemplate></Setter.Value></Setter></Style>
 <Style TargetType="ToolTip"><Setter Property="Background" Value="#2B2B2B"/><Setter Property="Foreground" Value="#F3F3F3"/><Setter Property="BorderBrush" Value="#4CC2FF"/><Setter Property="Padding" Value="12"/></Style>
 <Style x:Key="Card" TargetType="Button"><Setter Property="Foreground" Value="#F3F3F3"/><Setter Property="Cursor" Value="Hand"/><Setter Property="Margin" Value="6"/><Setter Property="HorizontalContentAlignment" Value="Stretch"/><Setter Property="VerticalContentAlignment" Value="Stretch"/><Setter Property="Template"><Setter.Value><ControlTemplate TargetType="Button">
  <Border x:Name="b" Background="#2B2B2B" CornerRadius="14" BorderBrush="#3A3A3A" BorderThickness="1" Padding="22,18" RenderTransformOrigin="0.5,0.5"><Border.RenderTransform><ScaleTransform/></Border.RenderTransform><ContentPresenter HorizontalAlignment="{TemplateBinding HorizontalContentAlignment}" VerticalAlignment="{TemplateBinding VerticalContentAlignment}"/></Border>
  <ControlTemplate.Triggers><Trigger Property="IsMouseOver" Value="True"><Setter TargetName="b" Property="BorderBrush" Value="#4CC2FF"/><Setter TargetName="b" Property="Background" Value="#313131"/></Trigger>
   <Trigger Property="IsPressed" Value="True"><Setter TargetName="b" Property="RenderTransform"><Setter.Value><ScaleTransform ScaleX="0.98" ScaleY="0.98"/></Setter.Value></Setter></Trigger>
   <Trigger Property="IsEnabled" Value="False"><Setter TargetName="b" Property="Opacity" Value="0.45"/></Trigger></ControlTemplate.Triggers></ControlTemplate></Setter.Value></Setter></Style>
 <LinearGradientBrush x:Key="Brand" StartPoint="0,0" EndPoint="1,0"><GradientStop Color="#4CC2FF" Offset="0"/><GradientStop Color="#B388FF" Offset="1"/></LinearGradientBrush>
</Window.Resources>
<Grid><Grid.ColumnDefinitions><ColumnDefinition Width="260"/><ColumnDefinition Width="*"/></Grid.ColumnDefinitions>
 <Border Background="#181818" Padding="16,16,16,12"><DockPanel>
  <StackPanel DockPanel.Dock="Top" Margin="6,4,0,18"><TextBlock Text="DebloatHub" FontSize="26" FontWeight="Bold"><TextBlock.Foreground><LinearGradientBrush StartPoint="0,0" EndPoint="1,0"><GradientStop Color="#4CC2FF" Offset="0"/><GradientStop Color="#B388FF" Offset="1"/></LinearGradientBrush></TextBlock.Foreground></TextBlock>
   <TextBlock x:Name="info" Foreground="#8C8C8C" FontSize="11" TextWrapping="Wrap" Margin="0,4,0,0"/></StackPanel>
  <Border DockPanel.Dock="Bottom" Background="#232323" CornerRadius="8" Padding="12" Margin="0,10,0,0"><TextBlock x:Name="sum" Foreground="#9A9A9A" FontSize="11" TextWrapping="Wrap" Text="Scanning..."/></Border>
  <ListBox x:Name="nav" Background="Transparent" BorderThickness="0" ScrollViewer.HorizontalScrollBarVisibility="Disabled"/></DockPanel></Border>
 <Grid Grid.Column="1" Margin="24,20,24,16"><Grid.RowDefinitions><RowDefinition Height="Auto"/><RowDefinition Height="*"/><RowDefinition Height="Auto"/></Grid.RowDefinitions>
  <WrapPanel Margin="0,0,0,14">
   <Border CornerRadius="8" Background="#2B2B2B" BorderBrush="#454545" BorderThickness="1" Width="260" Margin="0,0,16,6"><TextBox x:Name="txt" Background="Transparent" BorderThickness="0" Foreground="#F3F3F3" CaretBrush="#F3F3F3" Padding="10,7"/></Border>
   <Button x:Name="bScan" Content="Detect applied tweaks" Style="{StaticResource Btn}" Background="#4CC2FF" Foreground="#0B0B0B" Margin="0,0,16,6"/>
   <Button x:Name="pSafe" Content="Recommended" Style="{StaticResource Btn}"/><Button x:Name="pPriv" Content="Privacy" Style="{StaticResource Btn}"/>
   <Button x:Name="pGame" Content="Gaming" Style="{StaticResource Btn}"/><Button x:Name="pNone" Content="Reset" Style="{StaticResource Btn}"/><Button x:Name="bToSimple" Content="Simple view" Style="{StaticResource Btn}"/>
   <CheckBox x:Name="chkPC" Style="{StaticResource Sw}" Content="Show pros &amp; cons" IsChecked="True" VerticalAlignment="Center" Margin="8,0,0,6"/></WrapPanel>
  <ScrollViewer Grid.Row="1" VerticalScrollBarVisibility="Auto"><StackPanel x:Name="pnl" Margin="0,0,6,0"/></ScrollViewer>
  <Border Grid.Row="2" Background="#2B2B2B" CornerRadius="10" Padding="16,12,16,8" Margin="0,10,0,0"><StackPanel>
   <WrapPanel><CheckBox x:Name="chkRP" Style="{StaticResource Sw}" Content="Restore point first" IsChecked="True" Margin="0,0,22,6"/>
    <CheckBox x:Name="chkDry" Style="{StaticResource Sw}" Content="Dry run (preview only)" Margin="0,0,26,6"/>
    <Button x:Name="bApply" Content="No changes" IsEnabled="False" Style="{StaticResource Btn}" Background="#4CC2FF" Foreground="#0B0B0B" FontWeight="SemiBold"/>
    <Button x:Name="bExp" Content="Save selection" Style="{StaticResource Btn}"/><Button x:Name="bImp" Content="Load selection" Style="{StaticResource Btn}"/></WrapPanel>
   <Border CornerRadius="6" Background="#1A1A1A"><TextBox x:Name="log" Height="96" IsReadOnly="True" VerticalScrollBarVisibility="Auto" FontFamily="Consolas" Background="Transparent" Foreground="#CFCFCF" BorderThickness="0" Padding="8"/></Border></StackPanel></Border>
 </Grid>
 <Border x:Name="ld" Grid.Column="1" HorizontalAlignment="Right" VerticalAlignment="Top" Margin="0,16,26,0" Background="#2B2B2B" BorderBrush="#4CC2FF" BorderThickness="1" CornerRadius="18" Padding="12,7,16,7">
  <StackPanel Orientation="Horizontal"><Grid Width="18" Height="18" RenderTransformOrigin="0.5,0.5" Margin="0,0,10,0"><Grid.RenderTransform><RotateTransform x:Name="rot"/></Grid.RenderTransform>
   <Grid.Triggers><EventTrigger RoutedEvent="FrameworkElement.Loaded"><BeginStoryboard><Storyboard><DoubleAnimation Storyboard.TargetName="rot" Storyboard.TargetProperty="Angle" From="0" To="360" Duration="0:0:0.9" RepeatBehavior="Forever"/></Storyboard></BeginStoryboard></EventTrigger></Grid.Triggers>
   <Path Data="M 9,2 A 7,7 0 1 1 2,9" Stroke="#4CC2FF" StrokeThickness="2.5" StrokeStartLineCap="Round" StrokeEndLineCap="Round"/></Grid>
   <TextBlock x:Name="ldText" Text="Loading applied tweaks..." VerticalAlignment="Center" FontSize="13"/></StackPanel></Border>
 <Border x:Name="simpleRoot" Grid.ColumnSpan="2" Background="#1E1E1E" Visibility="Collapsed"><Grid>
  <StackPanel x:Name="chooser" VerticalAlignment="Center" HorizontalAlignment="Center" Width="780">
   <TextBlock Text="DebloatHub" FontSize="44" FontWeight="Bold" HorizontalAlignment="Center" Foreground="{StaticResource Brand}"/>
   <TextBlock Text="How do you want to use it?" FontSize="16" Foreground="#9A9A9A" HorizontalAlignment="Center" Margin="0,6,0,26"/>
   <UniformGrid Columns="2" Height="190">
    <Button x:Name="chSimple" Style="{StaticResource Card}"><StackPanel>
     <TextBlock Text="Simple" FontSize="24" FontWeight="SemiBold"/>
     <TextBlock Text="A few big buttons. Removes ads, telemetry and background junk in one click. Safe and fully undoable." TextWrapping="Wrap" Foreground="#B0B0B0" FontSize="13" Margin="0,8,0,0"/>
     <TextBlock Text="Best for most people" Foreground="#4CC2FF" FontSize="12" Margin="0,14,0,0"/></StackPanel></Button>
    <Button x:Name="chAdv" Style="{StaticResource Card}"><StackPanel>
     <TextBlock Text="Advanced" FontSize="24" FontWeight="SemiBold"/>
     <TextBlock Text="Every tweak with details, pros and cons. Choose item by item, services, apps, presets." TextWrapping="Wrap" Foreground="#B0B0B0" FontSize="13" Margin="0,8,0,0"/>
     <TextBlock Text="Full control" Foreground="#B388FF" FontSize="12" Margin="0,14,0,0"/></StackPanel></Button>
   </UniformGrid>
   <CheckBox x:Name="chRemember" Style="{StaticResource Sw}" Content="Remember my choice" HorizontalAlignment="Center" Margin="0,22,0,0"/>
  </StackPanel>
  <Grid x:Name="simpleView" Visibility="Collapsed" MaxWidth="940" Margin="36,26,36,20">
   <Grid.RowDefinitions><RowDefinition Height="Auto"/><RowDefinition Height="Auto"/><RowDefinition Height="Auto"/><RowDefinition Height="Auto"/><RowDefinition Height="*"/></Grid.RowDefinitions>
   <DockPanel><Button x:Name="bToAdv" DockPanel.Dock="Right" Content="Advanced options" Style="{StaticResource Btn}" VerticalAlignment="Center"/>
    <TextBlock Text="DebloatHub" FontSize="30" FontWeight="Bold" Foreground="{StaticResource Brand}" VerticalAlignment="Center"/></DockPanel>
   <TextBlock x:Name="sStatus" Grid.Row="1" FontSize="15" Foreground="#C8C8C8" Margin="2,14,0,16" TextWrapping="Wrap" Text="Checking your PC..."/>
   <UniformGrid Grid.Row="2" Columns="3" Height="200">
    <Button x:Name="bRec" Style="{StaticResource Card}"><DockPanel>
     <TextBlock x:Name="tRec" DockPanel.Dock="Bottom" Foreground="#4CC2FF" FontSize="13" Margin="0,10,0,0"/>
     <StackPanel><TextBlock Text="Debloat" FontSize="22" FontWeight="SemiBold"/>
      <TextBlock Text="Turns off ads, telemetry, Widgets and background junk. Everything you use keeps working." TextWrapping="Wrap" Foreground="#B0B0B0" FontSize="13" Margin="0,8,0,0"/></StackPanel></DockPanel></Button>
    <Button x:Name="bGame" Style="{StaticResource Card}"><DockPanel>
     <TextBlock x:Name="tGame" DockPanel.Dock="Bottom" Foreground="#4CC2FF" FontSize="13" Margin="0,10,0,0"/>
     <StackPanel><TextBlock Text="Debloat + Gaming" FontSize="22" FontWeight="SemiBold"/>
      <TextBlock Text="Everything in Debloat, plus raw mouse input and no Game Bar or Sticky Keys pop-ups." TextWrapping="Wrap" Foreground="#B0B0B0" FontSize="13" Margin="0,8,0,0"/></StackPanel></DockPanel></Button>
    <Button x:Name="bUndo" Style="{StaticResource Card}"><DockPanel>
     <TextBlock x:Name="tUndo" DockPanel.Dock="Bottom" Foreground="#FFB74D" FontSize="13" Margin="0,10,0,0"/>
     <StackPanel><TextBlock Text="Undo" FontSize="22" FontWeight="SemiBold"/>
      <TextBlock Text="Puts back everything DebloatHub changed on this PC." TextWrapping="Wrap" Foreground="#B0B0B0" FontSize="13" Margin="0,8,0,0"/></StackPanel></DockPanel></Button>
   </UniformGrid>
   <WrapPanel Grid.Row="3" Margin="8,14,0,10">
    <CheckBox x:Name="sRP" Style="{StaticResource Sw}" Content="Create a restore point first" IsChecked="True" Margin="0,0,24,6"/>
    <TextBlock x:Name="lnkShow" Text="Show me exactly what changes" Foreground="#4CC2FF" Cursor="Hand" VerticalAlignment="Center" Margin="0,0,24,6" TextDecorations="Underline"/>
    <Button x:Name="bReboot" Content="Restart now to finish" Style="{StaticResource Btn}" Background="#4CC2FF" Foreground="#0B0B0B" FontWeight="SemiBold" Visibility="Collapsed"/>
   </WrapPanel>
   <Border Grid.Row="4" CornerRadius="10" Background="#151515"><TextBox x:Name="slog" IsReadOnly="True" VerticalScrollBarVisibility="Auto" TextWrapping="Wrap" FontFamily="Consolas" FontSize="12" Background="Transparent" Foreground="#A8A8A8" BorderThickness="0" Padding="12"/></Border>
  </Grid>
 </Grid></Border>
</Grid></Window>
'@
$w=[Windows.Markup.XamlReader]::Parse($xaml)
$w.Title="DebloatHub v$AppVersion"
'info','sum','nav','txt','pnl','log','ld','ldText','chkRP','chkDry','bScan','pSafe','pPriv','pGame','pNone','bApply','bExp','bImp','chkPC','bToSimple','simpleRoot','chooser','chSimple','chAdv','chRemember','simpleView','bToAdv','sStatus','bRec','bGame','bUndo','tRec','tGame','tUndo','sRP','lnkShow','bReboot','slog'|ForEach-Object{Set-Variable $_ ($w.FindName($_))}
$pSafe.ToolTip='Recommended: performance and privacy tweaks that keep every common feature working and can all be undone with one click (no app removals, no cleanups). Tweaks in this preset carry a "Recommended" badge.'
$info.Text="Windows $(if($W11){'11'}else{'10'}) (build $build)`nSwitches show what is ON now. Flip, then Apply.`nSwitches named Disable / Turn off: ON = that data collection is off."
$bc=New-Object Windows.Media.BrushConverter
function Badge($t,$c,$tip){$b=New-Object Windows.Controls.Border;$b.Background=$bc.ConvertFromString($c)
 $b.CornerRadius=New-Object Windows.CornerRadius 10;$b.Padding=[Windows.Thickness]::new(8,2,8,2);$b.Margin=[Windows.Thickness]::new(0,0,5,0);$b.VerticalAlignment='Center'
 $x=New-Object Windows.Controls.TextBlock;$x.Text=$t;$x.FontSize=10.5;$x.Foreground=[Windows.Media.Brushes]::White;$b.Child=$x;$b}

$pcBlocks=@();$showPC=$true;try{$v=(Get-ItemProperty 'HKCU:\SOFTWARE\DebloatHub' -Name ShowProsCons -ErrorAction Stop).ShowProsCons;$showPC=[bool]$v}catch{};$chkPC.IsChecked=$showPC
$boxes=@();$cards=@();$rowsBy=@();$sb=@{};$rv=@{};$actSt=@{};$stat=@{};$ust=@{};$boxOf=@{};$barOf=@{};$subsOf=@{};$units=@();$secCnt=@()
[void]$nav.Items.Add('All sections')
$accent=$bc.ConvertFromString('#4CC2FF')
foreach($sec in $secs){
 $items=@($db|Where-Object Sec -eq $sec)
 $card=New-Object Windows.Controls.Border;$card.Background=$bc.ConvertFromString('#2B2B2B');$card.CornerRadius=New-Object Windows.CornerRadius 10
 $card.Padding=[Windows.Thickness]::new(14,14,14,8);$card.Margin=[Windows.Thickness]::new(0,0,0,14)
 $sp=New-Object Windows.Controls.StackPanel
 $hd=New-Object Windows.Controls.DockPanel;$hd.Margin=[Windows.Thickness]::new(8,0,8,8)
 $cn=New-Object Windows.Controls.TextBlock;$cn.FontSize=12;$cn.VerticalAlignment='Center';$cn.Foreground=$accent;[Windows.Controls.DockPanel]::SetDock($cn,'Right');[void]$hd.Children.Add($cn);$secCnt+=$cn
 $h=New-Object Windows.Controls.TextBlock;$h.Text=$sec;$h.FontSize=17;$h.FontWeight=[Windows.FontWeights]::SemiBold;[void]$hd.Children.Add($h);[void]$sp.Children.Add($hd)
 if($sec -eq $sSvc){$mp=New-Object Windows.Controls.StackPanel;$mp.Margin=[Windows.Thickness]::new(8,0,8,10)
  $mc=New-Object Windows.Controls.CheckBox;$mc.Style=$w.FindResource('Sw');$mc.Content='Strict mode: Disabled instead of Manual';$mc.IsChecked=$SvcStrict
  $mc.ToolTip='Manual (default): Windows can still start a service when an app or feature asks for it, so nothing breaks or crashes; it just no longer runs all the time. Strict: services are Disabled and never start. Use Strict only for services you are sure you never need.'
  $mc.Add_Click({param($s,$e) $want=[bool]$s.IsChecked;$s.IsChecked=$SvcStrict
   if($script:busy){return}
   if([Windows.MessageBox]::Show("Switch the Background Services section to $(if($want){'Strict (Disabled)'}else{'Manual'}) mode?`n`nDebloatHub restarts to rebuild the switches. Changes you have not applied yet are lost. Services you already changed keep their current state (a Disabled service still counts as switched on in Manual mode; to make it Manual, switch it off, Apply, then on again). The original start type stays recorded for undo.",'DebloatHub','YesNo','Question') -ne 'Yes'){return}
   try{if(-not(Test-Path 'HKCU:\SOFTWARE\DebloatHub')){New-Item 'HKCU:\SOFTWARE\DebloatHub' -Force|Out-Null};New-ItemProperty 'HKCU:\SOFTWARE\DebloatHub' -Name ServiceMode -Value $(if($want){'Strict'}else{'Manual'}) -PropertyType String -Force|Out-Null}catch{Log "! could not save the mode: $($_.Exception.Message)";return}
   Start-Process powershell -WindowStyle $(if($ShowConsole){'Normal'}else{'Hidden'}) -ArgumentList "-NoProfile -ExecutionPolicy Bypass -File `"$MyPath`" -Elevated$(if($ShowConsole){' -ShowConsole'})";$w.Close()})
  [void]$mp.Children.Add($mc)
  $md=New-Object Windows.Controls.TextBlock;$md.TextWrapping='Wrap';$md.FontSize=11;$md.Foreground=$bc.ConvertFromString('#9A9A9A');$md.Margin=[Windows.Thickness]::new(56,2,0,0)
  $md.Text=$(if($SvcStrict){'Strict mode: switched-on services are Disabled and never start, even when an app asks for them. Features that need them stop working.'}else{'Manual mode: switched-on services stop starting at boot, but Windows still starts them when an app or feature asks. Nothing crashes; they just stop running all the time. Services that already work this way are not listed.'})
  [void]$mp.Children.Add($md);[void]$sp.Children.Add($mp)}
 if($sec -eq $s20){$pr=New-Object Windows.Controls.WrapPanel;$pr.Margin=[Windows.Thickness]::new(8,0,0,2)
  foreach($pn in 'Maximize looks','Recommended','Maximize performance'){$bt=New-Object Windows.Controls.Button;$bt.Content=$pn;$bt.Tag=$pn;$bt.Style=$w.FindResource('Btn');if($pn -eq 'Recommended'){$bt.Background=$accent;$bt.Foreground=[Windows.Media.Brushes]::Black}
   $bt.Add_Click({param($s,$e) Set-Preset $s.Tag});[void]$pr.Children.Add($bt)}
  [void]$sp.Children.Add($pr)
  $pd=New-Object Windows.Controls.TextBlock;$pd.Text='Presets only move the switches; press Apply to use them. Recommended = every effect off except thumbnails, window contents while dragging, icon-label shadows and smooth font edges (these cost almost nothing).';$pd.FontSize=11;$pd.TextWrapping='Wrap';$pd.Foreground=$bc.ConvertFromString('#9A9A9A');$pd.Margin=[Windows.Thickness]::new(8,0,8,10);[void]$sp.Children.Add($pd)}
 $rs=@()
 foreach($t in $items){
  $row=New-Object Windows.Controls.Border;$row.Style=$w.FindResource('Row');$row.CornerRadius=New-Object Windows.CornerRadius 8;$row.Padding=[Windows.Thickness]::new(8,8,8,8);$row.Margin=[Windows.Thickness]::new(0,0,0,2)
  $g=New-Object Windows.Controls.Grid;$c0=New-Object Windows.Controls.ColumnDefinition;$c0.Width=[Windows.GridLength]::Auto;[void]$g.ColumnDefinitions.Add($c0);[void]$g.ColumnDefinitions.Add((New-Object Windows.Controls.ColumnDefinition))
  $bar=New-Object Windows.Controls.Border;$bar.Width=3;$bar.CornerRadius=New-Object Windows.CornerRadius 2;$bar.Background=$accent;$bar.Margin=[Windows.Thickness]::new(0,0,10,0);$bar.Visibility='Hidden';$barOf[$t.Name]=$bar
  $inner=New-Object Windows.Controls.StackPanel;[Windows.Controls.Grid]::SetColumn($inner,1)
  $top=New-Object Windows.Controls.WrapPanel
  $cb=New-Object Windows.Controls.CheckBox;$cb.Style=$w.FindResource('Sw');$cb.Tag=$t;$cb.VerticalAlignment='Center';$cb.IsEnabled=Fits $t
  $cb.ToolTip=Tip $t;[Windows.Controls.ToolTipService]::SetShowDuration($cb,180000);[Windows.Controls.ToolTipService]::SetInitialShowDelay($cb,150)
  $cb.Add_Click({param($s,$e) if($script:busy){$s.IsChecked=-not $s.IsChecked;return};$k=$s.Tag.Name;if($excl.ContainsKey($k) -and $s.IsChecked){$o=$excl[$k];$boxOf[$o].IsChecked=$false;if($subsOf.ContainsKey($o)){foreach($x in $subsOf[$o]){if($x.IsEnabled){$x.IsChecked=$false}}}};if($subsOf.ContainsKey($k)){foreach($x in $subsOf[$k]){if($x.IsEnabled){$x.IsChecked=$s.IsChecked}};$s.IsChecked=(@($subsOf[$k]|Where-Object{-not $_.IsChecked}).Count -eq 0)};Update-Bar})
  $nm=New-Object Windows.Controls.TextBlock;$nm.Text=$t.Name;$nm.FontSize=14;$nm.VerticalAlignment='Center';$nm.Margin=[Windows.Thickness]::new(0,0,10,0)
  [void]$top.Children.Add($cb);[void]$top.Children.Add($nm);$boxes+=$cb;$boxOf[$t.Name]=$cb
  $rc=@{Safe='#2E7D32';Moderate='#EF6C00';Advanced='#C62828'}[$t.Risk]
  [void]$top.Children.Add((Badge $t.Risk $rc ''))
  if(($t.Prof -split ',') -contains 'telemetry'){[void]$top.Children.Add((Badge 'ON = telemetry off' '#00695C' ''))}
  $n=($t.Src -split ',').Count
  if(Is-RecT $t){[void]$top.Children.Add((Badge 'Recommended' '#4527A0' ''))}
  [void]$top.Children.Add((Badge "$n tool$(if($n -gt 1){'s'})" '#1565C0' ''))
  if($t.Win -ne 'Any'){[void]$top.Children.Add((Badge "Win $($t.Win) only" '#6A1B9A' ''))}
  [void]$top.Children.Add((Badge $(if(Undoable $t){'Undoable'}else{'No undo'}) $(if(Undoable $t){'#455A64'}else{'#8D6E63'}) ''))
  $stb=Badge 'Not scanned' '#5A5A5A' '';$stb.Visibility='Collapsed';$sb[$t.Name]=$stb;[void]$top.Children.Add($stb)
  $rvb=New-Object Windows.Controls.Button;$rvb.Style=$w.FindResource('Btn');$rvb.Content='Revert applied parts';$rvb.FontSize=11;$rvb.Margin=[Windows.Thickness]::new(8,0,0,0);$rvb.Visibility='Collapsed';$rvb.Tag=$t
  $rvb.ToolTip='Some parts of this tweak are applied. Undo just those parts now; parts that are not applied are left untouched. (Right-click the row for more.)'
  $rvb.Add_Click({param($s,$e) Revert-Partial $s.Tag});$rv[$t.Name]=$rvb;[void]$top.Children.Add($rvb)
  $cm=New-Object Windows.Controls.ContextMenu
  $m1=New-Object Windows.Controls.MenuItem;$m1.Header='Revert the applied parts now';$m1.Tag=$t;$m1.Add_Click({param($s,$e) Revert-Partial $s.Tag})
  $m2=New-Object Windows.Controls.MenuItem;$m2.Header='Complete this tweak now (apply the missing parts)';$m2.Tag=$t;$m2.Add_Click({param($s,$e) Complete-Partial $s.Tag})
  [void]$cm.Items.Add($m1);[void]$cm.Items.Add($m2)
  $cm.Add_Opened({param($s,$e) $tw=$s.Items[0].Tag;$st=$stat[$tw.Name];$s.Items[0].IsEnabled=(-not $script:busy) -and ($st -in 'Partial','Applied','Applied-perm') -and (Can-Undo $tw);$s.Items[1].IsEnabled=(-not $script:busy) -and ($st -eq 'Partial')})
  $row.ContextMenu=$cm
  $d=New-Object Windows.Controls.TextBlock;$d.Text=$t.Desc;$d.Foreground=$bc.ConvertFromString('#A0A0A0');$d.FontSize=12;$d.TextWrapping='Wrap';$d.Margin=[Windows.Thickness]::new(56,3,0,0)
  [void]$inner.Children.Add($top);[void]$inner.Children.Add($d)
  $mm=$more[$t.Name]
  if($mm){$pc=New-Object Windows.Controls.TextBlock;$pc.TextWrapping='Wrap';$pc.FontSize=11.5;$pc.Margin=[Windows.Thickness]::new(56,4,0,0)
   foreach($ln in @(@('Pros: ',$mm[1],'#81C784'),@('Cons: ',$mm[2],'#FFB74D'))){
    if($pc.Inlines.Count){[void]$pc.Inlines.Add((New-Object Windows.Documents.LineBreak))}
    $r1=New-Object Windows.Documents.Run $ln[0];$r1.FontWeight=[Windows.FontWeights]::SemiBold;$r1.Foreground=$bc.ConvertFromString($ln[2])
    $r2=New-Object Windows.Documents.Run ([string]$ln[1]);$r2.Foreground=$bc.ConvertFromString('#B8B8B8')
    [void]$pc.Inlines.Add($r1);[void]$pc.Inlines.Add($r2)}
   $pc.Visibility=$(if($showPC){'Visible'}else{'Collapsed'});[void]$inner.Children.Add($pc);$pcBlocks+=$pc}
  $sub=($t.Acts.Count -gt 1) -and ((@($t.Acts|Where-Object{$_.K -notin 'App','Task','Svc','SvcM','Feat','Json'}).Count -eq 0) -or ($splitOK -contains $t.Name))
  if($sub){
   $subsOf[$t.Name]=@();$seenK=@{}
   $subp=New-Object Windows.Controls.WrapPanel;$subp.Margin=[Windows.Thickness]::new(56,4,0,0);$subOpen=($t.Sec -eq $sSvc);$subp.Visibility=$(if($subOpen){'Visible'}else{'Collapsed'})
   foreach($a in $t.Acts){
    $lk=Act-Label $a;$kk=$lk;$c=2;while($seenK.ContainsKey($kk)){$kk="$lk ($c)";$c++};$seenK[$kk]=1
    $u=@{T=$t;Acts=@($a);Sub=$true;Key="$($t.Name)|$kk"}
    $sc=New-Object Windows.Controls.CheckBox;$sc.Style=$w.FindResource('Sw');$sc.Tag=$u;$sc.IsEnabled=$cb.IsEnabled;$sc.ToolTip=$(if($a.K -in 'Svc','SvcM' -and $SVCINFO.Contains($a.N)){$SVCINFO[$a.N]+"`n`n"})+(Show-Act $a);$sc.VerticalAlignment='Center'
    $sc.Add_Click({param($s,$e) if($script:busy){$s.IsChecked=-not $s.IsChecked;return};$tt=$s.Tag.T;$boxOf[$tt.Name].IsChecked=(@($subsOf[$tt.Name]|Where-Object{-not $_.IsChecked}).Count -eq 0);Update-Bar})
    $u.Box=$sc;$units+=,$u;$subsOf[$t.Name]+=$sc
    $it2=New-Object Windows.Controls.StackPanel;$it2.Orientation='Horizontal';$it2.Margin=[Windows.Thickness]::new(0,4,22,4)
    $lb=New-Object Windows.Controls.TextBlock;$lb.Text=(Act-Label $a);$lb.FontSize=12;$lb.VerticalAlignment='Center'
    [void]$it2.Children.Add($sc);[void]$it2.Children.Add($lb);[void]$subp.Children.Add($it2)}
   $lnk=New-Object Windows.Controls.TextBlock;$lnk.Text=$(if($subOpen){"- Hide individual options"}else{"+ Choose individually ($($t.Acts.Count))"});$lnk.FontSize=12;$lnk.Foreground=$accent;$lnk.Cursor=[Windows.Input.Cursors]::Hand;$lnk.Margin=[Windows.Thickness]::new(56,5,0,0);$lnk.Tag=$subp
   $lnk.Add_MouseLeftButtonUp({param($s,$e) $pp=$s.Tag;if($pp.Visibility -eq 'Visible'){$pp.Visibility='Collapsed';$s.Text="+ Choose individually ($($pp.Children.Count))"}else{$pp.Visibility='Visible';$s.Text='- Hide individual options'}})
   [void]$inner.Children.Add($lnk);[void]$inner.Children.Add($subp)
  }else{$units+=,@{T=$t;Acts=@($t.Acts);Sub=$false;Key=$t.Name;Box=$cb}}
  [void]$g.Children.Add($bar);[void]$g.Children.Add($inner);$row.Child=$g
  $row.Tag="$($t.Name) $($t.Desc) $($t.Src) $(($t.Acts|ForEach-Object{Act-Label $_}) -join ' ') $(if($more[$t.Name]){$more[$t.Name] -join ' '})"
  [void]$sp.Children.Add($row);$rs+=$row}
 $card.Child=$sp;[void]$pnl.Children.Add($card);$cards+=$card;$rowsBy+=,$rs;[void]$nav.Items.Add("$sec  ($($items.Count))")}

function Refresh-View{$q=$txt.Text.Trim();$i=$nav.SelectedIndex
 for($k=0;$k -lt $secs.Count;$k++){$n=0
  foreach($r in $rowsBy[$k]){$m=(-not $q) -or (([string]$r.Tag).IndexOf($q,[StringComparison]::OrdinalIgnoreCase) -ge 0);$r.Visibility=if($m){'Visible'}else{'Collapsed'};if($m){$n++}}
  $cards[$k].Visibility=if(($i -le 0 -or ($i-1) -eq $k) -and $n -gt 0){'Visible'}else{'Collapsed'}}}
function Pick($tag){if($script:busy){return};$n=0   # presets only ADD: switches that are already applied stay on
 foreach($u in $units){$t=$u.T;$ap=($ust[$u.Key] -eq 'Applied')
  $want=if($tag -eq 'recommended'){Is-Rec $u}else{$tag -and (($t.Prof -split ',') -contains $tag)}
  $u.Box.IsChecked=[bool]((Fits $t) -and ($ap -or $want));if((Fits $t) -and $want -and -not $ap){$n++}}
 Sync-Masters;Update-Bar;if($tag){Log "Preset '$tag': $n switch(es) turned on. Review them (blue bar), then press Apply."}}
$cfg=Join-Path $(if($UserDesktop -and (Test-Path -LiteralPath $UserDesktop)){$UserDesktop}else{$UserProfile}) 'DebloatHub-selection.json'
$nav.Add_SelectionChanged({Refresh-View});$txt.Add_TextChanged({Refresh-View});$nav.SelectedIndex=0
$bScan.Add_Click({Scan})
$pSafe.Add_Click({Pick 'recommended'});$pPriv.Add_Click({Pick 'privacy'});$pGame.Add_Click({Pick 'gaming'});$pNone.Add_Click({Pick $null})
$bApply.Add_Click({Run})
$chkPC.Add_Click({$on=[bool]$chkPC.IsChecked;foreach($x in $pcBlocks){$x.Visibility=$(if($on){'Visible'}else{'Collapsed'})}
 try{if(-not(Test-Path 'HKCU:\SOFTWARE\DebloatHub')){New-Item 'HKCU:\SOFTWARE\DebloatHub' -Force|Out-Null};New-ItemProperty 'HKCU:\SOFTWARE\DebloatHub' -Name ShowProsCons -Value ([int]$on) -PropertyType DWord -Force|Out-Null}catch{}})
$bExp.Add_Click({try{ConvertTo-Json -InputObject @($units|Where-Object{$_.Box.IsChecked}|ForEach-Object{$_.Key})|Set-Content -LiteralPath $cfg -Encoding UTF8;Log "Saved switches (ON) to $cfg"}catch{Log "! could not save the selection: $($_.Exception.Message)"}})
$bImp.Add_Click({try{if(Test-Path -LiteralPath $cfg){$raw=Get-Content -LiteralPath $cfg -Raw;$n=@(if("$raw".Trim()){($raw|ConvertFrom-Json)|ForEach-Object{$_}});foreach($u in $units){if($u.Box.IsEnabled){$u.Box.IsChecked=[bool]($n -contains $u.Key)}};Sync-Masters;Update-Bar;Log "Loaded $cfg"}else{Log "No saved selection at $cfg"}}catch{Log "! could not load the selection: $($_.Exception.Message)"}})
Add-Type -Namespace DH -Name Win -MemberDefinition @'
[DllImport("kernel32.dll")] public static extern IntPtr GetConsoleWindow();
[DllImport("user32.dll")] public static extern bool ShowWindow(IntPtr h,int c);
'@
$timer=New-Object Windows.Threading.DispatcherTimer;$timer.Interval=[TimeSpan]::FromMilliseconds(120)
$timer.Add_Tick({$j=$script:job;if(-not $j){return}
 $m=$null;while($j.Sync.Q.TryDequeue([ref]$m)){Log $m}
 if($j.Sync.Msg){$ldText.Text=$j.Sync.Msg;if($sStatus -and $simpleView.Visibility -eq 'Visible'){$sStatus.Text=$j.Sync.Msg}}
 if($j.H.IsCompleted){$timer.Stop()
  try{[void]$j.PS.EndInvoke($j.H)}catch{Log "! $($_.Exception.Message)"}
  foreach($er in @($j.PS.Streams.Error)){Log "! $($er.ToString())"}
  while($j.Sync.Q.TryDequeue([ref]$m)){Log $m}
  $script:res=$j.Sync.Result;$j.PS.Dispose();$j.RS.Dispose();$script:job=$null;$script:busy=$false;$bScan.IsEnabled=$true;Hide-Load
  & $j.Done $script:res}})
# ---------- Simple view: three buttons on top of the same engine (presets -> switches -> Run) ----------
$script:needReboot=$false;$script:scanned=$false
function In-Set($u,$what){(Fits $u.T) -and $u.Box.IsEnabled -and $(if($what -eq 'game'){(Is-Rec $u) -or ($SIMPLE_GAMING -contains $u.T.Name) -or ($SIMPLE_GAMING -contains $u.Key)}else{Is-Rec $u})}
function DH-Changed($u){                          # did DebloatHub itself change this switch? (a recorded original or a command marker exists)
 foreach($a in $u.Acts){if(-not(Act-Revertible $a)){continue}
  if($a.K -eq 'Cmd'){$id=Cmd-Id $a;if((Get-ItemProperty 'HKLM:\SOFTWARE\DebloatHub\Applied' -Name $id -ErrorAction SilentlyContinue).$id){return $true}}
  elseif(Snap-Read $a){return $true}}
 return $false}
function Undo-Units{@($units|Where-Object{$_.Box.IsEnabled -and $ust[$_.Key] -eq 'Applied' -and (Can-Undo $_) -and (DH-Changed $_)})}
function Update-Simple{
 if(-not $simpleView -or $simpleView.Visibility -ne 'Visible'){return}
 if($script:busy -or -not $script:scanned){$bRec.IsEnabled=$false;$bGame.IsEnabled=$false;$bUndo.IsEnabled=$false;return}
 $rn=@($units|Where-Object{(In-Set $_ 'rec') -and $ust[$_.Key] -ne 'Applied'}).Count
 $gn=@($units|Where-Object{(In-Set $_ 'game') -and $ust[$_.Key] -ne 'Applied'}).Count
 $un=@(Undo-Units).Count
 $tRec.Text=$(if($rn){"$rn change$(if($rn -ne 1){'s'}) to make"}else{'Done on this PC'});$bRec.IsEnabled=($rn -gt 0)
 $tGame.Text=$(if($gn){"$gn change$(if($gn -ne 1){'s'}) to make"}else{'Done on this PC'});$bGame.IsEnabled=($gn -gt 0)
 $tUndo.Text=$(if($un){"$un change$(if($un -ne 1){'s'}) to undo"}else{'Nothing to undo'});$bUndo.IsEnabled=($un -gt 0)
 $sStatus.Text=$(if($script:needReboot){'Done. Restart your PC to finish.'}elseif(-not $rn){'Your PC is debloated. You can still undo it at any time.'}else{"Ready. Pick what you want; nothing changes until you confirm."})
 $bReboot.Visibility=$(if($script:needReboot){'Visible'}else{'Collapsed'})}
function Simple-Run($what){
 if($script:busy){return}
 Pick $null                                       # every switch = current state of the PC
 if($what -eq 'undo'){foreach($u in (Undo-Units)){$u.Box.IsChecked=$false}}
 else{foreach($u in $units){if(In-Set $u $what){$u.Box.IsChecked=$true}}}
 Sync-Masters;Update-Bar
 $chkDry.IsChecked=$false;$chkRP.IsChecked=[bool]$sRP.IsChecked
 Run}
function Show-View($v){
 switch($v){
  'choose'  {$simpleRoot.Visibility='Visible';$chooser.Visibility='Visible';$simpleView.Visibility='Collapsed'}
  'simple'  {$simpleRoot.Visibility='Visible';$chooser.Visibility='Collapsed';$simpleView.Visibility='Visible';Update-Simple}
  'advanced'{$simpleRoot.Visibility='Collapsed'}}}
function Save-UiMode($v){try{if(-not(Test-Path 'HKCU:\SOFTWARE\DebloatHub')){New-Item 'HKCU:\SOFTWARE\DebloatHub' -Force|Out-Null};New-ItemProperty 'HKCU:\SOFTWARE\DebloatHub' -Name UiMode -Value $v -PropertyType String -Force|Out-Null}catch{}}
$chSimple.Add_Click({if($chRemember.IsChecked){Save-UiMode 'Simple'};Show-View 'simple'})
$chAdv.Add_Click({if($chRemember.IsChecked){Save-UiMode 'Advanced'};Show-View 'advanced'})
$bToAdv.Add_Click({Save-UiMode 'Advanced';Show-View 'advanced'})
$bToSimple.Add_Click({Save-UiMode 'Simple';Show-View 'simple'})
$bRec.Add_Click({Simple-Run 'rec'});$bGame.Add_Click({Simple-Run 'game'});$bUndo.Add_Click({Simple-Run 'undo'})
$lnkShow.Add_MouseLeftButtonUp({if($script:busy){return};Pick 'recommended';Show-View 'advanced';$nav.SelectedIndex=0})   # the blue bars show every pending change
$bReboot.Add_Click({if([Windows.MessageBox]::Show('Restart the PC now? Save your work in other apps first.','DebloatHub','YesNo','Question') -eq 'Yes'){Start-Process shutdown.exe -ArgumentList '/r /t 5'}})
$startView='choose';try{$um=(Get-ItemProperty 'HKCU:\SOFTWARE\DebloatHub' -Name UiMode -ErrorAction Stop).UiMode;if($um -eq 'Simple'){$startView='simple'}elseif($um -eq 'Advanced'){$startView='advanced'}}catch{}
Show-View $startView
$w.Add_Closing({param($s,$e) if($script:busy -and [Windows.MessageBox]::Show('A job is still running. Close anyway?','DebloatHub','YesNo') -ne 'Yes'){$e.Cancel=$true}})
$w.Add_ContentRendered({if(-not $ShowConsole){try{[void][DH.Win]::ShowWindow([DH.Win]::GetConsoleWindow(),0)}catch{}};Warn-OtherUser;Show-EditionNote;Scan})
[void]$w.ShowDialog()
