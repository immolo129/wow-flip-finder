@echo off
title Install Flip Finder addon
cd /d "%~dp0"
set "WOW=C:\Program Files (x86)\World of Warcraft\_forever_"
if not exist "%WOW%\Interface\AddOns" (
  echo Couldn't find WoW: Forever at "%WOW%".
  echo Edit WOW= in this file to point at your _forever_ folder.
  pause
  exit /b
)
xcopy /E /I /Y "addon\FlipFinder" "%WOW%\Interface\AddOns\FlipFinder" >nul
echo Flip Finder installed. In game, type /reload (or log in) to load the new version.
pause
