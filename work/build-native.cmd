@echo off
setlocal
call "C:\Program Files (x86)\Microsoft Visual Studio\2022\BuildTools\VC\Auxiliary\Build\vcvars64.bat" >nul
if errorlevel 1 exit /b 1
msbuild "%~dp0WitcherNativeBridge\WitcherNativeBridge.sln" -p:Configuration=Release -p:Platform=x64 -p:OutDir="%~dp0WitcherNativeBridge\build\Release/" -v:minimal -nologo
if errorlevel 1 exit /b 1
call "%~dp0witcher3-coop\w3test\build.cmd"
if errorlevel 1 exit /b 1
cl /nologo /EHsc /O2 /MD /std:c++17 /W3 /I"%~dp0WitcherNativeBridge\include" "%~dp0native-tests\sandbox_fixture.cpp" /Fo"%~dp0native-tests\sandbox_fixture.obj" /Fe"%~dp0native-tests\sandbox_fixture.exe"
if errorlevel 1 exit /b 1
cl /nologo /EHsc /O2 /MD /std:c++17 /W4 /WX "%~dp0native-tests\string_result_test.cpp" /Fo"%~dp0native-tests\string_result_test.obj" /Fe"%~dp0native-tests\string_result_test.exe"
if errorlevel 1 exit /b 1
"%~dp0native-tests\string_result_test.exe"
if errorlevel 1 exit /b 1
echo NATIVE_BUILD_OK
