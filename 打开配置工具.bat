@echo off
chcp 65001 >nul
cd /d "%~dp0"
set "CLAUDE_TOOL_DIR=%~dp0"
powershell -NoProfile -ExecutionPolicy Bypass -Command "$env:CLAUDE_TOOL_DIR=$env:CLAUDE_TOOL_DIR; $code=[System.IO.File]::ReadAllText($env:CLAUDE_TOOL_DIR + 'ClaudeConfigTool.ps1', [System.Text.Encoding]::UTF8); Invoke-Expression $code"
if errorlevel 1 (
  echo.
  echo [ERROR] Failed to start. Make sure Windows PowerShell is available.
  pause
)
