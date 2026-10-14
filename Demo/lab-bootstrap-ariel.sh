#!/bin/bash
# =====================================================================
# lab-bootstrap-ariel.sh  -  CloudLabs "Ariel" Ubuntu GUI (XFCE + xrdp)
# Runs via Azure Custom Script Extension as root, before any user login.
#  (1) Blur-free text           (2) Hebrew language + keyboard (IBus) + Hebrew HOST keyboard (patched xrdp)
#  (3) Background updates off   (4) Firefox snap -> deb (faster)
#  (5) Text size: default DPI 144, set on FIRST login only (student can change it)
#  (6) Desktop shortcuts: MATLAB + Firefox
#  (7) MATLAB first-run warm-up in background (faster first MATLAB start)
# Logs on VM: /var/log/lab-bootstrap.log   /var/log/matlab-warmup.log
# No reboot, no logoff.
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
step "1. Stop background update jobs (they slow the lab VM)"
for u in unattended-upgrades.service apt-daily.timer apt-daily-upgrade.timer \
         apt-daily.service apt-daily-upgrade.service fwupd.service fwupd-refresh.timer \
         packagekit.service; do
  if systemctl cat "$u" >/dev/null 2>&1; then
    systemctl disable --now "$u" >/dev/null 2>&1
    [[ $u == packagekit.service || $u == fwupd.service ]] && systemctl mask "$u" >/dev/null 2>&1
    log "Disabled: $u"
  fi
done
cat > /etc/apt/apt.conf.d/99-lab-no-auto-update <<'EOF'
APT::Periodic::Update-Package-Lists "0";
APT::Periodic::Unattended-Upgrade "0";
APT::Periodic::Download-Upgradeable-Packages "0";
EOF
log "APT periodic updates off"
F=/etc/xdg/autostart/update-notifier.desktop
[[ -f $F ]] && { grep -q '^Hidden=true' "$F" || echo 'Hidden=true' >> "$F"; log "update-notifier hidden at login"; }
command -v snap >/dev/null && { snap refresh --hold >/dev/null 2>&1 && log "Snap auto-refresh on hold"; }

# ---------------------------------------------------------------------
step "2. Packages"
$APT update
$APT install crudini dconf-cli dbus fontconfig fonts-dejavu-core fonts-noto-core fonts-liberation \
  language-pack-he language-pack-he-base fonts-culmus hunspell-he locales x11-xkb-utils curl \
  && log "Packages OK" || log "WARN: some packages failed, continuing"

# ---------------------------------------------------------------------
step "3. Blur fix - system font rules"
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
step "4. Hebrew - locale, system keyboard, xrdp keyboard map"
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
step "5. Hebrew - IBus system default (any user)"
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
step "5b. Hebrew from a HEBREW host keyboard (Guacamole sends Hebrew as Unicode)"
# (1) patched xrdp: Unicode keys sent as press+release (stock 0.10.1 leaves keys held)
# Uses a prebuilt package if one is on GitHub (fast); otherwise builds it here (~3-4 min). No manual step needed.
XRDP_DEB_URL="${XRDP_DEB_URL:-https://raw.githubusercontent.com/fardeena-spektra/demo/refs/heads/main/Demo/xrdp-lab-hebrew_amd64.deb}"
build_patched_xrdp() {   # builds Ubuntu's own xrdp source + lab patch -> /tmp/xrdp-lab.deb
  local B=/opt/xrdp-lab; rm -rf $B/src; mkdir -p $B/src
  if [[ -f /etc/apt/sources.list.d/ubuntu.sources ]]; then sed -i 's/^Types: deb$/Types: deb deb-src/' /etc/apt/sources.list.d/ubuntu.sources
  else grep -q '^deb-src' /etc/apt/sources.list || sed -n 's/^deb /deb-src /p' /etc/apt/sources.list >> /etc/apt/sources.list; fi
  $APT update >/dev/null 2>&1 || return 1
  $APT install --no-install-recommends dpkg-dev devscripts fakeroot >/dev/null 2>&1 || return 1
  $APT build-dep xrdp >/dev/null 2>&1 || return 1
  (cd $B/src && apt-get source -q xrdp >/dev/null 2>&1) || return 1
  cd $B/src/xrdp-*/ || return 1
  python3 - xrdp/xrdp_wm.c <<'PY' || return 1
import sys
f=sys.argv[1]; s=open(f).read()
old="static int\nxrdp_wm_key_unicode(struct xrdp_wm *self, int device_flags, char32_t unicode)\n{"
if old not in s: sys.exit("patch target not found")
new=("static int\nxrdp_wm_key_unicode_impl(struct xrdp_wm *self, int device_flags, char32_t unicode);\n\n"
"/* Lab patch: Guacamole sends Unicode key events press-only; emit press+release. */\n"
"static int\nxrdp_wm_key_unicode(struct xrdp_wm *self, int device_flags, char32_t unicode)\n{\n"
"    if (device_flags & KBD_FLAG_UP)\n    {\n        return 0;\n    }\n"
"    xrdp_wm_key_unicode_impl(self, device_flags, unicode);\n"
"    return xrdp_wm_key_unicode_impl(self, device_flags | KBD_FLAG_UP, unicode);\n}\n\n"
"static int\nxrdp_wm_key_unicode_impl(struct xrdp_wm *self, int device_flags, char32_t unicode)\n{")
open(f,'w').write(s.replace(old,new,1))
PY
  DEBFULLNAME="Lab Build" DEBEMAIL="lab@localhost" dch --local +lab "Unicode keys press+release (Guacamole Hebrew)" >/dev/null 2>&1
  DEB_BUILD_OPTIONS="nocheck parallel=$(nproc)" dpkg-buildpackage -us -uc -b > $B/build.log 2>&1 || return 1
  cp "$(ls $B/src/xrdp_*+lab*_amd64.deb | grep -v dbgsym | head -1)" /tmp/xrdp-lab.deb || return 1
  cp /tmp/xrdp-lab.deb $B/xrdp-lab-hebrew_amd64.deb; cd /
}
if dpkg-query -W -f='${Version}' xrdp | grep -q '+lab'; then
  log "Patched xrdp already installed"
else
  rm -f /tmp/xrdp-lab.deb
  if curl -fsSL "$XRDP_DEB_URL" -o /tmp/xrdp-lab.deb 2>/dev/null && dpkg-deb -f /tmp/xrdp-lab.deb Version 2>/dev/null | grep -q '+lab'; then
    log "Prebuilt patched xrdp downloaded from GitHub"
  else
    rm -f /tmp/xrdp-lab.deb; log "No prebuilt package on GitHub - building patched xrdp here (3-4 min)..."
    T0=$(date +%s); build_patched_xrdp && log "Built in $(( $(date +%s)-T0 )) s (copy kept: /opt/xrdp-lab/xrdp-lab-hebrew_amd64.deb)" || { cd /; log "ERROR: build failed (see /opt/xrdp-lab/build.log)"; }
  fi
  if [[ -f /tmp/xrdp-lab.deb ]]; then
    cp -a /etc/xrdp /tmp/etc-xrdp.$TS
    dpkg -i --force-confold /tmp/xrdp-lab.deb >/dev/null && apt-mark hold xrdp >/dev/null \
      && log "Patched xrdp installed: $(dpkg-query -W -f='${Version}' xrdp) (held)" || log "ERROR: patched xrdp install failed"
    cp -a /tmp/etc-xrdp.$TS/. /etc/xrdp/
  else
    log "WARN: patched xrdp not available - Hebrew HOST keyboard will not work (rest of lab OK)"
  fi
fi
# (2) xrdp keymap: Hebrew letters on RightAlt (so xrdp does not drop them)
python3 - /etc/xrdp/km-00000409.ini <<'PY'
import sys, re
f = sys.argv[1]
m = {26:0x5E7,27:0x5E8,28:0x5D0,29:0x5D8,30:0x5D5,31:0x5DF,32:0x5DD,33:0x5E4,38:0x5E9,39:0x5D3,40:0x5D2,41:0x5DB,42:0x5E2,
     43:0x5D9,44:0x5D7,45:0x5DC,46:0x5DA,47:0x5E3,52:0x5D6,53:0x5E1,54:0x5D1,55:0x5D4,56:0x5E0,57:0x5DE,58:0x5E6,59:0x5EA,60:0x5E5}
out, sec, n = [], None, 0
for l in open(f).read().splitlines():
    h = re.match(r'^\[(.+)\]\s*$', l)
    if h: sec = h.group(1)
    k = re.match(r'^Key(\d+)=', l)
    if sec == 'altgr' and k and int(k.group(1)) in m:
        cp = m[int(k.group(1))]; l = "Key%s=%d:%d" % (k.group(1), 0xce0 + cp - 0x5d0, cp); n += 1
    out.append(l)
open(f, 'w').write("\n".join(out) + "\n"); print("  xrdp keymap: %d/27 Hebrew letters on RightAlt" % n)
PY
# (3) XKB: RightAlt + key = Hebrew letter in the English and Hebrew layouts
X=/usr/share/X11/xkb/symbols
python3 - <<'PY'
heb=[("AD03","05E7"),("AD04","05E8"),("AD05","05D0"),("AD06","05D8"),("AD07","05D5"),("AD08","05DF"),("AD09","05DD"),("AD10","05E4"),
     ("AC01","05E9"),("AC02","05D3"),("AC03","05D2"),("AC04","05DB"),("AC05","05E2"),("AC06","05D9"),("AC07","05D7"),("AC08","05DC"),
     ("AC09","05DA"),("AC10","05E3"),("AB01","05D6"),("AB02","05E1"),("AB03","05D1"),("AB04","05D4"),("AB05","05E0"),("AB06","05DE"),
     ("AB07","05E6"),("AB08","05EA"),("AB09","05E5")]
out=[]
for name in ("us3","il3"):
    out.append('partial alphanumeric_keys\nxkb_symbols "%s" {\n    include "level3(ralt_switch)"' % name)
    for k,u in heb:
        t = "FOUR_LEVEL" if (k in ("AC10","AB08","AB09") and name=="us3") else "FOUR_LEVEL_SEMIALPHABETIC"
        out.append('    key <%s> { type[Group1]="%s", symbols[Group1]=[ NoSymbol, NoSymbol, U%s, U%s ] };' % (k,t,u,u))
    out.append('};\n')
open("/usr/share/X11/xkb/symbols/labheb","w").write("\n".join(out))
PY
for f in us il; do
  grep -q labheb $X/$f && continue
  cp -a $X/$f $X/$f.orig.$TS
  python3 - $X/$f "labheb($([ $f = us ] && echo us3 || echo il3))" <<'PY'
import sys,re
f,inc=sys.argv[1],sys.argv[2]; s=open(f).read()
m=re.search(r'default[^{]*?xkb_symbols\s+"[^"]+"\s*\{',s); end=s.index('\n};',m.end())
open(f,'w').write(s[:end]+'\n    include "%s"'%inc+s[end:])
PY
done
printf 'xkb_keymap { xkb_keycodes {include "xfree86+aliases(qwerty)"}; xkb_types {include "complete"}; xkb_compat {include "complete"}; xkb_symbols {include "pc+us+il:2"}; xkb_geometry {include "pc(pc104)"}; };\n' > /tmp/labheb-test.xkb
if xkbcomp -w0 -xkb /tmp/labheb-test.xkb /tmp/labheb-test.out 2>/dev/null && grep -q U05E9 /tmp/labheb-test.out; then
  log "XKB layout: RightAlt+key = Hebrew (compiles OK)"
else
  log "ERROR: XKB layout does not compile - restoring originals"
  for f in us il; do O=$(ls $X/$f.orig.* 2>/dev/null | head -1); [[ -n $O ]] && cp -a "$O" $X/$f; done
fi
rm -f /var/lib/xkb/*.xkm

# ---------------------------------------------------------------------
step "6. Per-user settings script (fonts, effects, keyboard, IBus)"
cat > /usr/local/bin/lab-user-settings.sh <<'EOF'
#!/bin/bash
xq() { xfconf-query "$@" 2>/dev/null; }
# Blur fix (applied every login)
xq -c xsettings -p /Xft/Antialias -n -t int    -s 1
xq -c xsettings -p /Xft/Hinting   -n -t int    -s 1
xq -c xsettings -p /Xft/HintStyle -n -t string -s hintfull
xq -c xsettings -p /Xft/RGBA      -n -t string -s none
xq -c xsettings -p /Gdk/WindowScalingFactor -n -t int -s 1
xq -c xfwm4 -p /general/use_compositing -n -t bool -s false
# Text size: DPI 144 (matches 67% browser zoom) set ONCE only.
# Student can change it (Settings > Appearance > Fonts > DPI) and it is kept.
if [[ ! -f ~/.config/lab-dpi-set ]]; then
  xq -c xsettings -p /Xft/DPI -n -t int -s 144
  mkdir -p ~/.config && touch ~/.config/lab-dpi-set
fi
# Layout for 67% zoom: desktop icons + label font, top panel height
xq -c xfce4-desktop -p /desktop-icons/icon-size            -n -t uint   -s 64
xq -c xfce4-desktop -p /desktop-icons/use-custom-font-size -n -t bool   -s true
xq -c xfce4-desktop -p /desktop-icons/font-size            -n -t double -s 9
TOP=""
for p in $(xq -c xfce4-panel -p /panels | grep -E '^[0-9]+$'); do
  for id in $(xq -c xfce4-panel -p /panels/panel-$p/plugin-ids | grep -E '^[0-9]+$'); do
    [[ $(xq -c xfce4-panel -p /plugins/plugin-$id) == "clock" ]] && TOP=$p
  done
done
xq -c xfce4-panel -p /panels/panel-${TOP:-1}/size -n -t uint -s 36
# Hebrew - XFCE keyboard
xq -c keyboard-layout -p /Default/XkbDisable       -n -t bool   -s false
xq -c keyboard-layout -p /Default/XkbLayout        -n -t string -s "us,il"
xq -c keyboard-layout -p /Default/XkbVariant       -n -t string -s ","
xq -c keyboard-layout -p /Default/XkbOptions/Group -n -t string -s "grp:alt_shift_toggle"
# Hebrew - IBus (the EN/HE indicator)
gsettings set org.freedesktop.ibus.general preload-engines "['xkb:us::eng', 'xkb:il::heb']" 2>/dev/null
gsettings set org.freedesktop.ibus.general engines-order  "['xkb:us::eng', 'xkb:il::heb']" 2>/dev/null
[[ -n ${DISPLAY:-} ]] && setxkbmap -layout us,il -variant , -option -option grp:alt_shift_toggle 2>/dev/null
# Desktop shortcuts: mark as trusted (no "untrusted launcher" prompt)
for f in ~/Desktop/*.desktop; do
  [[ -f $f ]] || continue
  chmod +x "$f"
  gio set "$f" metadata::xfce-exe-checksum "$(sha256sum "$f" | cut -d' ' -f1)" 2>/dev/null
  gio set "$f" metadata::trusted true 2>/dev/null
done
sleep 2
EOF
chmod +x /usr/local/bin/lab-user-settings.sh
log "Created /usr/local/bin/lab-user-settings.sh (DPI 144 first login only)"

# ---------------------------------------------------------------------
step "7. Firefox: snap -> Mozilla .deb (faster start)"
if snap list firefox >/dev/null 2>&1; then
  install -d -m 0755 /etc/apt/keyrings
  if curl -fsSL https://packages.mozilla.org/apt/repo-signing-key.gpg -o /etc/apt/keyrings/packages.mozilla.org.asc; then
    echo "deb [signed-by=/etc/apt/keyrings/packages.mozilla.org.asc] https://packages.mozilla.org/apt mozilla main" \
      > /etc/apt/sources.list.d/mozilla.list
    printf 'Package: *\nPin: origin packages.mozilla.org\nPin-Priority: 1000\n' > /etc/apt/preferences.d/mozilla
    snap remove --purge firefox >/dev/null 2>&1 && log "Firefox snap removed"
    $APT update >/dev/null && $APT install --allow-downgrades firefox >/dev/null \
      && log "Firefox .deb installed: $(dpkg-query -W -f='${Version}' firefox)" \
      || log "ERROR: Firefox .deb install failed"
  else
    log "WARN: packages.mozilla.org not reachable - keeping Firefox snap"
  fi
else
  log "Firefox snap not installed - skipping ($(dpkg-query -W -f='${Version}' firefox 2>/dev/null || echo 'no firefox'))"
fi

# ---------------------------------------------------------------------
step "8. Desktop shortcuts: MATLAB + Firefox"
DESK=$LHOME/Desktop
install -d -o "$LABUSER" -g "$LABUSER" "$DESK"
M=$(readlink -f "$(command -v matlab 2>/dev/null)" 2>/dev/null)
if [[ -x $M ]]; then
  MROOT=$(dirname "$(dirname "$M")")
  # MATLAB's own logo as SVG (sharp at any size); fallback PNG
  MICON=$(find "$MROOT/ui/icons" -iname 'matlabLogo.svg' 2>/dev/null | sort -V | tail -1)
  [[ -z $MICON ]] && MICON=$(find "$MROOT/ui/icons" -iname 'matlabLogo*.png' 2>/dev/null | sort -V | tail -1)
  cat > /usr/share/applications/lab-matlab.desktop <<EOF
[Desktop Entry]
Type=Application
Name=MATLAB
Comment=Start MATLAB
Exec=$M -desktop
Icon=${MICON:-applications-science}
Terminal=false
Categories=Development;Science;
StartupNotify=true
EOF
  install -o "$LABUSER" -g "$LABUSER" -m 755 /usr/share/applications/lab-matlab.desktop "$DESK/matlab.desktop"
  log "MATLAB shortcut created (icon: ${MICON:-generic})"
else
  log "WARN: MATLAB not found - no shortcut"
fi
FF=/usr/share/applications/firefox.desktop
[[ -f $FF ]] || FF=$(ls /var/lib/snapd/desktop/applications/firefox*.desktop 2>/dev/null | head -1)
if [[ -f $FF ]]; then
  install -o "$LABUSER" -g "$LABUSER" -m 755 "$FF" "$DESK/firefox.desktop"
  log "Firefox shortcut created (from $FF)"
else
  log "WARN: Firefox launcher not found - no shortcut"
fi

# ---------------------------------------------------------------------
step "9. Apply settings to $LABUSER now (no GUI session needed)"
RT=/run/user/$LUID
[[ -d $RT ]] || { RT=/tmp/lab-rt-$LUID; mkdir -p "$RT"; chown "$LABUSER": "$RT"; chmod 700 "$RT"; }
U() { sudo -u "$LABUSER" env HOME="$LHOME" XDG_RUNTIME_DIR="$RT" dbus-run-session -- "$@"; }
U /usr/local/bin/lab-user-settings.sh && log "Settings saved for $LABUSER"

# ---------------------------------------------------------------------
step "10. Login autostart (re-applies + reloads IBus at every login)"
cat > /usr/local/bin/lab-session-apply.sh <<'EOF'
#!/bin/bash
sleep 5
/usr/local/bin/lab-user-settings.sh
ibus restart >/dev/null 2>&1 || ibus-daemon --daemonize --xim --replace
echo "[$(date)] lab settings applied, DPI $(xfconf-query -c xsettings -p /Xft/DPI 2>/dev/null), IBus: $(gsettings get org.freedesktop.ibus.general preload-engines)" >> /tmp/lab-session-apply.log
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
step "11. Restart xrdp (no users connected yet)"
systemctl restart xrdp-sesman xrdp && log "xrdp restarted"
systemctl is-active --quiet xrdp && log "xrdp active" || log "ERROR: xrdp not active"

# ---------------------------------------------------------------------
step "12. MATLAB warm-up (background, does not delay deployment)"
cat > /usr/local/bin/lab-matlab-warmup.sh <<'EOF'
#!/bin/bash
# Runs MATLAB's slow first launch once, so the student's first start is fast.
exec >> /var/log/matlab-warmup.log 2>&1
log() { echo "[$(date '+%H:%M:%S')] $*"; }
RU=labuser; getent passwd $RU >/dev/null || RU=$(getent passwd 1000 | cut -d: -f1)
M=$(readlink -f "$(command -v matlab 2>/dev/null)" 2>/dev/null)
[[ -x $M ]] || { log "MATLAB not found - nothing to do"; exit 0; }
MROOT=$(dirname "$(dirname "$M")")
log "START warm-up: $MROOT as $RU"
T=$(date +%s)
for d in bin sys java resources; do
  [[ -d $MROOT/$d ]] && find "$MROOT/$d" -type f -size -200M -print0 2>/dev/null | xargs -0 -P8 -n200 cat >/dev/null 2>&1
done
find "$MROOT/toolbox" \( -name '*.xml' -o -name 'Contents.m' -o -name '*.p' -o -name '*.mat' \) -type f -print0 2>/dev/null \
  | xargs -0 -P8 -n500 cat >/dev/null 2>&1
log "Pre-read core files: $(( $(date +%s)-T )) s"
T=$(date +%s)
OUT=$(sudo -u "$RU" -H timeout 900 "$M" -batch "ver; disp('WARMUP_OK')" 2>&1)
if grep -q WARMUP_OK <<<"$OUT"; then
  log "MATLAB first run: $(( $(date +%s)-T )) s - OK"
  log "WARMUP DONE"
else
  log "MATLAB first run FAILED (license server reachable?):"; tail -5 <<<"$OUT" | sed 's/^/    /'
  log "WARMUP FAILED"
fi
EOF
chmod +x /usr/local/bin/lab-matlab-warmup.sh
if command -v matlab >/dev/null; then
  systemctl reset-failed lab-matlab-warmup 2>/dev/null
  if systemd-run --unit=lab-matlab-warmup --description="Lab MATLAB warm-up" \
       nice -n 10 /usr/local/bin/lab-matlab-warmup.sh >/dev/null 2>&1; then
    log "MATLAB warm-up started in background (unit lab-matlab-warmup, ~2-4 min, log /var/log/matlab-warmup.log)"
  else
    setsid nohup nice -n 10 /usr/local/bin/lab-matlab-warmup.sh >/dev/null 2>&1 < /dev/null &
    log "MATLAB warm-up started in background (nohup, log /var/log/matlab-warmup.log)"
  fi
else
  log "MATLAB not installed - warm-up skipped"
fi

# ---------------------------------------------------------------------
step "13. Verification"
locale -a | grep -qi he_IL && log "PASS Hebrew locale"
fc-list :lang=he family | grep -q 'CLM' && log "PASS Hebrew fonts" || log "FAIL Hebrew fonts"
grep -q 'us,il' "$KB" && log "PASS xrdp map us,il"
dpkg-query -W -f='${Version}' xrdp | grep -q '+lab' && log "PASS patched xrdp $(dpkg-query -W -f='${Version}' xrdp)" || log "FAIL patched xrdp not installed"
[[ $(grep -cE '^Key[0-9]+=3[23][0-9]{2}:1[45][0-9]{2}$' /etc/xrdp/km-00000409.ini) -ge 27 ]] && log "PASS xrdp keymap Hebrew (27)" || log "FAIL xrdp keymap Hebrew"
grep -q 'labheb(us3)' /usr/share/X11/xkb/symbols/us && grep -q 'labheb(il3)' /usr/share/X11/xkb/symbols/il && log "PASS XKB Hebrew on RightAlt" || log "FAIL XKB Hebrew on RightAlt"
for u in unattended-upgrades apt-daily.timer apt-daily-upgrade.timer; do
  [[ $(systemctl is-enabled $u 2>/dev/null) == enabled ]] && log "FAIL $u still enabled" || log "PASS $u off"
done
snap list firefox >/dev/null 2>&1 && log "INFO Firefox is snap" || { dpkg-query -W firefox >/dev/null 2>&1 && log "PASS Firefox deb $(dpkg-query -W -f='${Version}' firefox)"; }
for s in matlab firefox; do [[ -f $DESK/$s.desktop ]] && log "PASS Desktop shortcut: $s" || log "FAIL Desktop shortcut: $s"; done
echo "  IBus ($LABUSER): $(U gsettings get org.freedesktop.ibus.general preload-engines)"
U xfconf-query -c xsettings -l -v 2>/dev/null | grep -E 'Xft/(HintStyle|Antialias|DPI|RGBA)' | sed 's/^/  /'
echo "  Compositing  : $(U xfconf-query -c xfwm4 -p /general/use_compositing 2>/dev/null) (false = sharper/faster)"
[[ -f $LHOME/.config/lab-dpi-set ]] && log "PASS DPI first-login marker set"
log "MATLAB warm-up: $(systemctl is-active lab-matlab-warmup 2>/dev/null || echo 'see /var/log/matlab-warmup.log')"
log "BOOTSTRAP COMPLETE"
exit 0
