@echo off
title Forever Flip Finder
cd /d "%~dp0"

where py >nul 2>nul && (set PY=py) || (set PY=python)
%PY% --version >nul 2>nul || (echo Python is not installed. Get it from https://www.python.org/downloads/ and tick "Add python.exe to PATH". & pause & exit /b)

if not exist .venv (
  echo First run: setting up...
  %PY% -m venv .venv
)
call .venv\Scripts\activate.bat
pip install -q -r requirements.txt

if not exist .env (
  copy .env.example .env >nul
  echo.
  echo Add your Blizzard API client id and secret to the .env file that just opened, save it, then run start.bat again.
  notepad .env
  pause
  exit /b
)

start "" http://127.0.0.1:5000
python app.py
pause
