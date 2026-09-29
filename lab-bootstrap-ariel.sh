#!/bin/bash
# =====================================================================
# lab-bootstrap-ariel.sh  -  CloudLabs "Ariel" Ubuntu GUI (XFCE + xrdp)
# Runs via Azure Custom Script Extension as root, before any user login.
# Fixes: (1) blurry text  (2) Hebrew language + keyboard (IBus)
# Log on VM: /var/log/lab-bootstrap.log      (No reboot, no logoff)
# =====================================================================
set -uo pipefail
LOG=/var/log/lab-bootstrap.log
exec > >(tee -a "$LOG") 2>&1
log()  { echo "[$(date '+%H:%M:%S')] $*"; }
step() { echo; echo "================ $* ================"; }
export DEBIAN_FRONTEND=noninteractive
APT="apt-get -y -q -o DPkg::Lock::Timeout=900"
TS=$(date +%Y%m%d%H%M%S)

# ---------------------------------------------------------------------
step "0. Environment"
. /etc/os-release; log "OS: $PRETTY_NAME"
LABUSER=labuser
getent passwd "$LABUSER" >/dev/null || LABUSER=$(getent passwd 1000 | cut -d: -f1)
LUID=$(id -u "$LABUSER"); LHOME=$(getent passwd "$LABUSER" | cut -d: -f6)
log "Lab user: $LABUSER (uid $LUID, home $LHOME)"
log "xrdp: $(xrdp --version 2>/dev/null | head -1)"

# ---------------------------------------------------------------------
step "1. Packages"
$APT update
$APT install crudini dconf-cli dbus fontconfig fonts-dejavu-core fonts-noto-core fonts-liberation \
  language-pack-he language-pack-he-base fonts-culmus hunspell-he locales x11-xkb-utils \
  && log "Packages OK" || log "WARN: some packages failed, continuing"

# ---------------------------------------------------------------------
step "2. Blur fix - system font rules"
cat > /etc/fonts/local.conf <<'EOF'
<?xml version="1.0"?>
<!DOCTYPE fontconfig SYSTEM "fonts.dtd">
<fontconfig>
  <match target="font">
    <edit name="antialias" mode="assign"><bool>true</bool></edit>
    <edit name="hinting"   mode="assign"><bool>true</bool></edit>
    <edit name="hintstyle" mode="assign"><const>hintfull</const></edit>
    <edit name="rgba"      mode="assign"><const>none</const></edit>
  </match>
</fontconfig>
EOF
fc-cache -f >/dev/null && log "fontconfig: antialias + hintfull + grayscale"
crudini --ini-options=nospace --set /etc/xrdp/xrdp.ini Globals max_bpp 32 && log "xrdp max_bpp=32"

# ---------------------------------------------------------------------
step "3. Hebrew - locale, system keyboard, xrdp keyboard map"
locale-gen he_IL.UTF-8 >/dev/null && log "he_IL.UTF-8 generated (UI stays English)"
sed -i -E 's/^XKBLAYOUT=.*/XKBLAYOUT="us,il"/; s/^XKBOPTIONS=.*/XKBOPTIONS="grp:alt_shift_toggle"/' /etc/default/keyboard
log "System keyboard: $(grep -E '^XKB(LAYOUT|OPTIONS)' /etc/default/keyboard | tr '\n' ' ')"
KB=/etc/xrdp/xrdp_keyboard.ini
if [[ -f $KB ]]; then
  cp "$KB" "$KB.bak.$TS"
  sed -i -E '/=\s*0x/! s/^(\s*rdp_layout_us\s*=\s*)us\s*$/\1us,il/' "$KB"
  grep -n -E '^\s*rdp_layout_us\s*=' "$KB" | sed 's/^/  xrdp map: /'
fi

# ---------------------------------------------------------------------
step "4. Hebrew - IBus system default (any user)"
mkdir -p /etc/dconf/profile /etc/dconf/db/local.d
if [[ ! -f /etc/dconf/profile/user ]]; then
  printf 'user-db:user\nsystem-db:local\n' > /etc/dconf/profile/user
elif ! grep -q 'system-db:local' /etc/dconf/profile/user; then
  echo 'system-db:local' >> /etc/dconf/profile/user
fi
cat > /etc/dconf/db/local.d/00-lab-ibus <<'EOF'
[desktop/ibus/general]
preload-engines=['xkb:us::eng', 'xkb:il::heb']
engines-order=['xkb:us::eng', 'xkb:il::heb']
EOF
dconf update && log "IBus default: English + Hebrew"

# ---------------------------------------------------------------------
step "5. Per-user settings script (fonts, effects, keyboard, IBus)"
cat > /usr/local/bin/lab-user-settings.sh <<'EOF'
#!/bin/bash
xq() { xfconf-query "$@" 2>/dev/null; }
# Blur fix
xq -c xsettings -p /Xft/Antialias -n -t int    -s 1
xq -c xsettings -p /Xft/Hinting   -n -t int    -s 1
xq -c xsettings -p /Xft/HintStyle -n -t string -s hintfull
xq -c xsettings -p /Xft/RGBA      -n -t string -s none
xq -c xsettings -p /Xft/DPI       -n -t int    -s 96
xq -c xsettings -p /Gdk/WindowScalingFactor -n -t int -s 1
xq -c xfwm4 -p /general/use_compositing -n -t bool -s false
# Hebrew - XFCE keyboard
xq -c keyboard-layout -p /Default/XkbDisable       -n -t bool   -s false
xq -c keyboard-layout -p /Default/XkbLayout        -n -t string -s "us,il"
xq -c keyboard-layout -p /Default/XkbVariant       -n -t string -s ","
xq -c keyboard-layout -p /Default/XkbOptions/Group -n -t string -s "grp:alt_shift_toggle"
# Hebrew - IBus (the EN/HE indicator)
gsettings set org.freedesktop.ibus.general preload-engines "['xkb:us::eng', 'xkb:il::heb']" 2>/dev/null
gsettings set org.freedesktop.ibus.general engines-order  "['xkb:us::eng', 'xkb:il::heb']" 2>/dev/null
[[ -n ${DISPLAY:-} ]] && setxkbmap -layout us,il -variant , -option -option grp:alt_shift_toggle 2>/dev/null
sleep 2
EOF
chmod +x /usr/local/bin/lab-user-settings.sh
log "Created /usr/local/bin/lab-user-settings.sh"

# ---------------------------------------------------------------------
step "6. Apply settings to $LABUSER now (no GUI session needed)"
RT=/run/user/$LUID
[[ -d $RT ]] || { RT=/tmp/lab-rt-$LUID; mkdir -p "$RT"; chown "$LABUSER": "$RT"; chmod 700 "$RT"; }
U() { sudo -u "$LABUSER" env HOME="$LHOME" XDG_RUNTIME_DIR="$RT" dbus-run-session -- "$@"; }
U /usr/local/bin/lab-user-settings.sh && log "Settings saved for $LABUSER"

# ---------------------------------------------------------------------
step "7. Login autostart (re-applies + reloads IBus at every login)"
cat > /usr/local/bin/lab-session-apply.sh <<'EOF'
#!/bin/bash
sleep 5
/usr/local/bin/lab-user-settings.sh
ibus restart >/dev/null 2>&1 || ibus-daemon --daemonize --xim --replace
echo "[$(date)] lab settings applied, IBus: $(gsettings get org.freedesktop.ibus.general preload-engines)" >> /tmp/lab-session-apply.log
EOF
chmod +x /usr/local/bin/lab-session-apply.sh
cat > /etc/xdg/autostart/lab-session-apply.desktop <<'EOF'
[Desktop Entry]
Type=Application
Name=Lab session settings
Exec=/usr/local/bin/lab-session-apply.sh
OnlyShowIn=XFCE;
EOF
log "Autostart: /etc/xdg/autostart/lab-session-apply.desktop"

# ---------------------------------------------------------------------
step "8. Restart xrdp (no users connected yet)"
systemctl restart xrdp-sesman xrdp && log "xrdp restarted"
systemctl is-active --quiet xrdp && log "xrdp active" || log "ERROR: xrdp not active"

# ---------------------------------------------------------------------
step "9. Verification"
locale -a | grep -qi he_IL && log "PASS Hebrew locale"
fc-list :lang=he family | grep -q 'CLM' && log "PASS Hebrew fonts" || log "FAIL Hebrew fonts"
grep -q 'us,il' "$KB" && log "PASS xrdp map us,il"
echo "  IBus ($LABUSER): $(U gsettings get org.freedesktop.ibus.general preload-engines)"
U xfconf-query -c xsettings -l -v 2>/dev/null | grep -E 'Xft/(HintStyle|Antialias|DPI)' | sed 's/^/  /'
log "BOOTSTRAP COMPLETE"
exit 0
