@echo off
rem Launches a 2nd CLIENT as the "guest" instance, to test multiplayer on ONE PC with
rem two different players. It reads mmo_config_guest.txt so it can log into a
rem separate account (server-persisted like any other), and keeps its own log and
rem local save file. Start PlayMMO-server.bat first.
rem   - window 1: PlayMMO-debug.bat  (your usual account)
rem   - window 2: PlayMMO-guest.bat  (a distinct second player)
cd /d "%~dp0"
set PEMK_INSTANCE=guest
rem See PlayMMO-debug.bat: enlarge the Ruby VM stack (~16x headroom) so the debug
rem boot + save-state hydration can't hit a boot-stack SystemStackError.
set RUBY_THREAD_VM_STACK_SIZE=16777216
start "" "Game.exe" debug
