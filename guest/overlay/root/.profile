# Novie: tty1 is the desktop, so a login there goes straight into X rather than a shell.
# Any other tty (the serial console, a terminal inside XFCE) gets a normal shell.
if [ -z "${DISPLAY:-}" ] && [ "$(tty)" = /dev/tty1 ]; then
    exec startx >/tmp/startx.log 2>&1
fi
