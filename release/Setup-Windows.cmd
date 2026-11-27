@echo off
setlocal
cd /d "%~dp0"
if not exist models mkdir models
call :model ggml-large-v3-turbo-q5_0.bin https://huggingface.co/ggerganov/whisper.cpp/resolve/5359861c739e955e79d9a303bcbc70fb988958b1/ggml-large-v3-turbo-q5_0.bin SHA1 e050f7970618a659205450ad97eb95a18d69c9ee 574041195
if errorlevel 1 goto failed
call :model Qwen3-4B-Q4_K_M.gguf https://huggingface.co/Qwen/Qwen3-4B-GGUF/resolve/bc640142c66e1fdd12af0bd68f40445458f3869b/Qwen3-4B-Q4_K_M.gguf SHA256 7485fe6f11af29433bc51cab58009521f205840f5b4ae3a32fa7f92e8534fdf5 2497280256
if errorlevel 1 goto failed
start "" "%CD%\MeetingScribe.exe"
exit /b 0

:model
set "MODEL_FILE=models\%~1"
set "MODEL_HASH=%~4"
set "MODEL_ALGORITHM=%~3"
if exist "%MODEL_FILE%" (
    call :verify
    if not errorlevel 1 exit /b 0
)
set "MODEL_FILE=%MODEL_FILE%.part"
if exist "%MODEL_FILE%" (
    call :verify
    if not errorlevel 1 goto move_model
    powershell.exe -NoProfile -Command "if ((Get-Item -LiteralPath $env:MODEL_FILE).Length -ge %~5) { exit 0 }; exit 1"
    if not errorlevel 1 del "%MODEL_FILE%"
)
curl.exe -fL --retry 2 --continue-at - "%~2" -o "%MODEL_FILE%"
set "CURL_STATUS=%errorlevel%"
if "%CURL_STATUS%"=="33" goto restart_download
if "%CURL_STATUS%"=="36" goto restart_download
if not "%CURL_STATUS%"=="0" exit /b 1
goto check_model

:restart_download
if exist "%MODEL_FILE%" del "%MODEL_FILE%"
curl.exe -fL --retry 2 "%~2" -o "%MODEL_FILE%"
if errorlevel 1 exit /b 1

:check_model
call :verify
if errorlevel 1 (
    del "%MODEL_FILE%"
    exit /b 1
)

:move_model
move /y "%MODEL_FILE%" "models\%~1" >nul
exit /b %errorlevel%

:verify
powershell.exe -NoProfile -Command "try { if ((Get-FileHash -LiteralPath $env:MODEL_FILE -Algorithm $env:MODEL_ALGORITHM -ErrorAction Stop).Hash -ieq $env:MODEL_HASH) { exit 0 } } catch { }; exit 1"
exit /b %errorlevel%

:failed
echo Model setup failed. Check your internet connection and available disk space, then try this setup again.
pause
exit /b 1
