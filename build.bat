@echo off
rem Voxiverse build entry. Everything lives in tools/build (run `build help`).
cd /d "%~dp0"
where /q odin || (echo build: odin not found - install the toolchain with odinup ^(see README^) 1>&2 & exit /b 1)
if not exist build mkdir build
odin run tools/build -out:build\build-driver.exe -- %*
