@echo off
chcp 65001 >nul
cd /d "%~dp0"
if not exist "app\.env" copy "app\.env.example" "app\.env" >nul
if not exist "screenshots" mkdir "screenshots"
python -m pip install -q -r app\requirements.txt
python -m streamlit run app\app.py
pause
