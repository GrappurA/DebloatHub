# Tests for DebloatHub.ps1 that run without Windows UI or administrator rights (Windows PowerShell 5.1 and PowerShell 7, Windows or Linux).
# Usage: powershell -NoProfile -File tests\Test-DebloatHub.ps1      Exit code = number of failed tests.
# The engine functions are loaded straight from the script's syntax tree, so the GUI never starts.
$ErrorActionPreference = 'Stop'
$script:Failed = 0; $script:Passed = 0
$root = Split-Path -Parent $PSScriptRoot
$path = Join-Path $root 'DebloatHub.ps1'
function Check([string]$name, [scriptblock]$test) {
    try { $r = & $test; if ($r -eq $false) { throw 'returned $false' }; $script:Passed++; Write-Host "  ok    $name" }
    catch { $script:Failed++; Write-Host "  FAIL  $name : $($_.Exception.Message)" -ForegroundColor Red }
}
function Eq($actual, $expected, $what = 'value') {
    if ("$actual" -cne "$expected") { throw "$what was [$actual], expected [$expected]" }; $true
}

# ---------- parse ----------
$tokens = $null; $errors = $null
$ast = [System.Management.Automation.Language.Parser]::ParseFile($path, [ref]$tokens, [ref]$errors)
Write-Host 'Syntax'
Check 'script parses without errors' { if ($errors.Count) { throw ($errors | ForEach-Object { "L$($_.Extent.StartLineNumber): $($_.Message)" }) -join '; ' } }
Check 'script is pure ASCII (Windows PowerShell 5.1 reads BOM-less files as ANSI)' {
    $b = [IO.File]::ReadAllBytes($path); $bad = @($b | Where-Object { $_ -gt 127 }).Count; if ($bad) { throw "$bad non-ASCII byte(s)" } }

$funcs = @{}
foreach ($f in $ast.FindAll({ param($n) $n -is [System.Management.Automation.Language.FunctionDefinitionAst] }, $true)) { $funcs[$f.Name] = $f.Extent.Text }
function Load([string[]]$names) { foreach ($n in $names) { if (-not $funcs.ContainsKey($n)) { throw "function $n not found" } }; [scriptblock]::Create(($names | ForEach-Object { $funcs[$_] }) -join "`n") }   # use as: . (Load 'A','B')

# ---------- static consistency checks ----------
Write-Host 'Consistency'
$cmds = @($ast.FindAll({ param($n) $n -is [System.Management.Automation.Language.CommandAst] }, $true))
$strVars = @{}; foreach ($a in $ast.FindAll({ param($n) $n -is [System.Management.Automation.Language.AssignmentStatementAst] -and $n.Left -is [System.Management.Automation.Language.VariableExpressionAst] }, $true)) { $r = $a.Right; if ($r -is [System.Management.Automation.Language.CommandExpressionAst] -and $r.Expression -is [System.Management.Automation.Language.StringConstantExpressionAst]) { $strVars[$a.Left.VariablePath.UserPath] = $r.Expression.Value } }
function ConstArg($c, $i) { $e = $c.CommandElements; $k = 0; for ($x = 1; $x -lt $e.Count; $x++) { if ($e[$x] -is [System.Management.Automation.Language.CommandParameterAst]) { continue }; if ($k -eq $i) { if ($e[$x] -is [System.Management.Automation.Language.StringConstantExpressionAst]) { return $e[$x].Value }; if ($e[$x] -is [System.Management.Automation.Language.VariableExpressionAst] -and $strVars.ContainsKey($e[$x].VariablePath.UserPath) -and $c.GetCommandName() -ne 'fTw') { return $null }; if ($e[$x] -is [System.Management.Automation.Language.VariableExpressionAst] -and $i -eq 1) { return $strVars[$e[$x].VariablePath.UserPath] }; return $null }; $k++ }; $null }
$tweakNames = @{}
foreach ($c in $cmds) { $n = $c.GetCommandName(); if ($n -in 'fTw', 'AddT', 'SvcGroup') { $v = ConstArg $c 1; if ($n -eq 'SvcGroup') { $v = ConstArg $c 0 }; if ($v) { $tweakNames[$v] = $n } } }
Check 'tweak database found (100+ static tweaks)' { if ($tweakNames.Count -lt 100) { throw "only $($tweakNames.Count)" } }

$assign = @{}
foreach ($a in $ast.FindAll({ param($n) $n -is [System.Management.Automation.Language.AssignmentStatementAst] }, $true)) { $assign[$a.Left.Extent.Text] = $a }
function StringsIn($node) { @($node.FindAll({ param($n) $n -is [System.Management.Automation.Language.StringConstantExpressionAst] -and $n.StringConstantType -ne 'BareWord' }, $true) | ForEach-Object Value) }
$appNames = @{}
foreach ($sc in $ast.FindAll({ param($n) $n -is [System.Management.Automation.Language.StringConstantExpressionAst] }, $true)) { $appNames[$sc.Value] = 1 }
Check 'every Recommended entry names an existing tweak (or, for APP:<package>, a package the database lists)' {
    $miss = @(StringsIn $assign['$RECOMMENDED'].Right | Where-Object { if ($_ -like 'APP:*') { -not $appNames.ContainsKey($_.Substring(4)) } else { -not $tweakNames.ContainsKey(($_ -split '\|')[0]) } }); if ($miss.Count) { throw "unknown: $($miss -join ', ')" } }
Check 'every Simple "Debloat + Gaming" entry names an existing tweak' {
    $miss = @(StringsIn $assign['$SIMPLE_GAMING'].Right | Where-Object { -not $tweakNames.ContainsKey(($_ -split '\|')[0]) }); if ($miss.Count) { throw "unknown: $($miss -join ', ')" } }
Check 'every fTw tweak has pros/cons in $more' {
    $keys = @{}
    foreach ($h in $assign['$more'].Right.FindAll({ param($n) $n -is [System.Management.Automation.Language.HashtableAst] }, $true)) { foreach ($kv in $h.KeyValuePairs) { $keys[$kv.Item1.Value] = 1 } }
    foreach ($ix in $ast.FindAll({ param($n) $n -is [System.Management.Automation.Language.IndexExpressionAst] -and $n.Target.Extent.Text -eq '$more' }, $true)) { if ($ix.Index -is [System.Management.Automation.Language.StringConstantExpressionAst]) { $keys[$ix.Index.Value] = 1 } elseif ($ix.Index -is [System.Management.Automation.Language.VariableExpressionAst] -and $strVars.ContainsKey($ix.Index.VariablePath.UserPath)) { $keys[$strVars[$ix.Index.VariablePath.UserPath]] = 1 } }
    $miss = @($tweakNames.Keys | Where-Object { $tweakNames[$_] -eq 'fTw' -and -not $keys.ContainsKey($_) }); if ($miss.Count) { throw "missing: $($miss -join ' | ')" } }
$engine = @(StringsIn ($ast.FindAll({ param($n) $n -is [System.Management.Automation.Language.AssignmentStatementAst] -and $n.Left.Extent.Text -eq '$ENGINE_TXT' }, $true) | Select-Object -First 1).Right)
Check 'every engine function listed for the background runspace exists' { $miss = @($engine | Where-Object { $_ -match '^[A-Z][\w-]+$' -and -not $funcs.ContainsKey($_) }); if ($miss.Count) { throw ($miss -join ', ') } }
Check 'every function a tweak command calls is shipped to the background runspace' {
    $miss = @()
    foreach ($c in $cmds | Where-Object { $_.GetCommandName() -eq 'fCmd' }) {
        foreach ($i in 0, 1, 2) {
            $v = ConstArg $c $i; if (-not $v) { continue }
            $sub = [System.Management.Automation.Language.Parser]::ParseInput($v, [ref]$null, [ref]$null)
            foreach ($cc in $sub.FindAll({ param($n) $n -is [System.Management.Automation.Language.CommandAst] }, $true)) { $nm = $cc.GetCommandName(); if ($nm -and $funcs.ContainsKey($nm) -and $engine -notcontains $nm) { $miss += $nm } } } }
    if ($miss.Count) { throw (@($miss | Select-Object -Unique) -join ', ') } }
Check 'no Remove-Item -Recurse on user-writable folders (use Clear-Folder: 5.1 follows junctions)' {
    $bad = @($cmds | Where-Object { $_.GetCommandName() -eq 'Remove-Item' -and $_.Extent.Text -match '-Recurse' -and $_.Extent.Text -notmatch "Registry|HKLM|HKCU|DebloatHub\\Dns|CLSID|LiteralPath '\`$k'" })
    $bad = @($bad | Where-Object { $_.Extent.Text -notmatch '^Remove-Item -LiteralPath \$k -Recurse' })
    if ($bad.Count) { throw ($bad | ForEach-Object { "L$($_.Extent.StartLineNumber)" }) -join ', ' } }
Check 'pnputil is never called with /force' { if (@($cmds | Where-Object { $_.Extent.Text -match 'pnputil' -and $_.Extent.Text -match '/force' }).Count) { throw 'found' } }
Check 'every Start-Process of PowerShell uses the 64-bit $PSExe' {
    $bad = @($cmds | Where-Object { $_.GetCommandName() -eq 'Start-Process' -and $_.Extent.Text -match '^Start-Process powershell\b' }); if ($bad.Count) { throw ($bad | ForEach-Object { "L$($_.Extent.StartLineNumber)" }) -join ', ' } }

# ---------- one-line installer ----------
Write-Host 'Installer'
$inst = Join-Path $root 'install.ps1'
Check 'install.ps1 parses without errors' { $e2 = $null; [void][System.Management.Automation.Language.Parser]::ParseFile($inst, [ref]$null, [ref]$e2); if ($e2.Count) { throw ($e2 | ForEach-Object Message) -join '; ' } }
Check 'install.ps1 is pure ASCII' { -not @([IO.File]::ReadAllBytes($inst) | Where-Object { $_ -gt 127 }).Count }
Check 'install.ps1 verifies the SHA-256 before saving or starting anything' { $t = [IO.File]::ReadAllText($inst); ($t.IndexOf('Get-FileHash') -gt 0) -and ($t.IndexOf('Get-FileHash') -lt $t.IndexOf('Move-Item')) -and ($t.IndexOf('Move-Item') -lt $t.IndexOf('Start-Process')) }
Check 'the release attaches install.ps1 and lists it in SHA256SUMS.txt' { $r = [IO.File]::ReadAllText((Join-Path $root '.github/workflows/release.yml')); ($r -match 'sha256sum [^\n]*install\.ps1') -and ($r -match 'dist/install\.ps1') }
Check 'README, landing page and release notes show the same one-liner' { $l = 'irm https://grappura.github.io/DebloatHub/install.ps1 | iex'; foreach ($f in 'README.md', 'site/index.html', '.github/workflows/release.yml', 'release/README.txt') { if (-not ([IO.File]::ReadAllText((Join-Path $root $f))).Contains($l)) { throw "missing in $f" } }; $true }

# ---------- JSONC in-place editing ----------
Write-Host 'JSONC editing'
. (Load 'Json-Strip', 'Jsonc-SkipWs', 'Jsonc-StrEnd', 'Jsonc-ValEnd', 'Jsonc-Scan', 'Jsonc-Esc', 'Jsonc-Edit')
$nl = "`n"
Check 'adds a key to an empty file' { $r = Jsonc-Edit '' 'a' '1'; ($r | ConvertFrom-Json).a -eq 1 }
Check 'adds a key to {} ' { $r = Jsonc-Edit '{}' 'a' '"x"'; Eq ($r | ConvertFrom-Json).a 'x' }
Check 'replaces a value and keeps comments' {
    $t = "{$nl  // keep me$nl  `"a`": 1, /* and me */$nl  `"b`": 2$nl}"; $r = Jsonc-Edit $t 'a' '5'
    if ($r -notmatch '// keep me' -or $r -notmatch '/\* and me \*/') { throw 'comment lost' }; Eq ((Json-Strip $r) | ConvertFrom-Json).a 5 }
Check 'keeps trailing-comma style when adding' { $t = "{$nl    `"a`": 1,$nl}"; $r = Jsonc-Edit $t 'b' 'true'; if ($r -notmatch '"b": true,') { throw $r }; ((Json-Strip $r) | ConvertFrom-Json).b -eq $true }
Check 'removing the last key drops the dangling comma' { $t = "{$nl  `"a`": 1,$nl  `"b`": 2$nl}"; $r = Jsonc-Edit $t 'b' $null; $o = (Json-Strip $r) | ConvertFrom-Json; if ($o.PSObject.Properties['b']) { throw 'still there' }; Eq $o.a 1 }
Check 'strings containing // and /* are not treated as comments' { $t = "{ `"url`": `"http://x/*y`", `"g`": `"**/*.js`" }"; $r = Jsonc-Edit $t 'n' '1'; $o = (Json-Strip $r) | ConvertFrom-Json; (Eq $o.url 'http://x/*y') -and (Eq $o.g '**/*.js') }
Check 'refuses a file that is not an object' { try { Jsonc-Edit '[1,2]' 'a' '1'; $false } catch { $true } }

# ---------- driver store selection ----------
Write-Host 'Driver Store cleanup selection'
. (Load 'Select-StaleDrivers')
function Drv($d, $inf, $ver, $date, $cls = 'Display', $boot = $false) { [pscustomobject]@{Driver = $d; OriginalFileName = "C:\Windows\System32\DriverStore\FileRepository\$inf`_abc\$inf"; ProviderName = 'Acme'; ClassName = $cls; Version = $ver; Date = [datetime]$date; BootCritical = $boot } }
$drv = @((Drv 'oem1.inf' 'gpu.inf' '1.0' '2024-01-01'), (Drv 'oem2.inf' 'gpu.inf' '2.0' '2025-01-01'), (Drv 'oem3.inf' 'gpu.inf' '1.5' '2024-06-01'),
    (Drv 'oem4.inf' 'prn.inf' '1' '2020-01-01' 'Printer'), (Drv 'oem5.inf' 'prn.inf' '2' '2021-01-01' 'Printer'),
    (Drv 'oem6.inf' 'stor.inf' '1' '2020-01-01' 'SCSIAdapter' $true), (Drv 'oem7.inf' 'stor.inf' '2' '2021-01-01' 'SCSIAdapter' $true))
$plan = Select-StaleDrivers $drv @{ 'oem3.inf' = $true }; $plan = @($plan)
Check 'the plan is a flat list (not one wrapped array - the bug that broke the cleanup before 1.1.0)' { Eq $plan.Count 4 'number of entries' }
function Act($n) { ($plan | Where-Object { $_.Pkg.Driver -eq $n }).Action }
Check 'keeps the newest package of each family' { -not ($plan | Where-Object { $_.Pkg.Driver -in 'oem2.inf', 'oem5.inf', 'oem7.inf' }) }
Check 'deletes an older, unused package' { Eq (Act 'oem1.inf') 'delete' }
Check 'keeps an older package a device is using' { Eq (Act 'oem3.inf') 'keep' }
Check 'keeps printer drivers' { Eq (Act 'oem4.inf') 'keep' }
Check 'keeps boot-critical drivers' { Eq (Act 'oem6.inf') 'keep' }

# ---------- safe folder cleanup ----------
Write-Host 'Clear-Folder (junction-safe delete)'
. (Load 'Clear-Folder')
$base = Join-Path ([IO.Path]::GetTempPath()) ("dh-test-" + [guid]::NewGuid().ToString('N'))
$tgt = Join-Path $base 'outside'; $dir = Join-Path $base 'temp'
New-Item -ItemType Directory -Path $tgt, (Join-Path $dir 'sub\deeper') -Force | Out-Null
Set-Content (Join-Path $tgt 'precious.txt') 'do not delete'
Set-Content (Join-Path $dir 'a.tmp') 'x'; Set-Content (Join-Path $dir 'sub\deeper\b.tmp') 'x'; Set-Content (Join-Path $dir 'keep.ini') 'x'
$ro = Join-Path $dir 'ro.tmp'; Set-Content $ro 'x'; (Get-Item $ro).Attributes = 'ReadOnly'
$linkMade = $false
try { if ($IsLinux -or $IsMacOS) { New-Item -ItemType SymbolicLink -Path (Join-Path $dir 'link') -Target $tgt | Out-Null } else { New-Item -ItemType Junction -Path (Join-Path $dir 'link') -Target $tgt | Out-Null }; $linkMade = $true } catch { Write-Host "  (could not create a link here: $($_.Exception.Message))" }
$n = Clear-Folder $dir @('keep.ini')
Check 'empties the folder (files, read-only files and sub-folders)' { -not (Test-Path (Join-Path $dir 'a.tmp')) -and -not (Test-Path (Join-Path $dir 'sub')) -and -not (Test-Path $ro) }
Check 'keeps listed names' { Test-Path (Join-Path $dir 'keep.ini') }
Check 'keeps the folder itself' { Test-Path $dir }
if ($linkMade) {
    Check 'removes the junction/symlink itself' { -not (Test-Path (Join-Path $dir 'link')) }
    Check 'never deletes what a junction/symlink points to' { Test-Path (Join-Path $tgt 'precious.txt') }
}
Check 'returns 0 for a missing folder' { Eq (Clear-Folder (Join-Path $base 'nope')) 0 }
Remove-Item -LiteralPath $base -Recurse -Force -ErrorAction SilentlyContinue

# ---------- version fit / leftovers / state ----------
Write-Host 'State and leftovers'
. (Load 'Fits-Ver', 'Spi-Blocked', 'Fits', 'Is-Leftover', 'Get-StateEx')
$OtherUser = $false
function Has-Record($acts) { [bool]@($acts | Where-Object { $_.Rec }).Count }
$t10 = @{ Win = '10'; Acts = @(@{K = 'Reg'; Rec = $true }) }
$W11 = $true
Check 'a Windows 10 tweak does not fit Windows 11' { -not (Fits $t10) }
Check 'a Windows 10 tweak DebloatHub applied is a leftover on Windows 11 (undo stays possible)' { Is-Leftover $t10 }
Check 'a Windows 10 tweak never applied is not a leftover' { -not (Is-Leftover @{ Win = '10'; Acts = @(@{K = 'Reg' }) }) }
Check 'a tweak for this version is never a leftover' { -not (Is-Leftover @{ Win = 'Any'; Acts = @(@{K = 'Reg'; Rec = $true }) }) }
$OtherUser = $true
Check 'visual effects are blocked (not leftovers) when running as another account' { $t = @{ Win = 'Any'; Acts = @(@{K = 'Spi'; Rec = $true }) }; (-not (Fits $t)) -and -not (Is-Leftover $t) }
$OtherUser = $false
function Safe-Test($a) { $a.T }; function Act-Absent($a) { [bool]$a.Gone }
Check 'all targets missing = Not present (not Applied)' { Eq (Get-StateEx @{ Acts = @(@{T = $true; Gone = $true }, @{T = $true; Gone = $true }) }).State 'Not present' }
Check 'applied with targets present = Applied' { Eq (Get-StateEx @{ Acts = @(@{T = $true; Gone = $true }, @{T = $true }) }).State 'Applied' }
Check 'mixed = Partial' { Eq (Get-StateEx @{ Acts = @(@{T = $true }, @{T = $false }) }).State 'Partial' }
Check 'unknown only = Unknown' { Eq (Get-StateEx @{ Acts = @(@{T = $null }) }).State 'Unknown' }

# ---------- marker ids of older versions ----------
Write-Host 'Undo records of older versions'
. (Load 'Cmd-Id')
Check 'marker ids of rewritten commands match what v1.0/v1.1 wrote' {
    $old = @{
        'Cmd_382D9DC3F37109EF' = 'Disable-MMAgent -MemoryCompression'
        'Cmd_C3F6801958B79D8E' = 'powercfg /hibernate off'
    }
    foreach ($k in $old.Keys) { Eq (Cmd-Id @{V = $old[$k] }) $k "id of '$($old[$k])'" | Out-Null }
    $txt = [IO.File]::ReadAllText($path); foreach ($id in 'Cmd_26F50AB0DD212109', 'Cmd_3F2AA810B18B901E', 'Cmd_382D9DC3F37109EF', 'Cmd_C3F6801958B79D8E') { if (-not $txt.Contains($id)) { throw "$id not referenced" } }; $true }

# ---------- launcher ----------
Write-Host 'Launcher'
$bat = [IO.File]::ReadAllText((Join-Path $root 'Start DebloatHub.bat'))
Check 'launcher has CRLF line endings (cmd.exe misreads LF-only .bat files)' { if ($bat -match "[^`r]`n") { throw 'LF-only line found' } }
Check 'launcher does not put the folder path inside single quotes (breaks on apostrophes)' { -not ($bat -match "'%~dp0") }

Write-Host ''
Write-Host "$script:Passed passed, $script:Failed failed"
exit $script:Failed
