@echo off

set NODE_NAME=%~1
set PORT=%~2
set EPMD_MODULE=%~3
set EPMD_EBIN_PATH=%~4
set COOKIE=%~5
if "%COOKIE%"=="" set COOKIE=expert

set EXPERT_PARENT_PORT=%PORT%

iex --erl "-pa %EPMD_EBIN_PATH% -start_epmd false -epmd_module %EPMD_MODULE% -connect_all false" --name "expert-debug-%RANDOM%@127.0.0.1" --cookie "%COOKIE%" --remsh "%NODE_NAME%"
