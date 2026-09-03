<#
.SYNOPSIS
    Build Watch Key for one device, or package it for the store. Windows.

.DESCRIPTION
    The equivalent of scripts/build.sh for PowerShell. Needs the Connect IQ
    SDK installed - the SDK Manager from developer.garmin.com is the easiest
    route on Windows, because it handles both the Garmin sign-in and the
    device downloads.

    If you already work in VS Code with Garmin's Monkey C extension, you do
    not need this script: "Monkey C: Build Current Project" does the same job.

.EXAMPLE
    scripts\build.ps1
    scripts\build.ps1 -Device venu3
    scripts\build.ps1 -Package
#>
param(
    [string]$Device = "fenix7",
    [switch]$Package
)

$ErrorActionPreference = "Stop"
Set-Location (Join-Path $PSScriptRoot "..")

# Find monkeyc: on PATH first, then where the SDK Manager installs SDKs.
$monkeyc = (Get-Command monkeyc.bat -ErrorAction SilentlyContinue).Source
if (-not $monkeyc) {
    $sdkRoot = Join-Path $env:APPDATA "Garmin\ConnectIQ\Sdks"
    if (Test-Path $sdkRoot) {
        # Newest SDK wins if several are installed.
        $monkeyc = Get-ChildItem $sdkRoot -Directory |
            Sort-Object Name -Descending |
            ForEach-Object { Join-Path $_.FullName "bin\monkeyc.bat" } |
            Where-Object { Test-Path $_ } |
            Select-Object -First 1
    }
}
if (-not $monkeyc) {
    Write-Error @"
monkeyc not found.

Install the Connect IQ SDK Manager from https://developer.garmin.com/connect-iq/sdk/,
sign in, install an SDK and the devices you target, then re-run this script.
"@
}
Write-Host "using $monkeyc"

# The signing key identifies you as the publisher. The store ties an app to
# the key that signed it, so losing it means no more updates to that listing.
# It is gitignored - never commit it.
if (-not (Test-Path "developer_key.der")) {
    # Windows ships no openssl, but Git for Windows does.
    $openssl = (Get-Command openssl.exe -ErrorAction SilentlyContinue).Source
    if (-not $openssl) {
        $candidate = "C:\Program Files\Git\usr\bin\openssl.exe"
        if (Test-Path $candidate) { $openssl = $candidate }
    }
    if ($openssl) {
        Write-Host "generating developer key..."
        $pem = [System.IO.Path]::GetTempFileName()
        try {
            & $openssl genrsa -out $pem 4096 2>$null
            & $openssl pkcs8 -topk8 -inform PEM -outform DER -in $pem -out developer_key.der -nocrypt
        } finally {
            Remove-Item $pem -ErrorAction SilentlyContinue
        }
        Write-Host "wrote developer_key.der"
    } else {
        Write-Error @"
No developer key, and openssl was not found to generate one.

In VS Code, run "Monkey C: Generate a Developer Key" from the command palette
and save it as developer_key.der in this folder.
"@
    }
}

New-Item -ItemType Directory -Force -Path bin | Out-Null

if ($Package) {
    Write-Host "packaging for the store..."
    & $monkeyc -f monkey.jungle -o bin\watchkey.iq -y developer_key.der -e -r -w
    Write-Host "wrote bin\watchkey.iq"
} else {
    Write-Host "building for $Device..."
    & $monkeyc -f monkey.jungle -o "bin\watchkey-$Device.prg" -y developer_key.der -d $Device -w
    Write-Host "wrote bin\watchkey-$Device.prg"
}
