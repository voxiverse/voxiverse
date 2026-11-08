@echo off
rem Voxiverse build entry. Everything lives in tools/build (run `build help`).
cd /d "%~dp0"
where /q odin || (echo build: odin not found - install the toolchain with odinup ^(see README^) 1>&2 & exit /b 1)
if not exist build mkdir build
rem The driver is rebuilt when missing.
if not exist build\build-driver.exe (
	odin build tools/build -out:build\build-driver.exe -collection:client=client -collection:server=server -collection:common=common || exit /b 1
)
build\build-driver.exe %*
