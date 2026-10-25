@echo off
setlocal
call "C:\Program Files (x86)\Microsoft Visual Studio\2022\BuildTools\VC\Auxiliary\Build\vcvars64.bat" >nul
if errorlevel 1 exit /b 1
cl /nologo /std:c++17 /EHsc /W4 /WX /Fe:"%~dp0fact_operations_test.exe" /Fo:"%~dp0fact_operations_test.obj" "%~dp0fact_operations_test.cpp"
if errorlevel 1 exit /b 1
"%~dp0fact_operations_test.exe"
exit /b %errorlevel%
