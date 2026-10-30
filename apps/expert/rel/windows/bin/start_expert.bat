@echo off

rem Expert's VM takes its flags from vm.args only. Flags from the editor's
rem environment, like Livebook's -epmd_module, would override Expert's own.
set ELIXIR_ERL_OPTIONS=
set ERL_AFLAGS=
set ERL_FLAGS=
set ERL_ZFLAGS=

"%~dp0plain.bat" eval "System.no_halt(true); Application.ensure_all_started(:xp_expert)" %*
