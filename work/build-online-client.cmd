@echo off
setlocal
call "C:\Program Files (x86)\Microsoft Visual Studio\2022\BuildTools\VC\Auxiliary\Build\vcvars64.bat" >nul
if errorlevel 1 exit /b 1
msbuild "%~dp0WitcherOnline\client\MultiplayerClient.vcxproj" -p:Configuration=Release -p:Platform=x64 -p:OutDir="%~dp0WitcherOnline\client\build\Release/" -p:IntDir="%~dp0WitcherOnline\client\build\obj/" -v:minimal -nologo
exit /b %errorlevel%
