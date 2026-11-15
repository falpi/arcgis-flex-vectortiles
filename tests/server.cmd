@echo off
rem Development server of the examples: hosts a SWF and a proxy page on http://localhost:8790, then opens the
rem SWF in the standalone Flash Player of Flash Builder. Without a SWF it builds the demo of the repository
rem first. See tests/server.js for the details.
rem
rem   server.cmd [<file.swf>] [--flashbuilder <folder>] [--player <FlashPlayer.exe>] [--no-player] [--keep]
rem              [--allow host,host] [--verbose]

where node >nul 2>nul
if errorlevel 1 (
    echo Node.js is required: https://nodejs.org
    exit /b 1
)
node "%~dp0server.js" %*
