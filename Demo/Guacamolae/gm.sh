
#!/bin/bash
# =====================================================================
# gm.sh  -  Guacamole TEST server (Docker) for the Ariel lab
# Runs via Azure Custom Script Extension:  bash gm.sh <TARGET_HOST> <RDP_PASSWORD> [RDP_USER]
# Creates test connections to the Ariel VM:
#   D1  Baseline (32-bit)                D2  Lossless + Auto-resize
#   D3  Lossless + Auto-resize + DPI 120
#   K1  Keyboard default (en-us-qwerty)  K2  Keyboard Unicode (failsafe)
# Change target later (no redeploy):  sudo guac-set-target <HOST> <PASSWORD> [USER]
# Log: /var/log/gm-setup.log     Creds: /root/guac-test-creds.txt
# =====================================================================
set -uo pipefail
LOG=/var/log/gm-setup.log
exec > >(tee -a "$LOG") 2>&1
log()  { echo "[$(date '+%H:%M:%S')] $*"; }
step() { echo; echo "================ $* ================"; }
export DEBIAN_FRONTEND=noninteractive

TARGET=${1:-CHANGE-ME}; RPASS=${2:-CHANGE-ME}; RUSER=${3:-labuser}
GVER=1.5.5
BASE=/opt/guac-test
GUSER=guacadmin
GPASS=$(openssl rand -hex 6)

# ---------------------------------------------------------------------
step "1. Install Docker"
apt-get update -q
apt-get install -y -q -o DPkg::Lock::Timeout=600 docker.io curl python3 >/dev/null && log "Docker installed: $(docker --version)"
systemctl enable --now docker >/dev/null 2>&1
docker info >/dev/null 2>&1 && log "Docker running" || { log "ERROR: Docker not running"; exit 1; }

# ---------------------------------------------------------------------
step "2. Connection builder (also used by guac-set-target)"
cat > /usr/local/bin/guac-set-target <<'EOF'
#!/bin/bash
# usage: sudo guac-set-target <HOST> <RDP_PASSWORD> [RDP_USER]
set -uo pipefail
[[ $EUID -eq 0 ]] || { echo "run with sudo"; exit 1; }
H=${1:?host}; P=${2:?password}; U=${3:-labuser}
BASE=/opt/guac-test; F=$BASE/home/user-mapping.xml
GU=$(awk '/Username/{print $3}' /root/guac-test-creds.txt); GP=$(awk '/Password/{print $3}' /root/guac-test-creds.txt)
x() { printf '%s' "$1" | sed -e 's/&/\&amp;/g' -e 's/</\&lt;/g' -e 's/>/\&gt;/g' -e 's/"/\&quot;/g'; }
conn() {  # name, extra params
cat <<C
    <connection name="$1">
      <protocol>rdp</protocol>
      <param name="hostname">$(x "$H")</param>
      <param name="port">3389</param>
      <param name="username">$(x "$U")</param>
      <param name="password">$(x "$P")</param>
      <param name="ignore-cert">true</param>
      <param name="security">any</param>
      <param name="color-depth">32</param>
$2
    </connection>
C
}
L='      <param name="force-lossless">true</param>'
R='      <param name="resize-method">display-update</param>'
{
echo "<user-mapping>"
echo "  <authorize username=\"$(x "$GU")\" password=\"$(x "$GP")\">"
conn "D1-Baseline (32-bit only)" ""
conn "D2-Lossless + Auto-resize" "$L
$R"
conn "D3-Lossless + Auto-resize + DPI 120" "$L
$R
      <param name=\"dpi\">120</param>"
conn "K1-Keyboard default (en-us-qwerty)" "$L
$R
      <param name=\"server-layout\">en-us-qwerty</param>"
conn "K2-Keyboard Unicode (failsafe)" "$L
$R
      <param name=\"server-layout\">failsafe</param>"
echo "  </authorize>"
echo "</user-mapping>"
} > "$F"
chmod 755 "$BASE/home"; chmod 644 "$BASE/home/"*
docker restart guacamole >/dev/null 2>&1
echo "Target set to $H (user $U). 5 connections written. Refresh the Guacamole page."
EOF
chmod +x /usr/local/bin/guac-set-target
log "Created /usr/local/bin/guac-set-target"

# ---------------------------------------------------------------------
step "3. Guacamole config"
mkdir -p "$BASE/home"
cat > "$BASE/home/guacamole.properties" <<EOF
guacd-hostname: guacd
guacd-port: 4822
user-mapping: /etc/guacamole-home/user-mapping.xml
EOF
printf 'Username : %s\nPassword : %s\n' "$GUSER" "$GPASS" > /root/guac-test-creds.txt
chmod 600 /root/guac-test-creds.txt

# ---------------------------------------------------------------------
step "4. Start containers (guacd + guacamole $GVER)"
docker network inspect guacnet >/dev/null 2>&1 || docker network create guacnet >/dev/null
docker rm -f guacd guacamole >/dev/null 2>&1
docker pull -q guacamole/guacd:$GVER >/dev/null && docker pull -q guacamole/guacamole:$GVER >/dev/null && log "Images pulled"
docker run -d --name guacd --network guacnet --restart unless-stopped guacamole/guacd:$GVER >/dev/null
docker run -d --name guacamole --network guacnet --restart unless-stopped -p 8080:8080 \
  -e GUACD_HOSTNAME=guacd -e GUACAMOLE_HOME=/etc/guacamole-home \
  -v "$BASE/home":/etc/guacamole-home guacamole/guacamole:$GVER >/dev/null
/usr/local/bin/guac-set-target "$TARGET" "$RPASS" "$RUSER" | sed 's/^/  /'

# ---------------------------------------------------------------------
step "5. Verify"
for i in $(seq 1 40); do [[ $(curl -s -o /dev/null -w '%{http_code}' http://localhost:8080/guacamole/) == 200 ]] && break; sleep 3; done
CODE=$(curl -s -o /dev/null -w '%{http_code}' http://localhost:8080/guacamole/)
[[ $CODE == 200 ]] && log "PASS: web UI up" || log "FAIL: web UI HTTP $CODE"
TOK=$(curl -s -X POST -d "username=$GUSER&password=$GPASS" http://localhost:8080/guacamole/api/tokens | sed -n 's/.*"authToken":"\([^"]*\)".*/\1/p')
[[ -n $TOK ]] && log "PASS: login works" || log "FAIL: login"
timeout 5 bash -c "</dev/tcp/$TARGET/3389" 2>/dev/null && log "PASS: $TARGET:3389 reachable" || log "WARN: $TARGET:3389 not reachable (set with guac-set-target)"
PIP=$(curl -s -H Metadata:true --max-time 3 "http://169.254.169.254/metadata/instance/network/interface/0/ipv4/ipAddress/0/publicIpAddress?api-version=2021-02-01&format=text")

step "DONE"
echo "  URL      : http://${PIP:-<public-ip>}:8080/guacamole/"
sed 's/^/  /' /root/guac-test-creds.txt
echo "  Target   : $TARGET"
echo "  Retarget : sudo guac-set-target <ARIEL-DNS> '<password>'"
exit 0
