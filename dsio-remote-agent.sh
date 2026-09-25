#!/usr/bin/env bash
# DSIO Remote — Linux agent installer.
# Full-auto counterpart of the Windows agent: enrolls with the Hub (remote-hub.dsio.io),
# stands up a locally-managed Cloudflare tunnel + a loopback VNC server as systemd services,
# and disables sleep so the machine stays reachable. Run with sudo.
#
#   sudo bash dsio-remote-agent.sh              # enroll via the Hub (interactive approval)
#   sudo bash dsio-remote-agent.sh --uninstall  # remove everything
#
set -euo pipefail

HUB="https://remote-hub.dsio.io"
BOOTSTRAP="dsio-remote-6f2b9c1a-enroll"
VNC_PORT=5900
DIR="/etc/dsio-remote"
BIN="/usr/local/bin/cloudflared"
LOG="/var/log/dsio-remote-agent.log"

log(){ echo "[$(date '+%H:%M:%S')] $*" | tee -a "$LOG" >&2; }
die(){ log "FATAL: $*"; exit 1; }
need_root(){ [ "$(id -u)" = "0" ] || die "Run with sudo (needs root to install services)."; }

uninstall(){
  need_root
  log "Uninstalling DSIO Remote agent..."
  systemctl disable --now dsio-cloudflared.service 2>/dev/null || true
  systemctl disable --now dsio-vnc.service 2>/dev/null || true
  rm -f /etc/systemd/system/dsio-cloudflared.service /etc/systemd/system/dsio-vnc.service
  systemctl daemon-reload 2>/dev/null || true
  # re-allow sleep (leave the machine as we found it)
  systemctl unmask sleep.target suspend.target hibernate.target hybrid-sleep.target 2>/dev/null || true
  rm -rf "$DIR"
  log "Removed."
  exit 0
}

detect_arch(){
  case "$(uname -m)" in
    x86_64|amd64) echo "amd64";;
    aarch64|arm64) echo "arm64";;
    armv7l|armhf) echo "arm";;
    *) die "Unsupported CPU arch $(uname -m)";;
  esac
}

install_cloudflared(){
  if [ -x "$BIN" ]; then log "cloudflared present"; return; fi
  local arch; arch="$(detect_arch)"
  log "Downloading cloudflared ($arch)..."
  curl -fsSL "https://github.com/cloudflare/cloudflared/releases/latest/download/cloudflared-linux-${arch}" -o "$BIN" \
    || die "Could not download cloudflared."
  chmod +x "$BIN"
}

# The display server dictates the VNC server: X11 -> x11vnc; Wayland -> wayvnc (wlroots) or,
# on GNOME/KDE Wayland, the compositor's own built-in sharing (we detect and guide).
SESSION_TYPE=""
detect_session(){
  SESSION_TYPE="${XDG_SESSION_TYPE:-}"
  if [ -z "$SESSION_TYPE" ]; then
    local u; u="$(logname 2>/dev/null || stat -c '%U' "/proc/$(pgrep -n gnome-shell 2>/dev/null || echo 1)" 2>/dev/null)"
    SESSION_TYPE="$(loginctl show-session "$(loginctl 2>/dev/null | awk 'NR==2{print $1}')" -p Type --value 2>/dev/null)"
  fi
  [ -z "$SESSION_TYPE" ] && SESSION_TYPE="x11"
  log "Display session type: $SESSION_TYPE"
}
pkg_install(){
  if command -v apt-get >/dev/null 2>&1; then DEBIAN_FRONTEND=noninteractive apt-get update -qq && DEBIAN_FRONTEND=noninteractive apt-get install -y -qq "$@"
  elif command -v dnf >/dev/null 2>&1; then dnf install -y "$@"
  elif command -v yum >/dev/null 2>&1; then yum install -y "$@"
  elif command -v pacman >/dev/null 2>&1; then pacman -Sy --noconfirm "$@"
  else die "No supported package manager (apt/dnf/yum/pacman)."; fi
}
install_vnc(){
  detect_session
  if [ "$SESSION_TYPE" = "wayland" ]; then
    if command -v wayvnc >/dev/null 2>&1; then log "wayvnc present"; return; fi
    log "Wayland detected — installing wayvnc (works on wlroots compositors: sway, etc.)..."
    pkg_install wayvnc || log "WARN: wayvnc not available. On GNOME/KDE Wayland enable the built-in screen share (gnome-remote-desktop / krfb) instead."
  else
    if command -v x11vnc >/dev/null 2>&1; then log "x11vnc present"; return; fi
    log "Installing x11vnc..."
    pkg_install x11vnc
  fi
}

# Enroll with the Hub: announce, then poll for the operator-approved config.
# Emits the AgentConfig JSON on stdout.
enroll(){
  local name info eid secret body code
  name="$(hostname)"
  info="$(. /etc/os-release 2>/dev/null; echo "${PRETTY_NAME:-Linux} - user $(logname 2>/dev/null || echo root)")"
  eid="$(cat /proc/sys/kernel/random/uuid | tr -d '-')"
  secret="$(cat /proc/sys/kernel/random/uuid | tr -d '-')"
  local req; req=$(python3 - "$eid" "$secret" "$name" "$BOOTSTRAP" "$info" <<'PY'
import json,sys
print(json.dumps({"EnrollId":sys.argv[1],"Secret":sys.argv[2],"Name":sys.argv[3],"Bootstrap":sys.argv[4],"MachineInfo":sys.argv[5]}))
PY
)
  log "Contacting the DSIO Remote Hub to enroll '$name' (retrying up to 2 min)..."
  local deadline=$(( $(date +%s) + 120 )) ok=0
  while [ "$(date +%s)" -lt "$deadline" ]; do
    code=$(curl -fsS -o /dev/null -w "%{http_code}" -X POST "$HUB/enroll" -H "Content-Type: application/json" -d "$req" 2>/dev/null || echo 000)
    [ "$code" = "202" ] && { ok=1; break; }
    sleep 3
  done
  [ "$ok" = "1" ] || die "Could not reach the Hub. Make sure the DSIO Remote Hub is open and signed in, then re-run."
  log "Announced. Waiting for the operator to click 'Add' in the Hub (up to 10 min)..."
  deadline=$(( $(date +%s) + 600 ))
  while [ "$(date +%s)" -lt "$deadline" ]; do
    body=$(curl -fsS "$HUB/config?enrollId=$eid&secret=$secret" 2>/dev/null || echo "")
    if echo "$body" | python3 -c 'import sys,json;d=json.load(sys.stdin);print("OK") if (d.get("TunnelId") or d.get("tunnelId")) else sys.exit(1)' >/dev/null 2>&1; then
      echo "$body"; return 0
    fi
    sleep 4
  done
  die "Timed out waiting for the Hub operator to accept this machine."
}

configure(){
  local cfg="$1" field
  get(){ echo "$1" | python3 -c "import sys,json;d=json.load(sys.stdin);print(d.get('$2') or d.get('$3') or '')"; }
  local tid host cred vncpw
  tid="$(get "$cfg" TunnelId tunnelId)"
  host="$(get "$cfg" Hostname hostname)"
  cred="$(echo "$cfg" | python3 -c "import sys,json;d=json.load(sys.stdin);print(d.get('CredentialsJson') or d.get('credentialsJson') or '')")"
  vncpw="$(get "$cfg" VncPassword vncPassword)"
  [ -n "$tid" ] && [ -n "$host" ] && [ -n "$cred" ] || die "Config missing TunnelId/Hostname/CredentialsJson."
  [ -n "$vncpw" ] || vncpw="$(head -c8 /dev/urandom | base64 | tr -dc 'a-z0-9' | head -c8)"

  mkdir -p "$DIR"
  echo "$cred" > "$DIR/$tid.json"; chmod 600 "$DIR/$tid.json"
  cat > "$DIR/config.yml" <<YML
tunnel: $tid
credentials-file: $DIR/$tid.json
no-autoupdate: true
ingress:
  - hostname: $host
    service: tcp://localhost:$VNC_PORT
  - service: http_status:404
YML
  # VNC password (loopback-only server, only reachable through the tunnel)
  if [ "$SESSION_TYPE" != "wayland" ] && command -v x11vnc >/dev/null 2>&1; then
    x11vnc -storepasswd "$vncpw" "$DIR/vncpass" >/dev/null 2>&1 || true
    chmod 600 "$DIR/vncpass" 2>/dev/null || true
  fi
  echo "$vncpw" > "$DIR/vncpw.txt"; chmod 600 "$DIR/vncpw.txt"
  echo "$host" > "$DIR/hostname"
  log "Configured tunnel $host (VNC loopback:$VNC_PORT)"
}

install_services(){
  # cloudflared tunnel connector
  cat > /etc/systemd/system/dsio-cloudflared.service <<UNIT
[Unit]
Description=DSIO Remote - Cloudflare tunnel
After=network-online.target
Wants=network-online.target
[Service]
ExecStart=$BIN tunnel --config $DIR/config.yml run
Restart=always
RestartSec=5
[Install]
WantedBy=multi-user.target
UNIT

  # VNC server against the active graphical session, bound to loopback.
  local vncexec
  if [ "$SESSION_TYPE" = "wayland" ] && command -v wayvnc >/dev/null 2>&1; then
    # wayvnc (wlroots) on loopback; security is the tunnel + operator DSUI auth.
    vncexec="/usr/bin/wayvnc 127.0.0.1 $VNC_PORT"
  else
    vncexec="/usr/bin/x11vnc -rfbport $VNC_PORT -localhost -rfbauth $DIR/vncpass -forever -loop -shared -noxdamage -display :0 -auth guess"
  fi
  cat > /etc/systemd/system/dsio-vnc.service <<UNIT
[Unit]
Description=DSIO Remote - VNC server (loopback)
After=display-manager.service graphical.target
[Service]
Type=simple
ExecStart=$vncexec
Restart=always
RestartSec=5
[Install]
WantedBy=graphical.target
UNIT

  systemctl daemon-reload
  systemctl enable --now dsio-cloudflared.service
  systemctl enable --now dsio-vnc.service || log "WARN: dsio-vnc failed to start (no graphical :0 session yet? it will start when the desktop is up)."
}

disable_sleep(){
  systemctl mask sleep.target suspend.target hibernate.target hybrid-sleep.target 2>/dev/null || true
  log "Sleep/suspend/hibernate masked (stays reachable)."
}

report(){
  local host="$1" mac subnet
  mac="$(cat /sys/class/net/$(ip route show default 2>/dev/null | awk '/default/{print $5;exit}')/address 2>/dev/null || echo)"
  subnet="$(ip -o -4 addr show scope global 2>/dev/null | awk '{print $4}' | head -1 | cut -d/ -f1 | cut -d. -f1-3)"
  local vnc; vnc=$(ss -ltn 2>/dev/null | grep -q ":$VNC_PORT" && echo true || echo false)
  local rep; rep=$(python3 - "$host" "$(uname -sr)" "$mac" "$subnet" "$vnc" <<'PY'
import json,sys
print(json.dumps({"Name":__import__("socket").gethostname(),"Hostname":sys.argv[1],"RdpListening":sys.argv[5]=="true","Os":sys.argv[2],"Mac":sys.argv[3],"Subnet":sys.argv[4],"Detail":"Linux agent"}))
PY
)
  curl -fsS -o /dev/null -X POST "$HUB/report" -H "Content-Type: application/json" -d "$rep" 2>/dev/null || true
}

main(){
  [ "${1:-}" = "--uninstall" ] && uninstall
  need_root
  mkdir -p "$(dirname "$LOG")"
  log "=== DSIO Remote Linux agent $(date -u) ==="
  install_cloudflared
  install_vnc
  local cfg; cfg="$(enroll)"
  configure "$cfg"
  install_services
  disable_sleep
  local host; host="$(cat "$DIR/hostname")"
  report "$host"
  log "Done. This machine is reachable at: $host"
  echo
  echo "  DSIO Remote agent installed. Reachable at $host"
  echo "  (VNC needs a graphical session on :0; on a headless server, connect a display or set up a virtual X server.)"
}
main "$@"
