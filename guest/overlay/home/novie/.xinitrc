#!/bin/sh
# Novie: what `startx` on tty1 runs. The screen must never blank or lock — an agent driving
# this over MCP has no way to wake it, and a lock screen would strand the VM.
xset s off
xset s noblank
xset -dpms
xsetroot -solid '#2b3a4a'

# The desktop background. xfdesktop keys its backdrop in xfconf by the monitor's RandR
# connector name -- /backdrop/screen0/monitor<connector>/workspace0/last-image -- which
# nothing knows until X is up, so this store is written here instead of being shipped in the
# overlay with the name guessed. It is written before xfce4-session starts, so xfconfd reads
# it on its first look and the image is on the desktop's first frame rather than appearing a
# moment after the solid colour above.
backdrop=/usr/share/backgrounds/novie/novie_desktop_background.png
connector=$(xrandr --query 2>/dev/null | awk '/ connected/ { print $1; exit }')
if [ -n "$connector" ] && [ -r "$backdrop" ]; then
    xfconf_dir="$HOME/.config/xfce4/xfconf/xfce-perchannel-xml"
    mkdir -p "$xfconf_dir"
    cat > "$xfconf_dir/xfce4-desktop.xml" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!-- Written at session start by ~/.xinitrc; see the note there. -->
<channel name="xfce4-desktop" version="1.0">
  <property name="backdrop" type="empty">
    <!-- One backdrop for every workspace. xfdesktop 4.20 defaults this off, and without it
         only the workspace named below would have a background. -->
    <property name="single-workspace-mode" type="bool" value="true"/>
    <property name="single-workspace-number" type="int" value="0"/>
    <property name="screen0" type="empty">
      <property name="monitor$connector" type="empty">
        <property name="workspace0" type="empty">
          <!-- 5 is XFCE_BACKDROP_IMAGE_ZOOMED: fills the screen and crops the overhang,
               rather than stretching the image to the guest's aspect ratio. -->
          <property name="image-style" type="int" value="5"/>
          <property name="last-image" type="string" value="$backdrop"/>
        </property>
      </property>
    </property>
  </property>
</channel>
EOF
fi

exec dbus-run-session -- startxfce4
