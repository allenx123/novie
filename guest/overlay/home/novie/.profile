# Novie: tty1 is the desktop, so a login there goes straight into X rather than a shell.
# Any other tty (the serial console, a terminal inside XFCE) gets a normal shell.
#
# This runs as novie, not root. Xorg still needs privileges to open the VT and the input
# devices, and it gets them from its setuid wrapper (/usr/libexec/Xorg.wrap), which is
# allowed because login made novie the owner of /dev/tty1. See /etc/X11/Xwrapper.config.

# A normal desktop session has a runtime directory; without one, dbus, Thunar's volume
# monitor and the panel's plugins each fall back to their own guesses and say so in the log.
# Nothing here creates a logind session, so there is no pam_elogind to make this directory --
# /etc/local.d/novie-runtimedir.start does it at boot instead, as root.
if [ -z "${XDG_RUNTIME_DIR:-}" ] && [ -d "/run/user/$(id -u)" ]; then
    XDG_RUNTIME_DIR="/run/user/$(id -u)"
    export XDG_RUNTIME_DIR
fi

if [ -z "${DISPLAY:-}" ] && [ "$(tty)" = /dev/tty1 ]; then
    exec startx >/tmp/startx.log 2>&1
fi
