# DebloatHub one-line installer. Paste into PowerShell:
#
#     irm https://grappura.github.io/DebloatHub/install.ps1 | iex
#
# It downloads DebloatHub.ps1 from the latest GitHub release, checks its SHA-256 against the release's SHA256SUMS.txt,
# keeps it in %LOCALAPPDATA%\DebloatHub and starts it (Windows asks for administrator rights). Nothing else is installed.
# Source: https://github.com/GrappurA/DebloatHub
& {
    $ErrorActionPreference = 'Stop'
    $ProgressPreference = 'SilentlyContinue'   # Windows PowerShell 5.1 downloads many times faster without the progress bar
    try { [Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12 } catch {}

    $repo = 'https://github.com/GrappurA/DebloatHub'
    $base = "$repo/releases/latest/download"
    if ($env:DEBLOATHUB_RELEASE) { $base = "$repo/releases/download/$($env:DEBLOATHUB_RELEASE)" }   # a fixed version, e.g. v1.2.2
    $dir = Join-Path $env:LOCALAPPDATA 'DebloatHub'
    $ps1 = Join-Path $dir 'DebloatHub.ps1'
    $new = Join-Path $dir 'DebloatHub.ps1.download'
    $sum = Join-Path $dir 'SHA256SUMS.txt'

    try {
        Write-Host ''
        Write-Host '  DebloatHub installer' -ForegroundColor Cyan
        Write-Host "  Downloading the latest release from $repo ..."
        New-Item -ItemType Directory -Force -Path $dir | Out-Null
        Invoke-WebRequest -Uri "$base/DebloatHub.ps1" -OutFile $new -UseBasicParsing
        Invoke-WebRequest -Uri "$base/SHA256SUMS.txt" -OutFile $sum -UseBasicParsing

        # SHA256SUMS.txt lines: "<hash>  <file name>"
        $want = @(Get-Content -LiteralPath $sum | ForEach-Object { if ($_ -match '^\s*([0-9a-fA-F]{64})\s+\*?DebloatHub\.ps1\s*$') { $Matches[1] } }) | Select-Object -First 1
        if (-not $want) { throw 'SHA256SUMS.txt of the release does not list DebloatHub.ps1.' }
        $got = (Get-FileHash -LiteralPath $new -Algorithm SHA256).Hash
        if ($got -ne $want) { throw "The downloaded file does not match the release checksum (expected $want, got $got). Nothing was started." }
        Move-Item -LiteralPath $new -Destination $ps1 -Force

        $ver = (Select-String -LiteralPath $ps1 -Pattern "^\`$AppVersion='([^']+)'" | Select-Object -First 1).Matches.Groups[1].Value
        Write-Host "  DebloatHub v$ver downloaded and verified (SHA-256 $($got.Substring(0,16))...)." -ForegroundColor Green
        Write-Host "  Saved to $ps1"

        if ($env:DEBLOATHUB_NOSTART) { Write-Host '  DEBLOATHUB_NOSTART is set: not starting it.'; return }
        Write-Host '  Starting DebloatHub. Click Yes when Windows asks for administrator rights.'
        $exe = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
        Start-Process -FilePath $exe -ArgumentList "-NoProfile -ExecutionPolicy Bypass -File `"$ps1`""
        Write-Host ''
    }
    catch {
        Remove-Item -LiteralPath $new -Force -ErrorAction SilentlyContinue
        Write-Host ''
        Write-Host "  DebloatHub could not be installed: $($_.Exception.Message)" -ForegroundColor Red
        Write-Host "  You can also download DebloatHub.zip from $repo/releases/latest" -ForegroundColor Yellow
        Write-Host ''
        if ($env:DEBLOATHUB_NOSTART) { throw }   # make automated checks fail
    }
}
