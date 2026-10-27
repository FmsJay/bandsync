@echo off
rem Build ninjamsrv.exe with MSVC (BandSync). Put this file in ninjam/ninjam/server/ of the NINJAM repo. Sources as in its Makefile.
call "C:\Program Files (x86)\Microsoft Visual Studio\2019\BuildTools\VC\Auxiliary\Build\vcvars64.bat" >nul
cd /d "%~dp0"
if not exist obj mkdir obj
cl /nologo /O2 /EHsc /MT /DWIN32 /D_CRT_SECURE_NO_WARNINGS /D_WINSOCK_DEPRECATED_NO_WARNINGS /Foobj\ /Fe:ninjamsrv.exe ^
  ..\..\WDL\jnetlib\asyncdns.cpp ..\..\WDL\jnetlib\connection.cpp ..\..\WDL\jnetlib\listen.cpp ^
  ..\..\WDL\jnetlib\util.cpp ..\..\WDL\jnetlib\httpget.cpp ..\..\WDL\rng.cpp ..\..\WDL\sha.cpp ^
  ..\mpb.cpp ..\netmsg.cpp usercon.cpp ninjamsrv.cpp ^
  /link ws2_32.lib user32.lib advapi32.lib
