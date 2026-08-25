<#
    comyudyu P4 Display - firmware installer

    One-liner:

        irm https://raw.githubusercontent.com/comudu/comyudyu-p4-display/main/install.ps1 | iex

    Grabs the latest release, finds the board, flashes it, starts it.
    Nothing to install first: it fetches its own copy of esptool.
#>

[CmdletBinding()]
param(
    [string]$Port,
    [string]$Tag = "latest",
    [switch]$EraseFlash
)

$ErrorActionPreference = 'Stop'

$Repo           = "comudu/comyudyu-p4-display"
$EsptoolVersion = "v5.3.1"
$CacheRoot      = Join-Path $env:LOCALAPPDATA "comyudyu-p4"

function Say  { param($m) Write-Host "==> $m" -ForegroundColor Cyan }
function Ok   { param($m) Write-Host "    $m" -ForegroundColor Green }
function Warn { param($m) Write-Host "    $m" -ForegroundColor Yellow }

function Get-Esptool {
    # esptool v5 renamed its subcommands to kebab-case, so the version is
    # pinned rather than picking up whatever might be on PATH.
    $dir = Join-Path $CacheRoot "esptool-$EsptoolVersion"
    $exe = Get-ChildItem $dir -Recurse -Filter esptool.exe -ErrorAction SilentlyContinue | Select-Object -First 1
    if ($exe) { return $exe.FullName }

    Say "Fetching esptool $EsptoolVersion (one time, ~60 MB)"
    New-Item -ItemType Directory -Force -Path $dir | Out-Null
    $zip = Join-Path $CacheRoot "esptool.zip"
    $ProgressPreference = 'SilentlyContinue'
    Invoke-WebRequest -UseBasicParsing -OutFile $zip `
        -Uri "https://github.com/espressif/esptool/releases/download/$EsptoolVersion/esptool-$EsptoolVersion-windows-amd64.zip"
    Expand-Archive $zip -DestinationPath $dir -Force
    Remove-Item $zip -Force -ErrorAction SilentlyContinue
    $exe = Get-ChildItem $dir -Recurse -Filter esptool.exe | Select-Object -First 1
    if (-not $exe) { throw "esptool.exe missing from the downloaded archive" }
    return $exe.FullName
}

function Get-Firmware {
    $api = if ($Tag -eq "latest") {
        "https://api.github.com/repos/$Repo/releases/latest"
    } else {
        "https://api.github.com/repos/$Repo/releases/tags/$Tag"
    }

    Say "Looking up the $Tag release"
    try {
        $rel = Invoke-RestMethod -Uri $api -Headers @{ 'User-Agent' = 'comyudyu-installer' }
    } catch {
        throw "Could not reach GitHub: $_"
    }

    $asset = $rel.assets | Where-Object { $_.name -like "*firmware*.zip" } | Select-Object -First 1
    if (-not $asset) { $asset = $rel.assets | Where-Object { $_.name -like "*.zip" } | Select-Object -First 1 }
    if (-not $asset) { throw "Release $($rel.tag_name) has no firmware zip attached" }
    Ok "$($rel.tag_name) - $($asset.name)"

    $dir = Join-Path $CacheRoot "fw-$($rel.tag_name)"
    if (Test-Path $dir) { Remove-Item $dir -Recurse -Force }
    New-Item -ItemType Directory -Force -Path $dir | Out-Null

    $zip = Join-Path $dir "firmware.zip"
    $ProgressPreference = 'SilentlyContinue'
    Invoke-WebRequest -Uri $asset.browser_download_url -OutFile $zip -UseBasicParsing
    Expand-Archive $zip -DestinationPath $dir -Force
    Remove-Item $zip -Force -ErrorAction SilentlyContinue

    $manifest = Get-ChildItem $dir -Recurse -Filter flasher_args.json | Select-Object -First 1
    if (-not $manifest) { throw "flasher_args.json missing from the release archive" }
    return $manifest.Directory.FullName
}

function Get-FlashPlan {
    param([string]$Dir)
    $j = Get-Content (Join-Path $Dir "flasher_args.json") -Raw | ConvertFrom-Json
    $plan = @{
        Flash = @{ Mode = $j.flash_settings.flash_mode
                   Freq = $j.flash_settings.flash_freq
                   Size = $j.flash_settings.flash_size }
        Files = @()
    }
    foreach ($p in $j.flash_files.PSObject.Properties) {
        $f = Join-Path $Dir $p.Value
        if (-not (Test-Path $f)) { throw "Release archive is missing $($p.Value)" }
        $plan.Files += @{ Addr = $p.Name; File = (Resolve-Path $f).Path }
    }
    $plan.Files = $plan.Files | Sort-Object { [Convert]::ToInt64($_.Addr, 16) }
    return $plan
}

function Find-Port {
    if ($Port) { return $Port }
    Say "Looking for the display"
    # The Full-Speed connector is an ESP32-P4 USB-Serial-JTAG: 303A:1001.
    $dev = Get-CimInstance Win32_PnPEntity -ErrorAction SilentlyContinue |
           Where-Object { $_.DeviceID -match 'VID_303A&PID_1001' -and $_.Name -match '\(COM\d+\)' } |
           Select-Object -First 1
    if (-not $dev) {
        throw @"
No board found.

  * Use the USB-C connector marked USB2 - the Full-Speed one. The High-Speed
    connector carries the picture and cannot flash.
  * It must be a data cable, not a charge-only one.
  * The panel wants a supply good for more than 600 mA.
  * Or re-run with:  -Port COMxx
"@
    }
    if ($dev.Name -match '\((COM\d+)\)') { Ok "$($matches[1])"; return $matches[1] }
    throw "Could not read a COM port out of '$($dev.Name)'"
}

function Esptool {
    param([string]$Exe, [string[]]$Arguments, [switch]$Tolerant)
    if ($Tolerant) {
        # The reset takes the board off USB while esptool still holds the port,
        # so it always finishes with a meaningless "cannot configure port".
        # (No 2>&1 - in Windows PowerShell that turns native stderr into
        # ErrorRecords, which under ErrorActionPreference=Stop would throw.)
        $prev = $ErrorActionPreference
        $ErrorActionPreference = 'Continue'
        try { & $Exe @Arguments 2>$null | Out-Null } catch { }
        $ErrorActionPreference = $prev
        return
    }
    & $Exe @Arguments
    if ($LASTEXITCODE -ne 0) { throw "esptool failed (exit $LASTEXITCODE)" }
}

try {
    Write-Host ""
    Write-Host "comyudyu P4 Display - firmware installer" -ForegroundColor White
    Write-Host ""

    $fwDir   = Get-Firmware
    $plan    = Get-FlashPlan -Dir $fwDir
    $esptool = Get-Esptool
    $com     = Find-Port

    if ($EraseFlash) {
        Say "Erasing flash"
        Esptool -Exe $esptool -Arguments @("--chip","esp32p4","--port",$com,
            "--before","default-reset","--after","no-reset","erase-flash")
    }

    Say "Flashing"
    $args = @("--chip","esp32p4","--port",$com,"--baud","460800",
              "--before","default-reset","--after","no-reset","write-flash",
              "--flash-mode",$plan.Flash.Mode,
              "--flash-freq",$plan.Flash.Freq,
              "--flash-size",$plan.Flash.Size)
    foreach ($f in $plan.Files) { $args += @($f.Addr, $f.File) }
    Esptool -Exe $esptool -Arguments $args
    Ok "Written and verified"

    # Deliberately not hard-reset: on this ESP32-P4 rev v1.0 the RTS reset
    # leaves the chip in ROM download mode, where the firmware never starts
    # and nothing reports an error.
    Say "Starting"
    Esptool -Tolerant -Exe $esptool -Arguments @("--chip","esp32p4","--port",$com,
        "--before","no-reset","--after","watchdog-reset","run")

    Say "Waiting for the display"
    $seen = $null
    for ($i = 0; $i -lt 20 -and -not $seen; $i++) {
        Start-Sleep -Milliseconds 500
        $seen = Get-CimInstance Win32_PnPEntity -ErrorAction SilentlyContinue |
                Where-Object { $_.DeviceID -match 'VID_C872&PID_1004' } | Select-Object -First 1
    }

    Write-Host ""
    if ($seen) {
        Write-Host "Done." -ForegroundColor Green
        Write-Host "    $($seen.DeviceID)"
    } else {
        Write-Host "Done - firmware written." -ForegroundColor Green
        Warn "The display has not appeared on USB yet; plug a cable into the"
        Warn "High-Speed connector (USB3) as well. The panel should already be"
        Warn "cycling its test patterns."
    }
    Write-Host ""
    Write-Host "Next: plug the High-Speed connector (USB3) into the PC, then add"
    Write-Host "the screen in SimHub. Windows binds the driver by itself."
    Write-Host ""
    # The last native call was the reset, whose failure is deliberately
    # ignored, so $LASTEXITCODE is still non-zero at this point. Clear it, or
    # a successful install looks like a failure to anything checking after.
    #
    # Not `exit 0`: the documented way to run this is `irm ... | iex`, where
    # the script shares the caller's scope and `exit` would close the user's
    # PowerShell session.
    $global:LASTEXITCODE = 0
}
catch {
    Write-Host ""
    Write-Host "FAILED: $_" -ForegroundColor Red
    Write-Host ""
    $global:LASTEXITCODE = 1
    # Only bail out of the process when actually running as a script file;
    # under `irm | iex` this would take the user's session down with it.
    if ($PSCommandPath) { exit 1 }
}
