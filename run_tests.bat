@echo off
chcp 65001 >nul
cd /d "%~dp0"
set "OUT=%~dp0test_output.txt"
set "MYSQL="
for /d %%D in ("C:\Program Files\MySQL\MySQL Server*") do if exist "%%~D\bin\mysql.exe" set "MYSQL=%%~D\bin\mysql.exe"
if not defined MYSQL if exist "C:\xampp\mysql\bin\mysql.exe" set "MYSQL=C:\xampp\mysql\bin\mysql.exe"
if not defined MYSQL for /f "delims=" %%P in ('where mysql 2^>nul') do set "MYSQL=%%P"
if not defined MYSQL (
  echo mysql.exe NOT FOUND > "%OUT%"
  echo MySQL client not found.
  pause
  exit /b 1
)
set "DBUSER=root"
set /p "DBUSER=MySQL user [root]: "
set "MYSQL_PWD="
set /p "MYSQL_PWD=MySQL password: "
"%MYSQL%" -u %DBUSER% -e "SELECT CURRENT_USER(), VERSION();" > "%OUT%" 2>&1
if errorlevel 1 (
  type "%OUT%"
  echo.
  echo Login failed. Run the file again and check user/password.
  pause
  exit /b 1
)
echo MYSQL=%MYSQL% >> "%OUT%"
for %%F in (01_schema 02_seed 03_basic_operations 04_queries 05_procedures 07_app_user 06_tests) do (
  echo ##### FILE %%F >> "%OUT%"
  "%MYSQL%" -u %DBUSER% --default-character-set=utf8mb4 --force -t -vvv < "sql\%%F.sql" >> "%OUT%" 2>&1
)
echo ##### APP USER CHECK >> "%OUT%"
set "MYSQL_PWD=Stream#App2026"
"%MYSQL%" -u streaming_app --default-character-set=utf8mb4 -t -vvv streaming_service -e "SELECT CURRENT_USER(); SELECT COUNT(*) AS movies FROM movies; SELECT COUNT(*) AS report_rows FROM v_title_stats; CALL sp_expire_subscriptions();" >> "%OUT%" 2>&1
"%MYSQL%" -u streaming_app --default-character-set=utf8mb4 -t -vvv streaming_service -e "DELETE FROM watch_history WHERE history_id = 0;" >> "%OUT%" 2>&1
"%MYSQL%" -u streaming_app --default-character-set=utf8mb4 -t -vvv streaming_service -e "UPDATE user_subscriptions SET price_paid = 0 WHERE subscription_id = 0;" >> "%OUT%" 2>&1
echo ##### DONE >> "%OUT%"
set "MYSQL_PWD="
echo Done. Results saved to test_output.txt
pause
