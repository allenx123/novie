#!/bin/sh
# Novie: what `startx` on tty1 runs. The screen must never blank or lock — an agent driving
# this over MCP has no way to wake it, and a lock screen would strand the VM.
xset s off
xset s noblank
xset -dpms
xsetroot -solid '#2b3a4a'
exec dbus-run-session -- startxfce4
