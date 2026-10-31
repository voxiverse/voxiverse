@echo off
rem Voxiverse build entry. Everything lives in tools/build (run `build help`).
cd /d "%~dp0"
where /q odin || (echo build: odin not found - install the toolchain with odinup ^(see README^) 1>&2 & exit /b 1)
if not exist build\cache mkdir build\cache
rem The driver is rebuilt only when what it was built from changed (it keeps the
rem content key of its own sources: tools/build/cache.odin).
build\build-driver.exe self-fresh >nul 2>&1
if errorlevel 1 (
	type nul > build\cache\build-driver.started
	odin build tools/build -out:build/build-driver.exe -collection:client=client -collection:server=server -collection:common=common -export-dependencies:json -export-dependencies-file:build/cache/build-driver.deps.json || exit /b 1
	build\build-driver.exe self-built
)
build\build-driver.exe %*
