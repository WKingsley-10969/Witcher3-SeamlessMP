# Rebuild the native components

Requires Visual Studio 2022 C++ Build Tools (v143 and Windows SDK). No game is required to compile. The included `source` directory preserves the expected repository layout.

From a VS 2022 x64 Native Tools command prompt:

```bat
cd source\WitcherNativeBridge
msbuild WitcherNativeBridge.sln -p:Configuration=Release -p:Platform=x64
cd ..\witcher3-coop
w3test\build.cmd
```

The bridge builds under `source/WitcherNativeBridge/build/Release`; the helper builds to `source/witcher3-coop/w3test/build/w3test.asi`. Deploy only to an isolated game copy and update its helper hash after rebuilding.

Compile/run the standalone fixture from the package root in that x64 command prompt:

```bat
cl /nologo /EHsc /O2 /MD /std:c++17 /W3 /I source\WitcherNativeBridge\include source\native-tests\sandbox_fixture.cpp /Fe:source\native-tests\sandbox_fixture.exe /Fo:source\native-tests\sandbox_fixture.obj
python source\native-tests\test_sandbox.py
```

Python is for the test runner, not for playing. The fixture runs separate test processes without launching Witcher 3. Unchanged baseline native client/server source is under `mod/W3Coop/source`; use its upstream instructions if modifying it.
