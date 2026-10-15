cat > /tmp/test-all.sh <<'EOF'
#!/bin/bash
# Full check of a fresh lab: bootstrap results + Firefox/MATLAB speed (automatic timing)
# Optional: RESET=1 bash /tmp/test-all.sh  -> clears Firefox/MATLAB profiles first (simulates first open again)
export DISPLAY=${DISPLAY:-:10}
declare -A R
command -v xdotool >/dev/null || { echo "Installing xdotool..."; sudo apt-get -y -q install xdotool >/dev/null 2>&1; }

echo "== 1. Bootstrap results =="
sudo grep -E "PASS|FAIL|ERROR|Ctrl shortcuts|BOOTSTRAP COMPLETE" /var/log/lab-bootstrap.log | sed 's/^/  /'
echo "  MATLAB warm-up: $(sudo grep -E 'WARMUP (DONE|FAILED)|first run' /var/log/matlab-warmup.log | tail -2 | tr '\n' ' ')"

echo; echo "== 2. VM idle CPU (should be low) =="
top -bn2 -d2 | grep '^%Cpu' | tail -1 | awk '{printf "  CPU used: %.1f%%\n", 100-$8}'
echo "  Background update jobs running: $(pgrep -fc 'unattended-upgrade|apt.systemd.daily|packagekitd' || echo 0)"

if [[ ${RESET:-0} == 1 ]]; then
  echo; echo "== RESET: clearing Firefox + MATLAB user profiles =="
  pkill -f firefox; pkill -f MATLAB; sleep 3
  rm -rf ~/.mozilla ~/.cache/mozilla ~/.matlab; echo "  profiles cleared"
fi

M=$(readlink -f "$(command -v matlab)")
time_ff() {
  local k=$1; pkill -f firefox; sleep 3
  echo; echo ">>> $k: launching Firefox -> google.com ..."
  local t0=$(date +%s.%N)
  nohup firefox https://www.google.com >/dev/null 2>&1 &
  for i in $(seq 1 600); do
    xdotool search --onlyvisible --name "Google" >/dev/null 2>&1 && break; sleep 0.2
  done
  local t=$(echo "$(date +%s.%N) - $t0" | bc); R[$k]=$(printf "%.1f s" $t)
  echo "    $k: page loaded in ${R[$k]}"; sleep 3; pkill -f firefox; sleep 3
}
time_ml() {
  local k=$1; pkill -f MATLAB; rm -f /tmp/mlready; sleep 3
  echo; echo ">>> $k: launching MATLAB desktop ..."
  local t0=$(date +%s.%N)
  nohup "$M" -desktop -r "fclose(fopen('/tmp/mlready','w'));" >/dev/null 2>&1 &
  for i in $(seq 1 1200); do [[ -f /tmp/mlready ]] && break; sleep 0.2; done
  if [[ -f /tmp/mlready ]]; then
    local t=$(echo "$(date +%s.%N) - $t0" | bc); R[$k]=$(printf "%.1f s" $t)
  else R[$k]="TIMEOUT (>240 s)"; fi
  echo "    $k: ready in ${R[$k]}"; sleep 5; pkill -f MATLAB; sleep 5
}

echo; echo "== 3. Speed test (do not touch mouse/keyboard) =="
time_ff "Firefox-1st"; time_ff "Firefox-2nd"
time_ml "MATLAB-1st";  time_ml "MATLAB-2nd"

echo; echo "================ RESULTS ================"
for k in Firefox-1st Firefox-2nd MATLAB-1st MATLAB-2nd; do printf "  %-12s %s\n" "$k" "${R[$k]}"; done
echo "  Expected: Firefox ~3 s / <2 s, MATLAB ~30 s / ~20 s"
echo "DONE"
EOF
bash /tmp/test-all.sh
