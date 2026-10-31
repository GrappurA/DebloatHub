#Requires -Version 5.1
<#
  DebloatHub automated tests. Runs on a disposable Windows machine (GitHub Actions); it really applies and reverts tweaks.
  DO NOT run it on your own PC.

    powershell -ExecutionPolicy Bypass -File .\tests\Run-Tests.ps1 -DhtMode Manual -DhtOut .\test-results

  Steps: parse (Windows PowerShell 5.1) -> load the script with -NoShow -> sanity checks -> every detector on a real
  system -> background scan -> UI update + screenshots (start page, Simple, Advanced) -> apply/verify/undo round trip
  on every revertible registry/service/task/startup tweak, comparing the system state before and after.
#>
param([ValidateSet('Manual','Strict')][string]$DhtMode='Manual',[string]$DhtOut="$PSScriptRoot\..\test-results")

$ErrorActionPreference='Continue'
New-Item -ItemType Directory -Force -Path $DhtOut|Out-Null
$DhtOut=(Resolve-Path $DhtOut).Path
$DhtScript=(Resolve-Path "$PSScriptRoot\..\DebloatHub.ps1").Path
$DhtRes=[ordered]@{os="$((Get-CimInstance Win32_OperatingSystem).Caption) build $([Environment]::OSVersion.Version.Build)";mode=$DhtMode;checks=@();roundTrip=@()}
function DhtCheck($name,[bool]$ok,$detail=''){
 $script:DhtRes.checks+=,([ordered]@{name=$name;ok=$ok;detail="$detail"})
 Write-Host ("[{0}] {1}  {2}" -f $(if($ok){'PASS'}else{'FAIL'}),$name,$detail) -ForegroundColor $(if($ok){'Green'}else{'Red'})}
function DhtFinish{
 $DhtRes|ConvertTo-Json -Depth 6|Set-Content -Path (Join-Path $DhtOut 'results.json') -Encoding UTF8
 $fail=@($DhtRes.checks|Where-Object{-not $_.ok})
 $md=@("### DebloatHub tests - $($DhtRes.os), $($DhtRes.mode) mode","","$(@($DhtRes.checks).Count - $fail.Count) passed, $($fail.Count) failed","","| | Check | Detail |","|---|---|---|")
 foreach($c in $DhtRes.checks){$md+="| $(if($c.ok){'PASS'}else{'**FAIL**'}) | $($c.name) | $(($c.detail -replace '\|','/' -replace "`r?`n",' ').Substring(0,[Math]::Min(300,$c.detail.Length))) |"}
 foreach($f in @(Get-ChildItem $DhtOut -Filter *.png -ErrorAction SilentlyContinue)){$b=[Convert]::ToBase64String([IO.File]::ReadAllBytes($f.FullName));Write-Host "::group::$($f.Name) (base64)";for($i=0;$i -lt $b.Length;$i+=4000){Write-Host "DHPNG $($f.BaseName) $($b.Substring($i,[Math]::Min(4000,$b.Length-$i)))"};Write-Host '::endgroup::'}
 if($env:GITHUB_STEP_SUMMARY){$md|Out-File -FilePath $env:GITHUB_STEP_SUMMARY -Append -Encoding utf8}
 $md|Set-Content (Join-Path $DhtOut 'summary.md') -Encoding UTF8
 if($fail.Count){exit 1}else{exit 0}}

# Runs DebloatHub's background-job code synchronously (same runspace setup as Start-Bg, without the WPF timer)
function DhtEngine($vars,$code){
 $q=New-Object 'System.Collections.Concurrent.ConcurrentQueue[string]'
 $sync=[hashtable]::Synchronized(@{Q=$q;Msg='';Result=$null})
 $rs=[runspacefactory]::CreateRunspace();$rs.ApartmentState='STA';$rs.Open()
 foreach($kv in @{sync=$sync;W11=$W11;OtherUser=$OtherUser;UserLocal=$UserLocal}.GetEnumerator()){$rs.SessionStateProxy.SetVariable($kv.Key,$kv.Value)}
 foreach($k in $vars.Keys){$rs.SessionStateProxy.SetVariable($k,$vars[$k])}
 $ps=[powershell]::Create();$ps.Runspace=$rs;[void]$ps.AddScript($ENGINE_TXT+"`n"+$code)
 try{[void]$ps.Invoke()}catch{}
 $errs=@($ps.Streams.Error|ForEach-Object{$_.ToString()});$log=@();$m=$null;while($q.TryDequeue([ref]$m)){$log+=$m}
 $ps.Dispose();$rs.Dispose()
 @{Result=$sync.Result;Errors=$errs;Log=$log}}

function DhtState($a){                      # what is on the system right now, as a comparable string
 switch($a.K){
  'Reg'{$k=Get-Item -LiteralPath $a.P -ErrorAction SilentlyContinue
   if($k -and ($k.GetValueNames() -contains $a.N)){"{0}:{1}" -f $k.GetValueKind($a.N),((@($k.GetValue($a.N,$null,'DoNotExpandEnvironmentNames'))) -join ',')}else{'<absent>'}}
  {$_ -in 'Svc','SvcM'}{$p=Get-ItemProperty "HKLM:\SYSTEM\CurrentControlSet\Services\$($a.N)" -ErrorAction SilentlyContinue
   if($p){"Start=$($p.Start);Delayed=$([int]$p.DelayedAutostart)"}else{'<absent>'}}
  'Task'{$t=Get-ScheduledTask -TaskPath (Task-Path $a.N) -TaskName (Split-Path $a.N -Leaf) -ErrorAction SilentlyContinue
   if($t){if("$($t.State)" -eq 'Disabled'){'Disabled'}else{'Enabled'}}else{'<absent>'}}
  'Startup'{$v=(Get-ItemProperty -Path $a.A -Name $a.N -ErrorAction SilentlyContinue).($a.N);if($null -ne $v){[Convert]::ToBase64String([byte[]]$v)}else{'<absent>'}}
  default{'?'}}}

function DhtPng($name){                     # render the window content to a PNG without showing the window
 try{$root=$w.Content;$w.Content=$null
  $bd=New-Object Windows.Controls.Border;$bd.Background=$bc.ConvertFromString('#1E1E1E');$bd.Child=$root
  [Windows.Documents.TextElement]::SetForeground($bd,$bc.ConvertFromString('#F3F3F3'));[Windows.Documents.TextElement]::SetFontFamily($bd,$w.FontFamily)
  $sz=New-Object Windows.Size 1140,820;$bd.Measure($sz);$bd.Arrange((New-Object Windows.Rect 0,0,1140,820));$bd.UpdateLayout()
  $bmp=New-Object Windows.Media.Imaging.RenderTargetBitmap 1140,820,96,96,([Windows.Media.PixelFormats]::Pbgra32);$bmp.Render($bd)
  $enc=New-Object Windows.Media.Imaging.PngBitmapEncoder;$enc.Frames.Add([Windows.Media.Imaging.BitmapFrame]::Create($bmp))
  $fs=[IO.File]::Create((Join-Path $DhtOut "$name.png"));$enc.Save($fs);$fs.Close()
  $bd.Child=$null;$w.Content=$root;return $true}catch{Write-Host "screenshot $name failed: $($_.Exception.Message)";try{$bd.Child=$null;$w.Content=$root}catch{};return $false}}

# ---------------- 0) service mode for this run ----------------
New-Item 'HKCU:\SOFTWARE\DebloatHub' -Force|Out-Null
New-ItemProperty 'HKCU:\SOFTWARE\DebloatHub' -Name ServiceMode -Value $DhtMode -PropertyType String -Force|Out-Null
Remove-ItemProperty 'HKCU:\SOFTWARE\DebloatHub' -Name UiMode -ErrorAction SilentlyContinue   # first start: chooser

# ---------------- 1) parse ----------------
$tok=$null;$perr=$null;[void][Management.Automation.Language.Parser]::ParseFile($DhtScript,[ref]$tok,[ref]$perr)
DhtCheck 'Parse with Windows PowerShell 5.1' ($perr.Count -eq 0) $(if($perr.Count){($perr|Select-Object -First 3|ForEach-Object{"L$($_.Extent.StartLineNumber): $($_.Message)"}) -join '; '}else{"PowerShell $($PSVersionTable.PSVersion)"})
if($perr.Count){DhtFinish}

# ---------------- 2) load (builds the tweak list and the whole UI, does not show it) ----------------
$DhtT0=Get-Date
try{. $DhtScript -NoShow
 $ErrorActionPreference='Continue'
 DhtCheck 'Load script with -NoShow' ($db.Count -gt 50 -and $units.Count -gt 50) ("{0:N1} s, {1} tweaks, {2} switches, {3} sections, W11={4}, strict={5}" -f ((Get-Date)-$DhtT0).TotalSeconds,$db.Count,$units.Count,$secs.Count,$W11,$SvcStrict)}
catch{$ErrorActionPreference='Continue';DhtCheck 'Load script with -NoShow' $false "$($_.Exception.Message) $($_.ScriptStackTrace)";DhtFinish}
DhtCheck 'Service mode picked up from HKCU' ($SvcStrict -eq ($DhtMode -eq 'Strict')) "SvcStrict=$SvcStrict"

# ---------------- 3) sanity ----------------
$dupN=@($db|Group-Object Name|Where-Object Count -gt 1|ForEach-Object Name)
DhtCheck 'Unique tweak names' (-not $dupN.Count) ($dupN -join '; ')
$dupK=@($units|Group-Object {$_.Key}|Where-Object Count -gt 1|ForEach-Object Name)
DhtCheck 'Unique switch keys' (-not $dupK.Count) ($dupK -join '; ')
$noMore=@($db|Where-Object{-not $more.ContainsKey($_.Name)}|ForEach-Object Name)
DhtCheck 'Every tweak has need/pros/cons' (-not $noMore.Count) ($noMore -join '; ')
$orph=@($db|Where-Object{$secs -notcontains $_.Sec}|ForEach-Object{"$($_.Name) [$($_.Sec)]"})
DhtCheck 'Every tweak is in a visible section' (-not $orph.Count) ($orph -join '; ')
$recN=@($units|Where-Object{(Fits $_.T) -and (Is-Rec $_)}).Count
DhtCheck 'Recommended selects switches' ($recN -gt 20) "$recN switches"

try{
# ---------------- 4) every detector against the real system ----------------
$derr=@();$DhtT0=Get-Date
foreach($t in $db){foreach($a in $t.Acts){try{$null=Test-Act $a}catch{$derr+="$($t.Name) / $(Show-Act $a): $($_.Exception.Message)"}}}
DhtCheck 'All detectors run without errors' (-not $derr.Count) ("{0:N0} s; {1}" -f ((Get-Date)-$DhtT0).TotalSeconds,(($derr|Select-Object -First 8) -join ' || '))

# ---------------- 5) background scan + UI update ----------------
$scan=DhtEngine (New-ScanData) $SCANCODE
DhtCheck 'Background scan job' ($scan.Result -and $scan.Result.Ok -and -not $scan.Errors.Count) $(if($scan.Result -and $scan.Result.Ok){"states: "+((@($scan.Result.Stat.Values)|Group-Object|ForEach-Object{"$($_.Name)=$($_.Count)"}) -join ', ')}else{"$($scan.Result.Error) $($scan.Errors -join '; ')"})
DhtCheck 'System check returns data' (@($scan.Result.Sys).Count -gt 0) ((@($scan.Result.Sys)|ForEach-Object{"[$($_.S)] $($_.L)"}) -join ', ')
try{Scan-Done $scan.Result;DhtCheck 'UI updates from the scan (Apply-ScanResult)' ($script:scanned -and $stat.Count -gt 0) "$($stat.Count) tweak states shown"}catch{DhtCheck 'UI updates from the scan (Apply-ScanResult)' $false $_.Exception.Message}

# ---------------- 6) screenshots ----------------
$shots=@()
Show-View 'choose';if(DhtPng '1-start-page'){$shots+='1-start-page'}
Show-View 'simple';Update-Simple;if(DhtPng '2-simple-view'){$shots+='2-simple-view'}
Show-View 'advanced';if(DhtPng '3-advanced-view'){$shots+='3-advanced-view'}
$nav.SelectedIndex=[array]::IndexOf($secs,'Performance & Gaming')+1;Refresh-View;if(DhtPng '4-performance-section'){$shots+='4-performance-section'}
$nav.SelectedIndex=[array]::IndexOf($secs,$sSvc)+1;Refresh-View;if(DhtPng '5-background-services'){$shots+='5-background-services'}
$nav.SelectedIndex=0;Refresh-View
DhtCheck 'Screenshots rendered' ($shots.Count -eq 5) ($shots -join ', ')
DhtCheck 'Simple view counts' ($tRec.Text -and $tUndo.Text) "Debloat: '$($tRec.Text)', Gaming: '$($tGame.Text)', Undo: '$($tUndo.Text)'"

# ---------------- 7) apply -> verify -> undo round trip ----------------
$kinds='Reg','Svc','SvcM','Task','Startup'
# Autoruns tasks/services are this machine's own software (e.g. the CI runner agent): environment-specific, so not part of the round trip
$cand=@($units|Where-Object{(Fits $_.T) -and $_.Box.IsEnabled -and $ust[$_.Key] -notin 'Applied','N/A' -and -not @($_.Acts|Where-Object{$_.K -notin $kinds}).Count -and $_.T.Name -notmatch '^(Task|Service): '})
$acts=@();foreach($u in $cand){foreach($a in $u.Acts){$acts+=,$a}}
$before=@{};foreach($a in $acts){$before[(Snap-Id $a)]=DhtState $a}
$items=@(foreach($u in $cand){@{Label="[APPLY] $($u.Key)";Acts=@($u.Acts|ForEach-Object{Copy-Act $_});Undo=$false}})
$DhtT0=Get-Date;$ap=DhtEngine @{items=$items;dry=$false;rp=$false} $APPLYCODE
$apFail=@($ap.Result.Failed)
DhtCheck 'Apply: every change verified on the system' (-not $apFail.Count -and -not $ap.Errors.Count) ("{0} switches, {1} done, {2} skipped, {3:N0} s{4}" -f $cand.Count,$ap.Result.Done,$ap.Result.Skipped,((Get-Date)-$DhtT0).TotalSeconds,$(if($apFail.Count -or $ap.Errors.Count){'; '+((@($apFail)+@($ap.Errors)|Select-Object -First 6) -join ' || ')}))

# rescan, then let the Simple view pick what "Undo" would revert (tests DH-Changed / Undo-Units / Pending)
$scan2=DhtEngine (New-ScanData) $SCANCODE;Scan-Done $scan2.Result
$undoUnits=@(Undo-Units)
$nowApplied=@($cand|Where-Object{$ust[$_.Key] -eq 'Applied'})          # (mutually exclusive pairs: the second one applied wins)
$missing=@($nowApplied|Where-Object{$undoUnits -notcontains $_}|ForEach-Object{$_.Key})
DhtCheck 'Simple "Undo" finds the applied changes' ($nowApplied.Count -gt 0 -and -not $missing.Count) "$($undoUnits.Count) switches to undo, $($nowApplied.Count) applied now$(if($missing.Count){'; missing: '+($missing -join '; ')})"
Pick $null;foreach($u in $undoUnits){$u.Box.IsChecked=$false};Sync-Masters
$pend=Pending;$rem=@($pend[1])
$uitems=@(foreach($u in $rem){@{Label="[REVERT] $($u.Key)";Acts=@($u.Acts|ForEach-Object{Copy-Act $_});Undo=$true}})
$DhtT0=Get-Date;$un=DhtEngine @{items=$uitems;dry=$false;rp=$false} $APPLYCODE
$unFail=@($un.Result.Failed)
DhtCheck 'Undo: every revert verified on the system' (-not $unFail.Count -and -not $un.Errors.Count) ("{0} switches, {1} done, {2:N0} s{3}" -f $rem.Count,$un.Result.Done,((Get-Date)-$DhtT0).TotalSeconds,$(if($unFail.Count -or $un.Errors.Count){'; '+((@($unFail)+@($un.Errors)|Select-Object -First 6) -join ' || ')}))

$diff=@();foreach($a in $acts){$id=Snap-Id $a;$now=DhtState $a;if($now -ne $before[$id]){$diff+="$(Show-Act $a): before '$($before[$id])', after undo '$now'"};$DhtRes.roundTrip+=,([ordered]@{act=(Show-Act $a);before=$before[$id];after=$now})}
DhtCheck 'Undo restores the exact original state' (-not $diff.Count) ("{0} settings compared{1}" -f $acts.Count,$(if($diff.Count){"; $($diff.Count) differ: "+(($diff|Select-Object -First 8) -join ' || ')}))
$left=@();foreach($a in $acts){if(Snap-Read $a){$left+=(Show-Act $a)}}
DhtCheck 'Undo records are cleaned up' (-not $left.Count) (($left|Select-Object -First 5) -join '; ')

}catch{DhtCheck 'Test run finished without an unexpected error' $false "$($_.Exception.Message) at $($_.InvocationInfo.ScriptLineNumber): $($_.InvocationInfo.Line.Trim())"}
try{$ap.Log+$un.Log|Set-Content (Join-Path $DhtOut 'engine-log.txt') -Encoding UTF8}catch{}
DhtFinish
