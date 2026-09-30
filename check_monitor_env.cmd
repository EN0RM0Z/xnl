@echo off

set OUT=monitor_environment.txt

echo MONITOR ENVIRONMENT CHECK > "%OUT%"
echo Date: %DATE% %TIME% >> "%OUT%"
echo. >> "%OUT%"

echo ============================================================ >> "%OUT%"
echo WINDOWS >> "%OUT%"
echo ============================================================ >> "%OUT%"
ver >> "%OUT%"
echo PROCESSOR_ARCHITECTURE=%PROCESSOR_ARCHITECTURE% >> "%OUT%"
echo PROCESSOR_ARCHITEW6432=%PROCESSOR_ARCHITEW6432% >> "%OUT%"
echo. >> "%OUT%"

echo ============================================================ >> "%OUT%"
echo .NET FRAMEWORK >> "%OUT%"
echo ============================================================ >> "%OUT%"

reg query "HKLM\SOFTWARE\Microsoft\NET Framework Setup\NDP\v4\Full" /v Release >> "%OUT%" 2>&1
reg query "HKLM\SOFTWARE\Microsoft\NET Framework Setup\NDP\v4\Full" /v Version >> "%OUT%" 2>&1

dir C:\Windows\Microsoft.NET\Framework64\v4.0.30319\csc.exe >> "%OUT%" 2>&1

echo. >> "%OUT%"

echo --- Framework assemblies --- >> "%OUT%"
dir C:\Windows\Microsoft.NET\Framework64\v4.0.30319\System.Windows.Forms.dll >> "%OUT%" 2>&1
dir C:\Windows\Microsoft.NET\Framework64\v4.0.30319\System.Drawing.dll >> "%OUT%" 2>&1
dir C:\Windows\Microsoft.NET\Framework64\v4.0.30319\System.Data.dll >> "%OUT%" 2>&1
dir C:\Windows\Microsoft.NET\Framework64\v4.0.30319\System.Net.Http.dll >> "%OUT%" 2>&1
dir C:\Windows\Microsoft.NET\Framework64\v4.0.30319\System.Core.dll >> "%OUT%" 2>&1
dir C:\Windows\Microsoft.NET\Framework64\v4.0.30319\System.Web.Extensions.dll >> "%OUT%" 2>&1

echo. >> "%OUT%"

echo --- WPF assemblies --- >> "%OUT%"
dir C:\Windows\Microsoft.NET\Framework64\v4.0.30319\PresentationFramework.dll >> "%OUT%" 2>&1
dir C:\Windows\Microsoft.NET\Framework64\v4.0.30319\PresentationCore.dll >> "%OUT%" 2>&1
dir C:\Windows\Microsoft.NET\Framework64\v4.0.30319\WindowsBase.dll >> "%OUT%" 2>&1

echo. >> "%OUT%"

echo ============================================================ >> "%OUT%"
echo BUILD TOOLS >> "%OUT%"
echo ============================================================ >> "%OUT%"

where csc >> "%OUT%" 2>&1
where msbuild >> "%OUT%" 2>&1
where dotnet >> "%OUT%" 2>&1
where nuget >> "%OUT%" 2>&1

echo. >> "%OUT%"

echo ============================================================ >> "%OUT%"
echo POSTGRESQL >> "%OUT%"
echo ============================================================ >> "%OUT%"

where psql >> "%OUT%" 2>&1
where pg_isready >> "%OUT%" 2>&1
where libpq.dll >> "%OUT%" 2>&1

psql --version >> "%OUT%" 2>&1
pg_isready --version >> "%OUT%" 2>&1

echo. >> "%OUT%"

echo --- PostgreSQL files --- >> "%OUT%"
dir "C:\Program Files\PostgreSQL" /s /b 2>nul | findstr /i "psql.exe pg_isready.exe libpq.dll" >> "%OUT%"

echo. >> "%OUT%"

echo --- Npgsql --- >> "%OUT%"
where /r "C:\Program Files" Npgsql.dll >> "%OUT%" 2>&1
where /r "C:\Program Files (x86)" Npgsql.dll >> "%OUT%" 2>&1

echo. >> "%OUT%"

echo --- Npgsql GAC --- >> "%OUT%"
dir C:\Windows\Microsoft.NET\assembly\GAC_MSIL\Npgsql >> "%OUT%" 2>&1

echo. >> "%OUT%"

echo ============================================================ >> "%OUT%"
echo ORACLE >> "%OUT%"
echo ============================================================ >> "%OUT%"

where sqlplus >> "%OUT%" 2>&1
where tnsping >> "%OUT%" 2>&1
where oci.dll >> "%OUT%" 2>&1

sqlplus -v >> "%OUT%" 2>&1

echo ORACLE_HOME=%ORACLE_HOME% >> "%OUT%"
echo TNS_ADMIN=%TNS_ADMIN% >> "%OUT%"

echo. >> "%OUT%"

echo --- Oracle registry 64-bit --- >> "%OUT%"
reg query HKLM\SOFTWARE\ORACLE /s >> "%OUT%" 2>&1

echo. >> "%OUT%"

echo --- Oracle registry 32-bit --- >> "%OUT%"
reg query HKLM\SOFTWARE\WOW6432Node\ORACLE /s >> "%OUT%" 2>&1

echo. >> "%OUT%"

echo --- Oracle .NET providers --- >> "%OUT%"
where /r "C:\Program Files" Oracle.ManagedDataAccess.dll >> "%OUT%" 2>&1
where /r "C:\Program Files (x86)" Oracle.ManagedDataAccess.dll >> "%OUT%" 2>&1
where /r "C:\Program Files" Oracle.DataAccess.dll >> "%OUT%" 2>&1
where /r "C:\Program Files (x86)" Oracle.DataAccess.dll >> "%OUT%" 2>&1

echo. >> "%OUT%"

echo ============================================================ >> "%OUT%"
echo OTHER TOOLS >> "%OUT%"
echo ============================================================ >> "%OUT%"

where curl >> "%OUT%" 2>&1
curl --version >> "%OUT%" 2>&1

where openssl >> "%OUT%" 2>&1
openssl version >> "%OUT%" 2>&1

where ping >> "%OUT%" 2>&1
where nslookup >> "%OUT%" 2>&1
where powershell >> "%OUT%" 2>&1

echo. >> "%OUT%"

echo ============================================================ >> "%OUT%"
echo OPTIONAL JSON / SQLITE >> "%OUT%"
echo ============================================================ >> "%OUT%"

where /r "C:\Program Files" Newtonsoft.Json.dll >> "%OUT%" 2>&1
where /r "C:\Program Files (x86)" Newtonsoft.Json.dll >> "%OUT%" 2>&1

where /r "C:\Program Files" System.Data.SQLite.dll >> "%OUT%" 2>&1
where /r "C:\Program Files (x86)" System.Data.SQLite.dll >> "%OUT%" 2>&1

echo. >> "%OUT%"
echo ============================================================ >> "%OUT%"
echo END >> "%OUT%"
echo ============================================================ >> "%OUT%"

echo.
echo Проверка завершена.
echo Результат:
echo %CD%\%OUT%
echo.

pause
