#!/bin/bash
# DSIO Remote — macOS agent installer.
# Full-auto counterpart of the Windows/Linux agent: enrolls with the Hub, enables the built-in
# Screen Sharing (VNC) bound to loopback, stands up a locally-managed Cloudflare tunnel as a
# launchd daemon, and disables sleep. Run with sudo.
#
#   sudo bash dsio-remote-agent-macos.sh              # enroll via the Hub
#   sudo bash dsio-remote-agent-macos.sh --uninstall  # remove everything
#
# NOTE: macOS requires a one-time Screen Recording permission for Screen Sharing to capture the
# display (System Settings > Privacy & Security > Screen Recording). This cannot be granted silently.
set -euo pipefail

HUB="https://remote-hub.dsio.io"
BOOTSTRAP="dsio-remote-6f2b9c1a-enroll"
VNC_PORT=5900
DIR="/Library/Application Support/DsioRemote"
BIN="/usr/local/bin/cloudflared"
PLIST="/Library/LaunchDaemons/io.dsio.remote.tunnel.plist"
LOG="/var/log/dsio-remote-agent.log"
# The account the tunnel daemon runs as (see install_daemon). SUDO_USER when run the documented
# way (sudo bash ...); falls back to the console user for the rare case it's run as root directly.
RUN_USER="${SUDO_USER:-$(stat -f%Su /dev/console 2>/dev/null || echo root)}"

log(){ echo "[$(date '+%H:%M:%S')] $*" | tee -a "$LOG" >&2; }
die(){ log "FATAL: $*"; exit 1; }
need_root(){ [ "$(id -u)" = "0" ] || die "Run with sudo."; }

# JSON via JavaScriptCore (osascript -l JavaScript) — always present on macOS, no python needed.
json_get(){ # $1=json  $2=key(PascalCase)  $3=key(camelCase)
  osascript -l JavaScript -e "function run(a){var d=JSON.parse(a[0]);return (d['$2']!==undefined?d['$2']:(d['$3']!==undefined?d['$3']:''))}" "$1" 2>/dev/null
}
json_build(){ # builds the enroll request json  $1..$5
  osascript -l JavaScript -e 'function run(a){return JSON.stringify({EnrollId:a[0],Secret:a[1],Name:a[2],Bootstrap:a[3],MachineInfo:a[4]})}' "$1" "$2" "$3" "$4" "$5" 2>/dev/null
}

uninstall(){
  need_root
  log "Uninstalling..."
  launchctl bootout system "$PLIST" 2>/dev/null || launchctl unload "$PLIST" 2>/dev/null || true
  rm -f "$PLIST"
  # turn Screen Sharing back off
  /System/Library/CoreServices/RemoteManagement/ARDAgent.app/Contents/Resources/kickstart -deactivate -stop 2>/dev/null || true
  launchctl unload -w /System/Library/LaunchDaemons/com.apple.screensharing.plist 2>/dev/null || true
  pmset -a sleep 15 2>/dev/null || true
  rm -rf "$DIR"
  log "Removed."; exit 0
}

install_cloudflared(){
  if [ -x "$BIN" ]; then log "cloudflared present"; return; fi
  local arch tgt; case "$(uname -m)" in arm64) arch=arm64;; x86_64) arch=amd64;; *) die "arch $(uname -m)";; esac
  # Pinned, not "latest": releases from late 2025 on use a newer Mach-O chained-fixups layout that
  # dyld on Catalina/Big Sur can't parse (SIGSEGV in dyld itself before main() even runs). 2024.6.1
  # is the newest build confirmed to load on 10.15 and still speaks the current tunnel protocol.
  log "Downloading cloudflared (darwin $arch)..."
  tgt="/tmp/cloudflared.tgz"
  curl -fsSL "https://github.com/cloudflare/cloudflared/releases/download/2024.6.1/cloudflared-darwin-${arch}.tgz" -o "$tgt" || die "download failed"
  tar -xzf "$tgt" -C /tmp cloudflared && mv /tmp/cloudflared "$BIN" && chmod +x "$BIN"
  rm -f "$tgt"
  # Re-sign ad hoc. On at least one old Intel Mac the shipped signature made every *run* of the
  # tunnel (not --version, which does nothing) get silently SIGKILLed a moment after it started
  # doing real work, with taskgated logging "no signature for pid=N (cannot make code)" for a pid
  # that had already been killed — the validation losing a race with an earlier kill, not causing
  # it. Re-signing ad hoc reliably fixed it there; harmless to do unconditionally everywhere else.
  codesign --remove-signature "$BIN" 2>/dev/null || true
  codesign -s - --force "$BIN" 2>/dev/null || true
}

enable_screen_sharing(){
  local pw="$1"
  # VNC (RFB) auth is DES over the first 8 password bytes; cap here so the Mac and the Hub's
  # viewer always agree on exactly those 8 chars even if a longer password is issued.
  pw="${pw:0:8}"
  log "Enabling Screen Sharing (VNC) on loopback..."
  # Enable Apple Remote Desktop / Screen Sharing agent with full access.
  /System/Library/CoreServices/RemoteManagement/ARDAgent.app/Contents/Resources/kickstart \
    -activate -configure -access -on -restart -agent -privs -all >/dev/null 2>&1 || true
  launchctl load -w /System/Library/LaunchDaemons/com.apple.screensharing.plist 2>/dev/null || true
  # Allow VNC-protocol clients and set the VNC password (macOS stores it XOR'd with a fixed key).
  defaults write /Library/Preferences/com.apple.RemoteManagement VNCAlwaysStartOnConsole -bool true 2>/dev/null || true
  defaults write /Library/Preferences/com.apple.VNCSettings VNCLegacyConnectionsEnabled -bool true 2>/dev/null || true
  local key="1734516E8BA8C5E2FF1C39567390ADCA"
  local enc; enc=$(osascript -l JavaScript -e "function run(a){var p=a[0],k=a[1],o='';for(var i=0;i<p.length;i++){o+=('0'+(p.charCodeAt(i)^parseInt(k.substr(i*2,2),16)).toString(16)).slice(-2)}return o}" "$pw" "$key" 2>/dev/null)
  printf '%s' "$enc" > /Library/Preferences/com.apple.VNCSettings.txt
  chmod 600 /Library/Preferences/com.apple.VNCSettings.txt
}

enroll(){
  local name info eid secret req code body
  name="$(scutil --get ComputerName 2>/dev/null || hostname)"
  info="macOS $(sw_vers -productVersion 2>/dev/null) - user $(stat -f%Su /dev/console 2>/dev/null || echo admin)"
  eid="$(uuidgen | tr -d '-')"; secret="$(uuidgen | tr -d '-')"
  req="$(json_build "$eid" "$secret" "$name" "$BOOTSTRAP" "$info")"
  log "Contacting the Hub to enroll '$name' (retry up to 2 min)..."
  local deadline=$(( $(date +%s) + 120 )) ok=0
  while [ "$(date +%s)" -lt "$deadline" ]; do
    code=$(curl -fsS -o /dev/null -w "%{http_code}" -X POST "$HUB/enroll" -H "Content-Type: application/json" -d "$req" 2>/dev/null || echo 000)
    [ "$code" = "202" ] && { ok=1; break; }; sleep 3
  done
  [ "$ok" = "1" ] || die "Could not reach the Hub. Open the DSIO Remote Hub (signed in), then re-run."
  log "Announced. Waiting for operator approval in the Hub (up to 10 min)..."
  deadline=$(( $(date +%s) + 600 ))
  while [ "$(date +%s)" -lt "$deadline" ]; do
    body=$(curl -fsS "$HUB/config?enrollId=$eid&secret=$secret" 2>/dev/null || echo "")
    if [ -n "$body" ] && [ -n "$(json_get "$body" TunnelId tunnelId)" ]; then echo "$body"; return 0; fi
    sleep 4
  done
  die "Timed out waiting for approval."
}

configure(){
  local cfg="$1" tid host cred vncpw
  tid="$(json_get "$cfg" TunnelId tunnelId)"
  host="$(json_get "$cfg" Hostname hostname)"
  cred="$(json_get "$cfg" CredentialsJson credentialsJson)"
  vncpw="$(json_get "$cfg" VncPassword vncPassword)"
  [ -n "$tid" ] && [ -n "$host" ] && [ -n "$cred" ] || die "config missing fields"
  [ -n "$vncpw" ] || vncpw="$(LC_ALL=C tr -dc 'a-z0-9' </dev/urandom | head -c8)"
  mkdir -p "$DIR"
  printf '%s' "$cred" > "$DIR/$tid.json"; chmod 600 "$DIR/$tid.json"
  cat > "$DIR/config.yml" <<YML
tunnel: $tid
credentials-file: $DIR/$tid.json
no-autoupdate: true
ingress:
  - hostname: $host
    service: tcp://localhost:$VNC_PORT
  - service: http_status:404
YML
  echo "$host" > "$DIR/hostname"
  # The daemon (below) runs as this account, not root, so it can read its own credentials.
  chown "$RUN_USER" "$DIR/$tid.json" "$DIR/config.yml" "$DIR/hostname" 2>/dev/null || true
  enable_screen_sharing "$vncpw"
  log "Configured $host"
}

install_daemon(){
  # Run as the enrolling user, not root. cloudflared needs no privilege to dial out and forward
  # to a loopback port, and on at least one old Mac the tunnel process was reliably SIGKILLed a
  # moment into running when launchd ran it as root (see install_cloudflared for the fuller story;
  # the ad-hoc re-sign there was the actual fix, but running unprivileged is also just correct).
  rm -f /var/log/dsio-cloudflared.log
  touch /var/log/dsio-cloudflared.log && chown "$RUN_USER" /var/log/dsio-cloudflared.log
  cat > "$PLIST" <<PL
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>Label</key><string>io.dsio.remote.tunnel</string>
  <key>UserName</key><string>$RUN_USER</string>
  <key>ProgramArguments</key><array>
    <string>$BIN</string><string>tunnel</string><string>--config</string><string>$DIR/config.yml</string><string>run</string>
  </array>
  <key>RunAtLoad</key><true/>
  <key>KeepAlive</key><true/>
  <key>StandardErrorPath</key><string>/var/log/dsio-cloudflared.log</string>
</dict></plist>
PL
  launchctl bootout system "$PLIST" 2>/dev/null || true
  launchctl bootstrap system "$PLIST" 2>/dev/null || launchctl load -w "$PLIST"
  log "Tunnel daemon installed."
}

disable_sleep(){ pmset -a sleep 0 displaysleep 0 disksleep 0 2>/dev/null || true; log "Sleep disabled."; }

report(){
  local host="$1" mac subnet listening rep
  mac="$(ifconfig en0 2>/dev/null | awk '/ether/{print $2;exit}')"
  subnet="$(ipconfig getifaddr en0 2>/dev/null | cut -d. -f1-3)"
  listening=$(netstat -an 2>/dev/null | grep -q "\.$VNC_PORT .*LISTEN" && echo true || echo false)
  rep=$(osascript -l JavaScript -e 'function run(a){return JSON.stringify({Name:a[0],Hostname:a[1],RdpListening:a[4]==="true",Os:a[2],Mac:a[3],Subnet:a[5],Detail:"macOS agent"})}' "$(scutil --get ComputerName 2>/dev/null||hostname)" "$host" "macOS $(sw_vers -productVersion)" "$mac" "$listening" "$subnet" 2>/dev/null)
  curl -fsS -o /dev/null -X POST "$HUB/report" -H "Content-Type: application/json" -d "$rep" 2>/dev/null || true
}

main(){
  [ "${1:-}" = "--uninstall" ] && uninstall
  need_root
  log "=== DSIO Remote macOS agent $(date -u) ==="
  install_cloudflared
  local cfg; cfg="$(enroll)"
  configure "$cfg"
  install_daemon
  disable_sleep
  local host; host="$(cat "$DIR/hostname")"
  report "$host"
  log "Done. Reachable at $host"
  echo
  echo "  DSIO Remote installed. Reachable at $host"
  echo "  IMPORTANT: grant Screen Recording to Screen Sharing under"
  echo "  System Settings > Privacy & Security > Screen Recording, or the remote view stays blank."
}
main "$@"
