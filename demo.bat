@echo off
title Forever Flip Finder (demo)
cd /d "%~dp0"
where py >nul 2>nul && (set PY=py) || (set PY=python)
if not exist .venv %PY% -m venv .venv
call .venv\Scripts\activate.bat
pip install -q -r requirements.txt
start "" http://127.0.0.1:5000
python app.py --demo
pause
