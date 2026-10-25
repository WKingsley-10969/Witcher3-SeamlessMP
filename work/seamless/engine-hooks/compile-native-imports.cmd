@echo off
setlocal
call "C:\Program Files (x86)\Microsoft Visual Studio\2022\BuildTools\VC\Auxiliary\Build\vcvars64.bat" >nul
if errorlevel 1 exit /b 1
cl /nologo /c /std:c++17 /EHsc /W4 /WX /DWITCHER_NATIVE_BRIDGE_EXPORTS /I"%~dp0..\..\WitcherNativeBridge\include" /Fo:"%~dp0NativeImports.check.obj" "%~dp0..\..\WitcherNativeBridge\src\NativeImports.cpp"
exit /b %errorlevel%
