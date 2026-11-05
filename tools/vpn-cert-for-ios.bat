@echo off
rem vpn-cert-for-ios.bat - repack a RouterOS PKCS#12 for iOS import (drag & drop the .p12 onto this file).
rem RouterOS p12 holds leaf + CA (2 certs); iOS rejects it for an identity profile.
rem Output (beside the source): <peer>.ios.p12 = exactly 1 cert + 1 key, readable name.
rem Passwords are prompted by openssl itself (hidden input): source passphrase, then the new one twice.
rem Requires openssl.exe: found automatically in PATH, Git for Windows, or OpenSSL-Win64.
rem If missing, install once:  winget install --id FireFruitDevelopment.Openssl -e

setlocal EnableDelayedExpansion
if "%~1"=="" (
    echo Usage: drag a .p12 file onto vpn-cert-for-ios.bat
    pause
    exit /b 1
)
set "SRC=%~f1"
if not exist "%SRC%" (
    echo File not found: %SRC%
    pause
    exit /b 1
)

rem --- locate openssl.exe ---
set "SSL="
where openssl.exe >nul 2>&1 && set "SSL=openssl.exe"
if not defined SSL for %%D in (
    "%ProgramFiles%\Git\usr\bin"
    "%ProgramFiles(x86)%\Git\usr\bin"
    "%ProgramW6432%\Git\usr\bin"
    "%ProgramFiles%\OpenSSL-Win64\bin"
    "%ProgramFiles(x86)%\OpenSSL-Win32\bin"
    "%ProgramW6432%\OpenSSL-Win64\bin"
) do (
    if not defined SSL if exist "%%~D\openssl.exe" set "SSL=%%~D\openssl.exe"
)
if not defined SSL (
    echo openssl.exe not found. Install it once, then rerun:
    echo    winget install --id FireFruitDevelopment.Openssl -e
    echo ^(or install Git for Windows - it bundles openssl^)
    pause
    exit /b 1
)

rem --- peer name from file name, strip everything from '@' on ---
set "NAME=%~n1"
for /f "delims=@" %%A in ("!NAME!") do set "NAME=%%A"
if "!NAME!"=="" (
    echo Cannot derive a name from "%~nx1"
    pause
    exit /b 1
)

set "TMPD=%TEMP%\vci_%RANDOM%"
mkdir "%TMPD%" >nul 2>&1 || (echo Cannot create temp dir & pause & exit /b 1)

echo Repacking for iOS: 1 certificate + 1 key, friendly name: !NAME!
echo You will be asked: source passphrase, then the NEW passphrase twice (hidden input).
echo.

"%SSL%" pkcs12 -in "%SRC%" -nocerts -nodes -out "%TMPD%\key.pem" || goto :fail
"%SSL%" pkcs12 -in "%SRC%" -clcerts -nokeys -out "%TMPD%\leaf.pem" || goto :fail

find /c "BEGIN CERTIFICATE" < "%TMPD%\leaf.pem" | find "1" >nul || (
    echo Expected exactly 1 leaf certificate in the source p12.
    goto :fail
)

set "OUT=%~dp1!NAME!.ios.p12"
rem Apple (iOS/macOS) only unwraps 3DES/legacy-KDF p12 keys; PBES2 half-imports.
rem OpenSSL 3+: needs -legacy (and legacy provider). OpenSSL 1.1.x: no -legacy
rem flag, but 3DES PBE args work directly. Try both.
"%SSL%" pkcs12 -export -legacy -certpbe PBE-SHA1-3DES -keypbe PBE-SHA1-3DES -macalg sha1 -in "%TMPD%\leaf.pem" -inkey "%TMPD%\key.pem" -name "!NAME!" -out "%OUT%" 2>nul
if not exist "%OUT%" "%SSL%" pkcs12 -export -certpbe PBE-SHA1-3DES -keypbe PBE-SHA1-3DES -macalg sha1 -in "%TMPD%\leaf.pem" -inkey "%TMPD%\key.pem" -name "!NAME!" -out "%OUT%" || goto :fail
if not exist "%OUT%" goto :fail
rem warn if the key bag is not 3DES/PBES1 (OID 1.2.840.113549.1.12.1.3)
"%SSL%" asn1parse -inform DER -in "%OUT%" | find /i "060A2A864886F70D010C0103" >nul || (
    echo WARNING: output is not 3DES/PBES1 - Apple may reject the key.
)

del /q "%TMPD%\key.pem" "%TMPD%\leaf.pem" >nul 2>&1
rmdir "%TMPD%" >nul 2>&1

echo.
echo OK: %OUT%
echo iPhone: send/AirDrop it, install the profile with the NEW passphrase.
echo Install the CA profile ^(cert_export_CA...crt from the router^) separately,
echo then pick this identity in the IKEv2 VPN config.
pause
exit /b 0

:fail
del /q "%TMPD%\key.pem" "%TMPD%\leaf.pem" >nul 2>&1
rmdir "%TMPD%" >nul 2>&1
echo FAILED - see the openssl messages above.
pause
exit /b 1
