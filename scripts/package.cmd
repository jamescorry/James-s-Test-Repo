@echo off
REM Build the store/beta .iq package on Windows, at a known path.
REM
REM VS Code's "Monkey C: Export Project" asks for a destination folder, which
REM is easy to click past. This always writes bin\WatchKey.iq.
REM
REM Usage:  scripts\package.cmd [path\to\developer_key]
REM
REM Note this compiles every product in manifest.xml, not just one device, so
REM a device that cannot support a requested permission fails the whole
REM package. Build a single device first if you only want a smoke test:
REM   monkeyc -f monkey.jungle -o bin\WatchKey.prg -y KEY -d fenix8pro47mm -w

setlocal enabledelayedexpansion

set "SDK_ROOT=%APPDATA%\Garmin\ConnectIQ\Sdks"
set "SDK="
for /f "delims=" %%d in ('dir /b /ad /o-n "%SDK_ROOT%" 2^>nul') do (
    if not defined SDK set "SDK=%SDK_ROOT%\%%d"
)

if not defined SDK (
    echo No Connect IQ SDK found under "%SDK_ROOT%".
    echo Install one with the SDK Manager first.
    exit /b 1
)

set "KEY=%~1"
if "%KEY%"=="" set "KEY=developer_key.der"

if not exist "%KEY%" (
    echo Developer key not found: "%KEY%"
    echo Pass its path as the first argument, or generate one with
    echo "Monkey C: Generate a Developer Key" in VS Code.
    exit /b 1
)

if not exist bin mkdir bin

echo Using SDK: %SDK%
echo Using key: %KEY%

REM -e packages an .iq for every product in the manifest, -r optimises
REM resources, -w shows warnings.
java -Xms1g -Dfile.encoding=UTF-8 -jar "%SDK%\bin\monkeybrains.jar" ^
    -o bin\WatchKey.iq ^
    -f monkey.jungle ^
    -y "%KEY%" ^
    -e -r -w

if errorlevel 1 (
    echo.
    echo Packaging failed. If the errors name a device other than
    echo fenix8pro47mm, that device is the problem, not the code - trim
    echo manifest.xml to the devices you have verified.
    exit /b 1
)

echo.
echo Wrote bin\WatchKey.iq
