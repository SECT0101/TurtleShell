#!/bin/bash
# Title: TurtleShell Hub Edition
# Description: TurtleTAK and TurtleMesh together on the LAN Turtle Hub - the Hub on TAK as a facility sensor with network watch alerts, plus a Meshtastic radio with mesh chat, mesh watch, alerts over LoRa and a mesh <-> TAK bridge, from one payload
# Author: SECT0101
# Version: 1.0.1
# Category: General
# Target: LAN Turtle Hub on a network you own or are authorized to monitor, with a Meshtastic radio
#
# What it does
#   The Hub runs one payload at a time. TurtleShell is that one payload: it carries TurtleTAK
#   1.0.2 and TurtleMesh 1.0.2 unchanged, starts both, and keeps them running.
#
#   TurtleTAK    http://<hub>:8484   TAK sensor, network watch alerts, mesh SA bridge, offline map
#   TurtleMesh   http://<hub>:8485   Meshtastic radio, mesh chat, nodes, mesh watch, alerts over LoRa
#
#   Working together
#     - TurtleMesh uses TurtleTAK's TAK Server and certificates (set up TAK once, in TurtleTAK)
#     - TurtleTAK's alerts go out over LoRa through TurtleMesh
#     - The radio's GPS fix becomes the Hub's position in both
#     - TurtleTAK's USB GPS reader leaves a USB radio alone
#     - Each web console links to the other
#     - TurtleTAK drives the Hub's LED; TurtleMesh leaves it alone
#     - If one service stops, TurtleShell restarts it; stopping the payload stops both
#
# Setup
#   1. Run the payload once. Each service posts its first web password as a Hub notification
#      (also in /root/turtletak/web-password.txt and /root/turtlemesh/web-password.txt).
#   2. TurtleTAK (port 8484) > Setup: connect to your TAK Server.
#   3. TurtleMesh (port 8485) > Radio: the radio's address (Wi-Fi) or USB.
#
# Files
#   /root/turtletak/ and /root/turtlemesh/   each service's settings, certificates and logs
#   /root/turtleshell/                       the two payloads as run, and turtleshell.log
#
# Meshtastic(R) is a registered trademark of Meshtastic LLC. Use only on networks you own or are
# authorized to monitor. Community payload, not supported by Hak5.
#
case "$(head -c 8192 "$0" 2>/dev/null)" in *$'\r'*) _lf="/tmp/.$(basename "$0").$$.lf"; tr -d '\r' < "$0" > "$_lf" && echo "fixed Windows line endings in $0" >&2 && exec bash "$_lf" "$@";; esac #
# ^ Pasted or saved on Windows? That line removes Windows line endings and runs the payload again.

SHELL_BASE="${TS_BASE:-/root/turtleshell}"
mkdir -p "$SHELL_BASE"
LOGF="$SHELL_BASE/turtleshell.log"
log() { echo "$(date '+%Y-%m-%d %H:%M:%S') $*" >> "$LOGF"; }

# If this file was cut off while copying it to the Hub, the script ends early: say so.
TS_STARTED=""
trap '[ -n "$TS_STARTED" ] || { log "[error] payload.sh ended early - the file is incomplete or damaged, copy the whole file again"; LED FAIL 2>/dev/null; NOTIFY_ERROR TurtleShell "payload.sh ended early - the file is incomplete or damaged (cut off while copying?). Copy the whole file again." 2>/dev/null; echo "TurtleShell: payload.sh is incomplete or damaged" >&2; }' EXIT

# Hak5 commands are handed to both payloads, whether they are programs or Bash functions here.
for c in LED NOTIFY_INFO NOTIFY_WARNING NOTIFY_ERROR LOG_INFO LOG_WARNING LOG_ERROR C2NOTIFY C2EXFIL \
         WIFI_CONNECT WIFI_DISCONNECT WIREGUARD_CONFIGURE WIREGUARD_ENABLE WIREGUARD_DISABLE \
         USB_CLAIM_DEVICE USB_POWER_ON USB_POWER_OFF BOOT_PAYLOAD; do
    [ "$(type -t "$c")" = "function" ] && export -f "$c"
done

# Stop an older TurtleShell (re-running the payload restarts both services with this version)
if [ -f "$SHELL_BASE/turtleshell.pid" ]; then
    old=$(cat "$SHELL_BASE/turtleshell.pid" 2>/dev/null)
    if [ -n "$old" ] && [ "$old" != "$$" ] && kill -0 "$old" 2>/dev/null; then
        kill "$old" 2>/dev/null; sleep 3
    fi
fi

# ---- the two payloads, unchanged (each checks itself when it starts) -------------------------
cat > "$SHELL_BASE/turtletak.sh" <<'TURTLESHELL_TAK'
#!/bin/bash
# Title: TurtleTAK Hub Edition
# Description: Puts the LAN Turtle Hub on TAK as a facility sensor - position and status, GeoChat, network watch alerts (new devices, ARP spoofing, rogue DHCP, link tamper), an ATAK mesh SA bridge and a web console
# Author: SECT0101
# Version: 1.0.2
# Category: General
# Target: LAN Turtle Hub on a network you own or are authorized to monitor
#
# What it does
#   Sensor on TAK     The Hub reports its position and status (uplink, RJ45 link, VPN, public IP,
#                     watch and bridge counts) as a CoT marker every SA_INTERVAL seconds: sensor
#                     (a-f-G-E-S, default), facility, team member in a team color, or custom (COT_TYPE)
#   GeoChat           Send / receive from the web console (reply, unread count, delete / clear).
#                     Others can direct-message the Hub: status, where, scan, alerts, help
#   Network watch     Sweeps the RJ45 network, keeps a baseline per network and alerts on:
#                     new devices, a gateway MAC change or duplicate gateway MAC (ARP spoofing),
#                     a rogue DHCP server, RJ45 link lost / restored (tamper), TAK link down
#   Alerts            Marker at the Hub (yellow = warning, red = critical) + All Chat Rooms line
#                     + Hub notification (bell icon) + optional Cloud C2 notification + LED flash.
#                     Nothing reachable? Alerts and chat are queued and sent when TAK is back.
#   Mesh SA bridge    Optional: ATAK mesh SA / chat on the LAN (239.2.3.1:6969, 224.10.10.1:17012,
#                     XML or TAK protocol v1) forwarded to the TAK Server, and server traffic
#                     repeated back onto the LAN - a whole room of ATAK users on the server
#   Uplinks           Out-of-band Wi-Fi client and the Hub's WireGuard client from the settings
#   Web console       http://<hub>:8484 on every interface (USB-C host, RJ45, Wi-Fi, VPN)
#
# Location (the Hub has no GPS), first that works in auto mode:
#   1. The Meshtastic radio's GPS, while TurtleMesh runs on the same Hub
#   2. USB GPS on the dynamic USB port (u-blox / VK-162 style NMEA, claimed for the Hub)
#   3. Anchor to your ATAK (MY_ATAK callsign, from the TAK Server or the mesh)
#   4. A saved site   5. Manual lat/lon (or click the web map)   6. Public IP (city level)
#   LOC_MODE picks a primary source; the rest stay as fallback in this order.
#
# Setup
#   1. Run the payload once. It creates /root/turtletak/ and its default.cfg, and posts the web
#      console's first password as a Hub notification (also in /root/turtletak/web-password.txt).
#   2. Open http://172.16.84.1:8484 (or the Hub's RJ45 / Wi-Fi / VPN address) > Setup.
#   3. Setup > TAK Server connection, one of:
#        Connection package  the .zip from your TAK admin (passwords inside it are used)
#        Certificates        server + client .p12 with its password + truststore .p12 with its password
#        Enroll              your TAK username and password (certificate enrollment)
#      No openssl needed: .p12 files (AES, 3DES or RC2) and enrollment keys are handled in Python.
#   4. Set the location, and turn on the mesh bridge if you want it.
#
# LED (LED: 0 in the settings keeps it dark)
#   Magenta solid    starting          Yellow double   connecting to TAK
#   Green single     on TAK            Red slow        setup needed (no server / certificate)
#   Cyan inverse     warning alert     Red fast        critical alert (both for 60 s)
#
# Files
#   /root/turtletak/default.cfg     every setting, "KEY: value" (web console Settings, or SSH)
#   /root/turtletak/certs/          TAK certificates, connection packages, wg.conf (never share)
#   /root/turtletak/baselines/      known devices, one file per network
#   /root/turtletak/sites.txt       saved sites: name|lat|lon
#   /root/turtletak/logs/           turtletak.log (also in the web console)
#   /root/turtletak/app/            the service and web page - rewritten from this payload on every run
#
# Use only on networks you own or are authorized to monitor. Community payload, not supported by Hak5.
#
case "$(head -c 8192 "$0" 2>/dev/null)" in *$'\r'*) _lf="/tmp/.$(basename "$0").$$.lf"; tr -d '\r' < "$0" > "$_lf" && echo "fixed Windows line endings in $0" >&2 && exec bash "$_lf" "$@";; esac #
# ^ Pasted or saved on Windows? That line removes Windows line endings and runs the payload again.

BASE="${TT_BASE:-/root/turtletak}"
APP="$BASE/app"
PY=$(command -v python3 || command -v python)

# If this file was cut off while copying it to the Hub, the script ends early and the service never
# starts. Say so (Hub notification, red LED, log) instead of failing silently.
TT_STARTED=""
trap '[ -n "$TT_STARTED" ] || { mkdir -p "$BASE/logs"; echo "$(date "+%Y-%m-%d %H:%M:%S") [error] payload.sh ended early - the file is incomplete or damaged, copy the whole file to the Hub again" >> "$BASE/logs/console.log"; LED FAIL 2>/dev/null; NOTIFY_ERROR TurtleTAK "payload.sh ended early - the file is incomplete or damaged (cut off while copying?). Copy the whole file again." 2>/dev/null; echo "TurtleTAK: payload.sh is incomplete or damaged" >&2; }' EXIT

# Hak5 commands (LED, NOTIFY_*, C2NOTIFY, WIFI_CONNECT, WIREGUARD_*, USB_*, BOOT_PAYLOAD) are
# handed to the Python service's child shells, whether they are programs or Bash functions here.
for c in LED NOTIFY_INFO NOTIFY_WARNING NOTIFY_ERROR LOG_INFO LOG_WARNING LOG_ERROR C2NOTIFY C2EXFIL \
         WIFI_CONNECT WIFI_DISCONNECT WIREGUARD_CONFIGURE WIREGUARD_ENABLE WIREGUARD_DISABLE \
         USB_CLAIM_DEVICE USB_POWER_ON USB_POWER_OFF BOOT_PAYLOAD; do
    [ "$(type -t "$c")" = "function" ] && export -f "$c"
done

if [ -z "$PY" ]; then
    LED FAIL 2>/dev/null
    NOTIFY_ERROR TurtleTAK "Python 3 not found - TurtleTAK needs it" 2>/dev/null
    echo "TurtleTAK: python3 not found" >&2
    exit 1
fi

mkdir -p "$APP" "$BASE/certs" "$BASE/logs" "$BASE/baselines"
chmod 700 "$BASE/certs"

# Stop an older copy (re-running the payload restarts the service with this version)
if [ -f "$BASE/turtletak.pid" ]; then
    old=$(cat "$BASE/turtletak.pid" 2>/dev/null)
    if [ -n "$old" ] && kill -0 "$old" 2>/dev/null && grep -q turtletak "/proc/$old/cmdline" 2>/dev/null; then
        kill "$old" 2>/dev/null; sleep 2; kill -9 "$old" 2>/dev/null
    fi
fi

# 1.0.0 wrote a note that still mentioned openssl: replace it once
[ -f "$BASE/certs/README.txt" ] && grep -q "converted with openssl" "$BASE/certs/README.txt" && rm -f "$BASE/certs/README.txt"
[ -f "$BASE/certs/README.txt" ] || cat > "$BASE/certs/README.txt" <<'EOF'
TurtleTAK certificates - keep this folder private.

Easiest: copy your ATAK connection package (.zip, with a .pref and .p12 files) here, or upload it
in the web console (Setup). Server, port, protocol and both certificates are imported from it.

Other ways, all in the web console (Setup):
  Certificates   client .p12 + truststore .p12, each with its own password (default atakatak)
  Enroll         your TAK username and password
No openssl needed. client.pem (certificate + key) and ca.pem copied here are used as they are.

wg.conf here (or uploaded in Setup) brings up the Hub's WireGuard client.
EOF

# ---- the service and the web page (written fresh every run) ----------------------------------
cat > "$APP/turtletak.py" <<'TURTLETAK_PY'
#!/usr/bin/env python3
# TurtleTAK Hub Edition - core service (written to /root/turtletak/app/ by payload.sh; started by it).
# Puts the LAN Turtle Hub on TAK as a sensor: position + status SA, GeoChat, facility network watch
# (new devices, ARP spoofing, rogue DHCP, link tamper), an ATAK mesh SA bridge and a web console.
# Standard library only (Python 3.7+). Use only on networks you own or are authorized to monitor.
import base64, binascii, calendar, hashlib, hmac, ipaddress, json, math, os, random, re, select, shutil
import socket, ssl, struct, subprocess, sys, threading, time, traceback, uuid, zipfile, io
import urllib.request, urllib.error, urllib.parse
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import ttcrypto
from http.server import BaseHTTPRequestHandler, HTTPServer
from socketserver import ThreadingMixIn
from xml.sax.saxutils import escape as _xesc

VERSION = "1.0.2"

# ---- DNS: the Hub's C library (musl) can fail a lookup that asks for IPv4 and IPv6 at once
# ("[Errno -5] Name has no usable address") while an IPv4-only lookup works - that is why ping works.
# Fall back to IPv4 only, then IPv6 only, then the system's nslookup. Covers TAK, enrollment and urllib.
_getaddrinfo = socket.getaddrinfo
DNS_CACHE = {}


def _nslookup(host):
    try:
        out = subprocess.run(["nslookup", host], stdout=subprocess.PIPE, stderr=subprocess.DEVNULL,
                             timeout=10).stdout.decode("utf-8", "replace")
    except Exception:
        return []
    ips, after_name = [], False
    for line in out.splitlines():
        if line.strip().lower().startswith("name:"):
            after_name = True
            continue
        m = re.search(r"Address(?:es)?(?:\s+\d+)?:\s*([0-9.]+)\s*$", line)
        if after_name and m:
            ips.append(m.group(1))
    return ips


def _gai(host, port, family=0, type=0, proto=0, flags=0):
    try:
        res = _getaddrinfo(host, port, family, type, proto, flags)
        if host:
            DNS_CACHE[host] = "system"
        return res
    except socket.gaierror as first:
        if not host or family not in (0, socket.AF_UNSPEC):
            raise
        for fam, how in ((socket.AF_INET, "IPv4 only"), (socket.AF_INET6, "IPv6 only")):
            try:
                res = _getaddrinfo(host, port, fam, type, proto, flags)
                DNS_CACHE[host] = how
                return res
            except socket.gaierror:
                pass
        ips = _nslookup(host)
        if ips:
            DNS_CACHE[host] = "nslookup %s" % ips[0]
            return _getaddrinfo(ips[0], port, socket.AF_INET, type, proto, flags | socket.AI_NUMERICHOST)
        DNS_CACHE[host] = "failed: %s" % first
        raise


socket.getaddrinfo = _gai
PRODUCT = "TurtleTAK"
EDITION = "Hub Edition"
BASE = os.environ.get("TT_BASE", "/root/turtletak")
APP = os.path.join(BASE, "app")
CERTS = os.path.join(BASE, "certs")
LOGS = os.path.join(BASE, "logs")
QUEUE = os.path.join(BASE, "queue.jsonl")
BASELINES = os.path.join(BASE, "baselines")
SITES = os.path.join(BASE, "sites.txt")
STATEF = os.path.join(BASE, "state.json")
CFG_FILE = os.path.join(BASE, "default.cfg")
LOOT = os.environ.get("TT_LOOT", "/root/loot/turtletak")
DRY = os.environ.get("TT_DRY_HUB") == "1"          # test mode: log Hub commands instead of running them

# ----------------------------------------------------------------------------------------------
# settings (default.cfg, "KEY: value", one per line; edited in the web console or over SSH)
# ----------------------------------------------------------------------------------------------
DEFAULTS = [
    ("# TAK Server", None),
    ("TAK_HOST", "takserver.example.com"),
    ("TAK_PROTO", "tls"),            # tls (8089, client cert) | tcp (8087/8088) | udp (send only)
    ("TAK_PORT", "8089"),
    ("TAK_VERIFY_HOST", "0"),        # 1 = check the server name against its certificate
    ("CLIENT_PASSWORD", "atakatak"), # client certificate (.p12) password - TAK default atakatak
    ("CA_PASSWORD", "atakatak"),     # truststore / CA (.p12) password - can differ from the client one
    ("API_PORT", "8443"),
    ("ENROLL_PORT", "8446"),
    ("CALLSIGN", "TURTLE-1"),
    ("UID", ""),                     # blank = made once from the device
    ("TEAM", "Cyan"),
    ("ROLE", "Team Member"),
    ("COT_TYPE", "a-f-G-E-S"),       # a-f-G-E-S sensor | a-f-G-I facility | a-f-G-U-C team member (team color) | custom
    ("SA_INTERVAL", "60"),           # seconds between position/status reports
    ("# Location", None),
    ("LOC_MODE", "auto"),            # primary source: auto | radio | gps | atak | site | manual | ip (then the rest, in that order)
    ("SITE", ""),
    ("MANUAL_LAT", ""),
    ("MANUAL_LON", ""),
    ("MY_ATAK", ""),                 # your ATAK callsign, for "anchor to my ATAK"
    ("ANCHOR_MAX_AGE", "1800"),      # seconds your ATAK position stays usable
    ("RADIO_GPS_MAX_AGE", "1800"),   # seconds TurtleMesh's radio GPS fix stays usable
    ("GPS_DEVICE", "auto"),          # auto | /dev/ttyACM0 | /dev/ttyUSB0 | off
    ("GPS_BAUD", "9600"),
    ("GPS_CLAIM_USB", "1"),          # 1 = claim the dynamic USB port for the Hub (GPS / radio)
    ("IPGEO", "1"),
    ("IPGEO_URL", "https://ipinfo.io/json"),
    ("# Network watch (RJ45 side)", None),
    ("WATCH", "1"),
    ("WATCH_IFACE", "auto"),         # auto = the RJ45 interface
    ("WATCH_INTERVAL", "300"),       # seconds between device sweeps
    ("WATCH_MAX_HOSTS", "256"),      # largest sweep (a /24); bigger subnets sweep the Hub's /24
    ("WATCH_RATE", "50"),            # nmap --max-rate when nmap is installed
    ("AUTO_BASELINE", "1"),          # 1 = first sweep of a new network becomes its baseline
    ("ARP_WATCH", "1"),              # gateway MAC changes / duplicate MACs
    ("DHCP_WATCH", "1"),             # rogue DHCP server check
    ("DHCP_INTERVAL", "900"),
    ("DHCP_KNOWN", ""),              # comma list of allowed DHCP server IPs (blank = learn the first)
    ("LINK_WATCH", "1"),             # RJ45 link lost / restored (tamper)
    ("UPLINK_WATCH", "1"),           # TAK link lost for longer than UPLINK_GRACE
    ("UPLINK_GRACE", "120"),
    ("MISSING_AFTER", "2"),          # sweeps a watched device can be absent before "Device missing"
    ("# Alerts", None),
    ("ALERTS_ON", "new_device,missing,arp,dhcp,link,uplink,cert"),  # alert types that are raised
    ("ALERT_MARKER", "1"),           # alert markers on the map
    ("MARKER_MIN_LEVEL", "warning"), # info | warning | critical - lowest level that gets a map marker
    ("ALERT_CHAT", "1"),             # alert line to All Chat Rooms
    ("CHAT_MIN_LEVEL", "info"),      # lowest level that goes to chat
    ("QUIET_HOURS", ""),             # e.g. 22-06: no chat lines or LED flashes then (still logged + marked)
    ("QUIET_CRITICAL", "1"),         # 1 = critical alerts still go out in quiet hours
    ("CERT_WARN_DAYS", "30"),        # warn this many days before the client certificate expires
    ("ALERT_TO", ""),                # blank = everyone, or a callsign for a direct chat instead
    ("ALERT_STALE_HOURS", "12"),
    ("HUB_NOTIFY", "1"),             # Hub web UI notifications (bell icon)
    ("C2_NOTIFY", "0"),              # also Cloud C2 notifications
    ("# Mesh SA bridge", None),
    ("BRIDGE_UP", "0"),              # 1 = forward ATAK mesh SA / chat on the LAN to the TAK Server
    ("BRIDGE_DOWN", "0"),            # 1 = repeat TAK Server traffic onto the LAN mesh
    ("BRIDGE_IFACES", "auto"),       # auto = every IPv4 interface except loopback / VPN, or a comma list
    ("BRIDGE_SA_GROUP", "239.2.3.1:6969"),
    ("BRIDGE_CHAT_GROUP", "224.10.10.1:17012"),
    ("BRIDGE_MIN_GAP", "5"),         # seconds: forward one SA per device at most this often
    ("BRIDGE_DOWN_TYPES", "a-f,a-h,a-n,a-u,b-t-f,b-m"),
    ("# Map", None),
    ("MAP_SOURCE", "usgs_topo"),     # usgs_topo | usgs_imagery | usgs_hybrid | osm (osm: live only, never bulk-saved)
    ("TILE_CACHE_MB", "500"),        # map tile cache limit (on USB storage when one is attached)
    ("TILE_MAX_DOWNLOAD", "20000"),  # most tiles one "Save this area" may fetch
    ("# Uplinks", None),
    ("WIFI_SSID", ""),               # out-of-band Wi-Fi uplink (Hub joins this network as a client)
    ("WIFI_KEY", ""),
    ("WIFI_ENC", "psk2"),            # open | psk | psk2 | sae
    ("WIFI_COUNTRY", "US"),
    ("WG_CONF", ""),                 # path to a wg.conf for the Hub's WireGuard client
    ("# Hub", None),
    ("LED", "1"),                    # 0 = keep the LED dark (stealth)
    ("RUN_AT_BOOT", "1"),
    ("CHAT_COMMANDS", "1"),          # answer "status", "where", "scan", "help" sent to this callsign
    ("CHAT_COMMANDS_FROM", ""),      # blank = anyone on the server, or a comma list of callsigns
    ("CLOCK_SYNC", "1"),             # "Set clock now" reads the time from the TAK Server / web, then NTP
    ("WEB", "1"),
    ("WEB_PORT", "8484"),
    ("WEB_BIND", "0.0.0.0"),         # every interface: USB-C host, RJ45, Wi-Fi, VPN
    ("WEB_TLS", "0"),
    ("WEB_PASS_HASH", ""),
]
CFG = {}
CFG_LOCK = threading.Lock()


def cfg_load():
    vals = {k: v for k, v in DEFAULTS if v is not None}
    if os.path.exists(CFG_FILE):
        for line in open(CFG_FILE, encoding="utf-8", errors="replace"):
            if ":" in line and not line.lstrip().startswith("#"):
                k, v = line.split(":", 1)
                vals[k.strip()] = v.strip()
    with CFG_LOCK:
        CFG.clear()
        CFG.update(vals)
    cfg_write()


def cfg_write():
    out = ["# TurtleTAK %s settings - KEY: value. Changed in the web console or over SSH." % EDITION]
    known = set()
    with CFG_LOCK:
        for k, v in DEFAULTS:
            if v is None:
                out.append("")
                out.append(k)
            else:
                out.append("%s: %s" % (k, CFG.get(k, v)))
                known.add(k)
        extra = [k for k in CFG if k not in known]
        if extra:
            out.append("")
            out.append("# Other")
            out += ["%s: %s" % (k, CFG[k]) for k in extra]
    tmp = "%s.%d.%d.tmp" % (CFG_FILE, os.getpid(), threading.get_ident())
    fd = os.open(tmp, os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o600)
    with os.fdopen(fd, "w") as fh:
        fh.write("\n".join(out) + "\n")
    os.replace(tmp, CFG_FILE)


def cfg(k, default=""):
    with CFG_LOCK:
        return CFG.get(k, default)


def cfgi(k, default=0):
    try:
        return int(float(cfg(k, default)))
    except (TypeError, ValueError):
        return default


def cfgb(k):
    return cfg(k, "0").strip().lower() in ("1", "yes", "true", "on")


def cfg_set(changes):
    with CFG_LOCK:
        for k, v in changes.items():
            CFG[k] = str(v).replace("\n", " ").strip()
    cfg_write()


# ----------------------------------------------------------------------------------------------
# logging, events, Hub commands
# ----------------------------------------------------------------------------------------------
LOGQ = []
LOG_LOCK = threading.Lock()


def log(msg, level="info"):
    line = "%s [%s] %s" % (time.strftime("%Y-%m-%d %H:%M:%S"), level, msg)
    with LOG_LOCK:
        LOGQ.append(line)
        del LOGQ[:-400]
        try:
            with open(os.path.join(LOGS, "turtletak.log"), "a") as fh:
                fh.write(line + "\n")
            p = os.path.join(LOGS, "turtletak.log")
            if os.path.getsize(p) > 512 * 1024:
                os.replace(p, p + ".1")
        except OSError:
            pass
    print(line, flush=True)


HUB_LOCK = threading.Lock()


def hub(*args, timeout=20):
    """Run a Hak5 DuckyScript command (LED, NOTIFY_INFO, C2NOTIFY...). payload.sh exports them to
    child shells, so they work whether the firmware ships them as programs or Bash functions."""
    cmd = " ".join(sh_quote(str(a)) for a in args)
    if DRY:
        log("hub> " + cmd, "debug")
        return 0, ""
    try:
        with HUB_LOCK:
            p = subprocess.run(["bash", "-c", cmd], stdout=subprocess.PIPE, stderr=subprocess.STDOUT,
                               timeout=timeout)
        return p.returncode, p.stdout.decode("utf-8", "replace").strip()
    except Exception as e:
        return 1, str(e)


def sh_quote(s):
    if re.match(r"^[A-Za-z0-9_./:@,+=-]+$", s):
        return s
    return "'" + s.replace("'", "'\\''") + "'"


def run(cmd, timeout=10):
    try:
        p = subprocess.run(cmd, stdout=subprocess.PIPE, stderr=subprocess.DEVNULL, timeout=timeout)
        return p.stdout.decode("utf-8", "replace")
    except Exception:
        return ""


def have(prog):
    return shutil.which(prog) is not None


LED_STATE = {"base": "SETUP", "until": 0, "shown": None}


def led(state=None, flash=None, secs=30):
    """state = steady LED for the current link state; flash = temporary state (alerts)."""
    if state:
        LED_STATE["base"] = state
    if flash:
        LED_STATE["flash"] = flash
        LED_STATE["until"] = time.time() + secs
    want = LED_STATE["base"]
    if time.time() < LED_STATE.get("until", 0):
        want = LED_STATE.get("flash", want)
    if not cfgb("LED"):
        want = "OFF"
    if want != LED_STATE["shown"]:
        LED_STATE["shown"] = want
        hub("LED", *want.split())


def notify(level, msg):
    if cfgb("HUB_NOTIFY"):
        hub({"info": "NOTIFY_INFO", "warning": "NOTIFY_WARNING", "error": "NOTIFY_ERROR"}[level], "TurtleTAK", msg)
    if cfgb("C2_NOTIFY"):
        hub("C2NOTIFY", {"info": "INFO", "warning": "WARNING", "error": "ERROR"}[level], "TurtleTAK: " + msg)


# ----------------------------------------------------------------------------------------------
# shared state
# ----------------------------------------------------------------------------------------------
S = {
    "started": time.time(),
    "tak": {"state": "starting", "since": time.time(), "error": "", "tx": 0, "rx": 0, "last_rx": 0},
    "pos": {"lat": None, "lon": None, "ce": 9999999, "hae": 0, "src": "none", "time": 0},
    "gps": {"device": "", "fix": False, "sats": 0, "time": 0, "lat": None, "lon": None},
    "contacts": {},       # uid -> {callsign, lat, lon, type, team, time, how}
    "chat": [],           # {time, dir, from, to, room, text, id}
    "alerts": [],         # {id, time, kind, level, title, detail, sent}
    "net": {},            # network watch status
    "hosts": {},          # mac -> {ip, first, last, known, vendor}
    "bridge": {"up_rx": 0, "up_tx": 0, "down_tx": 0, "devices": {}, "ifaces": [], "error": ""},
    "status": {},
    "unread": 0,          # chat messages in since the Chat tab was last open
    "clock": "",
}
SL = threading.RLock()


def save_state():
    try:
        with SL:
            keep = {"pos": S["pos"], "alerts": S["alerts"][-200:], "chat": S["chat"][-300:], "unread": S["unread"],
                    "dhcp_known": S["net"].get("dhcp_known", [])}
        tmp = "%s.%d.%d.tmp" % (STATEF, os.getpid(), threading.get_ident())
        with open(tmp, "w") as fh:
            json.dump(keep, fh)
        os.replace(tmp, STATEF)
    except Exception as e:
        log("state save failed: %s" % e, "warning")


def load_state():
    try:
        d = json.load(open(STATEF))
        with SL:
            if d.get("pos", {}).get("lat") is not None:
                S["pos"] = d["pos"]
                S["pos"]["src"] = "last known"
            S["alerts"] = d.get("alerts", [])
            S["chat"] = d.get("chat", [])
            S["unread"] = int(d.get("unread", 0))
            S["net"]["dhcp_known"] = d.get("dhcp_known", [])
    except Exception:
        pass


# ----------------------------------------------------------------------------------------------
# CoT helpers
# ----------------------------------------------------------------------------------------------
def x(v):
    return _xesc(str(v), {'"': "&quot;"})


def iso(t=None):
    t = time.time() if t is None else t
    return time.strftime("%Y-%m-%dT%H:%M:%S", time.gmtime(t)) + ".%03dZ" % int((t % 1) * 1000)


def my_uid():
    u = cfg("UID")
    if not u:
        mac = ""
        for n in sorted(os.listdir("/sys/class/net")) if os.path.isdir("/sys/class/net") else []:
            try:
                m = open("/sys/class/net/%s/address" % n).read().strip()
                if m and m != "00:00:00:00:00:00":
                    mac = m
                    break
            except OSError:
                pass
        u = "TurtleTAK-" + (mac.replace(":", "")[-8:] if mac else uuid.uuid4().hex[:8])
        cfg_set({"UID": u})
    return u


def point_xml(lat, lon, ce=9999999, hae=0):
    if lat is None:
        lat, lon, ce = 0.0, 0.0, 9999999
    return '<point lat="%.7f" lon="%.7f" hae="%s" ce="%s" le="9999999"/>' % (lat, lon, hae or 0, int(ce))


def ev_open(uid, ctype, stale_s, how="h-e", t=None):
    t = time.time() if t is None else t
    return '<event version="2.0" uid="%s" type="%s" how="%s" time="%s" start="%s" stale="%s">' % (
        x(uid), x(ctype), how, iso(t), iso(t), iso(t + stale_s))


def sa_event():
    p = S["pos"]
    st = S["status"]
    uid = my_uid()
    remarks = status_text()
    interval = max(15, cfgi("SA_INTERVAL", 60))
    return (ev_open(uid, cfg("COT_TYPE", "a-f-G-E-S"), interval * 3 + 30, "m-g" if p["src"] in ("gps", "radio") else "h-e")
            + point_xml(p["lat"], p["lon"], p["ce"], p.get("hae", 0))
            + "<detail>"
            + '<contact callsign="%s" endpoint="*:-1:stcp"/>' % x(cfg("CALLSIGN"))
            + '<__group name="%s" role="%s"/>' % (x(team_name(cfg("TEAM"))), x(cfg("ROLE")))
            + '<takv device="LAN Turtle Hub" platform="%s" os="%s" version="%s"/>' % (
                PRODUCT, x(st.get("os", "Linux")), VERSION)
            + '<precisionlocation geopointsrc="%s" altsrc="???"/>' % ("GPS" if p["src"] in ("gps", "radio") else "USER")
            + '<uid Droid="%s"/>' % x(cfg("CALLSIGN"))
            + "<remarks>%s</remarks>" % x(remarks)
            + "</detail></event>")


def chat_event(text, to_cs=None, to_uid=None):
    uid = my_uid()
    cs = cfg("CALLSIGN")
    mid = str(uuid.uuid4())
    if to_uid:
        room, rid = to_cs, to_uid
    else:
        room, rid = "All Chat Rooms", "All Chat Rooms"
    p = S["pos"]
    dest = '<marti><dest callsign="%s"/></marti>' % x(to_cs) if to_uid else ""
    return (ev_open("GeoChat.%s.%s.%s" % (uid, rid, mid), "b-t-f", 86400, "h-g-i-g-o")
            + point_xml(p["lat"], p["lon"], p["ce"])
            + "<detail>"
            + '<__chat parent="RootContactGroup" groupOwner="false" messageId="%s" chatroom="%s" id="%s" senderCallsign="%s">'
            % (mid, x(room), x(rid), x(cs))
            + '<chatgrp uid0="%s" uid1="%s" id="%s"/></__chat>' % (x(uid), x(rid), x(rid))
            + '<link uid="%s" type="%s" relation="p-p"/>' % (x(uid), x(cfg("COT_TYPE")))
            + '<remarks source="BAO.F.ATAK.%s" to="%s" time="%s">%s</remarks>' % (x(uid), x(rid), iso(), x(text))
            + dest + "</detail></event>"), mid, room


def marker_event(uid, ctype, title, remarks, lat, lon, ce, stale_s):
    return (ev_open(uid, ctype, stale_s, "h-e") + point_xml(lat, lon, ce)
            + "<detail>"
            + '<contact callsign="%s"/>' % x(title)
            + '<link uid="%s" production_time="%s" type="%s" parent_callsign="%s" relation="p-p"/>'
            % (x(my_uid()), iso(), x(cfg("COT_TYPE")), x(cfg("CALLSIGN")))
            + '<archive/><usericon iconsetpath="COT_MAPPING_2525B/%s/%s"/>' % (ctype[:3], ctype)
            + "<remarks>%s</remarks></detail></event>" % x(remarks))


ATTR_RE = re.compile(r'([A-Za-z_:][-\w:.]*)\s*=\s*"([^"]*)"|([A-Za-z_:][-\w:.]*)\s*=\s*\'([^\']*)\'')


def attrs(tag):
    out = {}
    for m in ATTR_RE.finditer(tag):
        if m.group(1):
            out[m.group(1)] = xml_unesc(m.group(2))
        else:
            out[m.group(3)] = xml_unesc(m.group(4))
    return out


def xml_unesc(v):
    return (v.replace("&lt;", "<").replace("&gt;", ">").replace("&quot;", '"').replace("&apos;", "'")
            .replace("&#10;", "\n").replace("&amp;", "&"))


def tag(ev, name):
    m = re.search(r"<%s\b([^>]*?)/?>" % re.escape(name), ev)
    return attrs(m.group(1)) if m else None


def parse_time(s):
    try:
        base, _, frac = s.rstrip("Z").partition(".")
        return calendar.timegm(time.strptime(base, "%Y-%m-%dT%H:%M:%S")) + float("0." + (re.sub(r"\D", "", frac) or "0"))
    except Exception:
        return time.time()


# ----------------------------------------------------------------------------------------------
# TAK protocol v1 (protobuf) - mesh SA from ATAK; tiny decoder, no library needed
# ----------------------------------------------------------------------------------------------
def pb_fields(buf):
    i, n = 0, len(buf)
    while i < n:
        key, i = pb_varint(buf, i)
        f, wt = key >> 3, key & 7
        if wt == 0:
            v, i = pb_varint(buf, i)
        elif wt == 1:
            v = buf[i:i + 8]; i += 8
        elif wt == 2:
            ln, i = pb_varint(buf, i)
            v = buf[i:i + ln]; i += ln
        elif wt == 5:
            v = buf[i:i + 4]; i += 4
        else:
            raise ValueError("wire type %d" % wt)
        yield f, wt, v


def pb_varint(buf, i):
    r = s = 0
    while True:
        b = buf[i]; i += 1
        r |= (b & 0x7F) << s
        s += 7
        if not b & 0x80:
            return r, i


def tak_proto_to_xml(data):
    """TAK protocol v1 mesh packet (0xbf 0x01 0xbf + TakMessage) -> CoT XML string."""
    if len(data) < 4 or data[0] != 0xBF or data[2] != 0xBF:
        return None
    ev = None
    for f, wt, v in pb_fields(data[3:]):
        if f == 2 and wt == 2:
            ev = v
    if ev is None:
        return None
    e = {}
    detail = b""
    for f, wt, v in pb_fields(ev):
        if wt == 2 and f in (1, 2, 3, 4, 5, 9):
            e[f] = v.decode("utf-8", "replace")
        elif wt == 0 and f in (6, 7, 8):
            e[f] = v
        elif wt == 1 and f in (10, 11, 12, 13, 14):
            e[f] = struct.unpack("<d", v)[0]
        elif f == 15 and wt == 2:
            detail = v
    d = []
    for f, wt, v in pb_fields(detail):
        if wt != 2:
            continue
        sub = {ff: vv for ff, ww, vv in pb_fields(v)} if f != 1 else {}
        s = lambda k: x(sub.get(k, b"").decode("utf-8", "replace")) if isinstance(sub.get(k, b""), bytes) else ""
        if f == 1:
            d.append(v.decode("utf-8", "replace"))
        elif f == 2:
            d.append('<contact endpoint="%s" callsign="%s"/>' % (s(1), s(2)))
        elif f == 3:
            d.append('<__group name="%s" role="%s"/>' % (s(1), s(2)))
        elif f == 4:
            d.append('<precisionlocation geopointsrc="%s" altsrc="%s"/>' % (s(1), s(2)))
        elif f == 5:
            d.append('<status battery="%s"/>' % sub.get(1, 0))
        elif f == 6:
            d.append('<takv device="%s" platform="%s" os="%s" version="%s"/>' % (s(1), s(2), s(3), s(4)))
        elif f == 7:
            sp = struct.unpack("<d", sub[1])[0] if isinstance(sub.get(1), bytes) and len(sub[1]) == 8 else 0
            co = struct.unpack("<d", sub[2])[0] if isinstance(sub.get(2), bytes) and len(sub[2]) == 8 else 0
            d.append('<track speed="%s" course="%s"/>' % (sp, co))
    ms = lambda k: iso(e.get(k, int(time.time() * 1000)) / 1000.0)
    return ('<event version="2.0" uid="%s" type="%s" how="%s" time="%s" start="%s" stale="%s">'
            % (x(e.get(5, "")), x(e.get(1, "a-u-G")), x(e.get(9, "m-g")), ms(6), ms(7), ms(8))
            + '<point lat="%s" lon="%s" hae="%s" ce="%s" le="%s"/>'
            % (e.get(10, 0.0), e.get(11, 0.0), e.get(12, 9999999.0), e.get(13, 9999999.0), e.get(14, 9999999.0))
            + "<detail>%s</detail></event>" % "".join(d))


# ----------------------------------------------------------------------------------------------
# certificates: ATAK connection package (.zip), .p12 files, PEM files, enrollment
# ----------------------------------------------------------------------------------------------
def write_secret(path, text):
    fd = os.open(path, os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o600)
    with os.fdopen(fd, "w") as fh:
        fh.write(text)


def b64_cert(v):
    """Server/file value -> clean base64 DER of one certificate (strips PEM headers, whitespace, escapes)."""
    v = re.sub(r"-----[A-Z0-9 ]+-----", "", str(v)).replace("\\n", "").replace("\\r", "")
    v = re.sub(r"[^A-Za-z0-9+/=]", "", v)
    der = base64.b64decode(v + "=" * (-len(v) % 4))
    if not der or der[0] != 0x30:
        raise ValueError("not a certificate")
    return base64.b64encode(der).decode()


def cert_pem(v):
    b = b64_cert(v)
    return "-----BEGIN CERTIFICATE-----\n%s\n-----END CERTIFICATE-----\n" % "\n".join(b[i:i + 64] for i in range(0, len(b), 64))


def pem_summary(path):
    """What is in a PEM file, without showing it: e.g. 'CERTIFICATE x1, RSA PRIVATE KEY x1'."""
    try:
        text = open(path, errors="replace").read()
    except OSError:
        return "missing"
    kinds = re.findall(r"-----BEGIN ([A-Z0-9 ]+)-----", text)
    if not kinds:
        return "no PEM blocks (%d bytes)" % len(text)
    out = []
    for k in sorted(set(kinds)):
        out.append("%s x%d" % (k, kinds.count(k)))
    if text.count("-----BEGIN") != text.count("-----END"):
        out.append("UNBALANCED begin/end")
    return ", ".join(out)


def save_cert_files(client=None, ca=None, why=""):
    """Check new client / CA PEM text loads in TLS before using it; keep the old files in certs/backup/."""
    tmp = {}
    try:
        for kind, text in (("client", client), ("ca", ca)):
            if text is None:
                continue
            t = os.path.join(CERTS, ".new-%s.pem" % kind)
            write_secret(t, text)
            tmp[kind] = t
        ctx = ssl.SSLContext(ssl.PROTOCOL_TLS_CLIENT)
        if "client" in tmp:
            try:
                ctx.load_cert_chain(tmp["client"])
            except (ssl.SSLError, OSError) as e:
                raise RuntimeError("the new client certificate does not load (%s; %s) - your old certificates are unchanged"
                                   % (e, pem_summary(tmp["client"])))
        if "ca" in tmp:
            try:
                ctx.load_verify_locations(tmp["ca"])
            except (ssl.SSLError, OSError) as e:
                raise RuntimeError("the new truststore does not load (%s; %s) - your old certificates are unchanged"
                                   % (e, pem_summary(tmp["ca"])))
        stamp = time.strftime("%Y%m%d-%H%M%S")
        for kind, t in tmp.items():
            cur = os.path.join(CERTS, kind + ".pem")
            if os.path.exists(cur):
                bdir = os.path.join(CERTS, "backup", stamp)
                os.makedirs(bdir, exist_ok=True)
                os.replace(cur, os.path.join(bdir, kind + ".pem"))
            os.replace(t, cur)
        if tmp:
            log("certificates updated (%s)%s" % (", ".join(sorted(tmp)), (" - " + why) if why else ""))
            threading.Thread(target=cert_check, daemon=True).start()
    finally:
        for t in tmp.values():
            if os.path.exists(t):
                os.unlink(t)


def restore_certs():
    bdir = os.path.join(CERTS, "backup")
    snaps = sorted(os.listdir(bdir)) if os.path.isdir(bdir) else []
    if not snaps:
        raise RuntimeError("no earlier certificates saved")
    last = os.path.join(bdir, snaps[-1])
    for kind in ("client", "ca"):
        f = os.path.join(last, kind + ".pem")
        if os.path.exists(f):
            os.replace(f, os.path.join(CERTS, kind + ".pem"))
    shutil.rmtree(last, ignore_errors=True)
    TAK.reconnect()
    return "restored the certificates from %s" % snaps[-1]


def p12_to_pem(p12, out, passwords, nokeys=False):
    """Convert a .p12 to PEM with the built-in reader (no openssl needed); openssl is only a fallback.
    passwords: one password or a list to try in order. Client: out gets leaf cert + key (+ CA certs go
    to ca.pem if there is none). CA: out gets every certificate."""
    if isinstance(passwords, str):
        passwords = [passwords]
    tried, errors = [], []
    data = open(p12, "rb").read()
    for pw in passwords:
        if pw is None or pw in tried:
            continue
        tried.append(pw)
        try:
            key, certs = ttcrypto.read_p12(data, pw)
        except ValueError as e:
            errors.append(str(e))
            if "wrong password" in str(e) or "padding" in str(e):
                continue
            break                                  # unsupported format: try openssl below
        kind_out = "ca" if os.path.basename(out).startswith("ca") else "client"
        if nokeys:
            if not certs:
                raise RuntimeError("%s has no certificates" % os.path.basename(p12))
            save_cert_files(**{kind_out: "".join(certs)}, why=os.path.basename(p12))
            return pw
        if not key:
            raise RuntimeError("%s has no private key - is it the truststore instead of the client cert?" % os.path.basename(p12))
        leaf, rest = ttcrypto.split_chain(key, certs)
        if not leaf:
            raise RuntimeError("%s: no certificate matches its private key" % os.path.basename(p12))
        ca = os.path.join(os.path.dirname(out), "ca.pem")
        save_cert_files(client=leaf + key, ca=("".join(rest) if rest and not os.path.exists(ca) else None),
                        why=os.path.basename(p12))
        return pw
    if have("openssl") and errors and not any("wrong password" in e for e in errors):
        for pw in tried:
            for legacy in (["-legacy"], []):
                p = subprocess.run(["openssl", "pkcs12"] + legacy + ["-in", p12, "-out", out, "-passin", "pass:" + pw]
                                   + (["-nokeys"] if nokeys else ["-nodes"]), stdout=subprocess.PIPE, stderr=subprocess.PIPE, timeout=30)
                if p.returncode == 0 and os.path.getsize(out) > 0:
                    os.chmod(out, 0o600)
                    return pw
    if any("wrong password" in e or "padding" in e for e in errors):
        raise RuntimeError("wrong password for %s - type its password in Setup (client and truststore passwords are separate)"
                           % os.path.basename(p12))
    raise RuntimeError("could not read %s: %s" % (os.path.basename(p12), "; ".join(errors) or "unknown format"))


def pref(xmltext, key):
    m = re.search(r'<entry[^>]*key="%s"[^>]*>([^<]*)</entry>' % re.escape(key), xmltext)
    return xml_unesc(m.group(1).strip()) if m else ""


def import_package(path, client_pw=None, ca_pw=None):
    """ATAK connection data package -> server settings + certs/client.pem + certs/ca.pem."""
    z = zipfile.ZipFile(path)
    names = z.namelist()
    prefs = [n for n in names if n.lower().endswith(".pref")]
    if not prefs:
        raise RuntimeError("no .pref file in %s - is it an ATAK connection package?" % os.path.basename(path))
    text = "\n".join(z.read(n).decode("utf-8", "replace") for n in prefs)
    conn = pref(text, "connectString0")
    parts = conn.split(":")
    if len(parts) < 2:
        raise RuntimeError("no TAK Server (connectString0) in the package")
    changes = {"TAK_HOST": parts[0], "TAK_PORT": parts[1],
               "TAK_PROTO": {"ssl": "tls", "tcp": "tcp", "udp": "udp"}.get((parts[2] if len(parts) > 2 else "ssl").lower(), "tls")}
    by_base = {os.path.basename(n): n for n in names if n.lower().endswith(".p12")}
    for kind, key, pwkey in (("client", "certificateLocation", "clientPassword"), ("ca", "caLocation", "caPassword")):
        base = os.path.basename(pref(text, key))
        src = by_base.get(base)
        if not src:
            continue
        tmp = os.path.join(CERTS, ".%s.p12" % kind)
        with open(tmp, "wb") as fh:
            fh.write(z.read(src))
        try:
            typed = client_pw if kind == "client" else ca_pw
            setting = "CLIENT_PASSWORD" if kind == "client" else "CA_PASSWORD"
            used = p12_to_pem(tmp, os.path.join(CERTS, kind + ".pem"),
                              [typed, pref(text, pwkey), cfg(setting), "atakatak"], nokeys=(kind == "ca"))
            changes[setting] = used
        finally:
            os.unlink(tmp)
    cfg_set(changes)
    log("imported connection package %s -> %s:%s (%s)" % (os.path.basename(path), changes["TAK_HOST"],
                                                         changes["TAK_PORT"], changes["TAK_PROTO"]))
    done = os.path.join(CERTS, "imported")
    os.makedirs(done, exist_ok=True)
    os.replace(path, os.path.join(done, os.path.basename(path)))
    return changes


def cert_kind(name):
    return "ca" if re.search(r"trust|(^|[^a-z])ca([^a-z]|$)|root", name, re.I) else "client"


def scan_certs():
    """Pick up a connection package or .p12 files dropped in certs/."""
    try:
        for n in sorted(os.listdir(CERTS)):
            p = os.path.join(CERTS, n)
            if n.lower().endswith(".zip"):
                try:
                    import_package(p)
                    notify("info", "Imported TAK connection package %s" % n)
                    TAK.reconnect()
                except Exception as e:
                    log("package %s: %s" % (n, e), "error")
                    notify("error", "Connection package %s: %s" % (n, e))
                    os.replace(p, p + ".failed")
            elif n.lower().endswith(".p12"):
                kind = cert_kind(n)
                try:
                    p12_to_pem(p, os.path.join(CERTS, kind + ".pem"),
                               [cfg("CLIENT_PASSWORD" if kind == "client" else "CA_PASSWORD"), "atakatak"], nokeys=(kind == "ca"))
                    os.makedirs(os.path.join(CERTS, "imported"), exist_ok=True)
                    os.replace(p, os.path.join(CERTS, "imported", n))
                    log("converted %s -> %s.pem" % (n, kind))
                    TAK.reconnect()
                except Exception as e:
                    log(str(e), "error")
                    os.replace(p, p + ".failed")
    except FileNotFoundError:
        pass


def enroll(user, password):
    """TAK Server certificate enrollment (port 8446). Key and CSR are made in Python - no openssl needed."""
    if not user or not password:
        raise RuntimeError("enter your TAK Server username and password")
    host, port = cfg("TAK_HOST"), cfgi("ENROLL_PORT", 8446)
    ctx = ssl.create_default_context()
    ctx.check_hostname = False
    ctx.verify_mode = ssl.CERT_NONE
    auth = "Basic " + base64.b64encode(("%s:%s" % (user, password)).encode()).decode()

    def call(path, body=None, ctype="text/plain"):
        req = urllib.request.Request("https://%s:%d%s" % (host, port, path), data=body,
                                     headers={"Authorization": auth, "Content-Type": ctype, "Accept": "application/json"})
        try:
            with urllib.request.urlopen(req, context=ctx, timeout=60) as r:
                return r.read().decode("utf-8", "replace")
        except urllib.error.HTTPError as e:
            if e.code == 401:
                raise RuntimeError("the TAK Server rejected that username or password")
            raise RuntimeError("enrollment %s failed: HTTP %d" % (path.split("?")[0], e.code))
        except (urllib.error.URLError, OSError) as e:
            raise RuntimeError("cannot reach %s:%d for enrollment: %s" % (host, port, getattr(e, "reason", e)))

    conf = call("/Marti/api/tls/config")
    names = dict(re.findall(r'<nameEntry[^>]*name="([^"]+)"[^>]*value="([^"]*)"', conf))
    subject = [(k, v) for k, v in names.items() if k.upper() != "CN"] + [("CN", user)]
    log("enrollment: making a 2048-bit key (can take up to a minute on the Hub)")
    key = ttcrypto.rsa_generate(2048)
    csr = ttcrypto.pem("CERTIFICATE REQUEST", ttcrypto.csr_der(key, subject))
    body = "".join(l for l in csr.splitlines(True) if "CERTIFICATE REQUEST" not in l)
    raw = call("/Marti/api/tls/signClient/v2?clientUid=%s&version=%s" % (my_uid(), VERSION), body.encode())
    try:
        resp = json.loads(raw)
    except ValueError:   # some servers answer in XML
        resp = {m[0]: m[1] for m in re.findall(r"<(signedCert|ca\d*)>\s*([^<]+?)\s*</\1>", raw)}
        if "ca" in resp:
            resp["ca0"] = resp.pop("ca")
    log("enrollment reply fields: %s" % ", ".join("%s(%d)" % (k, len(str(v))) for k, v in sorted(resp.items())))
    if "signedCert" not in resp:
        raise RuntimeError("the TAK Server did not return a certificate (fields: %s)" % ", ".join(sorted(resp)))
    try:
        client_text = cert_pem(resp["signedCert"]) + ttcrypto.rsa_key_pem(key)
    except ValueError as e:
        raise RuntimeError("the certificate the TAK Server sent could not be read (%s) - your old certificates are unchanged" % e)
    cas = []
    for k, v in sorted(resp.items()):
        if re.match(r"^ca\d*$", k):
            try:
                cas.append(cert_pem(v))
            except ValueError:
                log("enrollment: skipped %s (not a certificate)" % k, "warning")
    save_cert_files(client=client_text, ca=("".join(cas) if cas else None), why="enrollment")
    cfg_set({"TAK_PROTO": "tls"})
    log("enrolled with %s:%d" % (host, port))
    TAK.reconnect()


# ----------------------------------------------------------------------------------------------
# TAK Server link
# ----------------------------------------------------------------------------------------------
class TakLink:
    def __init__(self):
        self.sock = None
        self.lock = threading.Lock()
        self.kick = threading.Event()
        self.down_since = time.time()
        self.alerted_down = False
        self.recent_down = {}          # uid -> time, events we repeated onto the mesh (loop guard)

    def connected(self):
        return self.sock is not None

    def reconnect(self):
        with self.lock:
            self._close()
        self.kick.set()

    def _close(self):
        if self.sock:
            try:
                self.sock.close()
            except OSError:
                pass
        self.sock = None

    def set_state(self, st, err=""):
        with SL:
            if (S["tak"]["state"] == "connected") != (st == "connected"):
                S["tak"]["since"] = time.time()
            S["tak"]["state"] = st
            S["tak"]["error"] = err

    def open(self):
        host, port, proto = cfg("TAK_HOST"), cfgi("TAK_PORT", 8089), cfg("TAK_PROTO", "tls").lower()
        if not host or host.endswith("example.com"):
            raise RuntimeError("set TAK_HOST (Settings, or drop a connection package in certs/)")
        if proto == "udp":
            s = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
            s.connect((host, port))
            return s
        raw = socket.create_connection((host, port), timeout=15)
        if proto != "tls":
            raw.settimeout(None)
            return raw
        client = os.path.join(CERTS, "client.pem")
        ca = os.path.join(CERTS, "ca.pem")
        if not os.path.exists(client):
            raw.close()
            raise RuntimeError("no client certificate - drop an ATAK connection package (.zip) in %s, or enroll" % CERTS)
        ctx = ssl.SSLContext(ssl.PROTOCOL_TLS_CLIENT)
        keyf = os.path.join(CERTS, "client.key")
        ctx.load_cert_chain(client, keyf if os.path.exists(keyf) else None)
        if os.path.exists(ca):
            ctx.load_verify_locations(ca)
            ctx.check_hostname = cfgb("TAK_VERIFY_HOST")
            ctx.verify_mode = ssl.CERT_REQUIRED
        else:
            ctx.check_hostname = False
            ctx.verify_mode = ssl.CERT_NONE
            log("no ca.pem - the server certificate is not checked", "warning")
        s = ctx.wrap_socket(raw, server_hostname=host)
        s.settimeout(None)
        return s

    def send(self, xml, queue=False):
        data = xml.encode("utf-8")
        with self.lock:
            if self.sock:
                try:
                    self.sock.sendall(data)
                    with SL:
                        S["tak"]["tx"] += 1
                    return True
                except OSError as e:
                    log("TAK send failed: %s" % e, "warning")
                    self._close()
                    self.kick.set()
        if queue:
            with open(QUEUE, "a") as fh:
                fh.write(json.dumps({"t": time.time(), "xml": xml}) + "\n")
        return False

    def flush_queue(self):
        if not os.path.exists(QUEUE):
            return
        lines = open(QUEUE).read().splitlines()
        os.unlink(QUEUE)
        sent = 0
        for i, l in enumerate(lines):
            try:
                xml = json.loads(l)["xml"]
            except Exception:
                continue
            if not self.send(xml):
                with open(QUEUE, "a") as fh:
                    fh.write("\n".join(lines[i:]) + "\n")
                break
            sent += 1
        if sent:
            log("sent %d queued message(s)" % sent)

    def run(self):
        backoff = 5
        while True:
            self.kick.clear()
            try:
                self.set_state("connecting")
                led("Y DOUBLE")
                s = self.open()
                with self.lock:
                    self.sock = s
                self.set_state("connected")
                led("G SINGLE")
                log("TAK connected to %s:%s (%s)" % (cfg("TAK_HOST"), cfg("TAK_PORT"), cfg("TAK_PROTO")))
                if self.alerted_down:
                    raise_alert("uplink", "info", "TAK link restored",
                                "Back on the TAK Server after %s." % dur(time.time() - self.down_since), marker=False)
                self.alerted_down = False
                backoff = 5
                self.send(sa_event())
                self.flush_queue()
                if cfg("TAK_PROTO") == "udp":
                    while not self.kick.wait(30):
                        pass
                else:
                    self.read_loop(s)
            except Exception as e:
                err = str(e) or e.__class__.__name__
                self.set_state("down", err)
                if S["tak"]["error"] != getattr(self, "_last_err", None):
                    log("TAK: %s" % err, "warning")
                self._last_err = err
            with self.lock:
                self._close()
            if S["tak"]["state"] == "connected":
                self.set_state("down", "disconnected")
            led("FAIL" if "certificate" in S["tak"]["error"] or "TAK_HOST" in S["tak"]["error"] else "Y DOUBLE")
            self.kick.wait(backoff)
            backoff = min(backoff * 2, 60)

    def read_loop(self, s):
        buf = b""
        while True:
            try:
                chunk = s.recv(65536)
            except OSError as e:
                raise RuntimeError("read: %s" % e)
            if not chunk:
                raise RuntimeError("server closed the connection")
            buf += chunk
            if len(buf) > 2 * 1024 * 1024:
                buf = buf[-65536:]
            while b"</event>" in buf:
                ev, buf = buf.split(b"</event>", 1)
                start = ev.find(b"<event")
                if start < 0:
                    continue
                handle_event((ev[start:] + b"</event>").decode("utf-8", "replace"), source="server")

    def watchdog(self):
        """Raise an alert when the TAK link has been down longer than UPLINK_GRACE."""
        while True:
            time.sleep(10)
            if not cfgb("UPLINK_WATCH") or self.connected() or self.alerted_down:
                continue
            if S["tak"]["state"] in ("down", "connecting") and time.time() - S["tak"]["since"] > cfgi("UPLINK_GRACE", 120):
                if S["tak"]["error"].startswith("set TAK_HOST") or "certificate" in S["tak"]["error"]:
                    continue
                self.alerted_down = True
                self.down_since = S["tak"]["since"]
                raise_alert("uplink", "warning", "TAK link down",
                            "No TAK Server for %s: %s" % (dur(time.time() - S["tak"]["since"]), S["tak"]["error"]),
                            marker=False)


TAK = TakLink()


def handle_event(ev, source="server"):
    uid = (re.search(r'<event[^>]*\suid="([^"]*)"', ev) or [None, ""])[1]
    ctype = (re.search(r'<event[^>]*\stype="([^"]*)"', ev) or [None, ""])[1]
    if not uid or uid == my_uid():
        return
    with SL:
        S["tak"]["rx"] += 1
        S["tak"]["last_rx"] = time.time()
    if source == "server" and cfgb("BRIDGE_DOWN"):
        BRIDGE.down(ev, uid, ctype)
    if ctype.startswith("b-t-f"):
        chat_in(ev, ctype)
        return
    if ctype.startswith("t-x"):
        return
    pt = tag(ev, "point") or {}
    contact = tag(ev, "contact") or {}
    if not contact.get("callsign"):
        return
    try:
        lat, lon = float(pt.get("lat", 0)), float(pt.get("lon", 0))
    except ValueError:
        return
    grp = tag(ev, "__group") or {}
    stale = (re.search(r'<event[^>]*\sstale="([^"]*)"', ev) or [None, ""])[1]
    with SL:
        S["contacts"][uid] = {"callsign": contact["callsign"], "lat": lat, "lon": lon,
                              "ce": float(pt.get("ce", 9999999) or 9999999), "type": ctype, "team": grp.get("name", ""),
                              "role": grp.get("role", ""), "time": time.time(), "stale": parse_time(stale) if stale else 0,
                              "source": source, "endpoint": contact.get("endpoint", "")}
        if len(S["contacts"]) > 2000:
            for k in sorted(S["contacts"], key=lambda k: S["contacts"][k]["time"])[:200]:
                del S["contacts"][k]


def chat_in(ev, ctype):
    if ctype != "b-t-f":
        return
    c = tag(ev, "__chat") or {}
    m = re.search(r"<remarks[^>]*>(.*?)</remarks>", ev, re.S)
    text = xml_unesc(m.group(1)) if m else ""
    sender_uid = ((tag(ev, "link") or {}).get("uid")) or ""
    mid = c.get("messageId", "")
    with SL:
        if mid and any(cc.get("id") == mid for cc in S["chat"][-200:]):
            return
        to_me = c.get("id") == my_uid() or c.get("chatroom") == cfg("CALLSIGN")
        S["chat"].append({"time": time.time(), "dir": "in", "from": c.get("senderCallsign", "?"), "from_uid": sender_uid,
                          "room": "Direct" if to_me else c.get("chatroom", ""), "text": text, "id": mid})
        del S["chat"][:-300]
        S["unread"] += 1
    log("chat from %s: %s" % (c.get("senderCallsign", "?"), text[:120]))
    if to_me and cfgb("CHAT_COMMANDS"):
        chat_command(text.strip(), c.get("senderCallsign", ""), sender_uid)
    save_state()


def dm_targets():
    """callsign -> uid for everyone the Hub can direct-message: friendly TAK contacts, chat clients (they send
    an endpoint), mesh nodes, and anyone who has messaged the Hub (CloudTAK users, sensors) even when their
    position is stale. Same as BunnyTAK and SquirrelTAK."""
    out = {}
    with SL:
        for m in S["chat"]:
            if m.get("dir") == "in" and m.get("from_uid") and m.get("from"):
                out[m["from"]] = m["from_uid"]
        for u, c in S["contacts"].items():
            if c["type"].startswith("a-f-") or c.get("endpoint") or c.get("team") or c.get("source") == "mesh":
                out[c["callsign"]] = u
    out.pop(cfg("CALLSIGN"), None)
    return out


def chat_delete(mid=None, t=None):
    """One chat line, by its TAK message id, or by its time when it has none (same as BunnyTAK)."""
    with SL:
        n = len(S["chat"])
        if mid:
            S["chat"] = [m for m in S["chat"] if m.get("id") != mid]
        elif t is not None:
            S["chat"] = [m for m in S["chat"] if abs(float(m.get("time", 0)) - float(t)) > 0.001]
        gone = n - len(S["chat"])
    if not gone:
        raise RuntimeError("message not found")
    save_state()
    return "message deleted"


def chat_send(text, to_cs=None):
    to_uid = None
    if to_cs:
        to_uid = dm_targets().get(to_cs)
        if not to_uid:
            raise RuntimeError("no TAK contact called %s" % to_cs)
    xml, mid, room = chat_event(text, to_cs, to_uid)
    ok = TAK.send(xml, queue=True)
    with SL:
        S["chat"].append({"time": time.time(), "dir": "out", "from": cfg("CALLSIGN"), "room": room, "text": text,
                          "id": mid, "sent": ok})
        del S["chat"][:-300]
    save_state()
    return ok


def chat_command(text, cs, uid):
    allow = [a.strip() for a in cfg("CHAT_COMMANDS_FROM").split(",") if a.strip()]
    if allow and cs not in allow:
        return
    cmd = text.lower().split()[0] if text else ""
    if cmd == "status":
        reply = status_text()
    elif cmd == "where":
        p = S["pos"]
        reply = "%s at %s (%s, +/- %s m)" % (cfg("CALLSIGN"), fmt_ll(p["lat"], p["lon"]), p["src"], int(p["ce"]))
    elif cmd == "scan":
        WATCH.kick.set()
        reply = "Network sweep started."
    elif cmd == "alerts":
        with SL:
            al = S["alerts"][-5:]
        reply = "; ".join("%s %s" % (time.strftime("%H:%M", time.localtime(a["time"])), a["title"]) for a in al) or "No alerts."
    elif cmd == "help":
        reply = "TurtleTAK commands: status, where, scan, alerts"
    else:
        return
    try:
        chat_send(reply, cs)
    except RuntimeError:
        pass


# ----------------------------------------------------------------------------------------------
# alerts
# ----------------------------------------------------------------------------------------------
ALERT_TYPES = {"warning": "a-u-G", "critical": "a-h-G", "info": "a-n-G"}


LEVELS = {"info": 0, "warning": 1, "critical": 2}
ALERT_KINDS = [("new_device", "New device"), ("missing", "Watched device missing / back"), ("arp", "ARP spoofing"),
               ("dhcp", "Rogue DHCP"), ("link", "RJ45 link lost / restored"), ("uplink", "TAK link down / restored"),
               ("cert", "Certificate expiring")]


def in_quiet_hours(now=None):
    q = cfg("QUIET_HOURS").replace(" ", "")
    m = re.match(r"^(\d{1,2})(?::(\d\d))?-(\d{1,2})(?::(\d\d))?$", q)
    if not m:
        return False
    t = time.localtime(now or time.time())
    cur = t.tm_hour * 60 + t.tm_min
    start = int(m.group(1)) * 60 + int(m.group(2) or 0)
    end = int(m.group(3)) * 60 + int(m.group(4) or 0)
    return start <= cur < end if start < end else (cur >= start or cur < end)


def raise_alert(kind, level, title, detail, marker=True, key=None):
    """level: info | warning | critical. Goes to TAK (marker + chat), the Hub UI, Cloud C2, LED -
    filtered by ALERTS_ON, MARKER_MIN_LEVEL, CHAT_MIN_LEVEL and QUIET_HOURS."""
    now = time.time()
    if kind != "test" and kind not in [k.strip() for k in cfg("ALERTS_ON").split(",")]:
        log("alert type %s is off: %s - %s" % (kind, title, detail), "debug")
        return
    with SL:
        if key and any(a.get("key") == key and now - a["time"] < 3600 for a in S["alerts"]):
            return
        aid = "%s-%d-%04d" % (kind, int(now), random.randint(0, 9999))
        a = {"id": aid, "key": key, "time": now, "kind": kind, "level": level, "title": title, "detail": detail}
        S["alerts"].append(a)
        del S["alerts"][:-200]
    rank = LEVELS.get(level, 0)
    quiet = in_quiet_hours(now) and not (level == "critical" and cfgb("QUIET_CRITICAL"))
    log("ALERT [%s] %s - %s%s" % (level, title, detail, " (quiet hours)" if quiet else ""), "warning" if level != "info" else "info")
    notify("error" if level == "critical" else ("warning" if level == "warning" else "info"), "%s: %s" % (title, detail))
    if level != "info" and not quiet:
        led(flash="SPECIAL" if level == "warning" else "FAIL2", secs=60)
    line = "[%s] %s %s - %s" % (cfg("CALLSIGN"), {"critical": "CRITICAL", "warning": "WARNING"}.get(level, "INFO"),
                                title, detail)
    p = S["pos"]
    if marker and cfgb("ALERT_MARKER") and p["lat"] is not None and rank >= LEVELS.get(cfg("MARKER_MIN_LEVEL"), 1):
        ang = random.uniform(0, 2 * math.pi)
        dlat = 15 * math.cos(ang) / 111111.0
        dlon = 15 * math.sin(ang) / (111111.0 * max(0.1, math.cos(math.radians(p["lat"]))))
        rem = "%s\n%s\nFrom %s (%s) at %s. Position is the Hub's, offset a few meters." % (
            title, detail, cfg("CALLSIGN"), PRODUCT, time.strftime("%Y-%m-%d %H:%M:%S %Z"))
        TAK.send(marker_event("%s.alert.%s" % (my_uid(), aid), ALERT_TYPES.get(level, "a-u-G"),
                              "%s %s" % (cfg("CALLSIGN"), title), rem, p["lat"] + dlat, p["lon"] + dlon,
                              max(15, p["ce"]), cfgi("ALERT_STALE_HOURS", 12) * 3600), queue=True)
    if cfgb("ALERT_CHAT") and not quiet and rank >= LEVELS.get(cfg("CHAT_MIN_LEVEL"), 0):
        to = cfg("ALERT_TO").strip() or None
        try:
            chat_send(line, to)
        except RuntimeError:
            chat_send(line, None)
    save_state()


# ----------------------------------------------------------------------------------------------
# device names and watched devices (devices.json: mac -> {name, watch})
# ----------------------------------------------------------------------------------------------
DEVICES_FILE = os.path.join(BASE, "devices.json")
DEV_LOCK = threading.Lock()


def devices():
    with DEV_LOCK:
        try:
            return json.load(open(DEVICES_FILE))
        except (OSError, ValueError):
            return {}


def set_device(mac, name=None, watch=None):
    mac = mac.lower()
    if not re.match(r"^[0-9a-f]{2}(:[0-9a-f]{2}){5}$", mac):
        raise RuntimeError("bad MAC address")
    with DEV_LOCK:
        try:
            d = json.load(open(DEVICES_FILE))
        except (OSError, ValueError):
            d = {}
        e = d.get(mac, {})
        if name is not None:
            e["name"] = name.strip()[:40]
        if watch is not None:
            e["watch"] = bool(watch)
        if e.get("name") or e.get("watch"):
            d[mac] = e
        else:
            d.pop(mac, None)
        tmp = "%s.%d.%d.tmp" % (DEVICES_FILE, os.getpid(), threading.get_ident())
        json.dump(d, open(tmp, "w"), indent=1)
        os.replace(tmp, DEVICES_FILE)
    return e


def dev_label(mac, ip=""):
    n = devices().get((mac or "").lower(), {}).get("name")
    return "%s (%s)" % (n, ip or mac) if n else (ip or mac)


# ----------------------------------------------------------------------------------------------
# client certificate expiry
# ----------------------------------------------------------------------------------------------
def cert_info():
    path = os.path.join(CERTS, "client.pem")
    if not os.path.exists(path):
        return {}
    try:
        d = ssl._ssl._test_decode_cert(path)
        exp = ssl.cert_time_to_seconds(d["notAfter"])
        subj = ", ".join("%s=%s" % kv for rdn in d.get("subject", ()) for kv in rdn)
        return {"subject": subj, "expires": exp, "days": int((exp - time.time()) // 86400),
                "issuer": ", ".join("%s=%s" % kv for rdn in d.get("issuer", ()) for kv in rdn)}
    except Exception as e:
        return {"error": str(e)}


def cert_check():
    c = cert_info()
    with SL:
        S["cert"] = c
    if "days" not in c:
        return
    day = time.strftime("%Y-%m-%d")
    if c["days"] < 0:
        raise_alert("cert", "critical", "Client certificate expired",
                    "Expired %s - TurtleTAK cannot connect until it is renewed (Setup > Enroll)" %
                    time.strftime("%Y-%m-%d", time.localtime(c["expires"])), marker=False, key="certexp:" + day)
    elif c["days"] <= cfgi("CERT_WARN_DAYS", 30):
        raise_alert("cert", "warning", "Client certificate expires in %d days" % c["days"],
                    "Expires %s - renew it (Setup > Enroll, or a new certificate)" %
                    time.strftime("%Y-%m-%d", time.localtime(c["expires"])), marker=False, key="certwarn:" + day)


# ----------------------------------------------------------------------------------------------
# system status, interfaces
# ----------------------------------------------------------------------------------------------

def _ioctl_addr(name, req):
    import fcntl
    s = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
    try:
        r = fcntl.ioctl(s.fileno(), req, struct.pack("256s", name[:15].encode()))
        return socket.inet_ntoa(r[20:24])
    finally:
        s.close()


def ipv4_addrs():
    """iface -> [cidr]. `ip` when present, else ioctl (primary address only)."""
    out = {}
    if have("ip"):
        for line in run(["ip", "-o", "-4", "addr", "show"]).splitlines():
            m = re.match(r"\d+:\s+(\S+)\s+inet\s+(\S+)", line)
            if m:
                out.setdefault(m.group(1), []).append(m.group(2))
        return out
    for n in (os.listdir("/sys/class/net") if os.path.isdir("/sys/class/net") else []):
        try:
            a = _ioctl_addr(n, 0x8915)
            mask = _ioctl_addr(n, 0x891B)
            out[n] = ["%s/%d" % (a, ipaddress.ip_network("0.0.0.0/%s" % mask).prefixlen)]
        except OSError:
            pass
    return out


def routes():
    """[(iface, dest_cidr, gateway)] from /proc/net/route."""
    out = []
    for line in rd("/proc/net/route").splitlines()[1:]:
        f = line.split()
        if len(f) < 8:
            continue
        h = lambda v: socket.inet_ntoa(struct.pack("<I", int(v, 16)))
        out.append((f[0], "%s/%d" % (h(f[1]), ipaddress.ip_network("0.0.0.0/%s" % h(f[7])).prefixlen), h(f[2])))
    return out


def neighbors(dev=None):
    """[(ip, mac, iface)] from /proc/net/arp (complete entries only)."""
    out = []
    for line in rd("/proc/net/arp").splitlines()[1:]:
        f = line.split()
        if len(f) >= 6 and int(f[2], 16) & 2 and f[3] != "00:00:00:00:00:00" and (dev is None or f[5] == dev):
            out.append((f[0], f[3].lower(), f[5]))
    return out


def ifaces():
    """name -> {ipv4: [cidr], mac, carrier, kind}"""
    out = {n: {"ipv4": a} for n, a in ipv4_addrs().items()}
    base = "/sys/class/net"
    for n in (os.listdir(base) if os.path.isdir(base) else []):
        d = out.setdefault(n, {"ipv4": []})
        d["mac"] = rd("%s/%s/address" % (base, n))
        d["carrier"] = rd("%s/%s/carrier" % (base, n)) == "1"
        d["oper"] = rd("%s/%s/operstate" % (base, n))
        d["wireless"] = os.path.isdir("%s/%s/wireless" % (base, n)) or os.path.isdir("%s/%s/phy80211" % (base, n))
        d["bridge"] = os.path.isdir("%s/%s/bridge" % (base, n))
        d["usb"] = "usb" in os.path.realpath("%s/%s/device" % (base, n)) if os.path.exists("%s/%s/device" % (base, n)) else False
    return out


def rd(p):
    try:
        return open(p).read().strip()
    except OSError:
        return ""


def default_route(dev=None):
    for n, dest, gw in routes():
        if dest == "0.0.0.0/0" and gw != "0.0.0.0" and (dev is None or n == dev):
            return gw, n
    return None, None


def rj45_iface(ifs=None):
    w = cfg("WATCH_IFACE", "auto")
    if w and w != "auto":
        return w
    ifs = ifs or ifaces()
    # The Hub's RJ45 is its "WAN" (WAN_IPCONFIG). Prefer an Ethernet with carrier and an IPv4 address that
    # is not the USB-C target side (172.16.84.0/24 by default) and not Wi-Fi / VPN / bridge.
    cands = []
    for n, d in ifs.items():
        if n == "lo" or d.get("wireless") or n.startswith(("wg", "tun", "nb", "wt", "br-", "docker")):
            continue
        if any(c.startswith("172.16.84.") for c in d.get("ipv4", [])):
            continue
        score = (2 if d.get("ipv4") else 0) + (1 if d.get("carrier") else 0) + (1 if n.startswith(("eth", "wan")) else 0)
        cands.append((score, n))
    gw, dev = default_route()
    if dev and dev in ifs and not ifs[dev].get("wireless") and not dev.startswith(("wg", "tun")):
        return dev
    return max(cands)[1] if cands else None


def status_collect():
    ifs = ifaces()
    gw, dev = default_route()
    rj = rj45_iface(ifs)
    wifi = [n for n, d in ifs.items() if d.get("wireless") and d.get("ipv4")]
    wg = run(["wg", "show", "interfaces"]).split() if have("wg") else []
    wg_hs = ""
    if wg:
        hs = run(["wg", "show", wg[0], "latest-handshakes"]).split()
        if len(hs) >= 2 and hs[1].isdigit() and int(hs[1]):
            wg_hs = dur(time.time() - int(hs[1])) + " ago"
    up = float((rd("/proc/uptime") or "0").split()[0])
    mem = {}
    for line in rd("/proc/meminfo").splitlines():
        k, _, v = line.partition(":")
        mem[k] = int(v.split()[0]) if v.split() else 0
    leases = len([l for l in rd("/tmp/dhcp.leases").splitlines() if l.strip()])
    nb = ""
    if have("netbird"):
        nb = "connected" if "Management: Connected" in run(["netbird", "status"], 8) else "not connected"
    osname = ""
    for line in rd("/etc/os-release").splitlines():
        if line.startswith("PRETTY_NAME="):
            osname = line.split("=", 1)[1].strip('"')
    st = {
        "uplink": dev or "none", "gateway": gw or "", "rj45": rj or "", "rj45_ip": ",".join(ifs.get(rj, {}).get("ipv4", [])) if rj else "",
        "rj45_link": bool(ifs.get(rj, {}).get("carrier")) if rj else False,
        "wifi_client": ",".join("%s %s" % (n, ifs[n]["ipv4"][0]) for n in wifi),
        "vpn": ("WireGuard %s%s" % (wg[0], (", handshake " + wg_hs) if wg_hs else "")) if wg else "",
        "netbird": nb, "uptime": up, "mem_free_kb": mem.get("MemAvailable", mem.get("MemFree", 0)),
        "mem_total_kb": mem.get("MemTotal", 0), "load": (rd("/proc/loadavg") or "0").split()[0],
        "target_leases": leases, "os": osname or "Linux", "public_ip": S["status"].get("public_ip", ""),
        "isp": S["status"].get("isp", ""), "ifaces": {n: {k: d.get(k) for k in ("ipv4", "mac", "carrier", "wireless", "usb")}
                                                      for n, d in ifs.items() if n != "lo"},
        "dns": DNS_CACHE.get(cfg("TAK_HOST"), ""),
        "tools": {t: have(t) for t in ("openssl", "nmap", "wg", "netbird", "arping", "tcpdump", "stty")},
        "python": sys.version.split()[0],
    }
    with SL:
        S["status"] = st
    return st


def status_text():
    st = S["status"]
    p = S["pos"]
    n = S["net"]
    parts = ["%s %s %s" % (PRODUCT, EDITION, VERSION),
             "Uplink: %s%s" % (st.get("uplink", "?"), (" via " + st["gateway"]) if st.get("gateway") else ""),
             "RJ45: %s %s" % ("link" if st.get("rj45_link") else "NO LINK", st.get("rj45_ip", "")),
             ]
    if st.get("wifi_client"):
        parts.append("Wi-Fi: " + st["wifi_client"])
    if st.get("vpn"):
        parts.append("VPN: " + st["vpn"])
    if st.get("netbird"):
        parts.append("NetBird: " + st["netbird"])
    if st.get("public_ip"):
        parts.append("Public IP: %s %s" % (st["public_ip"], st.get("isp", "")))
    if cfgb("WATCH"):
        parts.append("Watch: %s devices (%s new), last sweep %s" % (
            n.get("count", 0), n.get("new", 0), (dur(time.time() - n["last_sweep"]) + " ago") if n.get("last_sweep") else "pending"))
    if cfgb("BRIDGE_UP") or cfgb("BRIDGE_DOWN"):
        b = S["bridge"]
        parts.append("Mesh bridge: %d devices, %d up / %d down" % (len(b["devices"]), b["up_tx"], b["down_tx"]))
    parts.append("Location: %s, +/- %s m" % (p["src"], int(p["ce"]) if p["ce"] < 9999999 else "?"))
    parts.append("Up %s, load %s, %d MB free" % (dur(st.get("uptime", 0)), st.get("load", "?"), st.get("mem_free_kb", 0) // 1024))
    return "\n".join(parts)


def dur(s):
    s = int(max(0, s))
    if s < 90:
        return "%ds" % s
    if s < 5400:
        return "%dm" % (s // 60)
    if s < 172800:
        return "%dh%02dm" % (s // 3600, (s % 3600) // 60)
    return "%dd%02dh" % (s // 86400, (s % 86400) // 3600)


def fmt_ll(lat, lon):
    return "unknown" if lat is None else "%.5f, %.5f" % (lat, lon)


# ----------------------------------------------------------------------------------------------
# location
# ----------------------------------------------------------------------------------------------
def sites():
    out = []
    for line in (open(SITES).read().splitlines() if os.path.exists(SITES) else []):
        p = line.split("|")
        if len(p) >= 3:
            try:
                out.append({"name": p[0], "lat": float(p[1]), "lon": float(p[2])})
            except ValueError:
                pass
    return out


def save_site(name, lat, lon):
    rows = [s for s in sites() if s["name"] != name] + [{"name": name, "lat": lat, "lon": lon}]
    with open(SITES, "w") as fh:
        fh.write("".join("%s|%.7f|%.7f\n" % (s["name"].replace("|", "/"), s["lat"], s["lon"]) for s in rows))


IPGEO = {"t": 0, "lat": None, "lon": None}


def ipgeo():
    if time.time() - IPGEO["t"] < 3600:
        return IPGEO
    IPGEO["t"] = time.time()
    try:
        with urllib.request.urlopen(cfg("IPGEO_URL"), timeout=10) as r:
            d = json.loads(r.read().decode())
        if "loc" in d:
            IPGEO["lat"], IPGEO["lon"] = [float(v) for v in d["loc"].split(",")]
        elif "lat" in d:
            IPGEO["lat"], IPGEO["lon"] = float(d["lat"]), float(d.get("lon", d.get("lng")))
        with SL:
            S["status"]["public_ip"] = d.get("ip") or d.get("query", "")
            S["status"]["isp"] = d.get("org") or d.get("isp", "")
    except Exception as e:
        log("IP geolocation failed: %s" % e, "debug")
    return IPGEO


TURTLEMESH_BASE = os.environ.get("TM_BASE", "/root/turtlemesh")
LOC_ORDER = ["radio", "gps", "atak", "site", "manual", "ip"]


def turtlemesh_running():
    """TurtleMesh on this Hub, running now (the Hub runs one payload at a time unless TurtleShell runs both)."""
    try:
        pid = int(open(os.path.join(TURTLEMESH_BASE, "turtlemesh.pid")).read().strip())
        return b"turtlemesh" in open("/proc/%d/cmdline" % pid, "rb").read()
    except (OSError, ValueError):
        return False


def turtlemesh_cfg():
    out = {}
    try:
        for line in open(os.path.join(TURTLEMESH_BASE, "default.cfg"), encoding="utf-8", errors="replace"):
            if ":" in line and not line.lstrip().startswith("#"):
                k, v = line.split(":", 1)
                out[k.strip()] = v.strip()
    except OSError:
        pass
    return out


def turtlemesh_info():
    """TurtleMesh on this Hub: running, its console port, and where it sends TurtleTAK's alerts over LoRa."""
    c = turtlemesh_cfg()
    lora = "off"
    if c and "turtletak" in [x.strip() for x in c.get("LORA_ALERT_SOURCES", "turtletak,turtlemesh").split(",")]:
        if c.get("LORA_ALERTS", "0") == "1" and c.get("LORA_ALERT_TO", "").strip():
            lora = "a direct message to %s" % c["LORA_ALERT_TO"].strip()
        elif c.get("LORA_ALERTS", "0") == "1" and c.get("LORA_ALERT_CHANNEL", "").strip().isdigit():
            lora = "mesh channel %s" % c["LORA_ALERT_CHANNEL"].strip()
    return {"installed": bool(c), "running": turtlemesh_running(), "port": c.get("WEB_PORT", "8485"),
            "lora": lora, "lora_min": c.get("LORA_ALERT_MIN", "warning")}


def radio_fix():
    """The Meshtastic radio's own GPS fix, shared by TurtleMesh while it runs."""
    if not turtlemesh_running():
        return None
    try:
        f = json.load(open(os.path.join(TURTLEMESH_BASE, "radio_fix.json")))
        if time.time() - f["time"] < cfgi("RADIO_GPS_MAX_AGE", 1800):
            return (float(f["lat"]), float(f["lon"]), 10, float(f.get("alt") or 0))
    except (OSError, ValueError, KeyError, TypeError):
        pass
    return None


def locate():
    mode = cfg("LOC_MODE", "auto").lower()
    order = LOC_ORDER if mode not in LOC_ORDER else [mode] + [m for m in LOC_ORDER if m != mode]
    for m in order:
        r = None
        if m == "radio":
            r = radio_fix()
        elif m == "gps":
            g = S["gps"]
            if g["fix"] and time.time() - g["time"] < 30:
                r = (g["lat"], g["lon"], g.get("ce", 10), g.get("hae", 0))
        elif m == "atak" and cfg("MY_ATAK"):
            with SL:
                for c in S["contacts"].values():
                    if c["callsign"] == cfg("MY_ATAK") and time.time() - c["time"] < cfgi("ANCHOR_MAX_AGE", 1800):
                        r = (c["lat"], c["lon"], max(10, c["ce"] if c["ce"] < 9999999 else 10), 0)
        elif m == "site" and cfg("SITE"):
            for s in sites():
                if s["name"] == cfg("SITE"):
                    r = (s["lat"], s["lon"], 10, 0)
        elif m == "manual" and cfg("MANUAL_LAT") and cfg("MANUAL_LON"):
            try:
                r = (float(cfg("MANUAL_LAT")), float(cfg("MANUAL_LON")), 10, 0)
            except ValueError:
                pass
        elif m == "ip" and cfgb("IPGEO"):
            g = ipgeo()
            if g["lat"] is not None:
                r = (g["lat"], g["lon"], 25000, 0)
        if r:
            with SL:
                changed = S["pos"]["src"] != m
                S["pos"] = {"lat": r[0], "lon": r[1], "ce": r[2], "hae": r[3], "src": m, "time": time.time()}
            if changed:
                log("location from %s: %s" % (m, fmt_ll(r[0], r[1])))
                save_state()
            return
    if cfgb("IPGEO"):
        ipgeo()     # still fill in the public IP for the status


class Gps:
    def run(self):
        claimed = False
        while True:
            dev = cfg("GPS_DEVICE", "auto")
            if dev == "off":
                time.sleep(30)
                continue
            if cfgb("GPS_CLAIM_USB") and not claimed:
                hub("USB_CLAIM_DEVICE")
                hub("USB_POWER_ON")
                claimed = True
            if dev == "auto":
                cands = sorted(p for p in ("/dev/ttyACM0", "/dev/ttyACM1", "/dev/ttyUSB0", "/dev/ttyUSB1") if os.path.exists(p))
                tm = turtlemesh_cfg()
                if tm.get("RADIO_CONN") == "usb":     # TurtleMesh's Meshtastic radio is not a GPS
                    rdev = tm.get("RADIO_DEV", "auto")
                    cands = [p for p in cands if p != (cands[0] if rdev in ("", "auto") else rdev)]
                dev = cands[0] if cands else ""
            if not dev or not os.path.exists(dev):
                with SL:
                    S["gps"].update({"device": "", "fix": False})
                time.sleep(15)
                continue
            try:
                if have("stty"):
                    run(["stty", "-F", dev, cfg("GPS_BAUD", "9600"), "raw", "-echo"], 5)
                with SL:
                    S["gps"]["device"] = dev
                self.read(dev)
            except Exception as e:
                log("GPS %s: %s" % (dev, e), "debug")
            time.sleep(5)

    def read(self, dev):
        fd = os.open(dev, os.O_RDONLY | os.O_NOCTTY | os.O_NONBLOCK)
        buf = b""
        last = time.time()
        try:
            while True:
                r, _, _ = select.select([fd], [], [], 5)
                if not r:
                    if time.time() - last > 20:
                        raise RuntimeError("no data")
                    continue
                chunk = os.read(fd, 4096)
                if not chunk:
                    raise RuntimeError("closed")
                last = time.time()
                buf += chunk
                while b"\n" in buf:
                    line, buf = buf.split(b"\n", 1)
                    self.nmea(line.decode("ascii", "replace").strip())
                buf = buf[-2048:]
        finally:
            os.close(fd)

    @staticmethod
    def dm(v, h):
        if not v:
            return None
        d = float(v)
        deg = int(d / 100)
        val = deg + (d - deg * 100) / 60
        return -val if h in ("S", "W") else val

    def nmea(self, line):
        if not line.startswith("$") or "*" not in line:
            return
        body, _, cks = line[1:].partition("*")
        c = 0
        for ch in body:
            c ^= ord(ch)
        if cks[:2].upper() != "%02X" % c:
            return
        f = body.split(",")
        t = f[0][2:]
        with SL:
            g = S["gps"]
            if t == "GGA" and len(f) > 9:
                q = int(f[6] or 0)
                g["sats"] = int(f[7] or 0)
                if q > 0 and f[2]:
                    hdop = float(f[8] or 2)
                    g.update({"lat": self.dm(f[2], f[3]), "lon": self.dm(f[4], f[5]), "hae": float(f[9] or 0),
                              "ce": max(3, round(hdop * 5)), "fix": True, "time": time.time()})
                else:
                    g["fix"] = False
            elif t == "RMC" and len(f) > 6:
                if f[2] == "A" and f[3]:
                    g.update({"lat": self.dm(f[3], f[4]), "lon": self.dm(f[5], f[6]), "fix": True, "time": time.time()})
                    g.setdefault("ce", 10)
                else:
                    g["fix"] = False


# ----------------------------------------------------------------------------------------------
# network watch: device sweep + baseline, ARP spoofing, rogue DHCP, link tamper
# ----------------------------------------------------------------------------------------------
class Watch:
    def __init__(self):
        self.kick = threading.Event()
        self.dhcp_kick = threading.Event()
        self.baseline = None
        self.key = None

    def sweep(self):
        ifn = rj45_iface()
        ifs = ifaces()
        if not ifn or ifn not in ifs or not ifs[ifn].get("ipv4"):
            with SL:
                S["net"].update({"iface": ifn or "", "state": "no IPv4 address on the RJ45 side", "last_try": time.time()})
            return
        cidr = ifs[ifn]["ipv4"][0]
        net = ipaddress.ip_interface(cidr).network
        my_ip = cidr.split("/")[0]
        if net.num_addresses > cfgi("WATCH_MAX_HOSTS", 256):
            net = ipaddress.ip_interface("%s/24" % my_ip).network
        gw, _ = default_route(ifn)
        with SL:
            S["net"].update({"iface": ifn, "subnet": str(net), "state": "sweeping", "my_ip": my_ip, "gateway": gw or ""})
        t0 = time.time()
        found = {}
        if have("nmap"):
            out = run(["nmap", "-sn", "-n", "-T3", "--max-rate", str(cfgi("WATCH_RATE", 50)), "-e", ifn, "-oX", "-", str(net)],
                      timeout=600)
            for h in re.findall(r"<host>.*?</host>", out, re.S):
                ip = re.search(r'addr="([\d.]+)" addrtype="ipv4"', h)
                mac = re.search(r'addr="([0-9A-Fa-f:]{17})" addrtype="mac"(?: vendor="([^"]*)")?', h)
                if ip and mac:
                    found[mac.group(1).lower()] = {"ip": ip.group(1), "vendor": mac.group(2) or ""}
            method = "nmap"
        else:
            self.ping_sweep(net, my_ip)
            method = "ping"
        for ip, mac, _ in neighbors(ifn):
            if ipaddress.ip_address(ip) in net:
                found.setdefault(mac, {"ip": ip, "vendor": ""})
        self.compare(found, net, gw, method, time.time() - t0)

    def ping_sweep(self, net, my_ip):
        hosts = [str(h) for h in net.hosts() if str(h) != my_ip]
        sem = threading.Semaphore(24)

        def one(ip):
            with sem:
                run(["ping", "-c", "1", "-W", "1", ip], 3)
        th = [threading.Thread(target=one, args=(h,), daemon=True) for h in hosts]
        for t in th:
            t.start()
        for t in th:
            t.join(10)

    def pick_baseline(self, found, net, gw, gw_mac):
        """Baselines are per network: subnet + gateway IP + gateway MAC. Same subnet and gateway IP but a
        different gateway MAC is either another site (few devices in common -> its own baseline) or the
        same network with a spoofed gateway (most devices in common -> keep that baseline, alert)."""
        stem = "%s_%s" % (str(net).replace("/", "-"), gw or "nogw")
        key = "%s_%s" % (stem, (gw_mac or "nomac").replace(":", ""))
        if os.path.exists(os.path.join(BASELINES, key + ".json")):
            return key, None
        macs = set(found) - {gw_mac}
        best, best_overlap = None, 0.0
        for f in os.listdir(BASELINES):
            if f.startswith(stem + "_") and f.endswith(".json"):
                try:
                    b = json.load(open(os.path.join(BASELINES, f)))
                except Exception:
                    continue
                devs = set(b.get("devices", {})) - {b.get("gateway_mac")}
                if devs and macs:
                    ov = len(devs & macs) / float(min(len(devs), len(macs)))
                    if ov > best_overlap:
                        best, best_overlap = f[:-5], ov
        if best and best_overlap >= 0.5 and gw_mac:
            return best, best_overlap
        return key, None

    def compare(self, found, net, gw, method, took):
        gw_mac = next((m for m, d in found.items() if d["ip"] == gw), None) if gw else None
        key, overlap = self.pick_baseline(found, net, gw, gw_mac)
        path = os.path.join(BASELINES, key + ".json")
        if self.key != key:
            self.key = key
            self.baseline = json.load(open(path)) if os.path.exists(path) else None
        now = time.time()
        new = []
        if self.baseline is None and cfgb("AUTO_BASELINE"):
            self.baseline = {"network": str(net), "gateway": gw, "gateway_mac": gw_mac, "created": now,
                             "devices": {m: {"ip": d["ip"], "vendor": d["vendor"], "first": now} for m, d in found.items()}}
            json.dump(self.baseline, open(path, "w"), indent=1)
            log("baseline saved for %s: %d devices" % (net, len(found)))
            notify("info", "Network baseline saved for %s (%d devices)" % (net, len(found)))
        known = (self.baseline or {}).get("devices", {})
        with SL:
            hosts = S["hosts"] if S["net"].get("key") == key else {}
            for m, d in found.items():
                h = hosts.get(m) or {"first": now, "vendor": d["vendor"]}
                h.update({"ip": d["ip"], "last": now, "known": m in known, "vendor": d["vendor"] or h.get("vendor", "")})
                hosts[m] = h
                if self.baseline is not None and m not in known and not h.get("alerted"):
                    h["alerted"] = True
                    new.append((m, d))
            S["hosts"] = hosts
            S["net"].update({"key": key, "state": "ok", "count": len(found), "last_sweep": now, "method": method,
                             "took": round(took, 1), "new": len([1 for h in hosts.values() if not h["known"]]),
                             "baseline": bool(self.baseline), "baseline_count": len(known), "gateway_mac": gw_mac or ""})
        for m, d in new:
            raise_alert("new_device", "warning", "New device %s" % dev_label(m, d["ip"]),
                        "MAC %s%s on %s, not in the baseline" % (m, (" (%s)" % d["vendor"]) if d["vendor"] else "", net),
                        key="new:%s:%s" % (key, m))
        self.missing_check(found, known, hosts, key)
        if cfgb("ARP_WATCH"):
            self.arp_check(found, gw, gw_mac, net)
        save_state()

    def missing_check(self, found, known, hosts, key):
        """Watched devices (devices.json watch=true) that belong to this network and stopped answering."""
        after = max(1, cfgi("MISSING_AFTER", 2))
        miss = S["net"].setdefault("missing", {})
        for mac, meta in devices().items():
            if not meta.get("watch") or (mac not in known and mac not in hosts):
                continue
            ip = (hosts.get(mac) or known.get(mac) or {}).get("ip", "")
            if mac in found:
                if miss.get(mac, {}).get("alerted"):
                    raise_alert("missing", "info", "Device back: %s" % dev_label(mac, ip),
                                "Answering again after %s" % dur(time.time() - miss[mac]["since"]), key=None)
                miss.pop(mac, None)
                continue
            m = miss.setdefault(mac, {"count": 0, "since": (hosts.get(mac) or {}).get("last", time.time())})
            m["count"] += 1
            if m["count"] >= after and not m.get("alerted"):
                m["alerted"] = True
                last = hosts.get(mac, {}).get("last")
                raise_alert("missing", "critical", "Device missing: %s" % dev_label(mac, ip),
                            "Watched device %s has not answered for %d sweeps%s" % (
                                mac, m["count"], (" (last seen %s ago)" % dur(time.time() - last)) if last else ""),
                            key="missing:%s:%d" % (mac, int(m["since"])))

    def arp_check(self, found, gw, gw_mac, net):
        if gw and gw_mac:
            base_gw = (self.baseline or {}).get("gateway_mac")
            if base_gw and base_gw != gw_mac:
                raise_alert("arp", "critical", "Gateway MAC changed",
                            "Gateway %s now answers as %s (baseline %s) - possible ARP spoofing / MITM" % (gw, gw_mac, base_gw),
                            key="gwmac:%s:%s" % (gw, gw_mac))
        by_mac = {}
        for m, d in found.items():
            by_mac.setdefault(m, set()).add(d["ip"])
        # ip neigh can show one MAC on several IPs - the gateway's IP sharing a MAC with another host is the classic sign
        for ip, mac, _ in neighbors():
            if ipaddress.ip_address(ip) in net:
                by_mac.setdefault(mac, set()).add(ip)
        for m, ips in by_mac.items():
            if gw and gw in ips and len(ips) > 1:
                raise_alert("arp", "critical", "Duplicate gateway MAC",
                            "%s claims the gateway %s and %s - possible ARP spoofing" % (dev_label(m, m), gw, ", ".join(sorted(ips - {gw}))),
                            key="dup:%s" % m)

    def accept_all(self):
        if not self.key:
            return 0
        now = time.time()
        with SL:
            for m, h in S["hosts"].items():
                h["known"] = True
            devs = {m: {"ip": h["ip"], "vendor": h.get("vendor", ""), "first": h.get("first", now)} for m, h in S["hosts"].items()}
            gwm = S["net"].get("gateway_mac") or None
            S["net"]["new"] = 0
            S["net"]["baseline"] = True
            S["net"]["baseline_count"] = len(devs)
        b = self.baseline or {"network": S["net"].get("subnet"), "created": now}
        b["devices"] = devs
        b["gateway_mac"] = gwm or b.get("gateway_mac")
        self.baseline = b
        json.dump(b, open(os.path.join(BASELINES, self.key + ".json"), "w"), indent=1)
        log("baseline updated: %d devices" % len(devs))
        return len(devs)

    def run(self):
        time.sleep(20)
        while True:
            if cfgb("WATCH"):
                try:
                    self.sweep()
                except Exception as e:
                    log("network sweep: %s" % e, "warning")
                    traceback.print_exc()
            self.kick.wait(max(60, cfgi("WATCH_INTERVAL", 300)))
            self.kick.clear()

    # ---- rogue DHCP: DHCPDISCOVER from a random MAC (broadcast reply), never requests a lease
    def dhcp_probe(self, ifn, wait=6):
        xid = random.getrandbits(32)
        mac = bytes([0x02] + [random.getrandbits(8) for _ in range(5)])
        pkt = struct.pack("!BBBBIHH4s4s4s4s16s64s128s", 1, 1, 6, 0, xid, 0, 0x8000, b"\0" * 4, b"\0" * 4, b"\0" * 4,
                          b"\0" * 4, mac + b"\0" * 10, b"\0" * 64, b"\0" * 128)
        pkt += b"\x63\x82\x53\x63" + b"\x35\x01\x01" + b"\x37\x03\x01\x03\x06" + b"\xff"
        s = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
        s.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
        s.setsockopt(socket.SOL_SOCKET, socket.SO_BROADCAST, 1)
        try:
            s.setsockopt(socket.SOL_SOCKET, 25, (ifn + "\0").encode())  # SO_BINDTODEVICE
        except OSError:
            pass
        s.bind(("0.0.0.0", 68))
        servers = {}
        try:
            s.sendto(pkt, ("255.255.255.255", 67))
            end = time.time() + wait
            while time.time() < end:
                r, _, _ = select.select([s], [], [], max(0.1, end - time.time()))
                if not r:
                    break
                data, addr = s.recvfrom(4096)
                if len(data) < 240 or struct.unpack("!I", data[4:8])[0] != xid:
                    continue
                opts, i, sid, mtype = data[240:], 0, addr[0], 0
                while i < len(opts) and opts[i] != 255:
                    if opts[i] == 0:
                        i += 1
                        continue
                    o, ln = opts[i], opts[i + 1]
                    v = opts[i + 2:i + 2 + ln]
                    if o == 54 and ln == 4:
                        sid = socket.inet_ntoa(v)
                    if o == 53 and ln == 1:
                        mtype = v[0]
                    i += 2 + ln
                if mtype == 2:
                    servers[sid] = {"offer": socket.inet_ntoa(data[16:20]), "from": addr[0]}
        finally:
            s.close()
        return servers

    def dhcp_check(self):
        ifn = rj45_iface()
        if not ifn:
            return
        try:
            servers = self.dhcp_probe(ifn)
        except OSError as e:
            with SL:
                S["net"]["dhcp"] = "check failed: %s" % e
            log("DHCP check: %s" % e, "debug")
            return
        allowed = [a.strip() for a in cfg("DHCP_KNOWN").split(",") if a.strip()]
        with SL:
            learned = S["net"].setdefault("dhcp_known", [])
            if not allowed and not learned and len(servers) == 1:
                learned.append(next(iter(servers)))
                log("DHCP server learned: %s" % learned[0])
            ok = allowed or learned
            S["net"]["dhcp"] = ", ".join("%s (offered %s)" % (k, v["offer"]) for k, v in servers.items()) or "no answer"
            S["net"]["dhcp_time"] = time.time()
        rogue = [k for k in servers if ok and k not in ok]
        if len(servers) > 1 and not ok:
            rogue = list(servers)
        for r in rogue:
            raise_alert("dhcp", "critical", "Rogue DHCP server %s" % r,
                        "DHCP offer from %s (offered %s); known server(s): %s" % (r, servers[r]["offer"], ", ".join(ok) or "none"),
                        key="dhcp:%s" % r)
        save_state()

    def dhcp_run(self):
        time.sleep(45)
        while True:
            if cfgb("DHCP_WATCH"):
                try:
                    self.dhcp_check()
                except Exception as e:
                    log("DHCP check: %s" % e, "warning")
            self.dhcp_kick.wait(max(120, cfgi("DHCP_INTERVAL", 900)))
            self.dhcp_kick.clear()

    def link_run(self):
        last = None
        down_at = 0
        while True:
            time.sleep(2)
            ifn = rj45_iface()
            if not ifn:
                continue
            up = rd("/sys/class/net/%s/carrier" % ifn) == "1"
            if last is not None and up != last and cfgb("LINK_WATCH"):
                if not up:
                    down_at = time.time()
                    raise_alert("link", "warning", "RJ45 link lost",
                                "Ethernet link on %s went down - cable pulled or switch port off?" % ifn)
                else:
                    raise_alert("link", "info", "RJ45 link restored", "Ethernet on %s back after %s" % (ifn, dur(time.time() - down_at)))
                    self.kick.set()
            last = up


WATCH = Watch()


# ----------------------------------------------------------------------------------------------
# ATAK mesh SA bridge (multicast <-> TAK Server)
# ----------------------------------------------------------------------------------------------
class Bridge:
    def __init__(self):
        self.out = None
        self.last_up = {}
        self.lock = threading.Lock()

    def groups(self):
        out = []
        for k in ("BRIDGE_SA_GROUP", "BRIDGE_CHAT_GROUP"):
            g, _, p = cfg(k).partition(":")
            if g and p.isdigit():
                out.append((g, int(p)))
        return out

    def local_ips(self):
        want = [i.strip() for i in cfg("BRIDGE_IFACES", "auto").split(",") if i.strip()]
        ips = []
        for n, d in ifaces().items():
            if n == "lo" or n.startswith(("wg", "tun", "nb", "wt")):
                continue
            if want and want != ["auto"] and n not in want:
                continue
            for c in d.get("ipv4", []):
                ips.append((n, c.split("/")[0]))
        return ips

    def run(self):
        while True:
            if not (cfgb("BRIDGE_UP") or cfgb("BRIDGE_DOWN")):
                time.sleep(5)
                continue
            socks = []
            try:
                ips = self.local_ips()
                for g, p in self.groups():
                    s = socket.socket(socket.AF_INET, socket.SOCK_DGRAM, socket.IPPROTO_UDP)
                    s.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
                    s.bind(("", p))
                    for n, ip in ips:
                        try:
                            s.setsockopt(socket.IPPROTO_IP, socket.IP_ADD_MEMBERSHIP, socket.inet_aton(g) + socket.inet_aton(ip))
                        except OSError:
                            pass
                    socks.append((s, g, p))
                self.out = socket.socket(socket.AF_INET, socket.SOCK_DGRAM, socket.IPPROTO_UDP)
                self.out.setsockopt(socket.IPPROTO_IP, socket.IP_MULTICAST_TTL, 1)
                self.out.setsockopt(socket.IPPROTO_IP, socket.IP_MULTICAST_LOOP, 0)
                with SL:
                    S["bridge"]["ifaces"] = ["%s %s" % i for i in ips]
                    S["bridge"]["error"] = ""
                log("mesh bridge on %s" % (", ".join("%s %s" % i for i in ips) or "no interfaces"))
                started = time.time()
                while (cfgb("BRIDGE_UP") or cfgb("BRIDGE_DOWN")) and time.time() - started < 300:
                    r, _, _ = select.select([s for s, _, _ in socks], [], [], 5)
                    for s in r:
                        data, addr = s.recvfrom(65535)
                        if addr[0] in [ip for _, ip in ips]:
                            continue
                        self.up(data, addr)
            except Exception as e:
                with SL:
                    S["bridge"]["error"] = str(e)
                log("mesh bridge: %s" % e, "warning")
                time.sleep(10)
            finally:
                for s, _, _ in socks:
                    s.close()
                if self.out:
                    self.out.close()
                    self.out = None
            # loop rebuilds every 5 minutes so new interfaces (Wi-Fi joins, DHCP) are picked up

    def up(self, data, addr):
        with SL:
            S["bridge"]["up_rx"] += 1
        try:
            if data[:1] == b"\xbf":
                xml = tak_proto_to_xml(data)
            else:
                xml = data.decode("utf-8", "replace")
                xml = xml[xml.find("<event"):] if "<event" in xml else None
        except Exception:
            xml = None
        if not xml:
            return
        uid = (re.search(r'<event[^>]*\suid="([^"]*)"', xml) or [None, ""])[1]
        ctype = (re.search(r'<event[^>]*\stype="([^"]*)"', xml) or [None, ""])[1]
        if not uid or uid == my_uid():
            return
        now = time.time()
        if TAK.recent_down.get(uid, 0) > now - 30:
            return   # our own repeat of server traffic
        cs = (tag(xml, "contact") or {}).get("callsign", "")
        with SL:
            dev = S["bridge"]["devices"].setdefault(uid, {"first": now})
            dev.update({"callsign": cs or dev.get("callsign", uid), "ip": addr[0], "last": now, "type": ctype})
        handle_event(xml, source="mesh")
        if not cfgb("BRIDGE_UP"):
            return
        if not ctype.startswith("b-t-f"):
            if now - self.last_up.get(uid, 0) < cfgi("BRIDGE_MIN_GAP", 5):
                return
            self.last_up[uid] = now
        if TAK.send(xml):
            with SL:
                S["bridge"]["up_tx"] += 1

    def down(self, xml, uid, ctype):
        if not self.out:
            return
        types = [t.strip() for t in cfg("BRIDGE_DOWN_TYPES").split(",") if t.strip()]
        if types and not any(ctype.startswith(t) for t in types):
            return
        with SL:
            if uid in S["bridge"]["devices"]:
                return  # it came from the mesh in the first place
        groups = self.groups()
        g = groups[1] if ctype.startswith("b-t-f") and len(groups) > 1 else groups[0]
        data = xml.encode("utf-8")
        TAK.recent_down[uid] = time.time()
        if len(TAK.recent_down) > 5000:
            cut = time.time() - 60
            TAK.recent_down = {k: v for k, v in TAK.recent_down.items() if v > cut}
        for n, ip in self.local_ips():
            try:
                self.out.setsockopt(socket.IPPROTO_IP, socket.IP_MULTICAST_IF, socket.inet_aton(ip))
                self.out.sendto(data, g)
            except OSError:
                pass
        with SL:
            S["bridge"]["down_tx"] += 1


BRIDGE = Bridge()


# ----------------------------------------------------------------------------------------------
# uplinks (Hub Wi-Fi client, WireGuard)
# ----------------------------------------------------------------------------------------------
def uplinks_apply():
    msgs = []
    if cfg("WIFI_SSID"):
        rc, out = hub("WIFI_CONNECT", cfg("WIFI_COUNTRY", "US"), cfg("WIFI_SSID"), cfg("WIFI_ENC", "psk2"),
                      cfg("WIFI_KEY") or "NONE", "ANY", timeout=60)
        msgs.append("Wi-Fi %s: %s" % (cfg("WIFI_SSID"), "ok" if rc == 0 else "failed " + out[-120:]))
    if cfg("WG_CONF"):
        if os.path.exists(cfg("WG_CONF")):
            rc, out = hub("WIREGUARD_CONFIGURE", "enable", cfg("WG_CONF"), timeout=60)
            msgs.append("WireGuard: %s" % ("ok" if rc == 0 else "failed " + out[-120:]))
        else:
            msgs.append("WireGuard: %s not found" % cfg("WG_CONF"))
    for m in msgs:
        log(m)
    return msgs


# ----------------------------------------------------------------------------------------------
# periodic SA
# ----------------------------------------------------------------------------------------------
def sa_loop():
    while True:
        try:
            status_collect()
            locate()
            if TAK.connected():
                TAK.send(sa_event())
            led()
        except Exception as e:
            log("SA: %s" % e, "warning")
            traceback.print_exc()
        time.sleep(max(15, cfgi("SA_INTERVAL", 60)))


def housekeeping():
    last_cert = 0
    while True:
        time.sleep(15)
        scan_certs()
        if time.time() - last_cert > 3600:
            last_cert = time.time()
            cert_check()
        now = time.time()
        with SL:
            for k in [k for k, c in S["contacts"].items() if (c.get("stale") or c["time"] + 900) < now - 3600]:
                del S["contacts"][k]
            for k in [k for k, d in S["bridge"]["devices"].items() if d["last"] < now - 3600]:
                del S["bridge"]["devices"][k]
        led()


# ----------------------------------------------------------------------------------------------
# clone package (.turtletak): settings, certificates, sites, device names, baselines -> another Hub
# ----------------------------------------------------------------------------------------------
CLONE_SKIP = {"UID", "WEB_PASS_HASH", "CALLSIGN"}


def clone_export():
    buf = io.BytesIO()
    with zipfile.ZipFile(buf, "w", zipfile.ZIP_DEFLATED) as z:
        with CFG_LOCK:
            cfgtxt = "".join("%s: %s\n" % (k, v) for k, v in CFG.items() if k not in CLONE_SKIP)
        z.writestr("default.cfg", cfgtxt)
        for f in ("client.pem", "ca.pem", "wg.conf"):
            fp = os.path.join(CERTS, f)
            if os.path.exists(fp):
                z.write(fp, "certs/" + f)
        for fp, arc in ((SITES, "sites.txt"), (DEVICES_FILE, "devices.json")):
            if os.path.exists(fp):
                z.write(fp, arc)
        for f in sorted(os.listdir(BASELINES)):
            if f.endswith(".json"):
                z.write(os.path.join(BASELINES, f), "baselines/" + f)
        z.writestr("turtletak-clone.json", json.dumps({"product": PRODUCT, "edition": EDITION, "version": VERSION,
                                                        "from": cfg("CALLSIGN"), "created": iso()}))
    log("clone package exported")
    return buf.getvalue()


def clone_import(data, callsign):
    callsign = (callsign or "").strip()
    if not re.match(r"^[A-Za-z0-9 _.-]{2,30}$", callsign):
        raise RuntimeError("give this Hub its own callsign (2-30 letters, numbers, - _ .)")
    try:
        z = zipfile.ZipFile(io.BytesIO(data))
        meta = json.loads(z.read("turtletak-clone.json"))
    except Exception:
        raise RuntimeError("not a TurtleTAK clone package")
    names = z.namelist()
    if "certs/client.pem" in names or "certs/ca.pem" in names:
        save_cert_files(client=z.read("certs/client.pem").decode() if "certs/client.pem" in names else None,
                        ca=z.read("certs/ca.pem").decode() if "certs/ca.pem" in names else None, why="clone package")
    ch = {}
    for line in z.read("default.cfg").decode("utf-8", "replace").splitlines():
        if ":" in line and not line.startswith("#"):
            k, v = line.split(":", 1)
            if k.strip() not in CLONE_SKIP:
                ch[k.strip()] = v.strip()
    if "certs/wg.conf" in names:
        write_secret(os.path.join(CERTS, "wg.conf"), z.read("certs/wg.conf").decode())
        ch["WG_CONF"] = os.path.join(CERTS, "wg.conf")
    for arc, fp in (("sites.txt", SITES), ("devices.json", DEVICES_FILE)):
        if arc in names:
            with open(fp, "wb") as fh:
                fh.write(z.read(arc))
    for n in names:
        if n.startswith("baselines/") and n.endswith(".json") and "/" not in n[10:]:
            with open(os.path.join(BASELINES, os.path.basename(n)), "wb") as fh:
                fh.write(z.read(n))
    ch["CALLSIGN"] = callsign
    ch["UID"] = ""                     # a new UID is made for this Hub
    cfg_set(ch)
    my_uid()
    log("clone package from %s imported as %s" % (meta.get("from"), callsign))
    TAK.reconnect()
    threading.Thread(target=uplinks_apply, daemon=True).start()
    return "set up as %s from %s's clone package" % (callsign, meta.get("from", "?"))


# ----------------------------------------------------------------------------------------------
# site survey data package (MANIFEST v2) - sent to TAK like SharkTAKDisplay
# ----------------------------------------------------------------------------------------------
def survey_build():
    now = time.time()
    sid = uuid.uuid4().hex[:8]
    muid = "%s.survey.%s" % (my_uid(), sid)
    name = "%s-survey-%s" % (re.sub(r"[^A-Za-z0-9_-]", "_", cfg("CALLSIGN")), time.strftime("%Y%m%d-%H%M", time.localtime(now)))
    DEVS = devices()
    with SL:
        n = dict(S["net"])
        hosts = sorted(S["hosts"].items(), key=lambda kv: ipaddress.ip_address(kv[1]["ip"]))
        alerts = list(S["alerts"][-50:])
        p = dict(S["pos"])
    summary = ["%s site survey - %s" % (cfg("CALLSIGN"), time.strftime("%Y-%m-%d %H:%M %Z", time.localtime(now))), "",
               status_text(), "",
               "Network: %s on %s, gateway %s %s" % (n.get("subnet", "?"), n.get("iface", "?"), n.get("gateway", ""), n.get("gateway_mac", "")),
               "Devices: %d seen, %d new (not in the baseline), baseline %d" % (len(hosts), n.get("new", 0), n.get("baseline_count", 0)),
               "DHCP servers: %s" % n.get("dhcp", "not checked"), ""]
    summary += ["%-15s %-17s %-6s %s" % (h["ip"], m, "known" if h.get("known") else "NEW",
                                          (DEVS.get(m, {}).get("name") or h.get("vendor") or "")) for m, h in hosts]
    csv = ["ip,mac,status,name,vendor,watched,first_seen,last_seen"]
    for m, h in hosts:
        nm = DEVS.get(m, {}).get("name", "").replace(",", " ")
        csv.append("%s,%s,%s,%s,%s,%s,%s,%s" % (h["ip"], m, "known" if h.get("known") else "new", nm, h.get("vendor", "").replace(",", " "),
                                                 "yes" if DEVS.get(m, {}).get("watch") else "", iso(h.get("first", now)), iso(h.get("last", now))))
    altxt = ["%s [%s] %s - %s" % (time.strftime("%Y-%m-%d %H:%M", time.localtime(a["time"])), a["level"], a["title"], a["detail"]) for a in alerts]
    rem = "Site survey by %s\n%s devices (%s new) on %s\nSee the attached data package for the device list." % (
        cfg("CALLSIGN"), len(hosts), n.get("new", 0), n.get("subnet", "?"))
    marker = marker_event(muid, "b-m-p-s-m", "%s survey %s" % (cfg("CALLSIGN"), time.strftime("%m-%d %H:%M", time.localtime(now))),
                          rem, p["lat"], p["lon"], p["ce"], 7 * 86400)
    files = {"survey/summary.txt": "\n".join(summary) + "\n", "survey/devices.csv": "\n".join(csv) + "\n",
             "survey/alerts.txt": "\n".join(altxt) + "\n", "survey/survey.cot": '<?xml version="1.0" encoding="UTF-8" standalone="yes"?>' + marker}
    if WATCH.baseline:
        files["survey/baseline.json"] = json.dumps(WATCH.baseline, indent=1)
    manifest = ['<MissionPackageManifest version="2">', " <Configuration>",
                '  <Parameter name="uid" value="%s"/>' % uuid.uuid4(), '  <Parameter name="name" value="%s"/>' % x(name),
                '  <Parameter name="onReceiveDelete" value="false"/>', " </Configuration>", " <Contents>"]
    for f in sorted(files):
        manifest.append('  <Content ignore="false" zipEntry="%s"><Parameter name="uid" value="%s"/></Content>' % (f, muid))
    manifest += [" </Contents>", "</MissionPackageManifest>"]
    buf = io.BytesIO()
    with zipfile.ZipFile(buf, "w", zipfile.ZIP_DEFLATED) as z:
        z.writestr("MANIFEST/manifest.xml", "\n".join(manifest) + "\n")
        for f, t in sorted(files.items()):
            z.writestr(f, t)
    data = buf.getvalue()
    os.makedirs(LOOT, exist_ok=True)
    with open(os.path.join(LOOT, name + ".zip"), "wb") as fh:
        fh.write(data)
    return name + ".zip", data, marker


def marti_upload(name, data):
    """Upload a data package to the TAK Server (Marti API) -> download URL."""
    tls = cfg("TAK_PROTO") == "tls"
    base = "%s://%s:%s" % ("https" if tls else "http", cfg("TAK_HOST"), cfg("API_PORT", "8443" if tls else "8080"))
    ctx = None
    if tls:
        ctx = ssl.SSLContext(ssl.PROTOCOL_TLS_CLIENT)
        ctx.load_cert_chain(os.path.join(CERTS, "client.pem"))
        ca = os.path.join(CERTS, "ca.pem")
        ctx.check_hostname = False
        if os.path.exists(ca):
            ctx.load_verify_locations(ca)
            ctx.verify_mode = ssl.CERT_REQUIRED
        else:
            ctx.verify_mode = ssl.CERT_NONE
    h = hashlib.sha256(data).hexdigest()
    bnd = "----TurtleTAK" + uuid.uuid4().hex
    body = ("--%s\r\nContent-Disposition: form-data; name=\"assetfile\"; filename=\"%s\"\r\n"
            "Content-Type: application/x-zip-compressed\r\n\r\n" % (bnd, name)).encode() + data + ("\r\n--%s--\r\n" % bnd).encode()
    q = urllib.parse.urlencode({"hash": h, "filename": name, "creatorUid": my_uid()})
    req = urllib.request.Request("%s/Marti/sync/missionupload?%s" % (base, q), data=body,
                                 headers={"Content-Type": "multipart/form-data; boundary=" + bnd})
    try:
        with urllib.request.urlopen(req, context=ctx, timeout=120) as r:
            url = r.read().decode("utf-8", "replace").strip()
    except urllib.error.HTTPError as e:
        raise RuntimeError("TAK Server refused the upload: HTTP %d" % e.code)
    except (urllib.error.URLError, OSError) as e:
        raise RuntimeError("cannot reach the TAK Server API (%s): %s" % (base, getattr(e, "reason", e)))
    if not url.startswith("http"):
        url = "%s/Marti/sync/content?hash=%s" % (base, h)
    try:   # list it in the server's Data Packages
        urllib.request.urlopen(urllib.request.Request("%s/Marti/api/sync/metadata/%s/tool" % (base, h), data=b"public",
                                                      method="PUT", headers={"Content-Type": "text/plain"}), context=ctx, timeout=30).read()
    except Exception:
        pass
    return url, h


def survey_send(to):
    """to: '' = everyone, 'upload' = server only, or a callsign."""
    if to and to != "upload":
        with SL:
            if not any(c["callsign"] == to for c in S["contacts"].values()):
                raise RuntimeError("no TAK contact called %s" % to)
    name, data, marker = survey_build()
    url, h = marti_upload(name, data)
    TAK.send(marker, queue=True)
    if to == "upload":
        log("survey %s uploaded to the TAK Server" % name)
        return "%s uploaded to the TAK Server's data packages" % name
    dest, dest_uid = "", None
    if to:
        with SL:
            dest_uid = next((u for u, c in S["contacts"].items() if c["callsign"] == to), None)
        if not dest_uid:
            raise RuntimeError("no TAK contact called %s" % to)
        dest = '<marti><dest callsign="%s"/></marti>' % x(to)
    p = S["pos"]
    ev = (ev_open(str(uuid.uuid4()), "b-f-t-r", 600) + point_xml(p["lat"], p["lon"], p["ce"]) + "<detail>"
          + '<fileshare filename="%s" senderUrl="%s" sizeInBytes="%d" sha256="%s" senderUid="%s" senderCallsign="%s" name="%s"/>'
          % (x(name), x(url), len(data), h, x(my_uid()), x(cfg("CALLSIGN")), x(name[:-4]))
          + '<ackrequest uid="%s" ackrequested="true" tag="%s"/>%s</detail></event>' % (uuid.uuid4(), x(name[:-4]), dest))
    TAK.send(ev, queue=True)
    log("survey %s sent to %s" % (name, to or "everyone"))
    return "%s sent to %s" % (name, to or "everyone")


# ----------------------------------------------------------------------------------------------
# map tiles: cached on the Hub (USB storage when attached) so the web map works offline
# ----------------------------------------------------------------------------------------------
TILE_SOURCES = {
    "usgs_topo": ("USGS Topo", "https://basemap.nationalmap.gov/arcgis/rest/services/USGSTopo/MapServer/tile/{z}/{y}/{x}", 16, True),
    "usgs_imagery": ("USGS Imagery", "https://basemap.nationalmap.gov/arcgis/rest/services/USGSImageryOnly/MapServer/tile/{z}/{y}/{x}", 16, True),
    "usgs_hybrid": ("USGS Imagery + Topo", "https://basemap.nationalmap.gov/arcgis/rest/services/USGSImageryTopo/MapServer/tile/{z}/{y}/{x}", 16, True),
    "osm": ("OpenStreetMap (live only)", "https://tile.openstreetmap.org/{z}/{x}/{y}.png", 19, False),
}


class Tiles:
    def __init__(self):
        self.job = None
        self.lock = threading.Lock()
        self.size = None

    def root(self):
        for u in ("/usb", "/mnt/usb", "/mnt/sda1"):
            if os.path.ismount(u) and os.access(u, os.W_OK):
                return os.path.join(u, "turtletak-tiles")
        return os.path.join(BASE, "tiles")

    def path(self, src, z, x_, y):
        return os.path.join(self.root(), src, str(z), str(x_), "%d.tile" % y)

    def fetch(self, src, z, x_, y):
        name, url, maxz, _ = TILE_SOURCES[src]
        req = urllib.request.Request(url.format(z=z, x=x_, y=y), headers={"User-Agent": "TurtleTAK/%s (LAN Turtle Hub)" % VERSION})
        with urllib.request.urlopen(req, timeout=10) as r:
            data = r.read()
        if len(data) < 64:
            raise ValueError("empty tile")
        fp = self.path(src, z, x_, y)
        if self.size is None or self.size < cfgi("TILE_CACHE_MB", 500) * 1048576:
            os.makedirs(os.path.dirname(fp), exist_ok=True)
            tmp = "%s.%d.tmp" % (fp, threading.get_ident())
            with open(tmp, "wb") as fh:
                fh.write(data)
            os.replace(tmp, fp)
            if self.size is not None:
                self.size += len(data)
        return data

    def get(self, src, z, x_, y):
        if src not in TILE_SOURCES or z > TILE_SOURCES[src][2]:
            return None
        fp = self.path(src, z, x_, y)
        if os.path.exists(fp):
            return open(fp, "rb").read()
        try:
            return self.fetch(src, z, x_, y)
        except Exception:
            return None

    def measure(self):
        total = n = 0
        for d, _, fs in os.walk(self.root()):
            for f in fs:
                total += os.path.getsize(os.path.join(d, f))
                n += 1
        self.size = total
        self.count = n
        return total

    @staticmethod
    def tile_range(s_, w, n, e, z):
        def xy(lat, lon):
            lat = max(-85.05, min(85.05, lat))
            k = 2 ** z
            xt = int((lon + 180) / 360 * k)
            yt = int((1 - math.log(math.tan(math.radians(lat)) + 1 / math.cos(math.radians(lat))) / math.pi) / 2 * k)
            return min(k - 1, max(0, xt)), min(k - 1, max(0, yt))
        x0, y0 = xy(n, w)
        x1, y1 = xy(s_, e)
        return x0, x1, y0, y1

    def plan(self, b, zmin, zmax):
        total = 0
        for z in range(zmin, zmax + 1):
            x0, x1, y0, y1 = self.tile_range(b["s"], b["w"], b["n"], b["e"], z)
            total += (x1 - x0 + 1) * (y1 - y0 + 1)
        return total

    def download(self, src, b, zmin, zmax):
        if src not in TILE_SOURCES or not TILE_SOURCES[src][3]:
            raise RuntimeError("%s can't be saved for offline use - pick a USGS map" % TILE_SOURCES.get(src, ("that map",))[0])
        zmax = min(zmax, TILE_SOURCES[src][2])
        n = self.plan(b, zmin, zmax)
        if n > cfgi("TILE_MAX_DOWNLOAD", 20000):
            raise RuntimeError("that is %d tiles - zoom in, or lower the top zoom (limit TILE_MAX_DOWNLOAD %s)" % (n, cfg("TILE_MAX_DOWNLOAD")))
        with self.lock:
            if self.job and self.job.get("running"):
                raise RuntimeError("a map download is already running")
            self.job = {"running": True, "total": n, "done": 0, "saved": 0, "failed": 0, "src": src, "started": time.time()}
        self.measure()
        threading.Thread(target=self._run, args=(src, b, zmin, zmax), daemon=True).start()
        return "saving %d tiles of %s for offline use" % (n, TILE_SOURCES[src][0])

    def _run(self, src, b, zmin, zmax):
        j = self.job
        try:
            for z in range(zmin, zmax + 1):
                x0, x1, y0, y1 = self.tile_range(b["s"], b["w"], b["n"], b["e"], z)
                for x_ in range(x0, x1 + 1):
                    for y in range(y0, y1 + 1):
                        if not j.get("running"):
                            return
                        if not os.path.exists(self.path(src, z, x_, y)):
                            if self.size is not None and self.size >= cfgi("TILE_CACHE_MB", 500) * 1048576:
                                j["error"] = "tile cache is full (TILE_CACHE_MB)"
                                return
                            try:
                                self.fetch(src, z, x_, y)
                                j["saved"] += 1
                            except Exception:
                                j["failed"] += 1
                            time.sleep(0.05)
                        j["done"] += 1
        finally:
            j["running"] = False
            j["finished"] = time.time()
            log("map download: %d saved, %d failed, %d already there" % (j["saved"], j["failed"], j["done"] - j["saved"] - j["failed"]))

    def clear(self):
        shutil.rmtree(self.root(), ignore_errors=True)
        self.size = 0
        return "tile cache cleared"

    def status(self):
        if self.size is None:
            threading.Thread(target=self.measure, daemon=True).start()
            self.size = 0
        return {"root": self.root(), "mb": round((self.size or 0) / 1048576.0, 1), "limit_mb": cfgi("TILE_CACHE_MB", 500),
                "job": self.job, "sources": {k: v[0] for k, v in TILE_SOURCES.items()}, "source": cfg("MAP_SOURCE", "usgs_topo"),
                "offline_ok": {k: v[3] for k, v in TILE_SOURCES.items()}}


TILES = Tiles()


# ----------------------------------------------------------------------------------------------
# web console
# ----------------------------------------------------------------------------------------------
SESSIONS = {}


def hash_pw(pw, salt=None):
    salt = salt or binascii.hexlify(os.urandom(8)).decode()
    h = hashlib.pbkdf2_hmac("sha256", pw.encode(), salt.encode(), 60000)
    return "pbkdf2$%s$%s" % (salt, binascii.hexlify(h).decode())


def check_pw(pw, stored):
    try:
        _, salt, h = stored.split("$")
        return hmac.compare_digest(hash_pw(pw, salt), stored)
    except ValueError:
        return False


# ----------------------------------------------------------------------------------------------
# clock: "Set clock now" reads the time from the TAK Server or the web, for a Hub without NTP
# ----------------------------------------------------------------------------------------------
HTTP_DATE = re.compile(r"^Date:\s*(.+)$", re.M | re.I)


def set_clock(t, why):
    if DRY:
        log("clock> %s (%s)" % (iso(t), why), "debug")
        return
    delta = t - time.time()
    try:
        rc = subprocess.run(["date", "-u", "-s", time.strftime("%Y-%m-%d %H:%M:%S", time.gmtime(t))],
                            stdout=subprocess.PIPE, stderr=subprocess.STDOUT, timeout=10).returncode
    except Exception:
        rc = 1
    if rc == 0 or abs(time.time() - t) < 120:
        if abs(delta) >= 30:
            with SL:                                   # move the times already recorded with the clock
                S["started"] += delta
                S["tak"]["since"] += delta
                for c in S["contacts"].values():
                    c["time"] += delta
                for h in S["hosts"].values():
                    for k in ("first", "last"):
                        if h.get(k):
                            h[k] += delta
            IPGEO["t"] = 0
        log("clock set to %s UTC from %s" % (time.strftime("%Y-%m-%d %H:%M:%S", time.gmtime(t)), why))
    else:
        log("could not set the clock (date -s failed)", "warning")


def clock_sync():
    """Date header from the TAK Server's API port (no certificate check - only the time is read), then the web,
    then NTP."""
    if not cfgb("CLOCK_SYNC"):
        S["clock"] = "off (CLOCK_SYNC)"
        return False
    import calendar
    tries = []
    host = cfg("TAK_HOST")
    if host and not host.endswith("example.com"):
        tries.append(("https", host, cfgi("API_PORT", 8443)))
    tries += [("http", "www.google.com", 80), ("http", "detectportal.firefox.com", 80)]
    for scheme, h, port in tries:
        try:
            s = socket.create_connection((h, port), timeout=8)
            if scheme == "https":
                ctx = ssl.SSLContext(ssl.PROTOCOL_TLS_CLIENT)
                ctx.check_hostname, ctx.verify_mode = False, ssl.CERT_NONE
                s = ctx.wrap_socket(s, server_hostname=h)
            s.sendall(("HEAD / HTTP/1.0\r\nHost: %s\r\nUser-Agent: TurtleTAK\r\n\r\n" % h).encode())
            head = s.recv(4096).decode("latin-1", "replace")
            s.close()
            m = HTTP_DATE.search(head)
            if not m:
                continue
            t = calendar.timegm(time.strptime(m.group(1).strip(), "%a, %d %b %Y %H:%M:%S GMT"))
            if abs(t - time.time()) > 30:
                set_clock(t, "%s:%d" % (h, port))
            S["clock"] = "synced %s from %s" % (time.strftime("%H:%M"), h)
            return True
        except Exception as e:
            log("clock from %s:%d: %s" % (h, port, e), "debug")
    if have("ntpd"):
        try:
            if subprocess.run(["ntpd", "-n", "-q", "-p", "pool.ntp.org"], stdout=subprocess.DEVNULL,
                              stderr=subprocess.DEVNULL, timeout=20).returncode == 0:
                S["clock"] = "synced %s (NTP)" % time.strftime("%H:%M")
                return True
        except Exception:
            pass
    S["clock"] = "not synced"
    return False


COT_TYPE_RE = re.compile(r"^a-[fhunpsajkox]-[A-Z](-[A-Za-z0-9]+)*$")
TEAM_COLORS = ["White", "Yellow", "Orange", "Magenta", "Red", "Maroon", "Purple", "Dark Blue", "Blue", "Cyan",
               "Teal", "Green", "Dark Green", "Brown"]


def team_name(v):
    """ATAK's spelling of a team color, whatever the case or hyphens: "dark-blue" -> "Dark Blue"."""
    v = (v or "").strip()
    key = re.sub(r"[\s_-]+", "", v).lower()
    for n in TEAM_COLORS:
        if n.replace(" ", "").lower() == key:
            return n
    return v


def state_json():
    DEVS = devices()
    with SL:
        now = time.time()
        p = S["pos"]
        contacts = []
        for u, c in S["contacts"].items():
            d = dict(c, uid=u, age=int(now - c["time"]))
            if p["lat"] is not None:
                d["dist"], d["brg"] = dist_brg(p["lat"], p["lon"], c["lat"], c["lon"])
            contacts.append(d)
        contacts.sort(key=lambda c: c.get("dist", 0))
        out = {"version": VERSION, "edition": EDITION, "callsign": cfg("CALLSIGN"), "uid": my_uid(), "now": now,
               "turtlemesh": turtlemesh_info(),
               "uptime": now - S["started"], "tak": dict(S["tak"], host=cfg("TAK_HOST"), port=cfg("TAK_PORT"),
                                                         proto=cfg("TAK_PROTO"), queued=queue_len()),
               "pos": p, "gps": S["gps"], "status": S["status"], "contacts": contacts[:500],
               "chat": S["chat"][-150:], "unread": S["unread"], "dm_targets": sorted(dm_targets(), key=lambda n: n.lower()),
               "clock": S["clock"], "team_colors": TEAM_COLORS, "alerts": S["alerts"][-100:][::-1], "net": {k: v for k, v in S["net"].items()},
               "hosts": sorted(({"mac": m, **h, "name": DEVS.get(m, {}).get("name", ""), "watch": DEVS.get(m, {}).get("watch", False),
                                 "missing": bool(S["net"].get("missing", {}).get(m, {}).get("alerted"))}
                                for m, h in S["hosts"].items()), key=lambda h: ipaddress.ip_address(h["ip"])),
               "devices": DEVS, "cert": S.get("cert", {}), "alert_kinds": ALERT_KINDS, "quiet": in_quiet_hours(),
               "tiles": TILES.status(),
               "bridge": {"up": cfgb("BRIDGE_UP"), "down": cfgb("BRIDGE_DOWN"), **{k: v for k, v in S["bridge"].items()}},
               "sites": sites(), "status_text": status_text(),
               "certs": {f: os.path.exists(os.path.join(CERTS, f)) for f in ("client.pem", "ca.pem")}}
    return json.dumps(out, default=str).encode()


def queue_len():
    try:
        return sum(1 for _ in open(QUEUE))
    except OSError:
        return 0


def dist_brg(a1, o1, a2, o2):
    r = 6371000.0
    p1, p2 = math.radians(a1), math.radians(a2)
    dp, dl = p2 - p1, math.radians(o2 - o1)
    a = math.sin(dp / 2) ** 2 + math.cos(p1) * math.cos(p2) * math.sin(dl / 2) ** 2
    d = 2 * r * math.asin(min(1, math.sqrt(a)))
    b = math.degrees(math.atan2(math.sin(dl) * math.cos(p2), math.cos(p1) * math.sin(p2) - math.sin(p1) * math.cos(p2) * math.cos(dl)))
    return round(d), round((b + 360) % 360)


SECRET_KEYS = {"WEB_PASS_HASH", "WIFI_KEY", "CLIENT_PASSWORD", "CA_PASSWORD"}


def action(a, d):
    if a == "chat":
        text = (d.get("text") or "").strip()[:1000]
        if not text:
            raise RuntimeError("empty message")
        ok = chat_send(text, d.get("to") or None)
        return "sent" if ok else "queued (TAK offline)"
    if a == "chat_read":
        with SL:
            S["unread"] = 0
        return "ok"
    if a == "chat_delete":
        return chat_delete(str(d.get("id") or "") or None, d.get("time"))
    if a == "chat_clear":
        with SL:
            S["chat"] = []
            S["unread"] = 0
        save_state()
        return "chat cleared"
    if a == "clock_sync":
        return S["clock"] if clock_sync() else "could not get the time (no internet?)"
    if a == "scan":
        WATCH.kick.set()
        return "sweep started"
    if a == "dhcp":
        WATCH.dhcp_check()
        return S["net"].get("dhcp", "")
    if a == "accept":
        return "baseline now %d devices" % WATCH.accept_all()
    if a == "clear_alerts":
        with SL:
            S["alerts"] = []
        save_state()
        return "cleared"
    if a == "test_alert":
        raise_alert("test", "warning", "Test alert", "This is a TurtleTAK test alert.", key=None)
        return "sent"
    if a == "reconnect":
        TAK.reconnect()
        return "reconnecting"
    if a == "send_sa":
        locate()
        return "sent" if TAK.send(sa_event()) else "TAK offline"
    if a == "set_pos":
        lat, lon = float(d["lat"]), float(d["lon"])
        if not (-90 <= lat <= 90 and -180 <= lon <= 180):
            raise RuntimeError("bad coordinates")
        ch = {"MANUAL_LAT": "%.7f" % lat, "MANUAL_LON": "%.7f" % lon}
        if d.get("site"):
            save_site(d["site"].strip()[:40], lat, lon)
            ch = {"SITE": d["site"].strip()[:40], "LOC_MODE": "site"}
        elif cfg("LOC_MODE") not in ("manual", "auto"):
            ch["LOC_MODE"] = "manual"
        cfg_set(ch)
        locate()
        TAK.send(sa_event())
        return "location set"
    if a == "uplinks":
        return "; ".join(uplinks_apply()) or "nothing configured"
    if a == "enroll":
        enroll(d.get("user", ""), d.get("password", ""))
        return "enrolled"
    if a == "set_password":
        pw = d.get("password", "")
        if len(pw) < 8:
            raise RuntimeError("use at least 8 characters")
        cfg_set({"WEB_PASS_HASH": hash_pw(pw)})
        return "password changed"
    if a == "set_device":
        e = set_device(d.get("mac", ""), d.get("name"), d.get("watch"))
        return "saved %s" % (e.get("name") or d.get("mac"))
    if a == "send_survey":
        return survey_send((d.get("to") or "").strip())
    if a == "tiles_download":
        b = {k: float(d["bounds"][k]) for k in ("s", "w", "n", "e")}
        return TILES.download(d.get("src") or cfg("MAP_SOURCE"), b, int(d.get("zmin", 1)), int(d.get("zmax", 15)))
    if a == "tiles_plan":
        b = {k: float(d["bounds"][k]) for k in ("s", "w", "n", "e")}
        src = d.get("src") or cfg("MAP_SOURCE")
        return "%d tiles" % TILES.plan(b, int(d.get("zmin", 1)), min(int(d.get("zmax", 15)), TILE_SOURCES.get(src, ("", "", 16))[2]))
    if a == "tiles_stop":
        if TILES.job:
            TILES.job["running"] = False
        return "stopping"
    if a == "tiles_clear":
        return TILES.clear()
    if a == "restore_certs":
        return restore_certs()
    if a == "diagnose":
        return "\n".join(diagnose())
    if a == "install_openssl":
        for mgr, cmd in (("opkg", "opkg update && opkg install openssl-util"), ("apk", "apk update && apk add openssl")):
            if have(mgr):
                p = subprocess.run(["sh", "-c", cmd], stdout=subprocess.PIPE, stderr=subprocess.STDOUT, timeout=300)
                out = p.stdout.decode("utf-8", "replace")
                log("%s: %s" % (cmd, out[-300:]))
                return "openssl installed" if have("openssl") else "install failed: %s" % out.strip()[-160:]
        return "no package manager (opkg/apk) found - openssl is optional, TurtleTAK works without it"
    if a == "boot":
        rc, out = hub("BOOT_PAYLOAD", "enable" if d.get("on") else "disable")
        cfg_set({"RUN_AT_BOOT": "1" if d.get("on") else "0"})
        return "run at boot %s" % ("on" if d.get("on") else "off")
    raise RuntimeError("unknown action")


def diagnose():
    """Step-by-step TAK connection check for the Setup page."""
    host, port, proto = cfg("TAK_HOST"), cfgi("TAK_PORT", 8089), cfg("TAK_PROTO", "tls").lower()
    out = ["Server: %s:%d (%s)" % (host, port, proto)]
    out.append("DNS servers: %s" % (", ".join(re.findall(r"^nameserver\s+(\S+)", rd("/etc/resolv.conf"), re.M)) or "none in /etc/resolv.conf"))
    try:
        socket.inet_aton(host)
        ips = [host]
        out.append("1. DNS: %s is an IP address - no lookup needed" % host)
    except OSError:
        detail = []
        for fam, name in ((socket.AF_UNSPEC, "any"), (socket.AF_INET, "IPv4"), (socket.AF_INET6, "IPv6")):
            try:
                r = _getaddrinfo(host, port, fam, socket.SOCK_STREAM)
                detail.append("%s ok (%s)" % (name, r[0][4][0]))
            except socket.gaierror as e:
                detail.append("%s failed (%s)" % (name, e.strerror or e))
        ns = _nslookup(host)
        detail.append("nslookup %s" % (ns[0] if ns else "failed"))
        try:
            ips = [ai[4][0] for ai in socket.getaddrinfo(host, port, 0, socket.SOCK_STREAM)]
            out.append("1. DNS: OK -> %s  [%s]" % (ips[0], "; ".join(detail)))
        except socket.gaierror as e:
            out.append("1. DNS: FAILED - %s  [%s]. Check the server name's spelling first, then try the server's IP address, or set SYSTEM_DNS on the Hub." % (e, "; ".join(detail)))
            return out
    if proto == "udp":
        out.append("2. UDP: send-only, nothing to test")
        return out
    try:
        t0 = time.time()
        raw = socket.create_connection((host, port), timeout=10)
        out.append("2. TCP %d: OK (%d ms, from %s)" % (port, (time.time() - t0) * 1000, raw.getsockname()[0]))
    except OSError as e:
        out.append("2. TCP %d: FAILED - %s. Check the port, a firewall, or the route (VPN?)." % (port, e))
        return out
    if proto != "tls":
        raw.close()
        out.append("3. TLS: not used (tcp)")
        return out
    client, ca = os.path.join(CERTS, "client.pem"), os.path.join(CERTS, "ca.pem")
    if not os.path.exists(client):
        raw.close()
        out.append("3. TLS: no client certificate loaded")
        return out
    try:
        ctx = ssl.SSLContext(ssl.PROTOCOL_TLS_CLIENT)
        try:
            ctx.load_cert_chain(client)
            out.append("3a. Client certificate file: OK (%s)" % pem_summary(client))
        except (ssl.SSLError, OSError) as e:
            out.append("3a. Client certificate file: BROKEN - %s (%s). Re-import it, or Restore previous certificates." % (e, pem_summary(client)))
            raw.close()
            return out
        if os.path.exists(ca):
            try:
                ssl.SSLContext(ssl.PROTOCOL_TLS_CLIENT).load_verify_locations(ca)
                out.append("3b. Truststore file: OK (%s)" % pem_summary(ca))
            except (ssl.SSLError, OSError) as e:
                out.append("3b. Truststore file: BROKEN - %s (%s). Re-import it, or Restore previous certificates." % (e, pem_summary(ca)))
                raw.close()
                return out
        if os.path.exists(ca):
            ctx.load_verify_locations(ca)
            ctx.check_hostname = cfgb("TAK_VERIFY_HOST")
            ctx.verify_mode = ssl.CERT_REQUIRED
        else:
            ctx.check_hostname = False
            ctx.verify_mode = ssl.CERT_NONE
        s = ctx.wrap_socket(raw, server_hostname=host)
        peer = s.getpeercert(binary_form=False) or {}
        subj = ", ".join("%s=%s" % kv for rdn in peer.get("subject", ()) for kv in rdn)
        out.append("3. TLS: OK (%s, server cert %s%s)" % (s.version(), subj or "not checked", "" if os.path.exists(ca) else ", truststore not loaded"))
        s.settimeout(3)
        try:
            data = s.recv(4096)
            out.append("4. Server accepted the client certificate%s" % (" and sent data" if data else ""))
        except socket.timeout:
            out.append("4. Server accepted the client certificate (connection held open)")
        except (ssl.SSLError, OSError) as e:
            out.append("4. Server REJECTED the client certificate: %s (wrong CA / revoked / not enrolled?)" % e)
        s.close()
    except ssl.SSLCertVerificationError as e:
        out.append("3. TLS: server certificate NOT trusted by the truststore - %s (wrong truststore, or turn TAK_VERIFY_HOST off)" % e.verify_message)
    except (ssl.SSLError, OSError) as e:
        out.append("3. TLS: FAILED - %s" % e)
    return out


class Web(BaseHTTPRequestHandler):
    server_version = "TurtleTAK"
    protocol_version = "HTTP/1.0"

    def log_message(self, *a):
        pass

    def send(self, code, body=b"", ctype="application/json", extra=()):
        self.send_response(code)
        self.send_header("Content-Type", ctype)
        self.send_header("Content-Length", str(len(body)))
        if not any(k == "Cache-Control" for k, _ in extra):
            self.send_header("Cache-Control", "no-store")
        self.send_header("X-Frame-Options", "DENY")
        for k, v in extra:
            self.send_header(k, v)
        self.end_headers()
        self.wfile.write(body)

    def session(self):
        m = re.search(r"tt_session=([0-9a-f]{32})", self.headers.get("Cookie", ""))
        s = m and SESSIONS.get(m.group(1))
        return bool(s and s > time.time())

    def body(self, limit=64 * 1024):
        n = int(self.headers.get("Content-Length") or 0)
        if n > limit:
            raise RuntimeError("too large")
        return self.rfile.read(n)

    def do_GET(self):
        path = self.path.split("?")[0]
        if path in ("/", "/index.html"):
            return self.send(200, open(os.path.join(APP, "index.html"), "rb").read(), "text/html; charset=utf-8")
        if path == "/api/state":
            if not self.session():
                return self.send(401, b'{"login":true}')
            return self.send(200, state_json())
        if path == "/api/cfg":
            if not self.session():
                return self.send(401, b'{"login":true}')
            with CFG_LOCK:
                c = [{"key": k, "value": ("" if k in SECRET_KEYS and CFG.get(k) else CFG.get(k, v)) if v is not None else None,
                      "set": bool(CFG.get(k)), "secret": k in SECRET_KEYS, "section": v is None} for k, v in DEFAULTS]
            return self.send(200, json.dumps(c).encode())
        if path.startswith("/static/") and re.match(r"^/static/[a-z0-9_.-]+$", path):
            fp = os.path.join(APP, "static", path[8:])
            if os.path.exists(fp):
                ctype = "text/css" if fp.endswith(".css") else "application/javascript"
                return self.send(200, open(fp, "rb").read(), ctype, extra=[("Cache-Control", "max-age=86400")])
            return self.send(404, b"")
        m = re.match(r"^/tiles/([a-z_]+)/(\d+)/(\d+)/(\d+)$", path)
        if m:
            if not self.session():
                return self.send(401, b"")
            data = TILES.get(m.group(1), int(m.group(2)), int(m.group(3)), int(m.group(4)))
            if data is None:
                return self.send(404, b"")
            ctype = "image/png" if data[:4] == b"\x89PNG" else "image/jpeg"
            return self.send(200, data, ctype)
        if path in ("/api/export", "/api/survey"):
            if not self.session():
                return self.send(401, b'{"login":true}')
            if path == "/api/export":
                body, fname = clone_export(), "%s.turtletak" % re.sub(r"[^A-Za-z0-9_-]", "_", cfg("CALLSIGN"))
            else:
                fname, body, _ = survey_build()
            return self.send(200, body, "application/octet-stream",
                             extra=[("Content-Disposition", 'attachment; filename="%s"' % fname)])
        if path == "/api/log":
            if not self.session():
                return self.send(401, b'{"login":true}')
            with LOG_LOCK:
                return self.send(200, "\n".join(LOGQ[-250:]).encode(), "text/plain; charset=utf-8")
        self.send(404, b'{"error":"not found"}')

    def do_POST(self):
        path = self.path.split("?")[0]
        try:
            if path == "/api/login":
                d = json.loads(self.body() or b"{}")
                time.sleep(0.5)
                if check_pw(d.get("password", ""), cfg("WEB_PASS_HASH")):
                    sid = binascii.hexlify(os.urandom(16)).decode()
                    SESSIONS[sid] = time.time() + 12 * 3600
                    return self.send(200, b'{"ok":true}', extra=[("Set-Cookie", "tt_session=%s; HttpOnly; SameSite=Strict; Path=/" % sid)])
                log("web login failed from %s" % self.client_address[0], "warning")
                return self.send(403, b'{"error":"wrong password"}')
            if not self.session():
                return self.send(401, b'{"login":true}')
            if self.headers.get("X-TT") != "1":
                return self.send(403, b'{"error":"missing header"}')
            if path == "/api/logout":
                m = re.search(r"tt_session=([0-9a-f]{32})", self.headers.get("Cookie", ""))
                if m:
                    SESSIONS.pop(m.group(1), None)
                return self.send(200, b'{"ok":true}')
            if path == "/api/action":
                d = json.loads(self.body() or b"{}")
                return self.send(200, json.dumps({"ok": True, "msg": action(d.get("action"), d)}).encode())
            if path == "/api/cfg":
                d = json.loads(self.body() or b"{}")
                known = {k for k, v in DEFAULTS if v is not None} - {"WEB_PASS_HASH", "UID"}
                ch = {k: v for k, v in d.items() if k in known and not (k in SECRET_KEYS and v == "")}
                if "COT_TYPE" in ch:
                    ch["COT_TYPE"] = (ch["COT_TYPE"] or "").strip() or "a-f-G-E-S"
                    # only check a value that changed, so an older saved value never blocks other settings
                    if ch["COT_TYPE"] != cfg("COT_TYPE") and not COT_TYPE_RE.match(ch["COT_TYPE"]):
                        raise RuntimeError("marker type: a CoT type like a-f-G-E-S (a-, affiliation, -G or another dimension, then the rest)")
                if "TEAM" in ch:
                    ch["TEAM"] = team_name(ch["TEAM"])
                    if ch["TEAM"] != team_name(cfg("TEAM")) and ch["TEAM"] not in TEAM_COLORS:
                        raise RuntimeError("team color: one of " + ", ".join(TEAM_COLORS))
                cfg_set(ch)
                if set(ch) & {"TAK_HOST", "TAK_PORT", "TAK_PROTO", "TAK_VERIFY_HOST"}:
                    TAK.reconnect()
                if set(ch) & {"WIFI_SSID", "WIFI_KEY", "WIFI_ENC", "WG_CONF"}:
                    threading.Thread(target=uplinks_apply, daemon=True).start()
                if "LED" in ch:
                    LED_STATE["shown"] = None
                    led()
                if set(ch) & {"COT_TYPE", "TEAM", "ROLE", "CALLSIGN"}:
                    threading.Thread(target=lambda: TAK.send(sa_event()), daemon=True).start()
                log("settings changed in the web console: %s" % ", ".join(sorted(ch)))
                return self.send(200, json.dumps({"ok": True, "msg": "saved %d setting(s)" % len(ch)}).encode())
            if path == "/api/upload":
                name = os.path.basename(self.headers.get("X-Filename", "upload.bin"))
                name = re.sub(r"[^A-Za-z0-9._-]", "_", name)[:80]
                if name.lower().endswith(".turtletak"):
                    data = self.body(limit=64 * 1024 * 1024)
                    msg = clone_import(data, urllib.parse.unquote(self.headers.get("X-Callsign") or ""))
                    return self.send(200, json.dumps({"ok": True, "msg": msg}).encode())
                if not name.lower().endswith((".zip", ".p12", ".pfx", ".pem", ".key", ".conf")):
                    raise RuntimeError("upload a .zip connection package, .p12, .pem, .key, wg .conf or .turtletak clone")
                data = self.body(limit=8 * 1024 * 1024)
                dest = os.path.join(CERTS, name)
                if name.lower().endswith(".conf"):
                    dest = os.path.join(CERTS, "wg.conf")
                fd = os.open(dest, os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o600)
                with os.fdopen(fd, "wb") as fh:
                    fh.write(data)
                msg = "saved %s" % os.path.basename(dest)
                def hdr(k):
                    v = self.headers.get(k) or ""
                    return urllib.request.unquote(v) if v else None
                pw = hdr("X-Cert-Password")
                kind = (self.headers.get("X-Cert-Kind") or "").lower()
                if name.lower().endswith(".zip"):
                    import_package(dest, hdr("X-Client-Password"), hdr("X-CA-Password"))
                    TAK.reconnect()
                    msg = "connection package imported"
                elif name.lower().endswith((".p12", ".pfx")):
                    kind = kind if kind in ("client", "ca") else cert_kind(name)
                    setting = "CLIENT_PASSWORD" if kind == "client" else "CA_PASSWORD"
                    try:
                        used = p12_to_pem(dest, os.path.join(CERTS, kind + ".pem"), [pw, cfg(setting), "atakatak"],
                                          nokeys=(kind == "ca"))
                    except Exception:
                        os.unlink(dest)
                        raise
                    os.makedirs(os.path.join(CERTS, "imported"), exist_ok=True)
                    os.replace(dest, os.path.join(CERTS, "imported", name))
                    cfg_set({setting: used})
                    TAK.reconnect()
                    msg = "%s imported" % ("client certificate" if kind == "client" else "truststore")
                elif name.lower().endswith(".conf"):
                    cfg_set({"WG_CONF": dest})
                    msg = "; ".join(uplinks_apply())
                elif name.lower().endswith((".pem", ".key")):
                    if kind in ("client", "ca") and name.lower().endswith(".pem"):
                        text = open(dest).read()
                        os.unlink(dest)
                        save_cert_files(**{kind: text}, why=name)
                        msg = "saved as %s.pem" % kind
                    TAK.reconnect()
                return self.send(200, json.dumps({"ok": True, "msg": msg}).encode())
            self.send(404, b'{"error":"not found"}')
        except Exception as e:
            log("web %s: %s" % (path, e), "warning")
            self.send(400, json.dumps({"ok": False, "error": str(e)}).encode())


class WebServer(ThreadingMixIn, HTTPServer):
    daemon_threads = True
    allow_reuse_address = True


def web_run():
    if not cfgb("WEB"):
        return
    port = cfgi("WEB_PORT", 8484)
    if port == 1471:
        port = 8484
    try:
        srv = WebServer((cfg("WEB_BIND", "0.0.0.0"), port), Web)
    except OSError as e:
        log("web console could not use port %d: %s" % (port, e), "error")
        notify("error", "Web console port %d busy: %s" % (port, e))
        return
    scheme = "http"
    if cfgb("WEB_TLS") and have("openssl"):
        crt, key = os.path.join(BASE, "web.crt"), os.path.join(BASE, "web.key")
        if not os.path.exists(crt):
            run(["openssl", "req", "-x509", "-newkey", "rsa:2048", "-nodes", "-days", "3650", "-subj", "/CN=TurtleTAK",
                 "-keyout", key, "-out", crt], 120)
        ctx = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER)
        ctx.load_cert_chain(crt, key)
        srv.socket = ctx.wrap_socket(srv.socket, server_side=True)
        scheme = "https"
    log("web console on %s://<hub>:%d (all interfaces: %s)" % (scheme, port, cfg("WEB_BIND")))
    srv.serve_forever()


# ----------------------------------------------------------------------------------------------
def first_run_password():
    if cfg("WEB_PASS_HASH"):
        return
    pw = "".join(random.SystemRandom().choice("abcdefghjkmnpqrstuvwxyz23456789") for _ in range(10))
    cfg_set({"WEB_PASS_HASH": hash_pw(pw)})
    with open(os.path.join(BASE, "web-password.txt"), "w") as fh:
        fh.write("TurtleTAK web console first password: %s\nChange it in Setup > Web password, then delete this file.\n" % pw)
    os.chmod(os.path.join(BASE, "web-password.txt"), 0o600)
    notify("info", "Web console on port %s - first password: %s (change it in Setup)" % (cfg("WEB_PORT"), pw))
    log("web console first password written to %s/web-password.txt" % BASE)


def main():
    for d in (BASE, APP, CERTS, LOGS, BASELINES, LOOT):
        os.makedirs(d, exist_ok=True)
    os.chmod(CERTS, 0o700)
    cfg_load()
    load_state()
    log("%s %s %s starting (python %s)" % (PRODUCT, EDITION, VERSION, sys.version.split()[0]))
    led("SETUP")
    first_run_password()
    status_collect()
    if cfgb("RUN_AT_BOOT"):
        hub("BOOT_PAYLOAD", "enable")
    threading.Thread(target=uplinks_apply, daemon=True).start()
    scan_certs()
    locate()
    for target in (web_run, TAK.run, TAK.watchdog, sa_loop, housekeeping, Gps().run, WATCH.run, WATCH.dhcp_run,
                   WATCH.link_run, BRIDGE.run):
        threading.Thread(target=target, daemon=True, name=target.__name__).start()
    try:
        while True:
            time.sleep(3600)
    except KeyboardInterrupt:
        pass
    finally:
        save_state()
        hub("LED", "OFF") if not cfgb("LED") else None


if __name__ == "__main__":
    main()
TURTLETAK_PY
cat > "$APP/ttcrypto.py" <<'TTCRYPTO_PY'
# TurtleTAK certificate helpers in pure Python (stdlib only), for Hubs without openssl:
#   - RSA key generation + PKCS#10 CSR (for TAK Server enrollment)
#   - PKCS#12 (.p12) reader: PBES2 (PBKDF2 + AES-CBC) and legacy PKCS#12 PBE (3DES, RC2)
# Not a general crypto library: just enough for TAK client certificates.
import base64, hashlib, hmac, os, struct

# ---------------------------------------------------------------------------------------------
# DER
# ---------------------------------------------------------------------------------------------
def _len(n):
    if n < 0x80:
        return bytes([n])
    b = n.to_bytes((n.bit_length() + 7) // 8, "big")
    return bytes([0x80 | len(b)]) + b


def tlv(tag, body):
    return bytes([tag]) + _len(len(body)) + body


def d_int(v):
    b = v.to_bytes(max(1, (v.bit_length() + 8) // 8), "big", signed=False)
    if b[0] & 0x80:
        b = b"\0" + b
    while len(b) > 1 and b[0] == 0 and not b[1] & 0x80:
        b = b[1:]
    return tlv(0x02, b)


def d_seq(*items):
    return tlv(0x30, b"".join(items))


def d_set(*items):
    return tlv(0x31, b"".join(items))


def d_oid(s):
    p = [int(x) for x in s.split(".")]
    out = bytes([40 * p[0] + p[1]])
    for v in p[2:]:
        enc = [v & 0x7F]
        v >>= 7
        while v:
            enc.append(0x80 | (v & 0x7F))
            v >>= 7
        out += bytes(reversed(enc))
    return tlv(0x06, out)


def d_null():
    return b"\x05\x00"


def d_bits(b):
    return tlv(0x03, b"\0" + b)


def d_utf8(s):
    return tlv(0x0C, s.encode("utf-8"))


def d_printable(s):
    return tlv(0x13, s.encode("ascii"))


def parse(buf, i=0):
    """-> (tag, value_bytes, next_index)"""
    tag = buf[i]
    ln = buf[i + 1]
    i += 2
    if ln & 0x80:
        n = ln & 0x7F
        if n == 0:  # indefinite length (BER) - not used by the files we read
            raise ValueError("indefinite length")
        ln = int.from_bytes(buf[i:i + n], "big")
        i += n
    return tag, buf[i:i + ln], i + ln


def children(buf):
    out, i = [], 0
    while i < len(buf):
        t, v, i = parse(buf, i)
        out.append((t, v))
    return out


def oid_str(v):
    p = [v[0] // 40, v[0] % 40]
    acc = 0
    for b in v[1:]:
        acc = (acc << 7) | (b & 0x7F)
        if not b & 0x80:
            p.append(acc)
            acc = 0
    return ".".join(map(str, p))


def pem(kind, der):
    b = base64.b64encode(der).decode()
    return "-----BEGIN %s-----\n%s\n-----END %s-----\n" % (kind, "\n".join(b[i:i + 64] for i in range(0, len(b), 64)), kind)


# ---------------------------------------------------------------------------------------------
# RSA key + CSR
# ---------------------------------------------------------------------------------------------
_SMALL = [p for p in range(3, 2000, 2) if all(p % q for q in range(3, int(p ** .5) + 1, 2))]


def _probable_prime(n, rounds=24):
    for p in _SMALL:
        if n % p == 0:
            return n == p
    d, r = n - 1, 0
    while d % 2 == 0:
        d //= 2
        r += 1
    for _ in range(rounds):
        a = 2 + int.from_bytes(os.urandom(32), "big") % (n - 3)
        x = pow(a, d, n)
        if x in (1, n - 1):
            continue
        for _ in range(r - 1):
            x = pow(x, 2, n)
            if x == n - 1:
                break
        else:
            return False
    return True


def _prime(bits):
    while True:
        c = int.from_bytes(os.urandom(bits // 8), "big") | (3 << (bits - 2)) | 1
        if _probable_prime(c):
            return c


def rsa_generate(bits=2048, e=65537):
    while True:
        p, q = _prime(bits // 2), _prime(bits // 2)
        if p == q:
            continue
        phi = (p - 1) * (q - 1)
        if phi % e == 0:
            continue
        n = p * q
        if n.bit_length() != bits:
            continue
        d = pow(e, -1, phi)
        return {"n": n, "e": e, "d": d, "p": p, "q": q, "dp": d % (p - 1), "dq": d % (q - 1), "qi": pow(q, -1, p)}


def rsa_key_pem(k):
    der = d_seq(d_int(0), d_int(k["n"]), d_int(k["e"]), d_int(k["d"]), d_int(k["p"]), d_int(k["q"]),
                d_int(k["dp"]), d_int(k["dq"]), d_int(k["qi"]))
    return pem("RSA PRIVATE KEY", der)


def _rsa_sign_sha256(k, data):
    h = hashlib.sha256(data).digest()
    t = bytes.fromhex("3031300d060960864801650304020105000420") + h
    klen = (k["n"].bit_length() + 7) // 8
    em = b"\x00\x01" + b"\xff" * (klen - len(t) - 3) + b"\x00" + t
    m = int.from_bytes(em, "big")
    s1, s2 = pow(m, k["dp"], k["p"]), pow(m, k["dq"], k["q"])
    s = s2 + k["q"] * ((k["qi"] * (s1 - s2)) % k["p"])
    return s.to_bytes(klen, "big")


_NAME_OIDS = {"C": "2.5.4.6", "ST": "2.5.4.8", "L": "2.5.4.7", "O": "2.5.4.10", "OU": "2.5.4.11", "CN": "2.5.4.3"}


def csr_der(k, subject):
    """subject: list of (attr, value) e.g. [("O","TAK"),("OU","TAK"),("CN","user")]"""
    rdns = []
    for a, v in subject:
        oid = _NAME_OIDS.get(a.upper())
        if not oid:
            continue
        val = d_printable(v) if a.upper() == "C" else d_utf8(v)
        rdns.append(d_set(d_seq(d_oid(oid), val)))
    name = d_seq(*rdns)
    spki = d_seq(d_seq(d_oid("1.2.840.113549.1.1.1"), d_null()), d_bits(d_seq(d_int(k["n"]), d_int(k["e"]))))
    info = d_seq(d_int(0), name, spki, b"\xa0\x00")
    sig = _rsa_sign_sha256(k, info)
    return d_seq(info, d_seq(d_oid("1.2.840.113549.1.1.11"), d_null()), d_bits(sig))


# ---------------------------------------------------------------------------------------------
# AES (decrypt only, CBC)
# ---------------------------------------------------------------------------------------------
def _aes_tables():
    sbox = [0] * 256
    p = q = 1
    while True:
        p = p ^ ((p << 1) & 0xFF) ^ (0x1B if p & 0x80 else 0)
        q ^= q << 1
        q ^= q << 2
        q ^= q << 4
        q &= 0xFF
        if q & 0x80:
            q ^= 0x09
        x = q ^ ((q << 1) | (q >> 7)) ^ ((q << 2) | (q >> 6)) ^ ((q << 3) | (q >> 5)) ^ ((q << 4) | (q >> 4))
        sbox[p] = (x ^ 0x63) & 0xFF
        if p == 1:
            break
    sbox[0] = 0x63
    inv = [0] * 256
    for i, v in enumerate(sbox):
        inv[v] = i
    return sbox, inv


_SBOX, _INV = _aes_tables()


def _xt(a):
    return ((a << 1) ^ 0x1B) & 0xFF if a & 0x80 else a << 1


def _mul(a, b):
    r = 0
    while b:
        if b & 1:
            r ^= a
        a = _xt(a)
        b >>= 1
    return r


_M9 = [_mul(i, 9) for i in range(256)]
_M11 = [_mul(i, 11) for i in range(256)]
_M13 = [_mul(i, 13) for i in range(256)]
_M14 = [_mul(i, 14) for i in range(256)]


def _expand(key):
    nk = len(key) // 4
    nr = nk + 6
    w = [list(key[4 * i:4 * i + 4]) for i in range(nk)]
    rcon = 1
    for i in range(nk, 4 * (nr + 1)):
        t = list(w[i - 1])
        if i % nk == 0:
            t = t[1:] + t[:1]
            t = [_SBOX[b] for b in t]
            t[0] ^= rcon
            rcon = _xt(rcon)
        elif nk > 6 and i % nk == 4:
            t = [_SBOX[b] for b in t]
        w.append([a ^ b for a, b in zip(w[i - nk], t)])
    return [sum(w[4 * r:4 * r + 4], []) for r in range(nr + 1)], nr


def _aes_decrypt_block(rk, nr, blk):
    s = [b ^ k for b, k in zip(blk, rk[nr])]
    for rnd in range(nr - 1, -1, -1):
        # inverse shift rows (column-major state)
        s = [s[((c - r) % 4) * 4 + r] for c in range(4) for r in range(4)]
        s = [_INV[b] for b in s]
        s = [b ^ k for b, k in zip(s, rk[rnd])]
        if rnd:
            o = []
            for c in range(4):
                a0, a1, a2, a3 = s[4 * c:4 * c + 4]
                o += [_M14[a0] ^ _M11[a1] ^ _M13[a2] ^ _M9[a3], _M9[a0] ^ _M14[a1] ^ _M11[a2] ^ _M13[a3],
                      _M13[a0] ^ _M9[a1] ^ _M14[a2] ^ _M11[a3], _M11[a0] ^ _M13[a1] ^ _M9[a2] ^ _M14[a3]]
            s = o
    return bytes(s)


def aes_cbc_decrypt(key, iv, data):
    rk, nr = _expand(key)
    out, prev = bytearray(), iv
    for i in range(0, len(data), 16):
        blk = data[i:i + 16]
        out += bytes(a ^ b for a, b in zip(_aes_decrypt_block(rk, nr, blk), prev))
        prev = blk
    return _unpad(bytes(out), 16)


def _unpad(b, bs):
    n = b[-1] if b else 0
    if not 1 <= n <= bs or b[-n:] != bytes([n]) * n:
        raise ValueError("bad padding (wrong password?)")
    return b[:-n]


# ---------------------------------------------------------------------------------------------
# DES / 3DES (decrypt, CBC) - legacy PKCS#12
# ---------------------------------------------------------------------------------------------
_PC1 = [57, 49, 41, 33, 25, 17, 9, 1, 58, 50, 42, 34, 26, 18, 10, 2, 59, 51, 43, 35, 27, 19, 11, 3, 60, 52, 44, 36,
        63, 55, 47, 39, 31, 23, 15, 7, 62, 54, 46, 38, 30, 22, 14, 6, 61, 53, 45, 37, 29, 21, 13, 5, 28, 20, 12, 4]
_PC2 = [14, 17, 11, 24, 1, 5, 3, 28, 15, 6, 21, 10, 23, 19, 12, 4, 26, 8, 16, 7, 27, 20, 13, 2,
        41, 52, 31, 37, 47, 55, 30, 40, 51, 45, 33, 48, 44, 49, 39, 56, 34, 53, 46, 42, 50, 36, 29, 32]
_SHIFTS = [1, 1, 2, 2, 2, 2, 2, 2, 1, 2, 2, 2, 2, 2, 2, 1]
_IP = [58, 50, 42, 34, 26, 18, 10, 2, 60, 52, 44, 36, 28, 20, 12, 4, 62, 54, 46, 38, 30, 22, 14, 6, 64, 56, 48, 40, 32, 24, 16, 8,
       57, 49, 41, 33, 25, 17, 9, 1, 59, 51, 43, 35, 27, 19, 11, 3, 61, 53, 45, 37, 29, 21, 13, 5, 63, 55, 47, 39, 31, 23, 15, 7]
_FP = [40, 8, 48, 16, 56, 24, 64, 32, 39, 7, 47, 15, 55, 23, 63, 31, 38, 6, 46, 14, 54, 22, 62, 30, 37, 5, 45, 13, 53, 21, 61, 29,
       36, 4, 44, 12, 52, 20, 60, 28, 35, 3, 43, 11, 51, 19, 59, 27, 34, 2, 42, 10, 50, 18, 58, 26, 33, 1, 41, 9, 49, 17, 57, 25]
_E = [32, 1, 2, 3, 4, 5, 4, 5, 6, 7, 8, 9, 8, 9, 10, 11, 12, 13, 12, 13, 14, 15, 16, 17,
      16, 17, 18, 19, 20, 21, 20, 21, 22, 23, 24, 25, 24, 25, 26, 27, 28, 29, 28, 29, 30, 31, 32, 1]
_P = [16, 7, 20, 21, 29, 12, 28, 17, 1, 15, 23, 26, 5, 18, 31, 10, 2, 8, 24, 14, 32, 27, 3, 9, 19, 13, 30, 6, 22, 11, 4, 25]
_S = [
    [14, 4, 13, 1, 2, 15, 11, 8, 3, 10, 6, 12, 5, 9, 0, 7, 0, 15, 7, 4, 14, 2, 13, 1, 10, 6, 12, 11, 9, 5, 3, 8,
     4, 1, 14, 8, 13, 6, 2, 11, 15, 12, 9, 7, 3, 10, 5, 0, 15, 12, 8, 2, 4, 9, 1, 7, 5, 11, 3, 14, 10, 0, 6, 13],
    [15, 1, 8, 14, 6, 11, 3, 4, 9, 7, 2, 13, 12, 0, 5, 10, 3, 13, 4, 7, 15, 2, 8, 14, 12, 0, 1, 10, 6, 9, 11, 5,
     0, 14, 7, 11, 10, 4, 13, 1, 5, 8, 12, 6, 9, 3, 2, 15, 13, 8, 10, 1, 3, 15, 4, 2, 11, 6, 7, 12, 0, 5, 14, 9],
    [10, 0, 9, 14, 6, 3, 15, 5, 1, 13, 12, 7, 11, 4, 2, 8, 13, 7, 0, 9, 3, 4, 6, 10, 2, 8, 5, 14, 12, 11, 15, 1,
     13, 6, 4, 9, 8, 15, 3, 0, 11, 1, 2, 12, 5, 10, 14, 7, 1, 10, 13, 0, 6, 9, 8, 7, 4, 15, 14, 3, 11, 5, 2, 12],
    [7, 13, 14, 3, 0, 6, 9, 10, 1, 2, 8, 5, 11, 12, 4, 15, 13, 8, 11, 5, 6, 15, 0, 3, 4, 7, 2, 12, 1, 10, 14, 9,
     10, 6, 9, 0, 12, 11, 7, 13, 15, 1, 3, 14, 5, 2, 8, 4, 3, 15, 0, 6, 10, 1, 13, 8, 9, 4, 5, 11, 12, 7, 2, 14],
    [2, 12, 4, 1, 7, 10, 11, 6, 8, 5, 3, 15, 13, 0, 14, 9, 14, 11, 2, 12, 4, 7, 13, 1, 5, 0, 15, 10, 3, 9, 8, 6,
     4, 2, 1, 11, 10, 13, 7, 8, 15, 9, 12, 5, 6, 3, 0, 14, 11, 8, 12, 7, 1, 14, 2, 13, 6, 15, 0, 9, 10, 4, 5, 3],
    [12, 1, 10, 15, 9, 2, 6, 8, 0, 13, 3, 4, 14, 7, 5, 11, 10, 15, 4, 2, 7, 12, 9, 5, 6, 1, 13, 14, 0, 11, 3, 8,
     9, 14, 15, 5, 2, 8, 12, 3, 7, 0, 4, 10, 1, 13, 11, 6, 4, 3, 2, 12, 9, 5, 15, 10, 11, 14, 1, 7, 6, 0, 8, 13],
    [4, 11, 2, 14, 15, 0, 8, 13, 3, 12, 9, 7, 5, 10, 6, 1, 13, 0, 11, 7, 4, 9, 1, 10, 14, 3, 5, 12, 2, 15, 8, 6,
     1, 4, 11, 13, 12, 3, 7, 14, 10, 15, 6, 8, 0, 5, 9, 2, 6, 11, 13, 8, 1, 4, 10, 7, 9, 5, 0, 15, 14, 2, 3, 12],
    [13, 2, 8, 4, 6, 15, 11, 1, 10, 9, 3, 14, 5, 0, 12, 7, 1, 15, 13, 8, 10, 3, 7, 4, 12, 5, 6, 11, 0, 14, 9, 2,
     7, 11, 4, 1, 9, 12, 14, 2, 0, 6, 10, 13, 15, 3, 5, 8, 2, 1, 14, 7, 4, 10, 8, 13, 15, 12, 9, 0, 3, 5, 6, 11]]


def _perm(v, table, nbits):
    o = 0
    for t in table:
        o = (o << 1) | ((v >> (nbits - t)) & 1)
    return o


def _des_keys(key8):
    k = _perm(int.from_bytes(key8, "big"), _PC1, 64)
    c, d = k >> 28, k & 0xFFFFFFF
    ks = []
    for s in _SHIFTS:
        c = ((c << s) | (c >> (28 - s))) & 0xFFFFFFF
        d = ((d << s) | (d >> (28 - s))) & 0xFFFFFFF
        ks.append(_perm((c << 28) | d, _PC2, 56))
    return ks


def _des_block(ks, blk, decrypt):
    v = _perm(int.from_bytes(blk, "big"), _IP, 64)
    l, r = v >> 32, v & 0xFFFFFFFF
    for k in (reversed(ks) if decrypt else ks):
        x = _perm(r, _E, 32) ^ k
        f = 0
        for i in range(8):
            six = (x >> (42 - 6 * i)) & 0x3F
            f = (f << 4) | _S[i][((six & 0x20) >> 4 | (six & 1)) * 16 + ((six >> 1) & 0xF)]
        l, r = r, l ^ _perm(f, _P, 32)
    return _perm((r << 32) | l, _FP, 64).to_bytes(8, "big")


def des3_cbc_decrypt(key, iv, data):
    k1, k2, k3 = _des_keys(key[:8]), _des_keys(key[8:16]), _des_keys(key[16:24])
    out, prev = bytearray(), iv
    for i in range(0, len(data), 8):
        blk = data[i:i + 8]
        p = _des_block(k1, _des_block(k2, _des_block(k3, blk, True), False), True)
        out += bytes(a ^ b for a, b in zip(p, prev))
        prev = blk
    return _unpad(bytes(out), 8)


# ---------------------------------------------------------------------------------------------
# RC2 (decrypt, CBC) - legacy PKCS#12 certificate bags (RC2-40 / RC2-128)
# ---------------------------------------------------------------------------------------------
_PITABLE = bytes.fromhex(
    "d978f9c419ddb5ed28e9fd794aa0d89dc67e37832b76538e624c6488448bfba2179a59f587b34f1361456d8d09817d32"
    "bd8f40eb86b77b0bf09521225c6b4e8254d66593ce60b21c7356c014a78cf1dc1275ca1f3bbee4d1423dd430a33cb626"
    "6fbf0eda4669075727f21d9bbc944303f811c7f690ef3ee706c3d52fc8661ed708e8eade8052eef784aa72ac354d6a2a"
    "961ad2715a1549744b9fd05e0418a4ecc2e0416e0f51cbcc2491af50a1f47039997c3a8523b8b47afc02365b25559731"
    "2d5dfa98e38a92ae05df2910676cbac9d300e6cfe19ea82c6316013f58e289a90d38341bab33ffb0bb480c5fb9b1cd2e"
    "c5f3db47e5a59c770aa62068fe7fc1ad")


def _rc2_keyexp(key, bits):
    L = bytearray(key) + bytearray(128 - len(key))
    T = len(key)
    for i in range(T, 128):
        L[i] = _PITABLE[(L[i - 1] + L[i - T]) & 0xFF]
    T8 = (bits + 7) // 8
    TM = 0xFF % (1 << (8 + bits - 8 * T8))
    L[128 - T8] = _PITABLE[L[128 - T8] & TM]
    for i in range(127 - T8, -1, -1):
        L[i] = _PITABLE[L[i + 1] ^ L[i + T8]]
    return [L[2 * i] | (L[2 * i + 1] << 8) for i in range(64)]


def _rc2_decrypt_block(K, blk):
    R = list(struct.unpack("<4H", blk))
    s = [1, 2, 3, 5]
    j = 63
    for rnd in range(16):
        for i in (3, 2, 1, 0):
            R[i] = ((R[i] >> s[i]) | (R[i] << (16 - s[i]))) & 0xFFFF
            R[i] = (R[i] - K[j] - (R[(i - 1) % 4] & R[(i - 2) % 4]) - (~R[(i - 1) % 4] & R[(i - 3) % 4])) & 0xFFFF
            j -= 1
        if rnd in (4, 10):
            for i in (3, 2, 1, 0):
                R[i] = (R[i] - K[R[(i - 1) % 4] & 63]) & 0xFFFF
    return struct.pack("<4H", *R)


def rc2_cbc_decrypt(key, iv, data, bits):
    K = _rc2_keyexp(key, bits)
    out, prev = bytearray(), iv
    for i in range(0, len(data), 8):
        blk = data[i:i + 8]
        out += bytes(a ^ b for a, b in zip(_rc2_decrypt_block(K, blk), prev))
        prev = blk
    return _unpad(bytes(out), 8)


# ---------------------------------------------------------------------------------------------
# PKCS#12
# ---------------------------------------------------------------------------------------------
def _p12_kdf(pw_bmp, salt, iters, id_byte, n, hname="sha1"):
    """RFC 7292 appendix B.2"""
    h = getattr(hashlib, hname)
    u, v = h().digest_size, 64
    D = bytes([id_byte]) * v
    fill = lambda b: (b * ((v * ((len(b) + v - 1) // v)) // len(b) + 1))[:v * ((len(b) + v - 1) // v)] if b else b""
    I = bytearray(fill(salt) + fill(pw_bmp))
    out = b""
    while len(out) < n:
        A = h(D + bytes(I)).digest()
        for _ in range(iters - 1):
            A = h(A).digest()
        out += A
        B = (A * (v // u + 1))[:v]
        Bn = int.from_bytes(B, "big")
        for j in range(0, len(I), v):
            x = (int.from_bytes(I[j:j + v], "big") + Bn + 1) % (1 << (8 * v))
            I[j:j + v] = x.to_bytes(v, "big")
    return out[:n]


_HMAC = {"1.2.840.113549.2.7": "sha1", "1.2.840.113549.2.9": "sha256", "1.2.840.113549.2.10": "sha384",
         "1.2.840.113549.2.11": "sha512", "1.2.840.113549.2.8": "sha224"}
_AES = {"2.16.840.1.101.3.4.1.2": 16, "2.16.840.1.101.3.4.1.22": 24, "2.16.840.1.101.3.4.1.42": 32}


def _decrypt(alg, data, password):
    """alg = AlgorithmIdentifier bytes (SEQUENCE body)"""
    items = children(alg)
    oid = oid_str(items[0][1])
    pw_utf8 = password.encode("utf-8")
    pw_bmp = (password + "\0").encode("utf-16-be")
    if oid == "1.2.840.113549.1.5.13":  # PBES2
        kdf, enc = children(items[1][1])
        kdf_items = children(kdf[1])
        if oid_str(kdf_items[0][1]) != "1.2.840.113549.1.5.12":
            raise ValueError("unsupported key derivation")
        prm = children(kdf_items[1][1])
        salt = prm[0][1]
        iters = int.from_bytes(prm[1][1], "big")
        prf = "sha1"
        keylen = None
        for t, v in prm[2:]:
            if t == 0x02:
                keylen = int.from_bytes(v, "big")
            elif t == 0x30:
                prf = _HMAC.get(oid_str(children(v)[0][1]), "sha1")
        enc_items = children(enc[1])
        eoid = oid_str(enc_items[0][1])
        iv = enc_items[1][1]
        if eoid in _AES:
            kl = keylen or _AES[eoid]
            last = None
            for pw in (pw_utf8, pw_bmp[:-2]):
                try:
                    key = hashlib.pbkdf2_hmac(prf, pw, salt, iters, kl)
                    return aes_cbc_decrypt(key, iv, data)
                except ValueError as e:
                    last = e
            raise last
        if eoid == "1.2.840.113549.3.7":  # des-ede3-cbc
            key = hashlib.pbkdf2_hmac(prf, pw_utf8, salt, iters, 24)
            return des3_cbc_decrypt(key, iv, data)
        raise ValueError("unsupported cipher %s" % eoid)
    legacy = {"1.2.840.113549.1.12.1.3": ("3des", 24), "1.2.840.113549.1.12.1.4": ("2des", 16),
              "1.2.840.113549.1.12.1.5": ("rc2", 16), "1.2.840.113549.1.12.1.6": ("rc2", 5)}
    if oid in legacy:
        kind, kl = legacy[oid]
        prm = children(items[1][1])
        salt, iters = prm[0][1], int.from_bytes(prm[1][1], "big")
        key = _p12_kdf(pw_bmp, salt, iters, 1, kl)
        iv = _p12_kdf(pw_bmp, salt, iters, 2, 8)
        if kind == "3des":
            return des3_cbc_decrypt(key, iv, data)
        if kind == "2des":
            return des3_cbc_decrypt(key + key[:8], iv, data)
        return rc2_cbc_decrypt(key, iv, data, kl * 8)
    raise ValueError("unsupported encryption %s" % oid)


def _check_mac(pfx_items, auth_content, password):
    if len(pfx_items) < 3:
        return
    mac = children(pfx_items[2][1])
    digest_info = children(mac[0][1])
    alg = oid_str(children(digest_info[0][1])[0][1])
    want = digest_info[1][1]
    salt = mac[1][1]
    iters = int.from_bytes(mac[2][1], "big") if len(mac) > 2 else 1
    hname = {"1.3.14.3.2.26": "sha1", "2.16.840.1.101.3.4.2.1": "sha256", "2.16.840.1.101.3.4.2.2": "sha384",
             "2.16.840.1.101.3.4.2.3": "sha512"}.get(alg)
    if not hname:
        return
    n = hashlib.new(hname).digest_size
    for pw in ((password + "\0").encode("utf-16-be"), password.encode("utf-8")):
        key = _p12_kdf(pw, salt, iters, 3, n, hname)
        if hmac.compare_digest(hmac.new(key, auth_content, hname).digest(), want):
            return
    raise ValueError("wrong password for this .p12 (the integrity check failed)")


def read_p12(data, password):
    """-> (key_pem or None, [cert_pem, ...]). Raises ValueError with a readable reason."""
    try:
        t, pfx, _ = parse(data)
        items = children(pfx)
        ci = children(items[1][1])
        if oid_str(ci[0][1]) != "1.2.840.113549.1.7.1":
            raise ValueError("public-key protected .p12 files are not supported")
        auth_content = children(ci[1][1])[0][1]
    except (IndexError, ValueError) as e:
        if "supported" in str(e):
            raise
        raise ValueError("not a .p12 file (%s)" % e)
    _check_mac(items, auth_content, password)
    keys, certs = [], []

    def bags(safe_contents):
        for t, bag in children(parse(safe_contents)[1]):
            b = children(bag)
            bag_id = oid_str(b[0][1])
            val = children(b[1][1])[0]
            if bag_id == "1.2.840.113549.1.12.10.1.1":  # keyBag
                keys.append(tlv(val[0], val[1]))
            elif bag_id == "1.2.840.113549.1.12.10.1.2":  # pkcs8ShroudedKeyBag
                epki = children(val[1])
                keys.append(_decrypt(epki[0][1], epki[1][1], password))
            elif bag_id == "1.2.840.113549.1.12.10.1.3":  # certBag
                cb = children(val[1])
                if oid_str(cb[0][1]) == "1.2.840.113549.1.9.22.1":
                    certs.append(children(cb[1][1])[0][1])

    for t, ci in children(parse(auth_content)[1]):
        c = children(ci)
        ctype = oid_str(c[0][1])
        if ctype == "1.2.840.113549.1.7.1":
            bags(children(c[1][1])[0][1])
        elif ctype == "1.2.840.113549.1.7.6":
            ed = children(children(c[1][1])[0][1])
            eci = children(ed[1][1])
            alg = eci[1][1]
            enc = eci[2][1]
            if eci[2][0] == 0xA0:     # constructed [0]: concatenated OCTET STRINGs
                enc = b"".join(v for _, v in children(enc))
            bags(_decrypt(alg, enc, password))
    return (pem("PRIVATE KEY", keys[0]) if keys else None), [pem("CERTIFICATE", c) for c in certs]


def _rsa_n_from_cert(der):
    tbs = children(children(parse(der)[1])[0][1])
    off = 1 if tbs[0][0] == 0xA0 else 0
    spki = children(tbs[5 + off][1])
    pub = parse(spki[1][1][1:])[1]          # BIT STRING minus the unused-bits byte
    return int.from_bytes(children(pub)[0][1], "big")


def _rsa_n_from_key_pem(key_pem):
    der = base64.b64decode("".join(l for l in key_pem.splitlines() if not l.startswith("-----")))
    items = children(parse(der)[1])
    if items[0][0] == 0x02 and len(items) >= 3 and items[1][0] == 0x30:   # PKCS#8
        items = children(parse(items[2][1])[1])
    return int.from_bytes(items[1][1], "big")


def split_chain(key_pem, cert_pems):
    """-> (leaf_pem or None, [other cert pems]) - the leaf is the cert matching the private key."""
    if not key_pem:
        return None, list(cert_pems)
    try:
        n = _rsa_n_from_key_pem(key_pem)
    except Exception:
        return (cert_pems[0] if cert_pems else None), list(cert_pems[1:])
    leaf, rest = None, []
    for c in cert_pems:
        der = base64.b64decode("".join(l for l in c.splitlines() if not l.startswith("-----")))
        try:
            match = _rsa_n_from_cert(der) == n
        except Exception:
            match = False
        if match and leaf is None:
            leaf = c
        else:
            rest.append(c)
    return leaf, rest
TTCRYPTO_PY
mkdir -p "$APP/static"
# Leaflet 1.9.4 (BSD-2-Clause, see THIRD-PARTY-LICENSES.txt), gzip + base64
"$PY" -c 'import base64,sys,zlib;open(sys.argv[1],"wb").write(zlib.decompress(base64.b64decode(sys.stdin.read()),31))' "$APP/static/leaflet.js" <<'LEAFLET_JS'
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
LEAFLET_JS
"$PY" -c 'import base64,sys,zlib;open(sys.argv[1],"wb").write(zlib.decompress(base64.b64decode(sys.stdin.read()),31))' "$APP/static/leaflet.css" <<'LEAFLET_CSS'
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
LEAFLET_CSS
cat > "$APP/index.html" <<'TURTLETAK_HTML'
<!DOCTYPE html>
<html lang="en">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>TurtleTAK Hub Edition</title>
<style>
:root{--bg:#0f1411;--panel:#17201a;--line:#2a3a2f;--text:#dfe8e1;--dim:#8fa396;--acc:#6fcf4a;--warn:#f2b631;--crit:#ff5c5c;--info:#4fb3ff}
*{box-sizing:border-box}
body{margin:0;background:var(--bg);color:var(--text);font:14px/1.45 system-ui,-apple-system,"Segoe UI",Roboto,sans-serif}
header{display:flex;align-items:center;gap:12px;padding:10px 16px;background:#0a0e0b;border-bottom:1px solid var(--line);flex-wrap:wrap}
header h1{font-size:17px;margin:0;letter-spacing:.5px}
header h1 b{color:var(--acc)}
header .ed{color:var(--dim);font-size:12px}
.pill{padding:2px 9px;border-radius:10px;font-size:12px;border:1px solid var(--line);white-space:nowrap}
.pill.ok{color:#0a0e0b;background:var(--acc);border-color:var(--acc)}
.pill.bad{color:#fff;background:#8a2a2a;border-color:#a33}
.pill.mid{color:#0a0e0b;background:var(--warn);border-color:var(--warn)}
nav{display:flex;gap:2px;padding:0 10px;background:#0a0e0b;border-bottom:1px solid var(--line);overflow-x:auto}
nav button{background:none;border:0;color:var(--dim);padding:10px 14px;cursor:pointer;font-size:14px;border-bottom:2px solid transparent;white-space:nowrap}
nav button.on{color:var(--text);border-bottom-color:var(--acc)}
nav .n{background:var(--crit);color:#fff;border-radius:8px;padding:0 6px;font-size:11px;margin-left:4px}
main{padding:14px;max-width:1200px;margin:auto}
section{display:none}section.on{display:block}
.grid{display:grid;grid-template-columns:repeat(auto-fit,minmax(260px,1fr));gap:12px}
.card{background:var(--panel);border:1px solid var(--line);border-radius:8px;padding:12px 14px}
.card h3{margin:0 0 8px;font-size:13px;text-transform:uppercase;letter-spacing:.6px;color:var(--dim)}
.kv{display:grid;grid-template-columns:auto minmax(0,1fr);gap:3px 12px}.kv div{overflow-wrap:anywhere}.kv div:nth-child(odd){color:var(--dim)}
table{width:100%;border-collapse:collapse;font-size:13px}th,td{text-align:left;padding:5px 6px;border-bottom:1px solid var(--line);vertical-align:top}
th{color:var(--dim);font-weight:500}
button.b,.b{background:#24402c;color:var(--text);border:1px solid #356b43;border-radius:6px;padding:6px 12px;cursor:pointer;font-size:13px}
button.b:hover{background:#2e5537}button.b.red{background:#4a2020;border-color:#7a3030}
input,select,textarea{background:#0c110e;color:var(--text);border:1px solid var(--line);border-radius:5px;padding:6px 8px;font:inherit}
input:focus,select:focus,textarea:focus{outline:1px solid var(--acc)}
.row{display:flex;gap:8px;align-items:center;flex-wrap:wrap;margin:6px 0}
.dim{color:var(--dim)}.warn{color:var(--warn)}.crit{color:var(--crit)}.ok{color:var(--acc)}
.alert{background:var(--panel);border:1px solid var(--line);border-radius:6px;padding:8px 12px;margin-bottom:6px}
.alert.lvl-critical{border-left:4px solid var(--crit)}.alert.lvl-warning{border-left:4px solid var(--warn)}.alert.lvl-info{border-left:4px solid var(--info)}
input[type=file]{max-width:100%}
.seg{display:inline-flex;border:1px solid var(--line);border-radius:6px;overflow:hidden;margin-bottom:8px}
.seg button{background:#0c110e;color:var(--dim);border:0;padding:6px 12px;cursor:pointer}.seg button.on{background:#24402c;color:var(--text)}
.frm{display:grid;grid-template-columns:minmax(150px,190px) minmax(0,420px);gap:6px 10px;align-items:center;margin:8px 0}
details{margin:6px 0}
#map{height:62vh;border-radius:8px;border:1px solid var(--line);background:#0c110e}
.chatlog{height:52vh;overflow-y:auto;background:#0c110e;border:1px solid var(--line);border-radius:8px;padding:8px}
.msg{white-space:pre-wrap;margin:4px 0;padding:6px 10px;border-radius:8px;max-width:80%;background:#1f2b23}
.msg.out{margin-left:auto;background:#244a2f}.msg .h{font-size:11px;color:var(--dim)}
.msg .h a{color:var(--acc)}.msg .del{float:right;margin-left:8px;color:var(--dim);cursor:pointer;text-decoration:none}.msg .del:hover{color:var(--crit)}
pre{white-space:pre-wrap;background:#0c110e;border:1px solid var(--line);border-radius:6px;padding:8px;font-size:12px;max-height:60vh;overflow:auto}
.cfg{display:grid;grid-template-columns:minmax(160px,220px) 1fr;gap:4px 10px;align-items:center}
.cfg h4{grid-column:1/3;margin:14px 0 2px;color:var(--acc);font-size:13px}
.toast{position:fixed;bottom:16px;right:16px;background:#24402c;border:1px solid var(--acc);padding:9px 14px;border-radius:6px;display:none;max-width:80vw;z-index:9999}
.toast.err{background:#4a2020;border-color:var(--crit)}
#login{max-width:340px;margin:12vh auto;text-align:center}
.tag{font-size:11px;padding:1px 6px;border-radius:4px;background:#2a3a2f}.tag.new{background:var(--warn);color:#111}
.wide{grid-column:span 2}@media(max-width:760px){.wide{grid-column:auto}}
footer{color:var(--dim);font-size:12px;text-align:center;padding:20px}
</style>
</head>
<body>
<div id="login" style="display:none" class="card">
  <h2>Turtle<b style="color:var(--acc)">TAK</b></h2><p class="dim">Hub Edition web console</p>
  <form onsubmit="login(event)"><input type="password" id="pw" placeholder="Password" autofocus style="width:100%"><br><br>
  <button class="b" style="width:100%">Sign in</button></form>
  <p class="dim" style="font-size:12px">First password: Hub notifications (bell icon) or /root/turtletak/web-password.txt</p>
</div>
<div id="app" style="display:none">
<header>
  <h1>Turtle<b>TAK</b></h1><span class="ed" id="ed">Hub Edition</span>
  <span class="pill" id="p-tak">TAK</span><span class="pill" id="p-rj">RJ45</span><span class="pill" id="p-loc">Location</span>
  <span style="flex:1"></span><a id="tm-link" class="b" style="display:none" target="_blank">TurtleMesh console</a><span class="dim" id="h-cs"></span>
  <button class="b" onclick="logout()">Sign out</button>
</header>
<nav id="nav"></nav>
<main>
<section id="t-status">
  <div class="grid">
    <div class="card"><h3>TAK Server</h3><div class="kv" id="k-tak"></div>
      <div class="row"><button class="b" onclick="act('reconnect')">Reconnect</button><button class="b" onclick="act('send_sa')">Send position now</button></div></div>
    <div class="card"><h3>Network</h3><div class="kv" id="k-net"></div></div>
    <div class="card"><h3>Location</h3><div class="kv" id="k-loc"></div></div>
    <div class="card"><h3>Hub</h3><div class="kv" id="k-hub"></div></div>
  </div>
  <div class="card" style="margin-top:12px"><h3>What TAK sees (marker remarks)</h3><pre id="remarks"></pre></div>
</section>
<section id="t-map">
  <div class="row"><select id="mp-src" onchange="setCfg({MAP_SOURCE:this.value});mapSource(this.value)"></select>
    <label class="dim">Save to zoom</label><select id="mp-z"><option>13</option><option>14</option><option selected>15</option><option>16</option></select>
    <button class="b" onclick="saveArea()">Save this area offline</button><button class="b" onclick="act('tiles_stop')">Stop</button>
    <button class="b red" onclick="if(confirm('Delete every saved map tile on the Hub?'))act('tiles_clear')">Clear saved maps</button><span class="dim" id="mp-st"></span></div>
  <div id="map"></div>
  <p class="dim" id="mapnote">Click the map to place the Hub there (manual location). Map tiles come through the Hub and are kept there, so places you have viewed or saved work without internet. USGS maps cover the US.</p>
  <div class="card"><h3>Contacts (range and bearing from the Hub)</h3><table id="tb-contacts"></table></div>
</section>
<section id="t-chat">
  <div class="chatlog" id="chatlog"></div>
  <form class="row" onsubmit="sendChat(event)">
    <select id="chat-to"><option value="">All Chat Rooms</option></select>
    <input id="chat-text" style="flex:1;min-width:200px" placeholder="Message" maxlength="1000">
    <button class="b">Send</button>
    <button type="button" class="b red" onclick="if(confirm('Clear the whole chat on the Hub?'))act('chat_clear')">Clear chat</button>
  </form>
  <p class="dim">Click a name or <b>Reply</b> to answer that person directly, and &times; to delete a message. Anyone who has messaged the Hub stays in the list. Others can direct-message the Hub: <b>status</b>, <b>where</b>, <b>scan</b>, <b>alerts</b>, <b>help</b>.</p>
</section>
<section id="t-alerts">
  <div class="card" style="margin-bottom:12px"><h3>Alert settings</h3>
    <div class="row" id="al-kinds"></div>
    <div class="frm"><label>Map marker from</label><select id="al-marker"><option value="info">info</option><option value="warning">warning</option><option value="critical">critical</option></select>
      <label>Chat line from</label><select id="al-chat"><option value="info">info</option><option value="warning">warning</option><option value="critical">critical</option></select>
      <label>Send alerts to</label><select id="al-to"><option value="">All Chat Rooms</option></select>
      <label>Over LoRa (mesh)</label><span id="al-lora"></span>
      <label>Quiet hours</label><div class="row" style="margin:0"><input id="al-quiet" placeholder="e.g. 22-06 (blank = off)" size="16"><label><input type="checkbox" id="al-qcrit"> critical alerts still go out</label></div></div>
    <p class="dim">In quiet hours alerts are still logged, marked on the map and shown in the Hub's notifications, but there are no chat lines or LED flashes.</p>
    <div class="row"><button class="b" onclick="saveAlertCfg()">Save alert settings</button><span class="dim" id="al-qnow"></span></div></div>
  <div class="row"><button class="b" onclick="act('test_alert')">Send test alert</button><button class="b red" onclick="if(confirm('Clear the alert list on the Hub?'))act('clear_alerts')">Clear list</button></div>
  <div id="alertlist"></div>
</section>
<section id="t-network">
  <div class="grid"><div class="card"><h3>Watch</h3><div class="kv" id="k-watch"></div>
    <div class="row"><button class="b" onclick="act('scan')">Sweep now</button><button class="b" onclick="act('dhcp')">Check DHCP now</button>
    <button class="b" onclick="if(confirm('Mark every device seen as known (update the baseline)?'))act('accept')">Accept all as known</button></div></div>
    <div class="card"><h3>Site survey data package</h3><p class="dim">Device list, baseline, alerts and a summary, as a TAK data package with a survey marker at the Hub.</p>
      <div class="row"><select id="sv-to"><option value="">Send to everyone</option><option value="upload">Upload to the server only</option></select><button class="b" onclick="act('send_survey',{to:$('sv-to').value})">Send to TAK</button><a class="b" href="/api/survey" style="text-decoration:none">Download</a></div></div></div>
  <p class="dim">Name devices so alerts use the name. <b>Watch</b> a device (camera, NVR, door controller) to get a <b>Device missing</b> alert when it stops answering.</p>
  <div class="card" style="margin-top:12px"><h3>Devices on the RJ45 network</h3><table id="tb-hosts"></table></div>
</section>
<section id="t-bridge">
  <div class="grid">
    <div class="card"><h3>Mesh SA bridge</h3><div class="kv" id="k-bridge"></div>
      <div class="row"><label><input type="checkbox" id="br-up" onchange="setCfg({BRIDGE_UP:this.checked?'1':'0'})"> LAN mesh &rarr; TAK Server</label></div>
      <div class="row"><label><input type="checkbox" id="br-down" onchange="setCfg({BRIDGE_DOWN:this.checked?'1':'0'})"> TAK Server &rarr; LAN mesh</label></div>
      <p class="dim">Puts ATAK devices on a closed LAN (default mesh 239.2.3.1:6969, chat 224.10.10.1:17012) on your TAK Server, and the server's traffic back onto the LAN. XML and TAK protocol v1 (protobuf) are both understood.</p></div>
  </div>
  <div class="card" style="margin-top:12px"><h3>Devices heard on the mesh</h3><table id="tb-mesh"></table></div>
</section>
<section id="t-settings">
  <div class="row"><button class="b" onclick="saveCfg()">Save settings</button><span class="dim">Secrets show blank; leave them blank to keep them.</span></div>
  <div class="card"><div class="cfg" id="cfgform"></div></div>
  <div class="row"><button class="b" onclick="saveCfg()">Save settings</button></div>
</section>
<section id="t-setup">
  <div class="grid">
    <div class="card" style="grid-column:1/-1"><h3>1. TAK Server connection</h3>
      <div class="seg" id="seg"><button class="on" onclick="pane('cp',this)">Connection package</button><button onclick="pane('cr',this)">Certificates</button><button onclick="pane('en',this)">Enroll</button></div>
      <div id="p-cp" class="pane">
        <p>The <b>.zip</b> data package from your TAK Server admin. Server, port, protocol and both certificates come from it, with the passwords stored inside it.</p>
        <div class="row"><input type="file" id="cp-file" accept=".zip"></div>
        <details><summary class="dim">Package asks for passwords?</summary>
          <div class="frm"><label>Client certificate password</label><input type="password" id="cp-cpw" placeholder="blank = from the package" autocomplete="off">
          <label>Truststore password</label><input type="password" id="cp-tpw" placeholder="blank = from the package" autocomplete="off"></div></details>
        <div class="row"><button class="b" onclick="importPkg()">Import and connect</button></div>
      </div>
      <div id="p-cr" class="pane" style="display:none">
        <p>Same as ATAK's <i>Add Server</i>: the server, then the <b>client certificate</b> and the <b>truststore</b>, each with its own password.</p>
        <div class="frm">
          <label>Server address</label><input id="cr-host" placeholder="takserver.example.com">
          <label>Port / protocol</label><div class="row" style="margin:0"><input id="cr-port" size="6" placeholder="8089"><select id="cr-proto"><option value="tls">SSL/TLS</option><option value="tcp">TCP</option><option value="udp">UDP</option></select></div>
          <label>Client certificate</label><input type="file" id="cr-client" accept=".p12,.pfx,.pem">
          <label>Client password</label><input type="password" id="cr-cpw" placeholder="default atakatak" autocomplete="off">
          <label>Truststore (CA)</label><input type="file" id="cr-trust" accept=".p12,.pfx,.pem">
          <label>Truststore password</label><input type="password" id="cr-tpw" placeholder="default atakatak" autocomplete="off">
        </div>
        <div class="row"><button class="b" onclick="saveCerts()">Save and connect</button><span class="dim">Leave a file empty to keep the one already loaded.</span></div>
      </div>
      <div id="p-en" class="pane" style="display:none">
        <p>Get a certificate from the TAK Server with your TAK username and password (certificate enrollment, port 8446 by default). Uses the server address from Settings or the Certificates tab. Takes up to a minute on the Hub.</p>
        <div class="frm"><label>Server address</label><input id="en-host" placeholder="takserver.example.com">
          <label>Username</label><input id="en-u" autocomplete="off"><label>Password</label><input id="en-p" type="password" autocomplete="new-password"></div>
        <div class="row"><button class="b" onclick="enroll()">Enroll and connect</button></div>
      </div>
      <div class="kv" id="k-certs" style="margin-top:10px"></div>
      <div class="row"><button class="b" onclick="diag()">Test connection</button><button class="b" onclick="act('reconnect')">Reconnect</button><button class="b" onclick="act('clock_sync')">Set clock now</button><button class="b" onclick="if(confirm('Put back the certificates that were loaded before the last import or enrollment?'))act('restore_certs')">Restore previous certificates</button></div>
      <pre id="diag" style="display:none"></pre>
    </div>
    <div class="card wide"><h3>2. Location</h3>
      <div class="frm"><label>Primary source</label><select id="loc-mode"><option value="auto">Auto (in the order below)</option><option value="radio">Radio GPS (TurtleMesh)</option><option value="gps">USB GPS on the Hub</option><option value="atak">My phone (ATAK)</option><option value="site">Saved site</option><option value="manual">Manual</option><option value="ip">Network (public IP)</option></select>
        <label>My ATAK callsign</label><input id="loc-atak" placeholder="from the TAK Server"></div>
      <div class="row"><button class="b" onclick="saveLoc()">Save location settings</button></div>
      <p class="dim">Auto order: the Meshtastic radio's GPS (while TurtleMesh runs), USB GPS, my phone (ATAK), saved site, manual, network. A primary source goes first and the rest stay as fallback. GPS and phone positions count while they are fresh.</p>
      <div class="row"><input id="lat" placeholder="Latitude" size="11"><input id="lon" placeholder="Longitude" size="11"><input id="site" placeholder="Save as site (optional)" size="16"><button class="b" onclick="setPos()">Set manual</button></div>
      <table id="tb-sites"></table></div>
    <div class="card"><h3>3. Uplinks</h3>
      <p>Out-of-band Wi-Fi (WIFI_SSID / WIFI_KEY in Settings) and WireGuard. Upload a <b>wg.conf</b> to bring up the Hub's WireGuard client:</p>
      <div class="row"><input type="file" id="up-wg" accept=".conf"><button class="b" onclick="upload('up-wg')">Upload wg.conf</button><button class="b" onclick="act('uplinks')">Re-apply uplinks</button></div></div>
    <div class="card"><h3>4. Clone to another Hub</h3>
      <p>Download this Hub's settings, certificates, sites, device names and baselines as one <b>.turtletak</b> file, then load it on another Hub. The other Hub keeps its own web password and gets its own UID and callsign.</p>
      <div class="row"><a class="b" href="/api/export" style="text-decoration:none">Download clone package</a></div>
      <p class="warn" style="font-size:12px">It contains your TAK certificates and Wi-Fi key - keep it private.</p>
      <div class="row"><input type="file" id="cl-file" accept=".turtletak"><input id="cl-cs" placeholder="Callsign for this Hub" size="18"><button class="b" onclick="cloneImport()">Load clone package</button></div></div>
    <div class="card"><h3>5. Hub</h3>
      <div class="row"><label><input type="checkbox" id="boot" onchange="act('boot',{on:this.checked})"> Run TurtleTAK at boot</label></div>
      <div class="row"><label><input type="checkbox" id="ledon" onchange="setCfg({LED:this.checked?'1':'0'})"> Use the LED (off = stealth)</label></div>
      <div class="row"><input type="password" id="newpw" placeholder="New web password (8+)" autocomplete="new-password"><button class="b" onclick="setPw()">Change password</button></div>
      <h3 style="margin-top:12px">Setup check</h3><div class="kv" id="k-check"></div></div>
    <div class="card"><h3>6. On the TAK map</h3>
      <div class="frm" style="grid-template-columns:minmax(0,1fr);gap:4px"><label>Marker type</label><select id="mk-type" onchange="mkShow()"><option value="a-f-G-E-S">Sensor (a-f-G-E-S)</option><option value="a-f-G-I">Facility (a-f-G-I), a building or site</option><option value="a-f-G-U-C">Team member (a-f-G-U-C), a dot in a team color</option><option value="custom">Custom CoT type</option></select>
        <label id="mk-cl">Custom CoT type</label><input id="mk-custom" placeholder="a-f-G-E-S-..." autocomplete="off">
        <label>Team color</label><select id="mk-team"></select></div>
      <div class="row"><button class="b" onclick="saveMarker()">Save marker</button></div>
      <p class="dim">How TAK shows the Hub. Alert markers keep their own red / yellow / green. The team color shows on team member markers.</p>
    </div>
  </div>
  <div class="card" style="margin-top:12px"><h3>Log</h3><div class="row"><button class="b" onclick="loadLog()">Refresh</button></div><pre id="log"></pre></div>
</section>
</main>
<footer>TurtleTAK Hub Edition <span id="ver"></span> &middot; SECT0101 &middot; Use only on networks you own or are authorized to monitor.</footer>
</div>
<div class="toast" id="toast"></div>
<script>
const TABS=[["status","Status"],["map","Map"],["chat","Chat"],["alerts","Alerts"],["network","Network"],["bridge","Mesh Bridge"],["settings","Settings"],["setup","Setup"]];
let ST=null,tab=localStorageGet("tt_tab")||"status",map=null,layers=null,chatSig="",cfgLoaded=false,seenAlerts=+(localStorageGet("tt_seen")||0);
function localStorageGet(k){try{return localStorage.getItem(k)}catch(e){return null}}
function localStorageSet(k,v){try{localStorage.setItem(k,v)}catch(e){}}
const $=id=>document.getElementById(id);
const esc=s=>String(s==null?"":s).replace(/[&<>"']/g,c=>({"&":"&amp;","<":"&lt;",">":"&gt;",'"':"&quot;","'":"&#39;"}[c]));
function toast(m,err){const t=$("toast");t.textContent=m;t.className="toast"+(err?" err":"");t.style.display="block";clearTimeout(t._h);t._h=setTimeout(()=>t.style.display="none",4500)}
async function api(path,opt={}){opt.headers=Object.assign({"X-TT":"1"},opt.headers||{});opt.credentials="same-origin";
  const r=await fetch(path,opt);if(r.status==401){showLogin();throw new Error("sign in")}
  const ct=r.headers.get("content-type")||"";const d=ct.includes("json")?await r.json():await r.text();
  if(!r.ok)throw new Error(d.error||r.statusText);return d}
function showLogin(){$("app").style.display="none";$("login").style.display="block"}
async function login(e){e.preventDefault();try{await api("/api/login",{method:"POST",body:JSON.stringify({password:$("pw").value})});$("pw").value="";$("login").style.display="none";$("app").style.display="block";await refresh();go(tab)}catch(x){toast(x.message,1)}}
async function logout(){try{await api("/api/logout",{method:"POST"})}catch(e){}showLogin()}
async function act(a,extra={}){try{const d=await api("/api/action",{method:"POST",body:JSON.stringify(Object.assign({action:a},extra))});if(a!="chat_read")toast(d.msg||"done");refresh()}catch(e){toast(e.message,1)}}
async function setCfg(o){try{const d=await api("/api/cfg",{method:"POST",body:JSON.stringify(o)});toast(d.msg);cfgLoaded=false;refresh()}catch(e){toast(e.message,1)}}
function nav(){$("nav").innerHTML=TABS.map(([k,l])=>`<button class="${k==tab?"on":""}" onclick="go('${k}')">${l}${k=="alerts"?'<span class="n" id="n-al" style="display:none"></span>':k=="chat"?'<span class="n" id="n-ch" style="display:none"></span>':""}</button>`).join("");
  document.querySelectorAll("section").forEach(s=>s.classList.toggle("on",s.id=="t-"+tab))}
function syncChecks(){api("/api/cfg").then(c=>{const g=k=>(c.find(r=>r.key==k)||{}).value;const hst=g("TAK_HOST")||"";if(!/example\.com$/.test(hst)){$("cr-host").value=hst;$("en-host").value=hst}$("cr-port").value=g("TAK_PORT")||"";$("cr-proto").value=g("TAK_PROTO")||"tls";$("boot").checked=g("RUN_AT_BOOT")=="1";$("ledon").checked=g("LED")!="0";$("loc-mode").value=g("LOC_MODE")||"auto";$("loc-atak").value=g("MY_ATAK")||"";
  const ct=g("COT_TYPE")||"a-f-G-E-S",std=["a-f-G-E-S","a-f-G-I","a-f-G-U-C"].includes(ct);$("mk-type").value=std?ct:"custom";$("mk-custom").value=std?"":ct;
  const tc=$("mk-team");tc.innerHTML=((ST&&ST.team_colors)||[]).map(n=>`<option>${esc(n)}</option>`).join("");const tk=v=>(v||"").replace(/[\s_-]+/g,"").toLowerCase(),tn=((ST&&ST.team_colors)||[]).find(n=>tk(n)==tk(g("TEAM")));tc.value=tn||"Cyan";mkShow()}).catch(()=>{})}
function mkShow(){const c=$("mk-type").value=="custom";$("mk-cl").style.display=$("mk-custom").style.display=c?"":"none"}
function saveMarker(){const t=$("mk-type").value;setCfg({COT_TYPE:t=="custom"?$("mk-custom").value.trim():t,TEAM:$("mk-team").value})}
function saveLoc(){setCfg({LOC_MODE:$("loc-mode").value,MY_ATAK:$("loc-atak").value.trim()})}
function go(k){tab=k;if(k=="setup")syncChecks();if(k=="chat")act("chat_read");if(k=="alerts"&&ST)loadAlertCfg();localStorageSet("tt_tab",k);nav();if(k=="map")setTimeout(initMap,50);if(k=="settings")loadCfg();if(k=="setup")loadLog();if(k=="alerts"&&ST&&ST.alerts.length){seenAlerts=ST.alerts[0].time;localStorageSet("tt_seen",seenAlerts)}render()}
const ago=s=>{s=Math.max(0,Math.round(s));return s<90?s+"s":s<5400?Math.round(s/60)+"m":s<172800?Math.floor(s/3600)+"h"+String(Math.floor(s%3600/60)).padStart(2,"0"):Math.floor(s/86400)+"d"};
const tm=t=>new Date(t*1000).toLocaleString();
const kv=(id,rows)=>$(id).innerHTML=rows.filter(r=>r).map(([k,v])=>`<div>${esc(k)}</div><div>${v}</div>`).join("");
function pill(id,cls,txt){const p=$(id);p.className="pill "+cls;p.textContent=txt}
function render(){if(!ST)return;const s=ST,st=s.status||{},t=s.tak,p=s.pos;
  $("ver").textContent=s.version;$("h-cs").textContent=s.callsign;const al=$("al-lora"),tmi=s.turtlemesh||{};if(al)al.innerHTML=!tmi.installed?'<span class="dim">not sent - needs TurtleMesh (Meshtastic) on this Hub</span>':tmi.lora=="off"?'<span class="dim">not sent on the mesh - choose a channel or node in TurtleMesh &gt; Alerts'+(tmi.running?"":" (TurtleMesh is not running)")+'</span>':"sent by TurtleMesh to <b>"+esc(tmi.lora)+"</b>, "+esc(tmi.lora_min)+" and up"+(tmi.running?"":' <span class="warn">(TurtleMesh is not running, so nothing is sent)</span>')+' - change it in TurtleMesh &gt; Alerts';const tml=$("tm-link");if(s.turtlemesh&&s.turtlemesh.running){tml.style.display="inline-block";tml.href=location.protocol+"//"+location.hostname+":"+s.turtlemesh.port}else tml.style.display="none";
  pill("p-tak",t.state=="connected"?"ok":t.state=="connecting"?"mid":"bad","TAK "+t.state);
  pill("p-rj",st.rj45_link?"ok":"bad",st.rj45_link?"RJ45 link":"RJ45 no link");
  pill("p-loc",p.lat==null?"bad":p.ce>1000?"mid":"ok","Loc: "+p.src);
  const na=s.alerts.filter(a=>a.time>seenAlerts&&a.level!="info").length,n=$("n-al");if(n){n.textContent=na;n.style.display=na?"inline":"none"}
  const nc=$("n-ch");if(nc){nc.textContent=s.unread;nc.style.display=s.unread&&tab!="chat"?"inline":"none"}
  if(tab=="status"){kv("k-tak",[["Server",esc(t.host+":"+t.port+" ("+t.proto+")")],["State",`<span class="${t.state=="connected"?"ok":"warn"}">${esc(t.state)}</span> for ${ago(s.now-t.since)}`],t.error?["Error",`<span class="crit">${esc(t.error)}</span>`]:null,["Sent / received",t.tx+" / "+t.rx],s.cert&&s.cert.days!=null?["Certificate expires",`<span class="${s.cert.days<0?"crit":s.cert.days<=30?"warn":"ok"}">${new Date(s.cert.expires*1000).toLocaleDateString()} (${s.cert.days<0?"EXPIRED":s.cert.days+" days"})</span>`]:null,["Queued",t.queued],["Callsign",esc(s.callsign)],["UID",esc(s.uid)]]);
    kv("k-net",[["Uplink",esc(st.uplink+(st.gateway?" via "+st.gateway:""))],["RJ45",esc((st.rj45||"?")+" "+(st.rj45_link?"link ":"NO LINK ")+(st.rj45_ip||""))],["Wi-Fi client",esc(st.wifi_client||"off")],["VPN",esc(st.vpn||"none")],st.netbird?["NetBird",esc(st.netbird)]:null,["Public IP",esc((st.public_ip||"?")+" "+(st.isp||""))],["Target (USB-C) leases",st.target_leases]]);
    kv("k-loc",[["Source",esc(p.src)],["Position",p.lat==null?"unknown":p.lat.toFixed(6)+", "+p.lon.toFixed(6)],["Accuracy",p.ce>=9999999?"?":"+/- "+Math.round(p.ce)+" m"],["GPS",esc(s.gps.device?(s.gps.device+(s.gps.fix?" fix, "+s.gps.sats+" sats":" no fix")):"none")]]);
    kv("k-hub",[["Uptime",ago(st.uptime||0)],["TurtleTAK up",ago(s.uptime)],["Load",esc(st.load)],["Memory free",Math.round((st.mem_free_kb||0)/1024)+" of "+Math.round((st.mem_total_kb||0)/1024)+" MB"],["Clock",esc(new Date(s.now*1000).toLocaleString()+(s.clock?" ("+s.clock+")":""))],["OS",esc(st.os)],["Python",esc(st.python)]]);
    $("remarks").textContent=s.status_text}
  if(tab=="map"){const t2=s.tiles||{},sel=$("mp-src");if(!sel.options.length){sel.innerHTML=Object.entries(t2.sources||{}).map(([k,v])=>`<option value="${k}">${esc(v)}</option>`).join("");sel.value=t2.source}
    const j=t2.job;$("mp-st").textContent=(j&&j.running?`Saving ${j.done}/${j.total} tiles... `:j?`Last save: ${j.saved} new, ${j.failed} failed${j.error?" - "+j.error:""}. `:"")+`Saved maps: ${t2.mb} of ${t2.limit_mb} MB`+(t2.root&&t2.root.indexOf("/usb")>=0?" (USB)":"");drawMap();$("tb-contacts").innerHTML="<tr><th>Callsign</th><th>Team</th><th>Range</th><th>Bearing</th><th>Seen</th><th>Via</th></tr>"+s.contacts.map(c=>`<tr><td>${esc(c.callsign)}</td><td>${esc(c.team)}</td><td>${c.dist==null?"":c.dist<1000?c.dist+" m":(c.dist/1000).toFixed(1)+" km"}</td><td>${c.brg==null?"":c.brg+"&deg;"}</td><td>${ago(c.age)} ago</td><td>${esc(c.source)}</td></tr>`).join("")}
  if(tab=="chat"){const sig=s.chat.length+":"+(s.chat.length?s.chat[0].time+":"+s.chat[s.chat.length-1].time:"");if(sig!=chatSig){chatSig=sig;const l=$("chatlog");l.innerHTML=s.chat.map(m=>`<div class="msg ${m.dir}"><div class="h"><a href="#" class="del" title="Delete this message" onclick="delMsg(this.dataset.id,this.dataset.t);return false" data-id="${esc(m.id||"")}" data-t="${m.time}">&times;</a>${m.dir=="in"?`<a href="#" title="Direct message ${esc(m.from)}" onclick="replyTo(this.dataset.cs);return false" data-cs="${esc(m.from)}">${esc(m.from)}</a>`:esc(m.from)} &rarr; ${esc(m.room)} &middot; ${tm(m.time)}${m.dir=="out"&&m.sent===false?" &middot; queued":""}${m.dir=="in"?` &middot; <a href="#" onclick="replyTo(this.dataset.cs);return false" data-cs="${esc(m.from)}">Reply</a>`:""}</div>${esc(m.text)}</div>`).join("")||'<p class="dim">No messages yet.</p>';l.scrollTop=l.scrollHeight;if(s.unread)act("chat_read")}
    dmList($("chat-to"),'<option value="">All Chat Rooms</option>')}
  if(tab=="alerts"){dmList($("al-to"),'<option value="">All Chat Rooms</option>');$("al-qnow").textContent=s.quiet?"Quiet hours now":"";$("alertlist").innerHTML=s.alerts.map(a=>`<div class="alert lvl-${a.level}"><b>${esc(a.title)}</b> <span class="dim">${tm(a.time)} &middot; ${esc(a.kind)}</span><br>${esc(a.detail)}</div>`).join("")||'<p class="dim">No alerts.</p>'}
  if(tab=="network"){const n=s.net;kv("k-watch",[["Interface",esc((n.iface||"?")+" "+(n.my_ip||""))],["Subnet",esc(n.subnet||"")],["Gateway",esc((n.gateway||"")+" "+(n.gateway_mac||""))],["State",esc(n.state||"waiting")],["Devices",(n.count||0)+" seen, "+(n.new||0)+" new"],["Baseline",n.baseline?(n.baseline_count+" known devices"):"none yet"],["Last sweep",n.last_sweep?ago(s.now-n.last_sweep)+" ago ("+esc(n.method)+", "+n.took+" s)":"pending"],["DHCP servers",esc(n.dhcp||"not checked yet")]]);
    const tb=$("tb-hosts"),sig=JSON.stringify(s.hosts.map(h=>[h.mac,h.ip,h.known,h.name,h.watch,h.missing,Math.round((s.now-h.last)/60)]));
    if(tb._sig!=sig&&!tb.contains(document.activeElement)){tb._sig=sig;tb.innerHTML="<tr><th>IP</th><th>Name</th><th>Watch</th><th>MAC</th><th>Vendor</th><th></th><th>Last seen</th></tr>"+s.hosts.map(h=>`<tr><td>${esc(h.ip)}</td><td><input value="${esc(h.name)}" placeholder="name" size="14" onchange="act('set_device',{mac:'${h.mac}',name:this.value})"></td><td><input type="checkbox" ${h.watch?"checked":""} onchange="act('set_device',{mac:'${h.mac}',watch:this.checked})"></td><td>${esc(h.mac)}</td><td>${esc(h.vendor)}</td><td>${h.missing?'<span class="tag" style="background:var(--crit);color:#fff">MISSING</span>':h.known?'<span class="tag">known</span>':'<span class="tag new">NEW</span>'}</td><td>${ago(s.now-h.last)} ago</td></tr>`).join("")}
    const sv=$("sv-to"),names=[...new Set(s.contacts.filter(c=>c.type.startsWith("a-f-G-U")).map(c=>c.callsign))].sort();if(sv._n!=names.join("|")){const cur=sv.value;sv._n=names.join("|");sv.innerHTML='<option value="">Send to everyone</option><option value="upload">Upload to the server only</option>'+names.map(n=>`<option>${esc(n)}</option>`).join("");sv.value=cur}}
  if(tab=="bridge"){const b=s.bridge;$("br-up").checked=b.up;$("br-down").checked=b.down;kv("k-bridge",[["Interfaces",esc((b.ifaces||[]).join(", ")||"off")],["Heard on mesh",b.up_rx],["Forwarded up",b.up_tx],["Repeated down",b.down_tx],b.error?["Error",`<span class="crit">${esc(b.error)}</span>`]:null]);
    $("tb-mesh").innerHTML="<tr><th>Callsign</th><th>IP</th><th>Type</th><th>Last heard</th></tr>"+Object.entries(b.devices||{}).map(([u,d])=>`<tr><td>${esc(d.callsign)}</td><td>${esc(d.ip)}</td><td>${esc(d.type)}</td><td>${ago(s.now-d.last)} ago</td></tr>`).join("")}
  if(tab=="setup"){kv("k-certs",[["Server",esc(t.host+":"+t.port+" ("+t.proto+")")],["Client certificate",s.certs["client.pem"]?'<span class="ok">loaded</span>':'<span class="warn">not loaded</span>'],s.cert&&s.cert.days!=null?["Certificate expires",`<span class="${s.cert.days<0?"crit":s.cert.days<=30?"warn":"ok"}">${new Date(s.cert.expires*1000).toLocaleDateString()} (${s.cert.days<0?"EXPIRED":s.cert.days+" days"})</span>`]:null,["Truststore",s.certs["ca.pem"]?'<span class="ok">loaded</span>':'<span class="dim">not loaded (server not verified)</span>'],st.dns?["DNS lookup",esc(st.dns)]:null,["Status",t.state=="connected"?'<span class="ok">connected</span>':`<span class="warn">${esc(t.state)} ${esc(t.error)}</span>`]]);
    const tl=st.tools||{};kv("k-check",[["TAK",t.state=="connected"?'<span class="ok">connected</span>':`<span class="warn">${esc(t.state)} ${esc(t.error)}</span>`],["openssl",tl.openssl?'<span class="ok">yes</span>':'<span class="dim">no - not needed (built in)</span>'],["nmap",tl.nmap?'<span class="ok">yes</span>':'<span class="dim">no - ping sweep instead</span>'],["wg",tl.wg?"yes":"no"],["RJ45 interface",esc(st.rj45||"not found")],["Interfaces",esc(Object.entries(st.ifaces||{}).map(([k,v])=>k+(v.ipv4&&v.ipv4.length?" "+v.ipv4.join(","):"")).join(" | "))]]);
    $("tb-sites").innerHTML=s.sites.length?"<tr><th>Site</th><th>Lat</th><th>Lon</th><th></th></tr>"+s.sites.map(x=>`<tr><td>${esc(x.name)}</td><td>${x.lat.toFixed(5)}</td><td>${x.lon.toFixed(5)}</td><td><button class="b" onclick="setCfg({SITE:'${esc(x.name).replace(/'/g,"")}',LOC_MODE:'site'})">Use</button></td></tr>`).join(""):""}
}
function initMap(){if(map||!window.L){if(!window.L){const sc=document.createElement("script");sc.src="/static/leaflet.js";sc.onload=initMap;sc.onerror=()=>$("mapnote").textContent="Map library could not load - the contact table below still works.";document.head.appendChild(sc);const ln=document.createElement("link");ln.rel="stylesheet";ln.href="/static/leaflet.css";document.head.appendChild(ln)}return}
  map=L.map("map");mapSource((ST&&ST.tiles&&ST.tiles.source)||"usgs_topo");
  layers=L.layerGroup().addTo(map);const p=ST&&ST.pos;map.setView(p&&p.lat!=null?[p.lat,p.lon]:[20,0],p&&p.lat!=null?16:2);
  map.on("click",e=>{if(confirm("Place the Hub at "+e.latlng.lat.toFixed(6)+", "+e.latlng.lng.toFixed(6)+"? (manual location)"))act("set_pos",{lat:e.latlng.lat,lon:e.latlng.lng})});drawMap()}
function dot(c){return L.divIcon({className:"",html:`<div style="width:14px;height:14px;border-radius:50%;background:${c};border:2px solid #000"></div>`,iconSize:[14,14],iconAnchor:[7,7]})}
function drawMap(){if(!map||!ST)return;layers.clearLayers();const p=ST.pos;
  if(p.lat!=null){L.marker([p.lat,p.lon],{icon:dot("#6fcf4a")}).bindTooltip(ST.callsign+" (Hub)",{permanent:true,direction:"right"}).addTo(layers);if(p.ce<5000)L.circle([p.lat,p.lon],{radius:p.ce,color:"#6fcf4a",weight:1,fillOpacity:.05}).addTo(layers)}
  ST.contacts.forEach(c=>{const col=c.type.startsWith("a-h")?"#ff5c5c":c.type.startsWith("a-u")?"#f2b631":c.type.startsWith("a-n")?"#7de07d":"#4fb3ff";L.marker([c.lat,c.lon],{icon:dot(col)}).bindTooltip(esc(c.callsign)).addTo(layers)})}
function dmList(sel,head){const cur=sel.value||sel.dataset.want||"",names=(ST.dm_targets||[]).slice();if(cur&&!names.includes(cur))names.push(cur);const sig=names.join("|");
  if(sel._n!=sig){sel._n=sig;sel.innerHTML=head+names.map(n=>`<option>${esc(n)}</option>`).join("");sel.value=cur}}
function replyTo(cs){const sel=$("chat-to");if(![...sel.options].some(o=>o.value==cs)){const o=document.createElement("option");o.textContent=cs;sel.appendChild(o)}sel.value=cs;$("chat-text").focus()}
function delMsg(id,t){if(confirm("Delete this message?"))act("chat_delete",id?{id}:{time:+t})}
async function sendChat(e){e.preventDefault();const t=$("chat-text").value.trim();if(!t)return;await act("chat",{text:t,to:$("chat-to").value});$("chat-text").value=""}
async function loadCfg(){if(cfgLoaded)return;try{const c=await api("/api/cfg");cfgLoaded=true;$("cfgform").innerHTML=c.map(r=>r.section?`<h4>${esc(r.key.replace(/^#\s*/,""))}</h4>`:`<label for="c-${r.key}">${esc(r.key)}</label><input id="c-${r.key}" data-k="${r.key}" ${r.key=="UID"?"readonly title=\"Set once from the device\"":""} ${r.secret?'type="password" placeholder="'+(r.set?"(set - blank keeps it)":"")+'"':""} value="${esc(r.value)}">`).join("")}catch(e){toast(e.message,1)}}
async function saveCfg(){const o={};document.querySelectorAll("#cfgform input").forEach(i=>{if(i.type=="password"&&i.value==="")return;o[i.dataset.k]=i.value});await setCfg(o)}
function pane(k,btn){["cp","cr","en"].forEach(x=>$("p-"+x).style.display=x==k?"block":"none");document.querySelectorAll("#seg button").forEach(b=>b.classList.toggle("on",b==btn))}
async function sendFile(f,hdrs){const h=Object.assign({"X-Filename":f.name,"Content-Type":"application/octet-stream"},hdrs||{});for(const k in h)h[k]=encodeURIComponent(h[k]);return api("/api/upload",{method:"POST",headers:h,body:await f.arrayBuffer()})}
async function importPkg(){const f=$("cp-file").files[0];if(!f)return toast("Choose the .zip first",1);const h={};if($("cp-cpw").value)h["X-Client-Password"]=$("cp-cpw").value;if($("cp-tpw").value)h["X-CA-Password"]=$("cp-tpw").value;
  try{const d=await sendFile(f,h);toast(d.msg);$("cp-file").value="";$("cp-cpw").value="";$("cp-tpw").value="";refresh()}catch(e){toast(e.message,1)}}
async function saveCerts(){try{const cfg={};if($("cr-host").value.trim())cfg.TAK_HOST=$("cr-host").value.trim();if($("cr-port").value.trim())cfg.TAK_PORT=$("cr-port").value.trim();cfg.TAK_PROTO=$("cr-proto").value;
  for(const [id,kind,pw] of [["cr-client","client","cr-cpw"],["cr-trust","ca","cr-tpw"]]){const f=$(id).files[0];if(!f)continue;const h={"X-Cert-Kind":kind};if($(pw).value)h["X-Cert-Password"]=$(pw).value;await sendFile(f,h);$(id).value="";$(pw).value=""}
  await api("/api/cfg",{method:"POST",body:JSON.stringify(cfg)});toast("Saved - connecting");cfgLoaded=false;refresh()}catch(e){toast(e.message,1)}}
async function upload(id){const f=$(id).files[0];if(!f)return toast("Choose a file first",1);try{const d=await api("/api/upload",{method:"POST",headers:{"X-Filename":f.name,"Content-Type":"application/octet-stream"},body:await f.arrayBuffer()});toast(d.msg);$(id).value="";refresh()}catch(e){toast(e.message,1)}}
function setPos(){act("set_pos",{lat:$("lat").value,lon:$("lon").value,site:$("site").value})}
async function enroll(){if($("en-host").value.trim())await setCfg({TAK_HOST:$("en-host").value.trim()});toast("Enrolling - this can take up to a minute");await act("enroll",{user:$("en-u").value,password:$("en-p").value});$("en-p").value=""}
function setPw(){act("set_password",{password:$("newpw").value});$("newpw").value=""}
async function diag(){const d=$("diag");d.style.display="block";d.textContent="Testing...";try{const r=await api("/api/action",{method:"POST",body:JSON.stringify({action:"diagnose"})});d.textContent=r.msg}catch(e){d.textContent=e.message}}
let tileLayer=null;
function mapSource(src){if(!map)return;if(tileLayer)map.removeLayer(tileLayer);const osm=src=="osm";tileLayer=L.tileLayer("/tiles/"+src+"/{z}/{x}/{y}",{maxZoom:osm?19:16,attribution:osm?"&copy; OpenStreetMap contributors":"USGS The National Map"}).addTo(map)}
function bnds(){const b=map.getBounds();return {s:b.getSouth(),w:b.getWest(),n:b.getNorth(),e:b.getEast()}}
async function saveArea(){if(!map)return toast("Open the map first",1);const src=$("mp-src").value,zmax=+$("mp-z").value,zmin=Math.max(1,map.getZoom()-4);
  try{const r=await api("/api/action",{method:"POST",body:JSON.stringify({action:"tiles_plan",src,bounds:bnds(),zmin,zmax})});if(!confirm("Save "+r.msg+" of this view (zoom "+zmin+"-"+zmax+") on the Hub?"))return;act("tiles_download",{src,bounds:bnds(),zmin,zmax})}catch(e){toast(e.message,1)}}
async function cloneImport(){const f=$("cl-file").files[0];if(!f)return toast("Choose the .turtletak file",1);if(!$("cl-cs").value.trim())return toast("Give this Hub its own callsign",1);
  if(!confirm("Load "+f.name+" onto this Hub? Its TAK settings, certificates, sites and device names are replaced."))return;try{const d=await sendFile(f,{"X-Callsign":$("cl-cs").value.trim()});toast(d.msg);$("cl-file").value="";cfgLoaded=false;refresh()}catch(e){toast(e.message,1)}}
async function loadAlertCfg(){try{const c=await api("/api/cfg"),g=k=>(c.find(r=>r.key==k)||{}).value||"";const on=g("ALERTS_ON").split(",");
  $("al-kinds").innerHTML=(ST.alert_kinds||[]).map(([k,l])=>`<label style="margin-right:12px"><input type="checkbox" class="al-k" value="${k}" ${on.includes(k)?"checked":""}> ${esc(l)}</label>`).join("");
  $("al-marker").value=g("MARKER_MIN_LEVEL")||"warning";$("al-chat").value=g("CHAT_MIN_LEVEL")||"info";const at=$("al-to");at.dataset.want=g("ALERT_TO");at._n=null;dmList(at,'<option value="">All Chat Rooms</option>');at.value=g("ALERT_TO");$("al-quiet").value=g("QUIET_HOURS");$("al-qcrit").checked=g("QUIET_CRITICAL")!="0"}catch(e){}}
function saveAlertCfg(){setCfg({ALERTS_ON:[...document.querySelectorAll(".al-k:checked")].map(i=>i.value).join(","),MARKER_MIN_LEVEL:$("al-marker").value,CHAT_MIN_LEVEL:$("al-chat").value,ALERT_TO:$("al-to").value,QUIET_HOURS:$("al-quiet").value.trim(),QUIET_CRITICAL:$("al-qcrit").checked?"1":"0"})}
async function loadLog(){try{$("log").textContent=await api("/api/log");$("log").scrollTop=1e9}catch(e){}}
async function refresh(){try{ST=await api("/api/state");$("login").style.display="none";$("app").style.display="block";
  render()}catch(e){}}
(async()=>{nav();await refresh();if(ST)go(tab);else showLogin()})();
setInterval(refresh,4000);
</script>
</body>
</html>
TURTLETAK_HTML

# ---- self-check: a cut-off or damaged payload.sh, or a missing Python module, is reported -------
fail() {
    TT_STARTED=1
    echo "$(date '+%Y-%m-%d %H:%M:%S') [error] $1" >> "$BASE/logs/console.log"
    echo "TurtleTAK: $1" >&2
    LED FAIL 2>/dev/null
    NOTIFY_ERROR TurtleTAK "$1" 2>/dev/null
    exit 1
}
END_MARK="$(tail -c 40 "$APP/index.html" 2>/dev/null)"
case "$END_MARK" in *"</html>"*) ;; *) fail "payload.sh is incomplete (cut off while copying?) - copy the whole file again" ;; esac
[ -s "$APP/static/leaflet.js" ] && [ -s "$APP/static/leaflet.css" ] || fail "map files did not unpack - payload.sh is damaged, copy it again"
ERR=$(cd "$APP" && "$PY" -c 'import ast, sys
for f in sys.argv[1:]:
    ast.parse(open(f, "rb").read(), f)' turtletak.py ttcrypto.py 2>&1) \
    || fail "payload.sh is damaged: $(echo "$ERR" | tail -n 1)"
ERR=$(cd "$APP" && "$PY" -c 'import hashlib, json, select, socket, ssl, struct, subprocess, threading, uuid, zipfile, zlib
import ttcrypto' 2>&1) \
    || fail "Python on this Hub is missing something: $(echo "$ERR" | tail -n 1)"

LED SETUP 2>/dev/null
cd "$APP" || fail "cannot open $APP"
TT_STARTED=1
trap - EXIT
echo $$ > "$BASE/turtletak.pid"
# exec keeps the PID, so the Hub's payload stop ends the service too
exec "$PY" -u "$APP/turtletak.py" >> "$BASE/logs/console.log" 2>&1
TURTLESHELL_TAK
cat > "$SHELL_BASE/turtlemesh.sh" <<'TURTLESHELL_MESH'
#!/bin/bash
# Title: TurtleMesh Hub Edition
# Description: Meshtastic on the LAN Turtle Hub - a Meshtastic radio over Wi-Fi or USB with mesh chat, a node map, mesh watch and sensor alerts, alerts over LoRa, a mesh <-> TAK bridge, DM commands, a private MQTT proxy and a web console
# Author: SECT0101
# Version: 1.0.2
# Category: General
# Target: LAN Turtle Hub with a Meshtastic radio (Wi-Fi on the same network, or USB on the Hub)
#
# What it does
#   Radio             Connects to a Meshtastic radio over Wi-Fi/Ethernet (TCP 4403) or USB serial
#                     on the Hub's dynamic USB port. Reconnects on its own.
#   Mesh chat         Channels and direct messages from the web console
#   Nodes and map     Every node heard: name, battery, SNR, hops, range and bearing, traceroute,
#                     position request, labels; offline USGS maps cached on the Hub
#   Hub on the mesh   The Hub's position is sent every MESH_POS_INTERVAL seconds
#   Radio settings    Owner name, channels (keys, roles, share link), LoRa / device / position /
#                     network / MQTT settings, restart
#   Mesh watch        Alerts on a node never seen before (after a learning window), a watched node
#                     going quiet / coming back, low battery, the radio link lost / restored
#   Sensors           Detection-sensor packets, and texts from nodes marked as sensors, become alerts
#   Alerts over LoRa  TurtleMesh's alerts (and TurtleTAK's, while TurtleTAK runs) sent on a channel
#                     or as a DM: "[CALLSIGN] WARN title - detail"
#   DM commands       Any node can DM the Hub's radio: status, alerts, where, nodes, help
#   Mesh <-> TAK      Optional: mesh nodes as TAK markers, a mesh channel <-> TAK All Chat Rooms,
#                     Meshtastic ATAK plugin users on the TAK Server, alerts as markers and chat
#   MQTT proxy        The radio's MQTT traffic carried by the Hub to your own broker
#   Web console       http://<hub>:8485 on every interface (USB-C host, RJ45, Wi-Fi, VPN)
#
# TAK is optional. With TurtleTAK installed and TAK_FROM_TURTLETAK: 1, TurtleMesh uses TurtleTAK's
# server and certificates, so there is nothing to set up twice.
#
# Setup
#   1. Run the payload once. It creates /root/turtlemesh/ and its default.cfg, and posts the web
#      console's first password as a Hub notification (also in /root/turtlemesh/web-password.txt).
#   2. Open http://172.16.84.1:8485 (or the Hub's RJ45 / Wi-Fi / VPN address) > Radio.
#        Wi-Fi radio   its IP address (Meshtastic app > Settings > Network shows it)
#        USB radio     plug it into the dynamic USB port; TurtleMesh claims and powers it
#   3. Optional: Setup > TAK Server (connection package, certificates or enroll), the Hub's location,
#      alerts over LoRa, the MQTT proxy.
#
# LED (LED: 0 in the settings keeps it dark)
#   Magenta solid    starting          Yellow double   connecting to the radio
#   Green single     radio up          Cyan single     radio up, TAK not connected
#   Red slow         no radio set up   Cyan inverse / red fast   warning / critical alert (60 s)
#
# Files
#   /root/turtlemesh/default.cfg     every setting, "KEY: value" (web console Settings, or SSH)
#   /root/turtlemesh/certs/          TAK certificates and connection packages (never share)
#   /root/turtlemesh/nodes.json      node labels, watch and sensor flags
#   /root/turtlemesh/mesh_chat.jsonl mesh chat history
#   /root/turtlemesh/logs/           turtlemesh.log (also in the web console)
#   /root/turtlemesh/app/            the service and web page - rewritten from this payload on every run
#
# Meshtastic(R) is a registered trademark of Meshtastic LLC. Community payload, not supported by Hak5.
#
case "$(head -c 8192 "$0" 2>/dev/null)" in *$'\r'*) _lf="/tmp/.$(basename "$0").$$.lf"; tr -d '\r' < "$0" > "$_lf" && echo "fixed Windows line endings in $0" >&2 && exec bash "$_lf" "$@";; esac #
# ^ Pasted or saved on Windows? That line removes Windows line endings and runs the payload again.

BASE="${TM_BASE:-/root/turtlemesh}"
APP="$BASE/app"
PY=$(command -v python3 || command -v python)

# If this file was cut off while copying it to the Hub, the script ends early and the service never
# starts. Say so (Hub notification, red LED, log) instead of failing silently.
TM_STARTED=""
trap '[ -n "$TM_STARTED" ] || { mkdir -p "$BASE/logs"; echo "$(date "+%Y-%m-%d %H:%M:%S") [error] payload.sh ended early - the file is incomplete or damaged, copy the whole file to the Hub again" >> "$BASE/logs/console.log"; LED FAIL 2>/dev/null; NOTIFY_ERROR TurtleMesh "payload.sh ended early - the file is incomplete or damaged (cut off while copying?). Copy the whole file again." 2>/dev/null; echo "TurtleMesh: payload.sh is incomplete or damaged" >&2; }' EXIT

# Hak5 commands are handed to the Python service's child shells, whether programs or Bash functions.
for c in LED NOTIFY_INFO NOTIFY_WARNING NOTIFY_ERROR LOG_INFO LOG_WARNING LOG_ERROR C2NOTIFY C2EXFIL \
         WIFI_CONNECT WIFI_DISCONNECT WIREGUARD_CONFIGURE WIREGUARD_ENABLE WIREGUARD_DISABLE \
         USB_CLAIM_DEVICE USB_POWER_ON USB_POWER_OFF BOOT_PAYLOAD; do
    [ "$(type -t "$c")" = "function" ] && export -f "$c"
done

if [ -z "$PY" ]; then
    LED FAIL 2>/dev/null
    NOTIFY_ERROR TurtleMesh "Python 3 not found - TurtleMesh needs it" 2>/dev/null
    echo "TurtleMesh: python3 not found" >&2
    exit 1
fi

mkdir -p "$APP/static" "$BASE/certs" "$BASE/logs"
chmod 700 "$BASE/certs"

# Stop an older copy (re-running the payload restarts the service with this version)
if [ -f "$BASE/turtlemesh.pid" ]; then
    old=$(cat "$BASE/turtlemesh.pid" 2>/dev/null)
    if [ -n "$old" ] && kill -0 "$old" 2>/dev/null && grep -q turtlemesh "/proc/$old/cmdline" 2>/dev/null; then
        kill "$old" 2>/dev/null; sleep 2; kill -9 "$old" 2>/dev/null
    fi
fi

[ -f "$BASE/certs/README.txt" ] || cat > "$BASE/certs/README.txt" <<'EOF'
TurtleMesh TAK certificates - keep this folder private. TAK is optional.

With TurtleTAK on this Hub and TAK_FROM_TURTLETAK: 1, TurtleTAK's server and certificates are used
and nothing is needed here.

Otherwise, in the web console (Setup):
  Connection package  the .zip from your TAK admin (.pref + .p12 files, passwords inside it)
  Certificates        client .p12 + truststore .p12, each with its own password (default atakatak)
  Enroll              your TAK username and password
No openssl needed. client.pem (certificate + key) and ca.pem copied here are used as they are.
EOF

# ---- the service and the web page (written fresh every run) ----------------------------------
cat > "$APP/turtlemesh.py" <<'TURTLEMESH_PY'
#!/usr/bin/env python3
# TurtleMesh Hub Edition - core service (written to /root/turtlemesh/app/ by payload.sh; started by it).
# Puts a Meshtastic radio on the LAN Turtle Hub: mesh chat, node list and map, radio settings, node
# tools, perimeter sensors, mesh watch alerts, TurtleTAK alerts over LoRa, a mesh <-> TAK bridge, an
# MQTT proxy and a web console. Standard library only (Python 3.7+). Radio code from PagerMesh.
import base64, binascii, calendar, hashlib, hmac, ipaddress, json, math, os, random, re, select, shutil
import collections, socket, ssl, struct, subprocess, sys, threading, time, traceback, uuid, zipfile, io
import urllib.request, urllib.error, urllib.parse
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import ttcrypto
from http.server import BaseHTTPRequestHandler, HTTPServer
from socketserver import ThreadingMixIn
from xml.sax.saxutils import escape as _xesc

VERSION = "1.0.2"

# ---- DNS: the Hub's C library (musl) can fail a lookup that asks for IPv4 and IPv6 at once
# ("[Errno -5] Name has no usable address") while an IPv4-only lookup works - that is why ping works.
# Fall back to IPv4 only, then IPv6 only, then the system's nslookup. Covers TAK, enrollment and urllib.
_getaddrinfo = socket.getaddrinfo
DNS_CACHE = {}


def _nslookup(host):
    try:
        out = subprocess.run(["nslookup", host], stdout=subprocess.PIPE, stderr=subprocess.DEVNULL,
                             timeout=10).stdout.decode("utf-8", "replace")
    except Exception:
        return []
    ips, after_name = [], False
    for line in out.splitlines():
        if line.strip().lower().startswith("name:"):
            after_name = True
            continue
        m = re.search(r"Address(?:es)?(?:\s+\d+)?:\s*([0-9.]+)\s*$", line)
        if after_name and m:
            ips.append(m.group(1))
    return ips


def _gai(host, port, family=0, type=0, proto=0, flags=0):
    try:
        res = _getaddrinfo(host, port, family, type, proto, flags)
        if host:
            DNS_CACHE[host] = "system"
        return res
    except socket.gaierror as first:
        if not host or family not in (0, socket.AF_UNSPEC):
            raise
        for fam, how in ((socket.AF_INET, "IPv4 only"), (socket.AF_INET6, "IPv6 only")):
            try:
                res = _getaddrinfo(host, port, fam, type, proto, flags)
                DNS_CACHE[host] = how
                return res
            except socket.gaierror:
                pass
        ips = _nslookup(host)
        if ips:
            DNS_CACHE[host] = "nslookup %s" % ips[0]
            return _getaddrinfo(ips[0], port, socket.AF_INET, type, proto, flags | socket.AI_NUMERICHOST)
        DNS_CACHE[host] = "failed: %s" % first
        raise


socket.getaddrinfo = _gai
PRODUCT = "TurtleMesh"
EDITION = "Hub Edition"
BASE = os.environ.get("TM_BASE", "/root/turtlemesh")
APP = os.path.join(BASE, "app")
CERTS = os.path.join(BASE, "certs")
LOGS = os.path.join(BASE, "logs")
QUEUE = os.path.join(BASE, "queue.jsonl")
SITES = os.path.join(BASE, "sites.txt")
STATEF = os.path.join(BASE, "state.json")
CFG_FILE = os.path.join(BASE, "default.cfg")
LOOT = os.environ.get("TM_LOOT", "/root/loot/turtlemesh")
TURTLETAK_BASE = os.environ.get("TT_BASE", "/root/turtletak")
DRY = os.environ.get("TM_DRY_HUB") == "1"          # test mode: log Hub commands instead of running them

# ----------------------------------------------------------------------------------------------
# settings (default.cfg, "KEY: value", one per line; edited in the web console or over SSH)
# ----------------------------------------------------------------------------------------------
DEFAULTS = [
    ("# Radio", None),
    ("RADIO_CONN", "wifi"),          # wifi (radio on the network, TCP 4403) | usb (radio on the Hub's USB port)
    ("RADIO_HOST", ""),              # Wi-Fi radio's IP address or hostname
    ("RADIO_PORT", "4403"),
    ("RADIO_DEV", "auto"),           # USB radio: auto | /dev/ttyACM0 | /dev/ttyUSB0
    ("RADIO_CLAIM_USB", "1"),        # 1 = claim and power the Hub's dynamic USB port for a USB radio
    ("MESH_POS_INTERVAL", "900"),    # seconds between the Hub's position on the mesh (0 = off)
    ("MESH_POS_CHANNEL", "-1"),      # channel for the Hub's position (-1 = off); private channels only
    ("# Mesh -> TAK bridge", None),
    ("TAK", "1"),                    # 1 = connect to a TAK Server
    ("TAK_FROM_TURTLETAK", "1"),     # 1 = use TurtleTAK's server and certificates when it is installed
    ("TAK_HOST", "takserver.example.com"),
    ("TAK_PROTO", "tls"),
    ("TAK_PORT", "8089"),
    ("TAK_VERIFY_HOST", "0"),
    ("CLIENT_PASSWORD", "atakatak"),
    ("CA_PASSWORD", "atakatak"),
    ("API_PORT", "8443"),
    ("ENROLL_PORT", "8446"),
    ("CALLSIGN", "TURTLE-MESH"),
    ("UID", ""),
    ("TEAM", "Cyan"),
    ("ROLE", "Team Member"),
    ("COT_TYPE", "a-f-G-E-S"),
    ("SA_INTERVAL", "60"),
    ("BRIDGE_NODES", "1"),           # mesh nodes with a position -> TAK markers
    ("BRIDGE_NODE_MAX_AGE", "7200"), # seconds: nodes not heard for longer are not sent
    ("BRIDGE_CHAT_CHANNEL", "-1"),   # mesh channel linked with TAK All Chat Rooms (-1 = off); private channels only
    ("BRIDGE_ATAK_PLUGIN", "1"),     # Meshtastic ATAK plugin traffic (PLI and chat) -> TAK
    ("# Location", None),
    ("LOC_MODE", "auto"),            # primary source: auto | radio | gps | atak | mesh | site | manual | ip (then the rest, in that order)
    ("SITE", ""),
    ("MANUAL_LAT", ""),
    ("MANUAL_LON", ""),
    ("MY_ATAK", ""),                 # your ATAK callsign (position from the TAK Server)
    ("MY_NODE", ""),                 # your mesh node, e.g. the radio paired to your phone (!a1b2c3d4)
    ("ANCHOR_MAX_AGE", "1800"),      # seconds a phone position stays usable
    ("RADIO_GPS_MAX_AGE", "1800"),   # seconds the radio's GPS fix stays usable
    ("GPS_DEVICE", "off"),
    ("GPS_BAUD", "9600"),
    ("GPS_CLAIM_USB", "0"),
    ("IPGEO", "1"),
    ("IPGEO_URL", "https://ipinfo.io/json"),
    ("# Mesh watch and sensors", None),
    ("MESH_LEARN_MIN", "60"),        # minutes of learning which nodes belong before "New node" alerts
    ("NODE_QUIET_MIN", "60"),        # watched node not heard for this long -> "Node quiet"
    ("LOW_BATTERY", "20"),           # % - watched and sensor nodes below this -> "Low battery"
    ("SENSOR_LEVEL", "warning"),     # level of detection-sensor alerts: info | warning | critical
    ("UPLINK_WATCH", "1"),
    ("UPLINK_GRACE", "120"),
    ("RADIO_WATCH", "1"),            # alert when the radio link is lost
    ("# Alerts", None),
    ("ALERTS_ON", "new_node,quiet,battery,sensor,radio,uplink,cert"),
    ("ALERT_MARKER", "1"),
    ("MARKER_MIN_LEVEL", "warning"),
    ("ALERT_CHAT", "1"),             # TAK chat line
    ("CHAT_MIN_LEVEL", "info"),
    ("ALERT_TO", ""),
    ("ALERT_STALE_HOURS", "12"),
    ("QUIET_HOURS", ""),
    ("QUIET_CRITICAL", "1"),
    ("CERT_WARN_DAYS", "30"),
    ("HUB_NOTIFY", "1"),
    ("C2_NOTIFY", "0"),
    ("# Alerts over LoRa", None),
    ("LORA_ALERTS", "0"),            # send alerts as mesh text (works when the network is down)
    ("LORA_ALERT_SOURCES", "turtletak,turtlemesh"),
    ("LORA_ALERT_MIN", "warning"),
    ("LORA_ALERT_CHANNEL", ""),      # channel for alerts (blank = none chosen yet); a public channel gets a warning
    ("LORA_ALERT_TO", ""),           # blank = the channel, or a node id (!a1b2c3d4) for a direct message
    ("# Mesh commands", None),
    ("MESH_COMMANDS", "1"),          # answer status, alerts, where, nodes, help sent to the Hub's radio
    ("MESH_COMMANDS_FROM", ""),      # blank = any node, or a comma list of node ids
    ("CHAT_COMMANDS", "1"),          # same commands as TAK direct messages
    ("CHAT_COMMANDS_FROM", ""),
    ("# MQTT proxy", None),
    ("MQTT_PROXY", "0"),             # 1 = the Hub carries the radio's MQTT traffic to your broker
    ("MQTT_HOST", ""),
    ("MQTT_PORT", "1883"),
    ("MQTT_TLS", "0"),
    ("MQTT_USER", ""),
    ("MQTT_PASSWORD", ""),
    ("# Map", None),
    ("MAP_SOURCE", "usgs_topo"),
    ("TILE_CACHE_MB", "500"),
    ("TILE_MAX_DOWNLOAD", "20000"),
    ("# Uplinks", None),
    ("WIFI_SSID", ""),
    ("WIFI_KEY", ""),
    ("WIFI_ENC", "psk2"),
    ("WIFI_COUNTRY", "US"),
    ("WG_CONF", ""),
    ("# Hub", None),
    ("LED", "1"),
    ("RUN_AT_BOOT", "1"),
    ("SETTINGS_VERSION", "2"),
    ("WEB", "1"),
    ("WEB_PORT", "8485"),
    ("WEB_BIND", "0.0.0.0"),
    ("WEB_TLS", "0"),
    ("WEB_PASS_HASH", ""),
]
CFG = {}
CFG_LOCK = threading.Lock()


MIGRATED = []


def cfg_load():
    vals = {k: v for k, v in DEFAULTS if v is not None}
    seen = set()
    if os.path.exists(CFG_FILE):
        for line in open(CFG_FILE, encoding="utf-8", errors="replace"):
            if ":" in line and not line.lstrip().startswith("#"):
                k, v = line.split(":", 1)
                vals[k.strip()] = v.strip()
                seen.add(k.strip())
    if seen and "SETTINGS_VERSION" not in seen:
        # settings from 1.0.0, which sent alerts, TAK chat and the Hub position on channel 0 by default
        if vals.get("LORA_ALERT_CHANNEL") == "0" and vals.get("LORA_ALERTS") == "1" and not vals.get("LORA_ALERT_TO"):
            vals["LORA_ALERTS"], vals["LORA_ALERT_CHANNEL"] = "0", ""
            MIGRATED.append("alerts over LoRa")
        if vals.get("BRIDGE_CHAT_CHANNEL") == "0":
            vals["BRIDGE_CHAT_CHANNEL"] = "-1"
            MIGRATED.append("the TAK chat bridge")
        if vals.get("MESH_POS_CHANNEL") == "0":
            vals["MESH_POS_CHANNEL"] = "-1"
            MIGRATED.append("the Hub's position on the mesh")
        vals["SETTINGS_VERSION"] = "2"
    with CFG_LOCK:
        CFG.clear()
        CFG.update(vals)
    cfg_write()


def cfg_write():
    out = ["# TurtleMesh %s settings - KEY: value. Changed in the web console or over SSH." % EDITION]
    known = set()
    with CFG_LOCK:
        for k, v in DEFAULTS:
            if v is None:
                out.append("")
                out.append(k)
            else:
                out.append("%s: %s" % (k, CFG.get(k, v)))
                known.add(k)
        extra = [k for k in CFG if k not in known]
        if extra:
            out.append("")
            out.append("# Other")
            out += ["%s: %s" % (k, CFG[k]) for k in extra]
    tmp = CFG_FILE + ".tmp"
    fd = os.open(tmp, os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o600)
    with os.fdopen(fd, "w") as fh:
        fh.write("\n".join(out) + "\n")
    os.replace(tmp, CFG_FILE)


def cfg(k, default=""):
    with CFG_LOCK:
        return CFG.get(k, default)


def cfgi(k, default=0):
    try:
        return int(float(cfg(k, default)))
    except (TypeError, ValueError):
        return default


def cfgb(k):
    return cfg(k, "0").strip().lower() in ("1", "yes", "true", "on")


def cfg_set(changes):
    with CFG_LOCK:
        for k, v in changes.items():
            CFG[k] = str(v).replace("\n", " ").strip()
    cfg_write()


# ----------------------------------------------------------------------------------------------
# logging, events, Hub commands
# ----------------------------------------------------------------------------------------------
LOGQ = []
LOG_LOCK = threading.Lock()


def log(msg, level="info"):
    line = "%s [%s] %s" % (time.strftime("%Y-%m-%d %H:%M:%S"), level, msg)
    with LOG_LOCK:
        LOGQ.append(line)
        del LOGQ[:-400]
        try:
            with open(os.path.join(LOGS, "turtlemesh.log"), "a") as fh:
                fh.write(line + "\n")
            p = os.path.join(LOGS, "turtlemesh.log")
            if os.path.getsize(p) > 512 * 1024:
                os.replace(p, p + ".1")
        except OSError:
            pass
    print(line, flush=True)


HUB_LOCK = threading.Lock()


def hub(*args, timeout=20):
    """Run a Hak5 DuckyScript command (LED, NOTIFY_INFO, C2NOTIFY...). payload.sh exports them to
    child shells, so they work whether the firmware ships them as programs or Bash functions."""
    cmd = " ".join(sh_quote(str(a)) for a in args)
    if DRY:
        log("hub> " + cmd, "debug")
        return 0, ""
    try:
        with HUB_LOCK:
            p = subprocess.run(["bash", "-c", cmd], stdout=subprocess.PIPE, stderr=subprocess.STDOUT,
                               timeout=timeout)
        return p.returncode, p.stdout.decode("utf-8", "replace").strip()
    except Exception as e:
        return 1, str(e)


def sh_quote(s):
    if re.match(r"^[A-Za-z0-9_./:@,+=-]+$", s):
        return s
    return "'" + s.replace("'", "'\\''") + "'"


def run(cmd, timeout=10):
    try:
        p = subprocess.run(cmd, stdout=subprocess.PIPE, stderr=subprocess.DEVNULL, timeout=timeout)
        return p.stdout.decode("utf-8", "replace")
    except Exception:
        return ""


def have(prog):
    return shutil.which(prog) is not None


LED_STATE = {"base": "SETUP", "until": 0, "shown": None}


def led_link():
    """Steady LED from the radio and TAK links (radio first: TAK is optional for TurtleMesh)."""
    m = globals().get("MESH")
    radio = getattr(m, "link", "connecting")
    if radio != "connected":
        led("FAIL" if not (cfg("RADIO_HOST") or cfg("RADIO_CONN") == "usb") else "Y DOUBLE")
    elif cfgb("TAK") and S["tak"]["state"] != "connected" and not (tak_target()[0] or "example.com").endswith("example.com"):
        led("C SINGLE")
    else:
        led("G SINGLE")


IN_SHELL = bool(os.environ.get("TURTLESHELL"))


def led(state=None, flash=None, secs=30):
    """state = steady LED for the current link state; flash = temporary state (alerts)."""
    if state:
        LED_STATE["base"] = state
    if flash:
        LED_STATE["flash"] = flash
        LED_STATE["until"] = time.time() + secs
    want = LED_STATE["base"]
    if time.time() < LED_STATE.get("until", 0):
        want = LED_STATE.get("flash", want)
    if not cfgb("LED"):
        want = "OFF"
    if IN_SHELL:                       # TurtleShell: TurtleTAK owns the Hub's LED
        return
    if want != LED_STATE["shown"]:
        LED_STATE["shown"] = want
        hub("LED", *want.split())


def notify(level, msg):
    if cfgb("HUB_NOTIFY"):
        hub({"info": "NOTIFY_INFO", "warning": "NOTIFY_WARNING", "error": "NOTIFY_ERROR"}[level], "TurtleMesh", msg)
    if cfgb("C2_NOTIFY"):
        hub("C2NOTIFY", {"info": "INFO", "warning": "WARNING", "error": "ERROR"}[level], "TurtleMesh: " + msg)


# ----------------------------------------------------------------------------------------------
# shared state
# ----------------------------------------------------------------------------------------------
S = {
    "started": time.time(),
    "tak": {"state": "starting", "since": time.time(), "error": "", "tx": 0, "rx": 0, "last_rx": 0},
    "pos": {"lat": None, "lon": None, "ce": 9999999, "hae": 0, "src": "none", "time": 0},
    "gps": {"device": "", "fix": False, "sats": 0, "time": 0, "lat": None, "lon": None},
    "contacts": {},       # uid -> {callsign, lat, lon, type, team, time, how}
    "chat": [],           # {time, dir, from, to, room, text, id}
    "alerts": [],         # {id, time, kind, level, title, detail, sent}
    "net": {},            # network watch status
    "hosts": {},          # mac -> {ip, first, last, known, vendor}
    "bridge": {"up_rx": 0, "up_tx": 0, "down_tx": 0, "devices": {}, "ifaces": [], "error": ""},
    "status": {},
}
SL = threading.RLock()


def save_state():
    try:
        with SL:
            keep = {"pos": S["pos"], "alerts": S["alerts"][-200:], "chat": S["chat"][-300:]}
        tmp = "%s.%d.%d.tmp" % (STATEF, os.getpid(), threading.get_ident())
        with open(tmp, "w") as fh:
            json.dump(keep, fh)
        os.replace(tmp, STATEF)
    except Exception as e:
        log("state save failed: %s" % e, "warning")


def load_state():
    try:
        d = json.load(open(STATEF))
        with SL:
            if d.get("pos", {}).get("lat") is not None:
                S["pos"] = d["pos"]
                S["pos"]["src"] = "last known"
            S["alerts"] = d.get("alerts", [])
            S["chat"] = d.get("chat", [])
    except Exception:
        pass


# ----------------------------------------------------------------------------------------------
# CoT helpers
# ----------------------------------------------------------------------------------------------
def x(v):
    return _xesc(str(v), {'"': "&quot;"})


def iso(t=None):
    t = time.time() if t is None else t
    return time.strftime("%Y-%m-%dT%H:%M:%S", time.gmtime(t)) + ".%03dZ" % int((t % 1) * 1000)


def my_uid():
    u = cfg("UID")
    if not u:
        mac = ""
        for n in sorted(os.listdir("/sys/class/net")) if os.path.isdir("/sys/class/net") else []:
            try:
                m = open("/sys/class/net/%s/address" % n).read().strip()
                if m and m != "00:00:00:00:00:00":
                    mac = m
                    break
            except OSError:
                pass
        u = "TurtleMesh-" + (mac.replace(":", "")[-8:] if mac else uuid.uuid4().hex[:8])
        cfg_set({"UID": u})
    return u


def point_xml(lat, lon, ce=9999999, hae=0):
    if lat is None:
        lat, lon, ce = 0.0, 0.0, 9999999
    return '<point lat="%.7f" lon="%.7f" hae="%s" ce="%s" le="9999999"/>' % (lat, lon, hae or 0, int(ce))


def ev_open(uid, ctype, stale_s, how="h-e", t=None):
    t = time.time() if t is None else t
    return '<event version="2.0" uid="%s" type="%s" how="%s" time="%s" start="%s" stale="%s">' % (
        x(uid), x(ctype), how, iso(t), iso(t), iso(t + stale_s))


def sa_event():
    p = S["pos"]
    st = S["status"]
    uid = my_uid()
    remarks = status_text()
    interval = max(15, cfgi("SA_INTERVAL", 60))
    return (ev_open(uid, cfg("COT_TYPE", "a-f-G-E-S"), interval * 3 + 30, "m-g" if p["src"] in ("gps", "radio") else "h-e")
            + point_xml(p["lat"], p["lon"], p["ce"], p.get("hae", 0))
            + "<detail>"
            + '<contact callsign="%s" endpoint="*:-1:stcp"/>' % x(cfg("CALLSIGN"))
            + '<__group name="%s" role="%s"/>' % (x(cfg("TEAM")), x(cfg("ROLE")))
            + '<takv device="LAN Turtle Hub" platform="%s" os="%s" version="%s"/>' % (
                PRODUCT, x(st.get("os", "Linux")), VERSION)
            + '<precisionlocation geopointsrc="%s" altsrc="???"/>' % ("GPS" if p["src"] in ("gps", "radio") else "USER")
            + '<uid Droid="%s"/>' % x(cfg("CALLSIGN"))
            + "<remarks>%s</remarks>" % x(remarks)
            + "</detail></event>")


def chat_event(text, to_cs=None, to_uid=None):
    uid = my_uid()
    cs = cfg("CALLSIGN")
    mid = str(uuid.uuid4())
    if to_uid:
        room, rid = to_cs, to_uid
    else:
        room, rid = "All Chat Rooms", "All Chat Rooms"
    p = S["pos"]
    dest = '<marti><dest callsign="%s"/></marti>' % x(to_cs) if to_uid else ""
    return (ev_open("GeoChat.%s.%s.%s" % (uid, rid, mid), "b-t-f", 86400, "h-g-i-g-o")
            + point_xml(p["lat"], p["lon"], p["ce"])
            + "<detail>"
            + '<__chat parent="RootContactGroup" groupOwner="false" messageId="%s" chatroom="%s" id="%s" senderCallsign="%s">'
            % (mid, x(room), x(rid), x(cs))
            + '<chatgrp uid0="%s" uid1="%s" id="%s"/></__chat>' % (x(uid), x(rid), x(rid))
            + '<link uid="%s" type="%s" relation="p-p"/>' % (x(uid), x(cfg("COT_TYPE")))
            + '<remarks source="BAO.F.ATAK.%s" to="%s" time="%s">%s</remarks>' % (x(uid), x(rid), iso(), x(text))
            + dest + "</detail></event>"), mid, room


def marker_event(uid, ctype, title, remarks, lat, lon, ce, stale_s):
    return (ev_open(uid, ctype, stale_s, "h-e") + point_xml(lat, lon, ce)
            + "<detail>"
            + '<contact callsign="%s"/>' % x(title)
            + '<link uid="%s" production_time="%s" type="%s" parent_callsign="%s" relation="p-p"/>'
            % (x(my_uid()), iso(), x(cfg("COT_TYPE")), x(cfg("CALLSIGN")))
            + '<archive/><usericon iconsetpath="COT_MAPPING_2525B/%s/%s"/>' % (ctype[:3], ctype)
            + "<remarks>%s</remarks></detail></event>" % x(remarks))


ATTR_RE = re.compile(r'([A-Za-z_:][-\w:.]*)\s*=\s*"([^"]*)"|([A-Za-z_:][-\w:.]*)\s*=\s*\'([^\']*)\'')


def attrs(tag):
    out = {}
    for m in ATTR_RE.finditer(tag):
        if m.group(1):
            out[m.group(1)] = xml_unesc(m.group(2))
        else:
            out[m.group(3)] = xml_unesc(m.group(4))
    return out


def xml_unesc(v):
    return (v.replace("&lt;", "<").replace("&gt;", ">").replace("&quot;", '"').replace("&apos;", "'")
            .replace("&#10;", "\n").replace("&amp;", "&"))


def tag(ev, name):
    m = re.search(r"<%s\b([^>]*?)/?>" % re.escape(name), ev)
    return attrs(m.group(1)) if m else None


def parse_time(s):
    try:
        base, _, frac = s.rstrip("Z").partition(".")
        return calendar.timegm(time.strptime(base, "%Y-%m-%dT%H:%M:%S")) + float("0." + (re.sub(r"\D", "", frac) or "0"))
    except Exception:
        return time.time()


# ----------------------------------------------------------------------------------------------
# TAK protocol v1 (protobuf) - mesh SA from ATAK; tiny decoder, no library needed
# ----------------------------------------------------------------------------------------------
def pb_fields(buf):
    i, n = 0, len(buf)
    while i < n:
        key, i = pb_varint(buf, i)
        f, wt = key >> 3, key & 7
        if wt == 0:
            v, i = pb_varint(buf, i)
        elif wt == 1:
            v = buf[i:i + 8]; i += 8
        elif wt == 2:
            ln, i = pb_varint(buf, i)
            v = buf[i:i + ln]; i += ln
        elif wt == 5:
            v = buf[i:i + 4]; i += 4
        else:
            raise ValueError("wire type %d" % wt)
        yield f, wt, v


def pb_varint(buf, i):
    r = s = 0
    while True:
        b = buf[i]; i += 1
        r |= (b & 0x7F) << s
        s += 7
        if not b & 0x80:
            return r, i


def tak_proto_to_xml(data):
    """TAK protocol v1 mesh packet (0xbf 0x01 0xbf + TakMessage) -> CoT XML string."""
    if len(data) < 4 or data[0] != 0xBF or data[2] != 0xBF:
        return None
    ev = None
    for f, wt, v in pb_fields(data[3:]):
        if f == 2 and wt == 2:
            ev = v
    if ev is None:
        return None
    e = {}
    detail = b""
    for f, wt, v in pb_fields(ev):
        if wt == 2 and f in (1, 2, 3, 4, 5, 9):
            e[f] = v.decode("utf-8", "replace")
        elif wt == 0 and f in (6, 7, 8):
            e[f] = v
        elif wt == 1 and f in (10, 11, 12, 13, 14):
            e[f] = struct.unpack("<d", v)[0]
        elif f == 15 and wt == 2:
            detail = v
    d = []
    for f, wt, v in pb_fields(detail):
        if wt != 2:
            continue
        sub = {ff: vv for ff, ww, vv in pb_fields(v)} if f != 1 else {}
        s = lambda k: x(sub.get(k, b"").decode("utf-8", "replace")) if isinstance(sub.get(k, b""), bytes) else ""
        if f == 1:
            d.append(v.decode("utf-8", "replace"))
        elif f == 2:
            d.append('<contact endpoint="%s" callsign="%s"/>' % (s(1), s(2)))
        elif f == 3:
            d.append('<__group name="%s" role="%s"/>' % (s(1), s(2)))
        elif f == 4:
            d.append('<precisionlocation geopointsrc="%s" altsrc="%s"/>' % (s(1), s(2)))
        elif f == 5:
            d.append('<status battery="%s"/>' % sub.get(1, 0))
        elif f == 6:
            d.append('<takv device="%s" platform="%s" os="%s" version="%s"/>' % (s(1), s(2), s(3), s(4)))
        elif f == 7:
            sp = struct.unpack("<d", sub[1])[0] if isinstance(sub.get(1), bytes) and len(sub[1]) == 8 else 0
            co = struct.unpack("<d", sub[2])[0] if isinstance(sub.get(2), bytes) and len(sub[2]) == 8 else 0
            d.append('<track speed="%s" course="%s"/>' % (sp, co))
    ms = lambda k: iso(e.get(k, int(time.time() * 1000)) / 1000.0)
    return ('<event version="2.0" uid="%s" type="%s" how="%s" time="%s" start="%s" stale="%s">'
            % (x(e.get(5, "")), x(e.get(1, "a-u-G")), x(e.get(9, "m-g")), ms(6), ms(7), ms(8))
            + '<point lat="%s" lon="%s" hae="%s" ce="%s" le="%s"/>'
            % (e.get(10, 0.0), e.get(11, 0.0), e.get(12, 9999999.0), e.get(13, 9999999.0), e.get(14, 9999999.0))
            + "<detail>%s</detail></event>" % "".join(d))


# ----------------------------------------------------------------------------------------------
# certificates: ATAK connection package (.zip), .p12 files, PEM files, enrollment
# ----------------------------------------------------------------------------------------------
def write_secret(path, text):
    fd = os.open(path, os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o600)
    with os.fdopen(fd, "w") as fh:
        fh.write(text)


def b64_cert(v):
    """Server/file value -> clean base64 DER of one certificate (strips PEM headers, whitespace, escapes)."""
    v = re.sub(r"-----[A-Z0-9 ]+-----", "", str(v)).replace("\\n", "").replace("\\r", "")
    v = re.sub(r"[^A-Za-z0-9+/=]", "", v)
    der = base64.b64decode(v + "=" * (-len(v) % 4))
    if not der or der[0] != 0x30:
        raise ValueError("not a certificate")
    return base64.b64encode(der).decode()


def cert_pem(v):
    b = b64_cert(v)
    return "-----BEGIN CERTIFICATE-----\n%s\n-----END CERTIFICATE-----\n" % "\n".join(b[i:i + 64] for i in range(0, len(b), 64))


def pem_summary(path):
    """What is in a PEM file, without showing it: e.g. 'CERTIFICATE x1, RSA PRIVATE KEY x1'."""
    try:
        text = open(path, errors="replace").read()
    except OSError:
        return "missing"
    kinds = re.findall(r"-----BEGIN ([A-Z0-9 ]+)-----", text)
    if not kinds:
        return "no PEM blocks (%d bytes)" % len(text)
    out = []
    for k in sorted(set(kinds)):
        out.append("%s x%d" % (k, kinds.count(k)))
    if text.count("-----BEGIN") != text.count("-----END"):
        out.append("UNBALANCED begin/end")
    return ", ".join(out)


def save_cert_files(client=None, ca=None, why=""):
    """Check new client / CA PEM text loads in TLS before using it; keep the old files in certs/backup/."""
    tmp = {}
    try:
        for kind, text in (("client", client), ("ca", ca)):
            if text is None:
                continue
            t = os.path.join(CERTS, ".new-%s.pem" % kind)
            write_secret(t, text)
            tmp[kind] = t
        ctx = ssl.SSLContext(ssl.PROTOCOL_TLS_CLIENT)
        if "client" in tmp:
            try:
                ctx.load_cert_chain(tmp["client"])
            except (ssl.SSLError, OSError) as e:
                raise RuntimeError("the new client certificate does not load (%s; %s) - your old certificates are unchanged"
                                   % (e, pem_summary(tmp["client"])))
        if "ca" in tmp:
            try:
                ctx.load_verify_locations(tmp["ca"])
            except (ssl.SSLError, OSError) as e:
                raise RuntimeError("the new truststore does not load (%s; %s) - your old certificates are unchanged"
                                   % (e, pem_summary(tmp["ca"])))
        stamp = time.strftime("%Y%m%d-%H%M%S")
        for kind, t in tmp.items():
            cur = os.path.join(CERTS, kind + ".pem")
            if os.path.exists(cur):
                bdir = os.path.join(CERTS, "backup", stamp)
                os.makedirs(bdir, exist_ok=True)
                os.replace(cur, os.path.join(bdir, kind + ".pem"))
            os.replace(t, cur)
        if tmp:
            log("certificates updated (%s)%s" % (", ".join(sorted(tmp)), (" - " + why) if why else ""))
            threading.Thread(target=cert_check, daemon=True).start()
    finally:
        for t in tmp.values():
            if os.path.exists(t):
                os.unlink(t)


def restore_certs():
    bdir = os.path.join(CERTS, "backup")
    snaps = sorted(os.listdir(bdir)) if os.path.isdir(bdir) else []
    if not snaps:
        raise RuntimeError("no earlier certificates saved")
    last = os.path.join(bdir, snaps[-1])
    for kind in ("client", "ca"):
        f = os.path.join(last, kind + ".pem")
        if os.path.exists(f):
            os.replace(f, os.path.join(CERTS, kind + ".pem"))
    shutil.rmtree(last, ignore_errors=True)
    TAK.reconnect()
    return "restored the certificates from %s" % snaps[-1]


def p12_to_pem(p12, out, passwords, nokeys=False):
    """Convert a .p12 to PEM with the built-in reader (no openssl needed); openssl is only a fallback.
    passwords: one password or a list to try in order. Client: out gets leaf cert + key (+ CA certs go
    to ca.pem if there is none). CA: out gets every certificate."""
    if isinstance(passwords, str):
        passwords = [passwords]
    tried, errors = [], []
    data = open(p12, "rb").read()
    for pw in passwords:
        if pw is None or pw in tried:
            continue
        tried.append(pw)
        try:
            key, certs = ttcrypto.read_p12(data, pw)
        except ValueError as e:
            errors.append(str(e))
            if "wrong password" in str(e) or "padding" in str(e):
                continue
            break                                  # unsupported format: try openssl below
        kind_out = "ca" if os.path.basename(out).startswith("ca") else "client"
        if nokeys:
            if not certs:
                raise RuntimeError("%s has no certificates" % os.path.basename(p12))
            save_cert_files(**{kind_out: "".join(certs)}, why=os.path.basename(p12))
            return pw
        if not key:
            raise RuntimeError("%s has no private key - is it the truststore instead of the client cert?" % os.path.basename(p12))
        leaf, rest = ttcrypto.split_chain(key, certs)
        if not leaf:
            raise RuntimeError("%s: no certificate matches its private key" % os.path.basename(p12))
        ca = os.path.join(os.path.dirname(out), "ca.pem")
        save_cert_files(client=leaf + key, ca=("".join(rest) if rest and not os.path.exists(ca) else None),
                        why=os.path.basename(p12))
        return pw
    if have("openssl") and errors and not any("wrong password" in e for e in errors):
        for pw in tried:
            for legacy in (["-legacy"], []):
                p = subprocess.run(["openssl", "pkcs12"] + legacy + ["-in", p12, "-out", out, "-passin", "pass:" + pw]
                                   + (["-nokeys"] if nokeys else ["-nodes"]), stdout=subprocess.PIPE, stderr=subprocess.PIPE, timeout=30)
                if p.returncode == 0 and os.path.getsize(out) > 0:
                    os.chmod(out, 0o600)
                    return pw
    if any("wrong password" in e or "padding" in e for e in errors):
        raise RuntimeError("wrong password for %s - type its password in Setup (client and truststore passwords are separate)"
                           % os.path.basename(p12))
    raise RuntimeError("could not read %s: %s" % (os.path.basename(p12), "; ".join(errors) or "unknown format"))


def pref(xmltext, key):
    m = re.search(r'<entry[^>]*key="%s"[^>]*>([^<]*)</entry>' % re.escape(key), xmltext)
    return xml_unesc(m.group(1).strip()) if m else ""


def import_package(path, client_pw=None, ca_pw=None):
    """ATAK connection data package -> server settings + certs/client.pem + certs/ca.pem."""
    z = zipfile.ZipFile(path)
    names = z.namelist()
    prefs = [n for n in names if n.lower().endswith(".pref")]
    if not prefs:
        raise RuntimeError("no .pref file in %s - is it an ATAK connection package?" % os.path.basename(path))
    text = "\n".join(z.read(n).decode("utf-8", "replace") for n in prefs)
    conn = pref(text, "connectString0")
    parts = conn.split(":")
    if len(parts) < 2:
        raise RuntimeError("no TAK Server (connectString0) in the package")
    changes = {"TAK_HOST": parts[0], "TAK_PORT": parts[1],
               "TAK_PROTO": {"ssl": "tls", "tcp": "tcp", "udp": "udp"}.get((parts[2] if len(parts) > 2 else "ssl").lower(), "tls")}
    by_base = {os.path.basename(n): n for n in names if n.lower().endswith(".p12")}
    for kind, key, pwkey in (("client", "certificateLocation", "clientPassword"), ("ca", "caLocation", "caPassword")):
        base = os.path.basename(pref(text, key))
        src = by_base.get(base)
        if not src:
            continue
        tmp = os.path.join(CERTS, ".%s.p12" % kind)
        with open(tmp, "wb") as fh:
            fh.write(z.read(src))
        try:
            typed = client_pw if kind == "client" else ca_pw
            setting = "CLIENT_PASSWORD" if kind == "client" else "CA_PASSWORD"
            used = p12_to_pem(tmp, os.path.join(CERTS, kind + ".pem"),
                              [typed, pref(text, pwkey), cfg(setting), "atakatak"], nokeys=(kind == "ca"))
            changes[setting] = used
        finally:
            os.unlink(tmp)
    cfg_set(changes)
    log("imported connection package %s -> %s:%s (%s)" % (os.path.basename(path), changes["TAK_HOST"],
                                                         changes["TAK_PORT"], changes["TAK_PROTO"]))
    done = os.path.join(CERTS, "imported")
    os.makedirs(done, exist_ok=True)
    os.replace(path, os.path.join(done, os.path.basename(path)))
    return changes


def cert_kind(name):
    return "ca" if re.search(r"trust|(^|[^a-z])ca([^a-z]|$)|root", name, re.I) else "client"


def scan_certs():
    """Pick up a connection package or .p12 files dropped in certs/."""
    try:
        for n in sorted(os.listdir(CERTS)):
            p = os.path.join(CERTS, n)
            if n.lower().endswith(".zip"):
                try:
                    import_package(p)
                    notify("info", "Imported TAK connection package %s" % n)
                    TAK.reconnect()
                except Exception as e:
                    log("package %s: %s" % (n, e), "error")
                    notify("error", "Connection package %s: %s" % (n, e))
                    os.replace(p, p + ".failed")
            elif n.lower().endswith(".p12"):
                kind = cert_kind(n)
                try:
                    p12_to_pem(p, os.path.join(CERTS, kind + ".pem"),
                               [cfg("CLIENT_PASSWORD" if kind == "client" else "CA_PASSWORD"), "atakatak"], nokeys=(kind == "ca"))
                    os.makedirs(os.path.join(CERTS, "imported"), exist_ok=True)
                    os.replace(p, os.path.join(CERTS, "imported", n))
                    log("converted %s -> %s.pem" % (n, kind))
                    TAK.reconnect()
                except Exception as e:
                    log(str(e), "error")
                    os.replace(p, p + ".failed")
    except FileNotFoundError:
        pass


def enroll(user, password):
    """TAK Server certificate enrollment (port 8446). Key and CSR are made in Python - no openssl needed."""
    if not user or not password:
        raise RuntimeError("enter your TAK Server username and password")
    host, port = cfg("TAK_HOST"), cfgi("ENROLL_PORT", 8446)
    ctx = ssl.create_default_context()
    ctx.check_hostname = False
    ctx.verify_mode = ssl.CERT_NONE
    auth = "Basic " + base64.b64encode(("%s:%s" % (user, password)).encode()).decode()

    def call(path, body=None, ctype="text/plain"):
        req = urllib.request.Request("https://%s:%d%s" % (host, port, path), data=body,
                                     headers={"Authorization": auth, "Content-Type": ctype, "Accept": "application/json"})
        try:
            with urllib.request.urlopen(req, context=ctx, timeout=60) as r:
                return r.read().decode("utf-8", "replace")
        except urllib.error.HTTPError as e:
            if e.code == 401:
                raise RuntimeError("the TAK Server rejected that username or password")
            raise RuntimeError("enrollment %s failed: HTTP %d" % (path.split("?")[0], e.code))
        except (urllib.error.URLError, OSError) as e:
            raise RuntimeError("cannot reach %s:%d for enrollment: %s" % (host, port, getattr(e, "reason", e)))

    conf = call("/Marti/api/tls/config")
    names = dict(re.findall(r'<nameEntry[^>]*name="([^"]+)"[^>]*value="([^"]*)"', conf))
    subject = [(k, v) for k, v in names.items() if k.upper() != "CN"] + [("CN", user)]
    log("enrollment: making a 2048-bit key (can take up to a minute on the Hub)")
    key = ttcrypto.rsa_generate(2048)
    csr = ttcrypto.pem("CERTIFICATE REQUEST", ttcrypto.csr_der(key, subject))
    body = "".join(l for l in csr.splitlines(True) if "CERTIFICATE REQUEST" not in l)
    raw = call("/Marti/api/tls/signClient/v2?clientUid=%s&version=%s" % (my_uid(), VERSION), body.encode())
    try:
        resp = json.loads(raw)
    except ValueError:   # some servers answer in XML
        resp = {m[0]: m[1] for m in re.findall(r"<(signedCert|ca\d*)>\s*([^<]+?)\s*</\1>", raw)}
        if "ca" in resp:
            resp["ca0"] = resp.pop("ca")
    log("enrollment reply fields: %s" % ", ".join("%s(%d)" % (k, len(str(v))) for k, v in sorted(resp.items())))
    if "signedCert" not in resp:
        raise RuntimeError("the TAK Server did not return a certificate (fields: %s)" % ", ".join(sorted(resp)))
    try:
        client_text = cert_pem(resp["signedCert"]) + ttcrypto.rsa_key_pem(key)
    except ValueError as e:
        raise RuntimeError("the certificate the TAK Server sent could not be read (%s) - your old certificates are unchanged" % e)
    cas = []
    for k, v in sorted(resp.items()):
        if re.match(r"^ca\d*$", k):
            try:
                cas.append(cert_pem(v))
            except ValueError:
                log("enrollment: skipped %s (not a certificate)" % k, "warning")
    save_cert_files(client=client_text, ca=("".join(cas) if cas else None), why="enrollment")
    cfg_set({"TAK_PROTO": "tls"})
    log("enrolled with %s:%d" % (host, port))
    TAK.reconnect()


# ----------------------------------------------------------------------------------------------
# TAK Server link
# ----------------------------------------------------------------------------------------------
def turtletak_cfg():
    """TurtleTAK's settings, when TurtleTAK is installed on this Hub."""
    p = os.path.join(TURTLETAK_BASE, "default.cfg")
    out = {}
    try:
        for line in open(p, encoding="utf-8", errors="replace"):
            if ":" in line and not line.lstrip().startswith("#"):
                k, v = line.split(":", 1)
                out[k.strip()] = v.strip()
    except OSError:
        pass
    return out


def tak_target():
    """-> (host, port, proto, cert_dir, verify_host, source)"""
    if cfgb("TAK_FROM_TURTLETAK"):
        t = turtletak_cfg()
        tdir = os.path.join(TURTLETAK_BASE, "certs")
        if t.get("TAK_HOST") and not t["TAK_HOST"].endswith("example.com"):
            try:
                port = int(t.get("TAK_PORT", "8089"))
            except ValueError:
                port = 8089
            return (t["TAK_HOST"], port, t.get("TAK_PROTO", "tls").lower(), tdir,
                    t.get("TAK_VERIFY_HOST", "0") == "1", "TurtleTAK")
    return cfg("TAK_HOST"), cfgi("TAK_PORT", 8089), cfg("TAK_PROTO", "tls").lower(), CERTS, cfgb("TAK_VERIFY_HOST"), "own"


class TakLink:
    def __init__(self):
        self.sock = None
        self.lock = threading.Lock()
        self.kick = threading.Event()
        self.down_since = time.time()
        self.alerted_down = False
        self.recent_down = {}          # uid -> time, events we repeated onto the mesh (loop guard)

    def connected(self):
        return self.sock is not None

    def reconnect(self):
        with self.lock:
            self._close()
        self.kick.set()

    def _close(self):
        if self.sock:
            try:
                self.sock.close()
            except OSError:
                pass
        self.sock = None

    def set_state(self, st, err=""):
        with SL:
            if (S["tak"]["state"] == "connected") != (st == "connected"):
                S["tak"]["since"] = time.time()
            S["tak"]["state"] = st
            S["tak"]["error"] = err

    def open(self):
        host, port, proto, cdir, verify, _src = tak_target()
        if not cfgb("TAK"):
            raise RuntimeError("TAK is off (Settings > TAK)")
        if not host or host.endswith("example.com"):
            raise RuntimeError("set TAK_HOST (Settings, or drop a connection package in certs/)")
        if proto == "udp":
            s = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
            s.connect((host, port))
            return s
        raw = socket.create_connection((host, port), timeout=15)
        if proto != "tls":
            raw.settimeout(None)
            return raw
        client = os.path.join(cdir, "client.pem")
        ca = os.path.join(cdir, "ca.pem")
        if not os.path.exists(client):
            raw.close()
            raise RuntimeError("no client certificate - drop an ATAK connection package (.zip) in %s, or enroll" % CERTS)
        ctx = ssl.SSLContext(ssl.PROTOCOL_TLS_CLIENT)
        keyf = os.path.join(cdir, "client.key")
        ctx.load_cert_chain(client, keyf if os.path.exists(keyf) else None)
        if os.path.exists(ca):
            ctx.load_verify_locations(ca)
            ctx.check_hostname = verify
            ctx.verify_mode = ssl.CERT_REQUIRED
        else:
            ctx.check_hostname = False
            ctx.verify_mode = ssl.CERT_NONE
            log("no ca.pem - the server certificate is not checked", "warning")
        s = ctx.wrap_socket(raw, server_hostname=host)
        s.settimeout(None)
        return s

    def send(self, xml, queue=False):
        data = xml.encode("utf-8")
        with self.lock:
            if self.sock:
                try:
                    self.sock.sendall(data)
                    with SL:
                        S["tak"]["tx"] += 1
                    return True
                except OSError as e:
                    log("TAK send failed: %s" % e, "warning")
                    self._close()
                    self.kick.set()
        if queue:
            with open(QUEUE, "a") as fh:
                fh.write(json.dumps({"t": time.time(), "xml": xml}) + "\n")
        return False

    def flush_queue(self):
        if not os.path.exists(QUEUE):
            return
        lines = open(QUEUE).read().splitlines()
        os.unlink(QUEUE)
        sent = 0
        for i, l in enumerate(lines):
            try:
                xml = json.loads(l)["xml"]
            except Exception:
                continue
            if not self.send(xml):
                with open(QUEUE, "a") as fh:
                    fh.write("\n".join(lines[i:]) + "\n")
                break
            sent += 1
        if sent:
            log("sent %d queued message(s)" % sent)

    def run(self):
        backoff = 5
        while True:
            self.kick.clear()
            try:
                self.set_state("connecting")
                s = self.open()
                with self.lock:
                    self.sock = s
                self.set_state("connected")
                led_link()
                log("TAK connected to %s:%s (%s)" % tak_target()[:3])
                if self.alerted_down:
                    raise_alert("uplink", "info", "TAK link restored",
                                "Back on the TAK Server after %s." % dur(time.time() - self.down_since), marker=False)
                self.alerted_down = False
                backoff = 5
                self.send(sa_event())
                self.flush_queue()
                if tak_target()[2] == "udp":
                    while not self.kick.wait(30):
                        pass
                else:
                    self.read_loop(s)
            except Exception as e:
                err = str(e) or e.__class__.__name__
                self.set_state("down", err)
                if S["tak"]["error"] != getattr(self, "_last_err", None):
                    log("TAK: %s" % err, "warning")
                self._last_err = err
            with self.lock:
                self._close()
            if S["tak"]["state"] == "connected":
                self.set_state("down", "disconnected")
            led_link()
            self.kick.wait(backoff)
            backoff = min(backoff * 2, 60)

    def read_loop(self, s):
        buf = b""
        while True:
            try:
                chunk = s.recv(65536)
            except OSError as e:
                raise RuntimeError("read: %s" % e)
            if not chunk:
                raise RuntimeError("server closed the connection")
            buf += chunk
            if len(buf) > 2 * 1024 * 1024:
                buf = buf[-65536:]
            while b"</event>" in buf:
                ev, buf = buf.split(b"</event>", 1)
                start = ev.find(b"<event")
                if start < 0:
                    continue
                handle_event((ev[start:] + b"</event>").decode("utf-8", "replace"), source="server")

    def watchdog(self):
        """Raise an alert when the TAK link has been down longer than UPLINK_GRACE."""
        while True:
            time.sleep(10)
            if not cfgb("UPLINK_WATCH") or self.connected() or self.alerted_down:
                continue
            if S["tak"]["state"] in ("down", "connecting") and time.time() - S["tak"]["since"] > cfgi("UPLINK_GRACE", 120):
                if S["tak"]["error"].startswith("set TAK_HOST") or "certificate" in S["tak"]["error"]:
                    continue
                self.alerted_down = True
                self.down_since = S["tak"]["since"]
                raise_alert("uplink", "warning", "TAK link down",
                            "No TAK Server for %s: %s" % (dur(time.time() - S["tak"]["since"]), S["tak"]["error"]),
                            marker=False)


TAK = TakLink()


def handle_event(ev, source="server"):
    uid = (re.search(r'<event[^>]*\suid="([^"]*)"', ev) or [None, ""])[1]
    ctype = (re.search(r'<event[^>]*\stype="([^"]*)"', ev) or [None, ""])[1]
    if not uid or uid == my_uid():
        return
    with SL:
        S["tak"]["rx"] += 1
        S["tak"]["last_rx"] = time.time()
    if ctype.startswith("b-t-f"):
        chat_in(ev, ctype)
        return
    if ctype.startswith("t-x"):
        return
    pt = tag(ev, "point") or {}
    contact = tag(ev, "contact") or {}
    if not contact.get("callsign"):
        return
    try:
        lat, lon = float(pt.get("lat", 0)), float(pt.get("lon", 0))
    except ValueError:
        return
    grp = tag(ev, "__group") or {}
    stale = (re.search(r'<event[^>]*\sstale="([^"]*)"', ev) or [None, ""])[1]
    with SL:
        S["contacts"][uid] = {"callsign": contact["callsign"], "lat": lat, "lon": lon,
                              "ce": float(pt.get("ce", 9999999) or 9999999), "type": ctype, "team": grp.get("name", ""),
                              "role": grp.get("role", ""), "time": time.time(), "stale": parse_time(stale) if stale else 0,
                              "source": source, "endpoint": contact.get("endpoint", "")}
        if len(S["contacts"]) > 2000:
            for k in sorted(S["contacts"], key=lambda k: S["contacts"][k]["time"])[:200]:
                del S["contacts"][k]


def chat_in(ev, ctype):
    if ctype != "b-t-f":
        return
    c = tag(ev, "__chat") or {}
    m = re.search(r"<remarks[^>]*>(.*?)</remarks>", ev, re.S)
    text = xml_unesc(m.group(1)) if m else ""
    sender_uid = ((tag(ev, "link") or {}).get("uid")) or ""
    mid = c.get("messageId", "")
    with SL:
        if mid and any(cc.get("id") == mid for cc in S["chat"][-200:]):
            return
        to_me = c.get("id") == my_uid() or c.get("chatroom") == cfg("CALLSIGN")
        S["chat"].append({"time": time.time(), "dir": "in", "from": c.get("senderCallsign", "?"), "from_uid": sender_uid,
                          "room": "Direct" if to_me else c.get("chatroom", ""), "text": text, "id": mid})
        del S["chat"][:-300]
    log("chat from %s: %s" % (c.get("senderCallsign", "?"), text[:120]))
    if not to_me:
        threading.Thread(target=BRIDGE.tak_chat_to_mesh, args=(c.get("senderCallsign", "?"), sender_uid or "",
                                                              c.get("chatroom", ""), text), daemon=True).start()
    if to_me and cfgb("CHAT_COMMANDS"):
        chat_command(text.strip(), c.get("senderCallsign", ""), sender_uid)
    save_state()


def chat_send(text, to_cs=None):
    to_uid = None
    if to_cs:
        with SL:
            for u, c in S["contacts"].items():
                if c["callsign"] == to_cs:
                    to_uid = u
        if not to_uid:
            raise RuntimeError("no TAK contact called %s" % to_cs)
    xml, mid, room = chat_event(text, to_cs, to_uid)
    ok = TAK.send(xml, queue=True)
    with SL:
        S["chat"].append({"time": time.time(), "dir": "out", "from": cfg("CALLSIGN"), "room": room, "text": text,
                          "id": mid, "sent": ok})
        del S["chat"][:-300]
    save_state()
    return ok


def chat_command(text, cs, uid):
    allow = [a.strip() for a in cfg("CHAT_COMMANDS_FROM").split(",") if a.strip()]
    if allow and cs not in allow:
        return
    cmd = text.lower().split()[0] if text else ""
    reply = command_reply(cmd)
    if not reply:
        return
    try:
        chat_send(reply, cs)
    except RuntimeError:
        pass


# ----------------------------------------------------------------------------------------------
# alerts
# ----------------------------------------------------------------------------------------------
ALERT_TYPES = {"warning": "a-u-G", "critical": "a-h-G", "info": "a-n-G"}


LEVELS = {"info": 0, "warning": 1, "critical": 2}
ALERT_KINDS = [("new_node", "New mesh node"), ("quiet", "Watched node quiet / back"), ("battery", "Low battery"),
               ("sensor", "Detection sensors"), ("radio", "Radio link lost / restored"),
               ("uplink", "TAK link down / restored"), ("cert", "Certificate expiring")]


def in_quiet_hours(now=None):
    q = cfg("QUIET_HOURS").replace(" ", "")
    m = re.match(r"^(\d{1,2})(?::(\d\d))?-(\d{1,2})(?::(\d\d))?$", q)
    if not m:
        return False
    t = time.localtime(now or time.time())
    cur = t.tm_hour * 60 + t.tm_min
    start = int(m.group(1)) * 60 + int(m.group(2) or 0)
    end = int(m.group(3)) * 60 + int(m.group(4) or 0)
    return start <= cur < end if start < end else (cur >= start or cur < end)


def raise_alert(kind, level, title, detail, marker=True, key=None, at=None):
    """level: info | warning | critical. Goes to TAK (marker + chat), the Hub UI, Cloud C2, LED -
    filtered by ALERTS_ON, MARKER_MIN_LEVEL, CHAT_MIN_LEVEL and QUIET_HOURS."""
    now = time.time()
    if kind != "test" and kind not in [k.strip() for k in cfg("ALERTS_ON").split(",")]:
        log("alert type %s is off: %s - %s" % (kind, title, detail), "debug")
        return
    with SL:
        if key and any(a.get("key") == key and now - a["time"] < 3600 for a in S["alerts"]):
            return
        aid = "%s-%d-%04d" % (kind, int(now), random.randint(0, 9999))
        a = {"id": aid, "key": key, "time": now, "kind": kind, "level": level, "title": title, "detail": detail}
        S["alerts"].append(a)
        del S["alerts"][:-200]
    rank = LEVELS.get(level, 0)
    quiet = in_quiet_hours(now) and not (level == "critical" and cfgb("QUIET_CRITICAL"))
    log("ALERT [%s] %s - %s%s" % (level, title, detail, " (quiet hours)" if quiet else ""), "warning" if level != "info" else "info")
    notify("error" if level == "critical" else ("warning" if level == "warning" else "info"), "%s: %s" % (title, detail))
    if level != "info" and not quiet:
        led(flash="SPECIAL" if level == "warning" else "FAIL2", secs=60)
    line = "[%s] %s %s - %s" % (cfg("CALLSIGN"), {"critical": "CRITICAL", "warning": "WARNING"}.get(level, "INFO"),
                                title, detail)
    p = S["pos"]
    if marker and cfgb("ALERT_MARKER") and (p["lat"] is not None or at) and rank >= LEVELS.get(cfg("MARKER_MIN_LEVEL"), 1):
        base_lat, base_lon = at if at else (p["lat"], p["lon"])
        ang = random.uniform(0, 2 * math.pi)
        dlat = 15 * math.cos(ang) / 111111.0
        dlon = 15 * math.sin(ang) / (111111.0 * max(0.1, math.cos(math.radians(base_lat))))
        rem = "%s\n%s\nFrom %s (%s) at %s. %s" % (
            title, detail, cfg("CALLSIGN"), PRODUCT, time.strftime("%Y-%m-%d %H:%M:%S %Z"),
            "Position is the mesh node's." if at else "Position is the Hub's, offset a few meters.")
        TAK.send(marker_event("%s.alert.%s" % (my_uid(), aid), ALERT_TYPES.get(level, "a-u-G"),
                              "%s %s" % (cfg("CALLSIGN"), title), rem, base_lat + dlat, base_lon + dlon,
                              max(15, p["ce"]), cfgi("ALERT_STALE_HOURS", 12) * 3600), queue=True)
    if cfgb("ALERT_CHAT") and not quiet and rank >= LEVELS.get(cfg("CHAT_MIN_LEVEL"), 0):
        to = cfg("ALERT_TO").strip() or None
        try:
            chat_send(line, to)
        except RuntimeError:
            chat_send(line, None)
    save_state()


# ----------------------------------------------------------------------------------------------
# client certificate expiry
# ----------------------------------------------------------------------------------------------
def cert_info():
    path = os.path.join(tak_target()[3], "client.pem")
    if not os.path.exists(path):
        return {}
    try:
        d = ssl._ssl._test_decode_cert(path)
        exp = ssl.cert_time_to_seconds(d["notAfter"])
        subj = ", ".join("%s=%s" % kv for rdn in d.get("subject", ()) for kv in rdn)
        return {"subject": subj, "expires": exp, "days": int((exp - time.time()) // 86400),
                "issuer": ", ".join("%s=%s" % kv for rdn in d.get("issuer", ()) for kv in rdn)}
    except Exception as e:
        return {"error": str(e)}


def cert_check():
    c = cert_info()
    with SL:
        S["cert"] = c
    if "days" not in c:
        return
    day = time.strftime("%Y-%m-%d")
    if c["days"] < 0:
        raise_alert("cert", "critical", "Client certificate expired",
                    "Expired %s - TurtleMesh cannot connect until it is renewed (Setup > Enroll)" %
                    time.strftime("%Y-%m-%d", time.localtime(c["expires"])), marker=False, key="certexp:" + day)
    elif c["days"] <= cfgi("CERT_WARN_DAYS", 30):
        raise_alert("cert", "warning", "Client certificate expires in %d days" % c["days"],
                    "Expires %s - renew it (Setup > Enroll, or a new certificate)" %
                    time.strftime("%Y-%m-%d", time.localtime(c["expires"])), marker=False, key="certwarn:" + day)


# ----------------------------------------------------------------------------------------------
# system status, interfaces
# ----------------------------------------------------------------------------------------------

def _ioctl_addr(name, req):
    import fcntl
    s = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
    try:
        r = fcntl.ioctl(s.fileno(), req, struct.pack("256s", name[:15].encode()))
        return socket.inet_ntoa(r[20:24])
    finally:
        s.close()


def ipv4_addrs():
    """iface -> [cidr]. `ip` when present, else ioctl (primary address only)."""
    out = {}
    if have("ip"):
        for line in run(["ip", "-o", "-4", "addr", "show"]).splitlines():
            m = re.match(r"\d+:\s+(\S+)\s+inet\s+(\S+)", line)
            if m:
                out.setdefault(m.group(1), []).append(m.group(2))
        return out
    for n in (os.listdir("/sys/class/net") if os.path.isdir("/sys/class/net") else []):
        try:
            a = _ioctl_addr(n, 0x8915)
            mask = _ioctl_addr(n, 0x891B)
            out[n] = ["%s/%d" % (a, ipaddress.ip_network("0.0.0.0/%s" % mask).prefixlen)]
        except OSError:
            pass
    return out


def routes():
    """[(iface, dest_cidr, gateway)] from /proc/net/route."""
    out = []
    for line in rd("/proc/net/route").splitlines()[1:]:
        f = line.split()
        if len(f) < 8:
            continue
        h = lambda v: socket.inet_ntoa(struct.pack("<I", int(v, 16)))
        out.append((f[0], "%s/%d" % (h(f[1]), ipaddress.ip_network("0.0.0.0/%s" % h(f[7])).prefixlen), h(f[2])))
    return out


def neighbors(dev=None):
    """[(ip, mac, iface)] from /proc/net/arp (complete entries only)."""
    out = []
    for line in rd("/proc/net/arp").splitlines()[1:]:
        f = line.split()
        if len(f) >= 6 and int(f[2], 16) & 2 and f[3] != "00:00:00:00:00:00" and (dev is None or f[5] == dev):
            out.append((f[0], f[3].lower(), f[5]))
    return out


def ifaces():
    """name -> {ipv4: [cidr], mac, carrier, kind}"""
    out = {n: {"ipv4": a} for n, a in ipv4_addrs().items()}
    base = "/sys/class/net"
    for n in (os.listdir(base) if os.path.isdir(base) else []):
        d = out.setdefault(n, {"ipv4": []})
        d["mac"] = rd("%s/%s/address" % (base, n))
        d["carrier"] = rd("%s/%s/carrier" % (base, n)) == "1"
        d["oper"] = rd("%s/%s/operstate" % (base, n))
        d["wireless"] = os.path.isdir("%s/%s/wireless" % (base, n)) or os.path.isdir("%s/%s/phy80211" % (base, n))
        d["bridge"] = os.path.isdir("%s/%s/bridge" % (base, n))
        d["usb"] = "usb" in os.path.realpath("%s/%s/device" % (base, n)) if os.path.exists("%s/%s/device" % (base, n)) else False
    return out


def rd(p):
    try:
        return open(p).read().strip()
    except OSError:
        return ""


def default_route(dev=None):
    for n, dest, gw in routes():
        if dest == "0.0.0.0/0" and gw != "0.0.0.0" and (dev is None or n == dev):
            return gw, n
    return None, None


def rj45_iface(ifs=None):
    w = cfg("WATCH_IFACE", "auto")
    if w and w != "auto":
        return w
    ifs = ifs or ifaces()
    # The Hub's RJ45 is its "WAN" (WAN_IPCONFIG). Prefer an Ethernet with carrier and an IPv4 address that
    # is not the USB-C target side (172.16.84.0/24 by default) and not Wi-Fi / VPN / bridge.
    cands = []
    for n, d in ifs.items():
        if n == "lo" or d.get("wireless") or n.startswith(("wg", "tun", "nb", "wt", "br-", "docker")):
            continue
        if any(c.startswith("172.16.84.") for c in d.get("ipv4", [])):
            continue
        score = (2 if d.get("ipv4") else 0) + (1 if d.get("carrier") else 0) + (1 if n.startswith(("eth", "wan")) else 0)
        cands.append((score, n))
    gw, dev = default_route()
    if dev and dev in ifs and not ifs[dev].get("wireless") and not dev.startswith(("wg", "tun")):
        return dev
    return max(cands)[1] if cands else None


def status_collect():
    ifs = ifaces()
    gw, dev = default_route()
    rj = rj45_iface(ifs)
    wifi = [n for n, d in ifs.items() if d.get("wireless") and d.get("ipv4")]
    wg = run(["wg", "show", "interfaces"]).split() if have("wg") else []
    wg_hs = ""
    if wg:
        hs = run(["wg", "show", wg[0], "latest-handshakes"]).split()
        if len(hs) >= 2 and hs[1].isdigit() and int(hs[1]):
            wg_hs = dur(time.time() - int(hs[1])) + " ago"
    up = float((rd("/proc/uptime") or "0").split()[0])
    mem = {}
    for line in rd("/proc/meminfo").splitlines():
        k, _, v = line.partition(":")
        mem[k] = int(v.split()[0]) if v.split() else 0
    leases = len([l for l in rd("/tmp/dhcp.leases").splitlines() if l.strip()])
    nb = ""
    if have("netbird"):
        nb = "connected" if "Management: Connected" in run(["netbird", "status"], 8) else "not connected"
    osname = ""
    for line in rd("/etc/os-release").splitlines():
        if line.startswith("PRETTY_NAME="):
            osname = line.split("=", 1)[1].strip('"')
    st = {
        "uplink": dev or "none", "gateway": gw or "", "rj45": rj or "", "rj45_ip": ",".join(ifs.get(rj, {}).get("ipv4", [])) if rj else "",
        "rj45_link": bool(ifs.get(rj, {}).get("carrier")) if rj else False,
        "wifi_client": ",".join("%s %s" % (n, ifs[n]["ipv4"][0]) for n in wifi),
        "vpn": ("WireGuard %s%s" % (wg[0], (", handshake " + wg_hs) if wg_hs else "")) if wg else "",
        "netbird": nb, "uptime": up, "mem_free_kb": mem.get("MemAvailable", mem.get("MemFree", 0)),
        "mem_total_kb": mem.get("MemTotal", 0), "load": (rd("/proc/loadavg") or "0").split()[0],
        "target_leases": leases, "os": osname or "Linux", "public_ip": S["status"].get("public_ip", ""),
        "isp": S["status"].get("isp", ""), "ifaces": {n: {k: d.get(k) for k in ("ipv4", "mac", "carrier", "wireless", "usb")}
                                                      for n, d in ifs.items() if n != "lo"},
        "dns": DNS_CACHE.get(cfg("TAK_HOST"), ""),
        "tools": {t: have(t) for t in ("openssl", "nmap", "wg", "netbird", "arping", "tcpdump", "stty")},
        "python": sys.version.split()[0],
    }
    with SL:
        S["status"] = st
    return st


def status_text():
    st = S["status"]
    p = S["pos"]
    parts = ["%s %s %s" % (PRODUCT, EDITION, VERSION),
             "Uplink: %s%s" % (st.get("uplink", "?"), (" via " + st["gateway"]) if st.get("gateway") else ""),
             "RJ45: %s %s" % ("link" if st.get("rj45_link") else "NO LINK", st.get("rj45_ip", "")),
             ]
    if st.get("wifi_client"):
        parts.append("Wi-Fi: " + st["wifi_client"])
    if st.get("vpn"):
        parts.append("VPN: " + st["vpn"])
    if st.get("netbird"):
        parts.append("NetBird: " + st["netbird"])
    if st.get("public_ip"):
        parts.append("Public IP: %s %s" % (st["public_ip"], st.get("isp", "")))
    rows = MESH.node_rows()
    heard = len([r for r in rows if not r["me"] and r["age"] is not None and r["age"] < 3600])
    parts.append("Radio: %s %s (%s, %s)" % (MESH.link, MESH.name_of(MESH.my_num) if MESH.my_num else "",
                                          cfg("RADIO_CONN"), mp.REGIONS.get(MESH.region, "?")))
    parts.append("Mesh: %d nodes, %d heard in the last hour" % (len([r for r in rows if not r["me"]]), heard))
    if cfgb("MQTT_PROXY"):
        parts.append("MQTT proxy: %s" % MQTT.state)
    parts.append("Location: %s, +/- %s m" % (p["src"], int(p["ce"]) if p["ce"] < 9999999 else "?"))
    parts.append("Up %s, load %s, %d MB free" % (dur(st.get("uptime", 0)), st.get("load", "?"), st.get("mem_free_kb", 0) // 1024))
    return "\n".join(parts)


def dur(s):
    s = int(max(0, s))
    if s < 90:
        return "%ds" % s
    if s < 5400:
        return "%dm" % (s // 60)
    if s < 172800:
        return "%dh%02dm" % (s // 3600, (s % 3600) // 60)
    return "%dd%02dh" % (s // 86400, (s % 86400) // 3600)


def fmt_ll(lat, lon):
    return "unknown" if lat is None else "%.5f, %.5f" % (lat, lon)


# ----------------------------------------------------------------------------------------------
# location
# ----------------------------------------------------------------------------------------------
def sites():
    out = []
    for line in (open(SITES).read().splitlines() if os.path.exists(SITES) else []):
        p = line.split("|")
        if len(p) >= 3:
            try:
                out.append({"name": p[0], "lat": float(p[1]), "lon": float(p[2])})
            except ValueError:
                pass
    return out


def save_site(name, lat, lon):
    rows = [s for s in sites() if s["name"] != name] + [{"name": name, "lat": lat, "lon": lon}]
    with open(SITES, "w") as fh:
        fh.write("".join("%s|%.7f|%.7f\n" % (s["name"].replace("|", "/"), s["lat"], s["lon"]) for s in rows))


IPGEO = {"t": 0, "lat": None, "lon": None}


def ipgeo():
    if time.time() - IPGEO["t"] < 3600:
        return IPGEO
    IPGEO["t"] = time.time()
    try:
        with urllib.request.urlopen(cfg("IPGEO_URL"), timeout=10) as r:
            d = json.loads(r.read().decode())
        if "loc" in d:
            IPGEO["lat"], IPGEO["lon"] = [float(v) for v in d["loc"].split(",")]
        elif "lat" in d:
            IPGEO["lat"], IPGEO["lon"] = float(d["lat"]), float(d.get("lon", d.get("lng")))
        with SL:
            S["status"]["public_ip"] = d.get("ip") or d.get("query", "")
            S["status"]["isp"] = d.get("org") or d.get("isp", "")
    except Exception as e:
        log("IP geolocation failed: %s" % e, "debug")
    return IPGEO


LOC_ORDER = ["radio", "gps", "atak", "mesh", "site", "manual", "ip"]


def radio_fix():
    """The connected radio's own GPS fix (Position.location_source = internal), if recent."""
    m = globals().get("MESH")
    if not m or m.my_num is None or m.link != "connected":
        return None
    p = m.nodes.get(m.my_num, {}).get("position", {})
    if p.get("src") != 2 or p.get("lat") is None:
        return None
    seen = p.get("rx") or p.get("time") or 0
    if time.time() - seen > cfgi("RADIO_GPS_MAX_AGE", 1800):
        return None
    return (p["lat"], p["lon"], 10, p.get("alt", 0) or 0)


def mesh_anchor():
    """MY_NODE's position from the mesh (e.g. your phone's GPS shared through its radio), if recent."""
    m = globals().get("MESH")
    want = cfg("MY_NODE").strip().lower()
    if not m or not want:
        return None
    for num, n in list(m.nodes.items()):
        if mp.node_id(num).lower() == want and num != m.my_num:
            p = n.get("position", {})
            seen = p.get("rx") or p.get("time") or 0
            if p.get("lat") is not None and time.time() - seen < cfgi("ANCHOR_MAX_AGE", 1800):
                return (p["lat"], p["lon"], 10, p.get("alt", 0) or 0)
    return None


def share_radio_fix():
    """Write the radio's GPS fix where TurtleTAK can read it (TurtleShell, or both payloads on one Hub)."""
    r = radio_fix()
    p = os.path.join(BASE, "radio_fix.json")
    if r and time.time() - getattr(share_radio_fix, "last", 0) > 30:
        share_radio_fix.last = time.time()
        jsave(p, {"lat": r[0], "lon": r[1], "alt": r[3], "time": time.time()})


def locate():
    share_radio_fix()
    mode = cfg("LOC_MODE", "auto").lower()
    order = LOC_ORDER if mode not in LOC_ORDER else [mode] + [m for m in LOC_ORDER if m != mode]
    for m in order:
        r = None
        if m == "radio":
            r = radio_fix()
        elif m == "mesh":
            r = mesh_anchor()
        elif m == "gps":
            g = S["gps"]
            if g["fix"] and time.time() - g["time"] < 30:
                r = (g["lat"], g["lon"], g.get("ce", 10), g.get("hae", 0))
        elif m == "atak" and cfg("MY_ATAK"):
            with SL:
                for c in S["contacts"].values():
                    if c["callsign"] == cfg("MY_ATAK") and time.time() - c["time"] < cfgi("ANCHOR_MAX_AGE", 1800):
                        r = (c["lat"], c["lon"], max(10, c["ce"] if c["ce"] < 9999999 else 10), 0)
        elif m == "site" and cfg("SITE"):
            for s in sites():
                if s["name"] == cfg("SITE"):
                    r = (s["lat"], s["lon"], 10, 0)
        elif m == "manual" and cfg("MANUAL_LAT") and cfg("MANUAL_LON"):
            try:
                r = (float(cfg("MANUAL_LAT")), float(cfg("MANUAL_LON")), 10, 0)
            except ValueError:
                pass
        elif m == "ip" and cfgb("IPGEO"):
            g = ipgeo()
            if g["lat"] is not None:
                r = (g["lat"], g["lon"], 25000, 0)
        if r:
            with SL:
                changed = S["pos"]["src"] != m
                S["pos"] = {"lat": r[0], "lon": r[1], "ce": r[2], "hae": r[3], "src": m, "time": time.time()}
            if changed:
                log("location from %s: %s" % (m, fmt_ll(r[0], r[1])))
                save_state()
            return
    if cfgb("IPGEO"):
        ipgeo()     # still fill in the public IP for the status


class Gps:
    def run(self):
        claimed = False
        while True:
            dev = cfg("GPS_DEVICE", "auto")
            if dev == "off":
                time.sleep(30)
                continue
            if cfgb("GPS_CLAIM_USB") and not claimed:
                hub("USB_CLAIM_DEVICE")
                hub("USB_POWER_ON")
                claimed = True
            if dev == "auto":
                cands = sorted(p for p in ("/dev/ttyACM0", "/dev/ttyACM1", "/dev/ttyUSB0", "/dev/ttyUSB1") if os.path.exists(p))
                dev = cands[0] if cands else ""
            if not dev or not os.path.exists(dev):
                with SL:
                    S["gps"].update({"device": "", "fix": False})
                time.sleep(15)
                continue
            try:
                if have("stty"):
                    run(["stty", "-F", dev, cfg("GPS_BAUD", "9600"), "raw", "-echo"], 5)
                with SL:
                    S["gps"]["device"] = dev
                self.read(dev)
            except Exception as e:
                log("GPS %s: %s" % (dev, e), "debug")
            time.sleep(5)

    def read(self, dev):
        fd = os.open(dev, os.O_RDONLY | os.O_NOCTTY | os.O_NONBLOCK)
        buf = b""
        last = time.time()
        try:
            while True:
                r, _, _ = select.select([fd], [], [], 5)
                if not r:
                    if time.time() - last > 20:
                        raise RuntimeError("no data")
                    continue
                chunk = os.read(fd, 4096)
                if not chunk:
                    raise RuntimeError("closed")
                last = time.time()
                buf += chunk
                while b"\n" in buf:
                    line, buf = buf.split(b"\n", 1)
                    self.nmea(line.decode("ascii", "replace").strip())
                buf = buf[-2048:]
        finally:
            os.close(fd)

    @staticmethod
    def dm(v, h):
        if not v:
            return None
        d = float(v)
        deg = int(d / 100)
        val = deg + (d - deg * 100) / 60
        return -val if h in ("S", "W") else val

    def nmea(self, line):
        if not line.startswith("$") or "*" not in line:
            return
        body, _, cks = line[1:].partition("*")
        c = 0
        for ch in body:
            c ^= ord(ch)
        if cks[:2].upper() != "%02X" % c:
            return
        f = body.split(",")
        t = f[0][2:]
        with SL:
            g = S["gps"]
            if t == "GGA" and len(f) > 9:
                q = int(f[6] or 0)
                g["sats"] = int(f[7] or 0)
                if q > 0 and f[2]:
                    hdop = float(f[8] or 2)
                    g.update({"lat": self.dm(f[2], f[3]), "lon": self.dm(f[4], f[5]), "hae": float(f[9] or 0),
                              "ce": max(3, round(hdop * 5)), "fix": True, "time": time.time()})
                else:
                    g["fix"] = False
            elif t == "RMC" and len(f) > 6:
                if f[2] == "A" and f[3]:
                    g.update({"lat": self.dm(f[3], f[4]), "lon": self.dm(f[5], f[6]), "fix": True, "time": time.time()})
                    g.setdefault("ce", 10)
                else:
                    g["fix"] = False


# ----------------------------------------------------------------------------------------------
# uplinks (Hub Wi-Fi client, WireGuard)
# ----------------------------------------------------------------------------------------------
def uplinks_apply():
    msgs = []
    if cfg("WIFI_SSID"):
        rc, out = hub("WIFI_CONNECT", cfg("WIFI_COUNTRY", "US"), cfg("WIFI_SSID"), cfg("WIFI_ENC", "psk2"),
                      cfg("WIFI_KEY") or "NONE", "ANY", timeout=60)
        msgs.append("Wi-Fi %s: %s" % (cfg("WIFI_SSID"), "ok" if rc == 0 else "failed " + out[-120:]))
    if cfg("WG_CONF"):
        if os.path.exists(cfg("WG_CONF")):
            rc, out = hub("WIREGUARD_CONFIGURE", "enable", cfg("WG_CONF"), timeout=60)
            msgs.append("WireGuard: %s" % ("ok" if rc == 0 else "failed " + out[-120:]))
        else:
            msgs.append("WireGuard: %s not found" % cfg("WG_CONF"))
    for m in msgs:
        log(m)
    return msgs


# ----------------------------------------------------------------------------------------------
# periodic SA
# ----------------------------------------------------------------------------------------------
def sa_loop():
    while True:
        try:
            status_collect()
            locate()
            if TAK.connected():
                TAK.send(sa_event())
            led()
        except Exception as e:
            log("SA: %s" % e, "warning")
            traceback.print_exc()
        time.sleep(max(15, cfgi("SA_INTERVAL", 60)))


def housekeeping():
    last_cert = 0
    while True:
        time.sleep(15)
        scan_certs()
        if time.time() - last_cert > 3600:
            last_cert = time.time()
            cert_check()
        now = time.time()
        with SL:
            for k in [k for k, c in S["contacts"].items() if (c.get("stale") or c["time"] + 900) < now - 3600]:
                del S["contacts"][k]
        led()


# ----------------------------------------------------------------------------------------------
# Meshtastic radio (protocol code from PagerMesh: meshproto, radiocfg, sigint)
# ----------------------------------------------------------------------------------------------
import meshproto as mp
import radiocfg
import sigint as sigint_mod

NODES_META = os.path.join(BASE, "nodes.json")       # num -> {name, watch, sensor}
KNOWN_NODES = os.path.join(BASE, "known_nodes.json")
CHAT_LOG = os.path.join(BASE, "mesh_chat.jsonl")
HEARTBEAT_SEC = 300

TEAMS = {1: "White", 2: "Yellow", 3: "Orange", 4: "Magenta", 5: "Red", 6: "Maroon", 7: "Purple",
         8: "Dark Blue", 9: "Blue", 10: "Cyan", 11: "Teal", 12: "Green", 13: "Dark Green", 14: "Brown"}
TAK_ROLES = {1: "Team Member", 2: "Team Lead", 3: "HQ", 4: "Sniper", 5: "Medic", 6: "Forward Observer",
             7: "RTO", 8: "K9"}


def jload(path, default):
    try:
        return json.load(open(path))
    except (OSError, ValueError):
        return default


def jsave(path, data):
    tmp = "%s.%d.tmp" % (path, threading.get_ident())
    with open(tmp, "w") as fh:
        json.dump(data, fh, indent=1)
    os.replace(tmp, path)


def node_meta():
    return jload(NODES_META, {})


def set_node_meta(nid, **kw):
    meta = node_meta()
    e = meta.get(nid, {})
    for k, v in kw.items():
        if v is not None:
            e[k] = v.strip()[:40] if isinstance(v, str) else bool(v)
    if e.get("name") or e.get("watch") or e.get("sensor"):
        meta[nid] = e
    else:
        meta.pop(nid, None)
    jsave(NODES_META, meta)
    return e


class Mesh:
    def __init__(self):
        self.lock = threading.RLock()
        self.link, self.error = "starting", ""
        self.my_num = None
        self.nodes = {}            # num -> {num, user{}, position{}, metrics{}, last_heard, snr, rssi, hops_away}
        self.channels, self.channels_all, self.sections = {}, {}, {}
        self.metadata, self.region, self.hop_limit = {}, 0, 3
        self.chat = []             # newest last
        self.pending, self.traces = {}, {}
        self.outq = []
        self.wake = threading.Event()
        self.kick = threading.Event()
        self.sig = sigint_mod.Sigint(mp.PORT_NAMES, mp.node_id)
        self.last_pos = 0
        self.stream = None
        self.down_since = time.time()
        self.alerted_down = False
        self.started = time.time()
        self.known = set(jload(KNOWN_NODES, {}).get("nodes", []))
        self._learn_until = jload(KNOWN_NODES, {}).get("learn_until")   # first window starts once the settings are read
        self.quiet_alerted = set()
        self.batt_alerted = set()
        self.mqtt_out = []         # (topic, data, retained) from the radio for the MQTT proxy
        self.load_chat()

    # ---- names

    @property
    def learn_until(self):
        if self._learn_until is None:
            self._learn_until = time.time() + cfgi("MESH_LEARN_MIN", 60) * 60
        return self._learn_until

    @learn_until.setter
    def learn_until(self, v):
        self._learn_until = v
    def nid(self, num):
        return mp.node_id(num) if num is not None else "?"

    def name_of(self, num):
        if num is None:
            return "?"
        meta = node_meta().get(mp.node_id(num), {})
        if meta.get("name"):
            return meta["name"]
        n = self.nodes.get(num, {}).get("user", {})
        return n.get("long_name") or n.get("short_name") or mp.node_id(num)

    def short_of(self, num):
        return self.nodes.get(num, {}).get("user", {}).get("short_name") or mp.node_id(num)[-4:]

    def chan_private(self, idx):
        """True only for a channel with its own AES key. No key, the default key and the well-known
        "simple" keys can be read by anyone with Meshtastic, so they count as public."""
        c = self.channels.get(idx) or self.channels_all.get(idx)
        return bool(c) and str(c.get("psk_kind", "")).startswith("AES")

    def chan_label(self, idx):
        c = self.channels.get(idx)
        if not c:
            return "Ch %d" % idx
        return c.get("name") or ("Primary" if idx == 0 else "Ch %d" % idx)

    # ---- node database
    def update_node(self, n):
        num = n.get("num")
        if num is None:
            return
        with self.lock:
            cur = self.nodes.setdefault(num, {"num": num})
            for k, v in n.items():
                if isinstance(v, dict) and isinstance(cur.get(k), dict):
                    cur[k].update(v)
                elif v is not None:
                    cur[k] = v
        if "metrics" in n:
            self.check_battery(num)

    def heard(self, pkt):
        num = pkt.get("from")
        if num is None or num == self.my_num:
            return
        now = time.time()
        with self.lock:
            cur = self.nodes.setdefault(num, {"num": num})
            cur["last_heard"] = now
            for k in ("rx_snr", "rx_rssi"):
                if pkt.get(k) is not None:
                    cur[k.replace("rx_", "")] = pkt[k]
            if pkt.get("hop_start") is not None and pkt.get("hop_limit") is not None:
                cur["hops_away"] = max(0, pkt["hop_start"] - pkt["hop_limit"])
        self.watch_new(num)
        nid = mp.node_id(num)
        if nid in self.quiet_alerted:
            self.quiet_alerted.discard(nid)
            raise_alert("quiet", "info", "Node back: %s" % self.name_of(num), "Heard again on the mesh")

    # ---- mesh watch
    def watch_new(self, num):
        nid = mp.node_id(num)
        if nid in self.known:
            return
        self.known.add(nid)
        self.save_known()
        if time.time() < self.learn_until:
            return
        # a moment later, so the name / position in the same packet (nodeinfo, position) is known
        t = threading.Timer(2, self.alert_new, args=(num,))
        t.daemon = True
        t.start()

    def alert_new(self, num):
        nid = mp.node_id(num)
        n = self.nodes.get(num, {})
        where = ""
        p = n.get("position", {})
        hp = S["pos"]
        if p.get("lat") is not None and hp.get("lat") is not None:
            d, b = dist_brg(hp["lat"], hp["lon"], p["lat"], p["lon"])
            where = ", %s at %d deg" % (("%d m" % d) if d < 1000 else ("%.1f km" % (d / 1000.0)), b)
        raise_alert("new_node", "warning", "New mesh node %s" % self.name_of(num),
                    "%s first heard%s%s%s" % (nid, where, "" if n.get("snr") is None else ", SNR %s dB" % n["snr"],
                                              "" if n.get("hops_away") is None else ", %s hops" % n["hops_away"]),
                    key="newnode:" + nid, at=self.node_pos(num))

    def save_known(self):
        jsave(KNOWN_NODES, {"nodes": sorted(self.known), "learn_until": self.learn_until})

    def accept_nodes(self):
        with self.lock:
            self.known |= {mp.node_id(n) for n in self.nodes}
        self.learn_until = time.time()
        self.save_known()
        return len(self.known)

    def relearn(self):
        self.known = {mp.node_id(n) for n in self.nodes}
        self.learn_until = time.time() + cfgi("MESH_LEARN_MIN", 60) * 60
        self.save_known()
        return "learning for %d minutes" % cfgi("MESH_LEARN_MIN", 60)

    def watch_loop(self):
        while True:
            time.sleep(30)
            try:
                quiet = cfgi("NODE_QUIET_MIN", 60) * 60
                meta = node_meta()
                now = time.time()
                for nid, m in meta.items():
                    if not (m.get("watch") or m.get("sensor")):
                        continue
                    num = int(nid.lstrip("!"), 16)
                    last = self.nodes.get(num, {}).get("last_heard")
                    if last is None:
                        last = self.started          # never heard since start: count from start
                    if now - last > quiet and nid not in self.quiet_alerted and self.link == "connected":
                        self.quiet_alerted.add(nid)
                        raise_alert("quiet", "critical" if m.get("sensor") else "warning",
                                    "Node quiet: %s" % self.name_of(num),
                                    "Not heard on the mesh for %s" % dur(now - last), key="quiet:%s:%d" % (nid, int(last)),
                                    at=self.node_pos(num))
            except Exception as e:
                log("mesh watch: %s" % e, "warning")

    def check_battery(self, num):
        nid = mp.node_id(num)
        m = node_meta().get(nid, {})
        if not (m.get("watch") or m.get("sensor")):
            return
        b = self.nodes.get(num, {}).get("metrics", {}).get("battery")
        if b is None or b > 100:
            return
        if b < cfgi("LOW_BATTERY", 20):
            if nid not in self.batt_alerted:
                self.batt_alerted.add(nid)
                raise_alert("battery", "warning", "Low battery: %s" % self.name_of(num), "%d%%" % b,
                            key="batt:%s" % nid, at=self.node_pos(num))
        elif b > cfgi("LOW_BATTERY", 20) + 10:
            self.batt_alerted.discard(nid)

    def node_pos(self, num):
        p = self.nodes.get(num, {}).get("position", {})
        return (p["lat"], p["lon"]) if p.get("lat") is not None else None

    # ---- chat
    def load_chat(self):
        try:
            for line in open(CHAT_LOG, encoding="utf-8"):
                try:
                    self.chat.append(json.loads(line))
                except ValueError:
                    pass
            self.chat = self.chat[-400:]
        except OSError:
            pass

    def add_chat(self, e):
        with self.lock:
            self.chat.append(e)
            del self.chat[:-400]
        try:
            with open(CHAT_LOG, "a", encoding="utf-8") as fh:
                fh.write(json.dumps(e) + "\n")
            if os.path.getsize(CHAT_LOG) > 1024 * 1024:
                lines = open(CHAT_LOG, encoding="utf-8").read().splitlines()[-1000:]
                open(CHAT_LOG, "w", encoding="utf-8").write("\n".join(lines) + "\n")
        except OSError:
            pass

    def queue(self, payload):
        with self.lock:
            self.outq.append(payload)
        self.wake.set()

    def send_text(self, msg, to=None, channel=0, source="console"):
        msg = mp.clip_text(re.sub(r"[\x00-\x08\x0b-\x1f]", " ", msg).strip())
        if not msg:
            return False, "empty message"
        if self.link != "connected":
            return False, "radio not connected"
        pid = mp.new_packet_id()
        dest = mp.BROADCAST if to is None else to
        self.queue(mp.text_packet(msg, dest, 0 if to is not None else channel, self.hop_limit, pid))
        e = {"t": time.time(), "dir": "out", "conv": ("dm:" + mp.node_id(dest)) if to is not None else "ch:%d" % channel,
             "label": ("DM " + self.name_of(to)) if to is not None else self.chan_label(channel),
             "from": self.name_of(self.my_num) if self.my_num else "Hub", "text": msg,
             "status": "pending" if to is not None else "sent", "id": pid, "source": source}
        if to is not None:
            with self.lock:
                self.pending[pid] = e
        self.add_chat(e)
        return True, "sent"

    def send_position(self):
        p = S["pos"]
        if p.get("lat") is None or self.link != "connected":
            return False, "no Hub position" if p.get("lat") is None else "radio not connected"
        if p.get("src") == "radio":
            return False, "the radio sends its own GPS position"
        ch = cfgi("MESH_POS_CHANNEL", -1)
        if ch < 0:
            return False, "the Hub's position on the mesh is off (Radio > Hub position on the mesh)"
        if not self.chan_private(ch):
            return False, "%s is a public channel - the Hub's position only goes out on a channel with its own key" % self.chan_label(ch)
        self.queue(mp.position_packet(p["lat"], p["lon"], None, int(time.time()), ch,
                                      self.hop_limit, source=1))
        self.last_pos = time.time()
        if self.my_num is not None:
            self.update_node({"num": self.my_num, "position": {"lat": p["lat"], "lon": p["lon"], "src": 1, "rx": time.time()}})
        return True, "Hub position sent on the mesh"

    # ---- packets
    def on_packet(self, pkt):
        self.heard(pkt)
        d = pkt.get("decoded")
        if not d:
            return
        port, payload, frm = d["portnum"], d["payload"], pkt.get("from", 0)
        try:
            if port == mp.PORT_TEXT:
                self.on_text(pkt, frm, payload.decode("utf-8", "replace"))
            elif port == mp.PORT_POSITION:
                p = mp.dec_position(payload)
                if "lat" in p:
                    p["rx"] = time.time()
                    p.setdefault("src", 0)
                    self.update_node({"num": frm, "position": p})
                    self.sig.add_point(frm, p["lat"], p["lon"])
                    BRIDGE.node_moved(frm)
            elif port == mp.PORT_NODEINFO:
                self.update_node({"num": frm, "user": mp.dec_user(payload)})
            elif port == mp.PORT_TELEMETRY:
                m = mp.dec_telemetry(payload)
                if m:
                    self.update_node({"num": frm, "metrics": m})
            elif port == mp.PORT_TRACEROUTE and d.get("request_id"):
                r = mp.dec_route(payload)
                with self.lock:
                    tr = self.traces.get(frm) or {"t": time.time()}
                    tr.update(r)
                    tr["done"] = True
                    self.traces[frm] = tr
            elif port == mp.PORT_ROUTING and d.get("request_id"):
                err = mp.dec_routing_error(payload)
                with self.lock:
                    e = self.pending.pop(d["request_id"], None)
                if e is not None:
                    e["status"] = "delivered" if err == 0 else "failed"
            elif port == 10:                                   # DETECTION_SENSOR_APP
                self.on_sensor(frm, payload.decode("utf-8", "replace").strip())
            elif port == 72:                                   # ATAK_PLUGIN
                BRIDGE.atak_plugin(frm, payload)
        except (ValueError, IndexError, KeyError) as e:
            log("mesh packet skipped: %s" % e, "debug")

    def on_text(self, pkt, frm, txt):
        direct = pkt.get("to") not in (None, mp.BROADCAST)
        ch = pkt.get("channel", 0)
        e = {"t": time.time(), "dir": "in", "conv": ("dm:" + mp.node_id(frm)) if direct else "ch:%d" % ch,
             "label": ("DM " + self.name_of(frm)) if direct else self.chan_label(ch), "from": self.name_of(frm),
             "from_id": mp.node_id(frm), "text": txt, "snr": pkt.get("rx_snr"), "id": pkt.get("id", 0)}
        self.add_chat(e)
        log("mesh %s from %s: %s" % ("DM" if direct else self.chan_label(ch), self.name_of(frm), txt[:100]))
        if node_meta().get(mp.node_id(frm), {}).get("sensor") and not direct:
            self.on_sensor(frm, txt)
        if direct and cfgb("MESH_COMMANDS"):
            self.command(frm, txt)
        elif not direct and ch == cfgi("BRIDGE_CHAT_CHANNEL", -1) and self.chan_private(ch):
            BRIDGE.mesh_chat_to_tak(frm, txt)

    def on_sensor(self, frm, txt):
        lvl = cfg("SENSOR_LEVEL", "warning")
        lvl = lvl if lvl in LEVELS else "warning"
        raise_alert("sensor", lvl, "%s: %s" % (self.name_of(frm), txt or "detection"),
                    "Detection sensor %s" % mp.node_id(frm), key=None, at=self.node_pos(frm))

    def command(self, frm, txt):
        allow = [a.strip().lower() for a in cfg("MESH_COMMANDS_FROM").split(",") if a.strip()]
        if allow and mp.node_id(frm).lower() not in allow:
            return
        cmd = (txt.strip().lower().split() or [""])[0]
        reply = command_reply(cmd)
        if reply:
            self.send_text(reply[:200], to=frm, source="command")

    # ---- radio admin (from PagerMesh)
    def can_admin(self):
        if self.link != "connected" or self.my_num is None:
            return False, "radio not connected"
        return True, ""

    def radio_view(self):
        with self.lock:
            sec = dict(self.sections)
            chans = sorted(self.channels_all.values(), key=lambda c: c["index"])
            me = self.nodes.get(self.my_num, {}).get("user", {})
        return {"values": radiocfg.current(sec), "settings": radiocfg.describe(),
                "owner": {"long": me.get("long_name", ""), "short": me.get("short_name", "")},
                "channels": [{k: c.get(k) for k in ("index", "name", "role", "psk_kind", "uplink", "downlink", "precision")}
                             for c in chans if c.get("role") or c["index"] < 8],
                "metadata": {"firmware": self.metadata.get("firmware", ""),
                             "hw": mp.hw_name(self.metadata.get("hw_model", me.get("hw_model"))),
                             "region": mp.REGIONS.get(self.region, self.region)},
                "share_url": self.share_url()}

    def set_owner(self, long_name, short_name):
        ok, msg = self.can_admin()
        if not ok:
            return msg
        long_name, short_name = long_name.strip(), short_name.strip()
        if len(long_name.encode()) > 39 or len(short_name.encode()) > 4:
            raise RuntimeError("long name at most 39 characters, short name at most 4")
        self.queue(mp.admin_packet(self.my_num, mp.adm_set_owner(long_name, short_name)))
        self.update_node({"num": self.my_num, "user": {k: v for k, v in (("long_name", long_name), ("short_name", short_name)) if v}})
        return "name saved on the radio"

    def set_radio(self, changes):
        ok, msg = self.can_admin()
        if not ok:
            raise RuntimeError(msg)
        with self.lock:
            sec = dict(self.sections)
        try:
            parts, labels, _risky = radiocfg.build(sec, changes)
        except ValueError as e:
            raise RuntimeError(str(e))
        if not parts:
            return "nothing changed"
        self.queue(mp.admin_packet(self.my_num, mp.adm_begin()))
        for kind, section, raw in parts:
            adm = mp.adm_set_config(section, raw) if kind == radiocfg.CFG else mp.adm_set_module(section, raw)
            self.queue(mp.admin_packet(self.my_num, adm))
            with self.lock:
                self.sections[(kind, section)] = raw
        self.queue(mp.admin_packet(self.my_num, mp.adm_commit()))
        return "saved: %s - the radio restarts to apply it" % ", ".join(labels)

    def set_channel(self, index, **kw):
        ok, msg = self.can_admin()
        if not ok:
            raise RuntimeError(msg)
        with self.lock:
            cur = self.channels_all.get(index)
        try:
            raw = radiocfg.build_channel(cur, index, rand=os.urandom, **kw)
        except ValueError as e:
            raise RuntimeError(str(e))
        for adm in (mp.adm_begin(), mp.adm_set_channel(raw), mp.adm_commit()):
            self.queue(mp.admin_packet(self.my_num, adm))
        c = mp.dec_channel(raw)
        with self.lock:
            self.channels_all[index] = c
            if c["role"]:
                self.channels[index] = c
            else:
                self.channels.pop(index, None)
        return "channel %d saved" % index

    def share_url(self):
        with self.lock:
            chans = sorted((c for c in self.channels.values() if c.get("role")), key=lambda c: (c["role"] != 1, c["index"]))
            lora = self.sections.get((radiocfg.CFG, radiocfg.LORA), b"")
        if not chans:
            return ""
        try:
            return mp.channel_url([c.get("settings_raw", b"") for c in chans], lora)
        except Exception:
            return ""

    def reboot(self):
        ok, msg = self.can_admin()
        if not ok:
            raise RuntimeError(msg)
        self.queue(mp.admin_packet(self.my_num, mp.adm_reboot(2)))
        return "the radio restarts"

    def traceroute(self, num):
        if self.link != "connected":
            raise RuntimeError("radio not connected")
        with self.lock:
            self.traces[num] = {"t": time.time(), "done": False}
        self.queue(mp.traceroute_packet(num, self.hop_limit))
        return "traceroute sent to %s - the answer can take a minute" % self.name_of(num)

    def trace_text(self, num):
        tr = self.traces.get(num)
        if not tr:
            return ""
        if not tr.get("done"):
            return "waiting for an answer..."
        hops = [self.my_num] + list(tr.get("route", [])) + [num]
        out = " > ".join(self.name_of(h) for h in hops)
        back = tr.get("route_back")
        if back:
            out += "  |  back: " + " > ".join(self.name_of(h) for h in [num] + list(back) + [self.my_num])
        return out

    def request_position(self, num):
        if self.link != "connected":
            raise RuntimeError("radio not connected")
        p = S["pos"]
        self.queue(mp.position_request(num, p.get("lat"), p.get("lon"), self.hop_limit))
        return "position requested from %s" % self.name_of(num)

    # ---- link
    def connect(self):
        conn = cfg("RADIO_CONN", "wifi")
        dev = cfg("RADIO_DEV", "auto")
        if conn == "usb":
            if cfgb("RADIO_CLAIM_USB") and not getattr(self, "_claimed", False):
                hub("USB_CLAIM_DEVICE")
                hub("USB_POWER_ON")
                self._claimed = True
                time.sleep(3)
            if dev in ("", "auto"):
                ports = mp.serial_ports()
                if not ports:
                    raise OSError(usb_diag())
                dev = ports[0]
        elif not cfg("RADIO_HOST"):
            raise OSError("set the radio's address (Radio > Connection)")
        st = mp.open_stream(conn, cfg("RADIO_HOST"), cfgi("RADIO_PORT", 4403), dev, timeout=15)
        nonce = random.randint(1, 0x7FFFFFFF)
        if nonce in (69420, 69421):
            nonce += 2
        st.send(mp.want_config(nonce))
        deadline = time.time() + 60
        while time.time() < deadline:
            kind, v = self.decode(st.read())
            self.dispatch(kind, v)
            if kind == "config_complete" and v == nonce:
                return st
        st.close()
        raise ConnectionError("no answer from the radio")

    @staticmethod
    def decode(buf):
        for fn, wt, v in mp.fields(buf):          # MqttClientProxyMessage (FromRadio 14) is not in meshproto
            if fn == 14 and wt == 2:
                m = {"topic": "", "data": b"", "retained": False}
                for f2, w2, v2 in mp.fields(v):
                    if f2 == 1:
                        m["topic"] = bytes(v2).decode("utf-8", "replace")
                    elif f2 == 2:
                        m["data"] = bytes(v2)
                    elif f2 == 3:
                        m["data"] = bytes(v2)
                    elif f2 == 4:
                        m["retained"] = bool(v2)
                return "mqtt", m
        return mp.dec_fromradio(buf)

    def dispatch(self, kind, v):
        if kind == "my_info":
            self.my_num = v
        elif kind == "node_info":
            v.pop("user_raw", None)
            if "last_heard" in v:
                v["last_heard"] = min(v["last_heard"], time.time())
            self.update_node(v)
            if v.get("num") is not None and v["num"] != self.my_num:
                nid = mp.node_id(v["num"])
                if time.time() < self.learn_until and nid not in self.known:
                    self.known.add(nid)
        elif kind == "channel":
            with self.lock:
                self.channels_all[v["index"]] = v
                if v["role"]:
                    self.channels[v["index"]] = v
                else:
                    self.channels.pop(v["index"], None)
        elif kind == "metadata":
            self.metadata = v
        elif kind == "module_config":
            with self.lock:
                self.sections[(radiocfg.MOD, v[0])] = v[1]
        elif kind == "config":
            if "_section" in v:
                with self.lock:
                    self.sections[(radiocfg.CFG, v["_section"])] = v["_raw"]
            if "region" in v:
                self.region = v["region"]
            if v.get("hop_limit"):
                self.hop_limit = v["hop_limit"]
        elif kind == "packet":
            self.sig.add(v)
            self.on_packet(v)
        elif kind == "mqtt":
            MQTT.publish(v["topic"], v["data"], v["retained"])
        elif kind == "rebooted":
            raise ConnectionError("radio restarted")

    def session(self):
        st = self.connect()
        self.stream = st
        self.save_known()
        self.link, self.error = "connected", ""
        led_link()
        log("radio connected: %s (%s, %d nodes)" % (self.name_of(self.my_num), mp.REGIONS.get(self.region, "?"), len(self.nodes)))
        if self.alerted_down:
            raise_alert("radio", "info", "Radio link restored", "Back after %s" % dur(time.time() - self.down_since), marker=False)
        self.alerted_down = False
        st.settimeout(0.5)
        last_hb = time.time()
        while not self.kick.is_set():
            try:
                kind, v = self.decode(st.read())
                self.dispatch(kind, v)
            except socket.timeout:
                pass
            except ValueError as e:
                log("bad frame skipped: %s" % e, "debug")
            with self.lock:
                q, self.outq = self.outq, []
            for payload in q:
                st.send(payload)
            t = time.time()
            if t - last_hb > HEARTBEAT_SEC:
                st.send(mp.heartbeat())
                last_hb = t
            iv = cfgi("MESH_POS_INTERVAL", 900)
            if iv > 0 and t - self.last_pos >= max(60, iv):
                self.send_position()
        st.close()

    def run(self):
        delay = 3
        while True:
            self.kick.clear()
            self.link = "connecting"
            try:
                self.session()
                delay = 3
            except Exception as e:
                if self.link == "connected":
                    self.down_since = time.time()
                    delay = 3
                self.link, self.error = "down", (str(e) or type(e).__name__)[:160]
                led_link()
                with self.lock:
                    self.pending.clear()
                log("radio: %s" % self.error, "warning")
            finally:
                if self.stream:
                    try:
                        self.stream.close()
                    except Exception:
                        pass
                self.stream = None
            if (cfgb("RADIO_WATCH") and not self.alerted_down and time.time() - self.down_since > 120
                    and (cfg("RADIO_HOST") or cfg("RADIO_CONN") == "usb")):
                self.alerted_down = True
                raise_alert("radio", "warning", "Radio link lost", "%s: %s" % (cfg("RADIO_CONN"), self.error), marker=False)
            self.kick.wait(delay)
            delay = min(30, delay * 2)

    def reconnect(self):
        self.kick.set()
        if self.stream:
            try:
                self.stream.close()
            except Exception:
                pass

    def node_rows(self):
        now = time.time()
        meta = node_meta()
        hp = S["pos"]
        rows = []
        with self.lock:
            items = list(self.nodes.items())
        for num, n in items:
            nid = mp.node_id(num)
            u = n.get("user", {})
            p = n.get("position", {})
            m = n.get("metrics", {})
            r = {"num": num, "id": nid, "name": self.name_of(num), "short": u.get("short_name", ""),
                 "long": u.get("long_name", ""), "hw": mp.hw_name(u.get("hw_model")), "role": mp.ROLES.get(u.get("role"), ""),
                 "lat": p.get("lat"), "lon": p.get("lon"), "battery": m.get("battery"), "voltage": m.get("voltage"),
                 "snr": n.get("snr"), "rssi": n.get("rssi"), "hops": n.get("hops_away"),
                 "age": int(now - n["last_heard"]) if n.get("last_heard") else None, "me": num == self.my_num,
                 "watch": meta.get(nid, {}).get("watch", False), "sensor": meta.get(nid, {}).get("sensor", False),
                 "label": meta.get(nid, {}).get("name", ""), "known": nid in self.known,
                 "quiet": nid in self.quiet_alerted, "trace": self.trace_text(num)}
            if r["lat"] is not None and hp.get("lat") is not None:
                r["dist"], r["brg"] = dist_brg(hp["lat"], hp["lon"], r["lat"], r["lon"])
            rows.append(r)
        rows.sort(key=lambda r: (not r["me"], r["age"] if r["age"] is not None else 1e12))
        return rows


MESH = Mesh()


# USB-serial chips found on Meshtastic radios -> (name, Linux driver, OpenWrt package)
USB_SERIAL_CHIPS = {
    "10c4": ("CP210x (Heltec V3, T-Beam, RAK...)", "cp210x", "kmod-usb-serial-cp210x"),
    "1a86:7523": ("CH340", "ch341", "kmod-usb-serial-ch341"),
    "1a86:5523": ("CH341", "ch341", "kmod-usb-serial-ch341"),
    "1a86": ("CH9102 / CH343", "cdc_acm", "kmod-usb-acm"),
    "303a": ("ESP32-S3 native USB", "cdc_acm", "kmod-usb-acm"),
    "239a": ("nRF52 native USB (RAK4631, T-Echo...)", "cdc_acm", "kmod-usb-acm"),
    "2886": ("nRF52 native USB (Seeed)", "cdc_acm", "kmod-usb-acm"),
    "0403": ("FTDI", "ftdi_sio", "kmod-usb-serial-ftdi"),
}


def usb_diag():
    """Why no /dev/ttyUSB* or /dev/ttyACM* appeared: no device on the port, or no driver for its chip."""
    import glob
    seen = []
    for d in glob.glob("/sys/bus/usb/devices/*"):
        try:
            vid = open(d + "/idVendor").read().strip().lower()
            pid = open(d + "/idProduct").read().strip().lower()
        except OSError:
            continue
        if vid == "1d6b":                       # Linux root hubs
            continue
        chip = USB_SERIAL_CHIPS.get("%s:%s" % (vid, pid)) or USB_SERIAL_CHIPS.get(vid)
        drivers = set()
        for itf in glob.glob(d + ":*"):
            if os.path.islink(itf + "/driver"):
                drivers.add(os.path.basename(os.readlink(itf + "/driver")))
        seen.append((vid, pid, chip, drivers))
    for vid, pid, chip, drivers in seen:
        if chip:
            name, drv, pkg = chip
            if drv not in drivers:
                return ("USB radio found (%s, %s:%s) but this Hub has no %s driver for it, so no serial port appears. "
                        "Use Wi-Fi, or install %s on the Hub if a package is available" % (name, vid, pid, drv, pkg))
            return "USB radio found (%s, %s:%s) with the %s driver, but no serial port appeared yet - unplug it and plug it back in" % (name, vid, pid, drv)
    if seen:
        return ("no USB radio found - USB devices seen on the Hub: %s. Is it plugged into the dynamic USB port "
                "(nearest the USB-C cable) with a data cable?" % ", ".join("%s:%s" % (v, p) for v, p, _c, _d in seen[:5]))
    return ("no USB device on the Hub's dynamic port - plug the radio into the port nearest the USB-C cable, with a data "
            "cable (not charge-only). If your computer sees the radio instead, the port is still on passthrough")


def command_reply(cmd):
    """Answers for mesh and TAK direct-message commands (kept short for LoRa)."""
    if cmd == "status":
        rows = MESH.node_rows()
        heard = len([r for r in rows if r["age"] is not None and r["age"] < 3600 and not r["me"]])
        tt = turtletak_state()
        out = "%s: radio %s, TAK %s, %d nodes heard 1h" % (cfg("CALLSIGN"), MESH.link, S["tak"]["state"], heard)
        if tt is not None:
            out += ", TurtleTAK %d alerts 24h" % len([a for a in tt.get("alerts", []) if time.time() - a["time"] < 86400])
        return out
    if cmd == "where":
        p = S["pos"]
        return "%s at %s (%s)" % (cfg("CALLSIGN"), fmt_ll(p["lat"], p["lon"]), p["src"])
    if cmd == "alerts":
        al = all_alerts()[-4:]
        return "; ".join("%s %s" % (time.strftime("%H:%M", time.localtime(a["time"])), a["title"]) for a in al) or "No alerts."
    if cmd == "nodes":
        rows = [r for r in MESH.node_rows() if not r["me"] and r["age"] is not None][:6]
        return "; ".join("%s %s" % (r["short"] or r["id"][-4:], dur(r["age"])) for r in rows) or "No nodes heard."
    if cmd == "help":
        return "Commands: status, alerts, where, nodes, help"
    return None


def turtletak_running():
    """The Hub runs one payload at a time, so TurtleTAK's files can be old. True only while its service is up."""
    try:
        pid = int(open(os.path.join(TURTLETAK_BASE, "turtletak.pid")).read().strip())
        return b"turtletak" in open("/proc/%d/cmdline" % pid, "rb").read()
    except (OSError, ValueError):
        return False


def turtletak_state():
    if not turtletak_running():
        return None
    try:
        return json.load(open(os.path.join(TURTLETAK_BASE, "state.json")))
    except (OSError, ValueError):
        return None


def all_alerts():
    with SL:
        mine = [dict(a, source="TurtleMesh") for a in S["alerts"]]
    tt = turtletak_state() or {}
    theirs = [dict(a, source="TurtleTAK") for a in tt.get("alerts", [])]
    return sorted(mine + theirs, key=lambda a: a["time"])


# ----------------------------------------------------------------------------------------------
# alerts over LoRa: TurtleMesh's own alerts and TurtleTAK's (read from its state.json)
# ----------------------------------------------------------------------------------------------
class LoraAlerts:
    def __init__(self):
        self.seen = set()
        self.primed = False

    def text(self, a, source):
        tag = {"critical": "CRITICAL", "warning": "WARNING"}.get(a["level"], "INFO")
        who = turtletak_cfg().get("CALLSIGN", "TurtleTAK") if source == "turtletak" else cfg("CALLSIGN")
        return "[%s] %s %s - %s" % (who, tag, a["title"], a["detail"])

    def send(self, a, source):
        if not cfgb("LORA_ALERTS") or source not in [s.strip() for s in cfg("LORA_ALERT_SOURCES").split(",")]:
            return
        if LEVELS.get(a["level"], 0) < LEVELS.get(cfg("LORA_ALERT_MIN"), 1) or a.get("kind") == "radio":
            return
        if a["id"] in self.seen:
            return
        self.seen.add(a["id"])
        to = cfg("LORA_ALERT_TO").strip()
        num = None
        if to:
            try:
                num = int(to.lstrip("!"), 16)
            except ValueError:
                num = None
        if num is None and cfg("LORA_ALERT_CHANNEL").strip() == "":
            return                                  # no channel chosen yet
        ok, msg = MESH.send_text(self.text(a, source)[:200], to=num, channel=cfgi("LORA_ALERT_CHANNEL", 0), source="alert")
        if not ok:
            self.seen.discard(a["id"])          # try again on the next pass (radio not connected yet)

    def run(self):
        while True:
            try:
                tt = turtletak_state()
                if tt is not None:
                    alerts = tt.get("alerts", [])
                    if not self.primed:                 # don't replay TurtleTAK's history at start
                        self.seen |= {a["id"] for a in alerts}
                        self.primed = True
                    for a in alerts:
                        if a["id"] not in self.seen and time.time() - a["time"] < 3600:
                            self.send(a, "turtletak")
                with SL:
                    mine = list(S["alerts"][-20:])
                for a in mine:
                    if a["id"] not in self.seen and time.time() - a["time"] < 3600:
                        self.send(a, "turtlemesh")
            except Exception as e:
                log("alerts over LoRa: %s" % e, "warning")
            time.sleep(5)


LORA = LoraAlerts()


# ----------------------------------------------------------------------------------------------
# mesh <-> TAK bridge
# ----------------------------------------------------------------------------------------------
class MeshTakBridge:
    RESEND = 300
    STALE = 1200

    def __init__(self):
        self.sent = {}          # num -> (time, lat, lon)
        self.last_to_mesh = 0
        self.stats = {"nodes_to_tak": 0, "chat_to_tak": 0, "chat_to_mesh": 0, "atak_to_tak": 0, "atak_compressed": 0}

    def node_uid(self, num):
        return "TurtleMesh.%s" % mp.node_id(num)

    def node_cot(self, num):
        n = MESH.nodes.get(num, {})
        p = n.get("position", {})
        m = n.get("metrics", {})
        u = n.get("user", {})
        rem = ["Meshtastic %s %s" % (mp.node_id(num), mp.hw_name(u.get("hw_model")))]
        if m.get("battery") is not None:
            rem.append("Battery %s" % ("external power" if m["battery"] > 100 else "%d%%" % m["battery"]))
        if n.get("snr") is not None:
            rem.append("SNR %s dB, %s hops, via %s" % (n.get("snr"), n.get("hops_away", "?"), cfg("CALLSIGN")))
        if n.get("last_heard"):
            rem.append("Heard %s" % time.strftime("%H:%M:%S", time.localtime(n["last_heard"])))
        t = time.time()
        return (ev_open(self.node_uid(num), "a-f-G-U-C", self.STALE, "m-g") + point_xml(p["lat"], p["lon"], 30)
                + "<detail>" + '<contact callsign="%s"/>' % x(MESH.name_of(num))
                + '<__group name="Cyan" role="Team Member"/>'
                + '<takv device="Meshtastic" platform="%s" os="Meshtastic" version="%s"/>' % (PRODUCT, VERSION)
                + '<link uid="%s" type="%s" relation="p-p"/>' % (x(my_uid()), x(cfg("COT_TYPE")))
                + "<remarks>%s</remarks></detail></event>" % x("\n".join(rem)))

    def node_moved(self, num):
        if num != MESH.my_num:
            self.push_node(num, force=False)

    def push_node(self, num, force=False):
        if not cfgb("BRIDGE_NODES") or not TAK.connected():
            return
        n = MESH.nodes.get(num, {})
        p = n.get("position", {})
        if p.get("lat") is None or num == MESH.my_num:
            return
        if n.get("last_heard") and time.time() - n["last_heard"] > cfgi("BRIDGE_NODE_MAX_AGE", 7200):
            return
        last = self.sent.get(num)
        if not force and last and time.time() - last[0] < self.RESEND and abs(last[1] - p["lat"]) < 1e-5 and abs(last[2] - p["lon"]) < 1e-5:
            return
        if TAK.send(self.node_cot(num)):
            self.sent[num] = (time.time(), p["lat"], p["lon"])
            self.stats["nodes_to_tak"] += 1

    def loop(self):
        while True:
            time.sleep(30)
            try:
                for num in list(MESH.nodes):
                    self.push_node(num)
            except Exception as e:
                log("bridge: %s" % e, "warning")

    def mesh_chat_to_tak(self, frm, txt, cs=None, uid=None, plugin=False):
        # ATAK plugin chat follows BRIDGE_ATAK_PLUGIN; channel chat needs a bridged (private) channel
        if (not plugin and cfgi("BRIDGE_CHAT_CHANNEL", -1) < 0) or not TAK.connected():
            return
        uid = uid or self.node_uid(frm)
        cs = cs or MESH.name_of(frm)
        mid = str(uuid.uuid4())
        p = MESH.nodes.get(frm, {}).get("position", {})
        ev = (ev_open("GeoChat.%s.All Chat Rooms.%s" % (uid, mid), "b-t-f", 86400, "h-g-i-g-o")
              + point_xml(p.get("lat"), p.get("lon")) + "<detail>"
              + '<__chat parent="RootContactGroup" groupOwner="false" messageId="%s" chatroom="All Chat Rooms" id="All Chat Rooms" senderCallsign="%s">'
              % (mid, x(cs)) + '<chatgrp uid0="%s" uid1="All Chat Rooms" id="All Chat Rooms"/></__chat>' % x(uid)
              + '<link uid="%s" type="a-f-G-U-C" relation="p-p"/>' % x(uid)
              + '<remarks source="BAO.F.ATAK.%s" to="All Chat Rooms" time="%s">%s</remarks></detail></event>' % (x(uid), iso(), x(txt)))
        if TAK.send(ev):
            self.stats["chat_to_tak"] += 1

    def tak_chat_to_mesh(self, cs, sender_uid, room, text):
        """TAK GeoChat to All Chat Rooms -> mesh channel as '[callsign] text'. DMs are never bridged."""
        ch = cfgi("BRIDGE_CHAT_CHANNEL", -1)
        if ch < 0 or room != "All Chat Rooms" or not MESH.chan_private(ch):
            return
        if sender_uid.startswith("TurtleMesh.") or sender_uid == my_uid() or text.startswith("[%s]" % cfg("CALLSIGN")):
            return
        wait = 5 - (time.time() - self.last_to_mesh)
        if wait > 0:
            time.sleep(min(5, wait))
        ok, _ = MESH.send_text("[%s] %s" % (cs, text), channel=ch, source="tak")
        if ok:
            self.last_to_mesh = time.time()
            self.stats["chat_to_mesh"] += 1

    def atak_plugin(self, frm, payload):
        """Meshtastic ATAK plugin TAKPacket (atak.proto) -> CoT. Compressed strings (unishox2) can't be read
        without a library: their positions still come through, named from the mesh node."""
        if not cfgb("BRIDGE_ATAK_PLUGIN"):
            return
        pkt = {"compressed": False}
        for fn, wt, v in mp.fields(payload):
            if fn == 1 and wt == 0:
                pkt["compressed"] = bool(v)
            elif fn == 2 and wt == 2:
                for f2, w2, v2 in mp.fields(v):
                    if w2 == 2:
                        pkt["callsign" if f2 == 1 else "device"] = bytes(v2)
            elif fn == 3 and wt == 2:
                for f2, w2, v2 in mp.fields(v):
                    if w2 == 0:
                        pkt["role" if f2 == 1 else "team"] = v2
            elif fn == 4 and wt == 2:
                for f2, w2, v2 in mp.fields(v):
                    if f2 == 1 and w2 == 0:
                        pkt["battery"] = v2
            elif fn == 5 and wt == 2:
                pli = {}
                for f2, w2, v2 in mp.fields(v):
                    if f2 == 1 and w2 == 5:
                        pli["lat"] = mp.s32(v2) / 1e7
                    elif f2 == 2 and w2 == 5:
                        pli["lon"] = mp.s32(v2) / 1e7
                    elif f2 == 3 and w2 == 0:
                        pli["alt"] = mp.sint(v2) if v2 > 0x7FFFFFFF else v2
                    elif f2 == 4 and w2 == 0:
                        pli["speed"] = v2
                    elif f2 == 5 and w2 == 0:
                        pli["course"] = v2
                pkt["pli"] = pli
            elif fn == 6 and wt == 2:
                chat = {}
                for f2, w2, v2 in mp.fields(v):
                    if w2 == 2:
                        chat[{1: "message", 2: "to", 3: "to_callsign"}.get(f2, "x")] = bytes(v2)
                pkt["chat"] = chat
        comp = pkt["compressed"]
        if comp:
            self.stats["atak_compressed"] += 1
        txt = lambda b: None if (b is None or comp) else b.decode("utf-8", "replace")
        cs = txt(pkt.get("callsign")) or MESH.name_of(frm)
        uid = txt(pkt.get("device")) or "TurtleMesh.atak.%s" % mp.node_id(frm)
        if not TAK.connected():
            return
        if "pli" in pkt and pkt["pli"].get("lat") is not None:
            p = pkt["pli"]
            ev = (ev_open(uid, "a-f-G-U-C", 600, "m-g") + point_xml(p["lat"], p["lon"], 30, p.get("alt", 0)) + "<detail>"
                  + '<contact callsign="%s"/>' % x(cs)
                  + '<__group name="%s" role="%s"/>' % (TEAMS.get(pkt.get("team"), "Cyan"), TAK_ROLES.get(pkt.get("role"), "Team Member"))
                  + ('<status battery="%d"/>' % pkt["battery"] if pkt.get("battery") is not None else "")
                  + '<track speed="%s" course="%s"/>' % (p.get("speed", 0), p.get("course", 0))
                  + "<remarks>%s</remarks></detail></event>" % x("ATAK over Meshtastic via %s (%s)" % (cfg("CALLSIGN"), mp.node_id(frm))))
            if TAK.send(ev):
                self.stats["atak_to_tak"] += 1
        msg = txt(pkt.get("chat", {}).get("message"))
        if msg:
            self.mesh_chat_to_tak(frm, msg, cs=cs, uid=uid, plugin=True)


BRIDGE = MeshTakBridge()


# ----------------------------------------------------------------------------------------------
# MQTT proxy: the radio's MQTT traffic (MqttClientProxyMessage) <-> your broker (MQTT 3.1.1, QoS 0)
# ----------------------------------------------------------------------------------------------
class MqttProxy:
    def __init__(self):
        self.sock = None
        self.lock = threading.Lock()
        self.state, self.error = "off", ""
        self.stats = {"up": 0, "down": 0}
        self.last_tx = 0
        self.sent = collections.deque(maxlen=64)     # our own uplinks, so the broker's echo is not sent back down

    @staticmethod
    def _str(s):
        b = s.encode("utf-8")
        return struct.pack(">H", len(b)) + b

    @staticmethod
    def _len(n):
        out = b""
        while True:
            d = n % 128
            n //= 128
            out += bytes([d | (0x80 if n else 0)])
            if not n:
                return out

    def _recv_packet(self, s):
        h = s.recv(1)
        if not h:
            raise ConnectionError("broker closed the connection")
        mult, n = 1, 0
        while True:
            b = s.recv(1)[0]
            n += (b & 127) * mult
            mult *= 128
            if not b & 128:
                break
        body = b""
        while len(body) < n:
            chunk = s.recv(n - len(body))
            if not chunk:
                raise ConnectionError("broker closed the connection")
            body += chunk
        return h[0], body

    def root(self):
        raw = MESH.sections.get((radiocfg.MOD, radiocfg.MQTT), b"")
        for fn, wt, v in mp.fields(raw) if raw else []:
            if fn == 8 and wt == 2 and v:
                return bytes(v).decode("utf-8", "replace")
        return "msh"

    def connect(self):
        host, port = cfg("MQTT_HOST"), cfgi("MQTT_PORT", 1883)
        raw = socket.create_connection((host, port), timeout=15)
        if cfgb("MQTT_TLS"):
            ctx = ssl.create_default_context()
            raw = ctx.wrap_socket(raw, server_hostname=host)
        flags, payload = 0x02, self._str("TurtleMesh-%s" % uuid.uuid4().hex[:8])
        if cfg("MQTT_USER"):
            flags |= 0x80
            payload += self._str(cfg("MQTT_USER"))
            if cfg("MQTT_PASSWORD"):
                flags |= 0x40
                payload += self._str(cfg("MQTT_PASSWORD"))
        var = self._str("MQTT") + bytes([4, flags]) + struct.pack(">H", 60)
        raw.sendall(bytes([0x10]) + self._len(len(var + payload)) + var + payload)
        t, body = self._recv_packet(raw)
        if t >> 4 != 2 or len(body) < 2 or body[1] != 0:
            raise ConnectionError("broker refused the connection (code %s)" % (body[1] if len(body) > 1 else "?"))
        topic = "%s/#" % self.root()
        sub = struct.pack(">H", 1) + self._str(topic) + b"\x00"
        raw.sendall(bytes([0x82]) + self._len(len(sub)) + sub)
        return raw, topic

    def publish(self, topic, data, retained=False):
        if not cfgb("MQTT_PROXY"):
            return
        with self.lock:
            s = self.sock
        if not s:
            return
        body = self._str(topic) + data
        try:
            with self.lock:
                s.sendall(bytes([0x30 | (1 if retained else 0)]) + self._len(len(body)) + body)
                self.last_tx = time.time()
                self.sent.append(hash((topic, bytes(data))))
            self.stats["up"] += 1
        except OSError as e:
            self.error = str(e)

    def run(self):
        while True:
            if not cfgb("MQTT_PROXY") or not cfg("MQTT_HOST"):
                self.state = "off"
                time.sleep(5)
                continue
            try:
                self.state = "connecting"
                s, topic = self.connect()
                with self.lock:
                    self.sock = s
                self.state, self.error = "connected", ""
                log("MQTT proxy connected to %s, subscribed to %s" % (cfg("MQTT_HOST"), topic))
                s.settimeout(15)
                self.last_tx = time.time()
                while cfgb("MQTT_PROXY"):
                    if time.time() - self.last_tx > 30:   # keepalive 60 s: ping whenever we have sent nothing for 30 s
                        with self.lock:
                            s.sendall(b"\xc0\x00")        # PINGREQ
                            self.last_tx = time.time()
                    try:
                        t, body = self._recv_packet(s)
                    except socket.timeout:
                        continue
                    if t >> 4 == 3:                       # PUBLISH from the broker -> radio
                        tl = struct.unpack(">H", body[:2])[0]
                        tp = body[2:2 + tl].decode("utf-8", "replace")
                        data = body[2 + tl + (2 if (t >> 1) & 3 else 0):]
                        h = hash((tp, bytes(data)))
                        if h in self.sent:                # our own uplink coming back
                            self.sent.remove(h)
                            continue
                        msg = mp.f_bytes(1, tp.encode()) + mp.f_bytes(2, data) + (mp.f_varint(4, 1) if t & 1 else b"")
                        MESH.queue(mp.f_bytes(6, msg))      # ToRadio.mqttClientProxyMessage
                        self.stats["down"] += 1
            except Exception as e:
                self.state, self.error = "down", str(e)[:160]
                log("MQTT proxy: %s" % self.error, "warning")
            finally:
                with self.lock:
                    if self.sock:
                        try:
                            self.sock.close()
                        except OSError:
                            pass
                    self.sock = None
            time.sleep(15)


MQTT = MqttProxy()


# ----------------------------------------------------------------------------------------------
# map tiles: cached on the Hub (USB storage when attached) so the web map works offline
# ----------------------------------------------------------------------------------------------
TILE_SOURCES = {
    "usgs_topo": ("USGS Topo", "https://basemap.nationalmap.gov/arcgis/rest/services/USGSTopo/MapServer/tile/{z}/{y}/{x}", 16, True),
    "usgs_imagery": ("USGS Imagery", "https://basemap.nationalmap.gov/arcgis/rest/services/USGSImageryOnly/MapServer/tile/{z}/{y}/{x}", 16, True),
    "usgs_hybrid": ("USGS Imagery + Topo", "https://basemap.nationalmap.gov/arcgis/rest/services/USGSImageryTopo/MapServer/tile/{z}/{y}/{x}", 16, True),
    "osm": ("OpenStreetMap (live only)", "https://tile.openstreetmap.org/{z}/{x}/{y}.png", 19, False),
}


class Tiles:
    def __init__(self):
        self.job = None
        self.lock = threading.Lock()
        self.size = None

    def root(self):
        for u in ("/usb", "/mnt/usb", "/mnt/sda1"):
            if os.path.ismount(u) and os.access(u, os.W_OK):
                return os.path.join(u, "turtlemesh-tiles")
        return os.path.join(BASE, "tiles")

    def path(self, src, z, x_, y):
        return os.path.join(self.root(), src, str(z), str(x_), "%d.tile" % y)

    def fetch(self, src, z, x_, y):
        name, url, maxz, _ = TILE_SOURCES[src]
        req = urllib.request.Request(url.format(z=z, x=x_, y=y), headers={"User-Agent": "TurtleMesh/%s (LAN Turtle Hub)" % VERSION})
        with urllib.request.urlopen(req, timeout=10) as r:
            data = r.read()
        if len(data) < 64:
            raise ValueError("empty tile")
        fp = self.path(src, z, x_, y)
        if self.size is None or self.size < cfgi("TILE_CACHE_MB", 500) * 1048576:
            os.makedirs(os.path.dirname(fp), exist_ok=True)
            with open(fp + ".tmp", "wb") as fh:
                fh.write(data)
            os.replace(fp + ".tmp", fp)
            if self.size is not None:
                self.size += len(data)
        return data

    def get(self, src, z, x_, y):
        if src not in TILE_SOURCES or z > TILE_SOURCES[src][2]:
            return None
        fp = self.path(src, z, x_, y)
        if os.path.exists(fp):
            return open(fp, "rb").read()
        try:
            return self.fetch(src, z, x_, y)
        except Exception:
            return None

    def measure(self):
        total = n = 0
        for d, _, fs in os.walk(self.root()):
            for f in fs:
                total += os.path.getsize(os.path.join(d, f))
                n += 1
        self.size = total
        self.count = n
        return total

    @staticmethod
    def tile_range(s_, w, n, e, z):
        def xy(lat, lon):
            lat = max(-85.05, min(85.05, lat))
            k = 2 ** z
            xt = int((lon + 180) / 360 * k)
            yt = int((1 - math.log(math.tan(math.radians(lat)) + 1 / math.cos(math.radians(lat))) / math.pi) / 2 * k)
            return min(k - 1, max(0, xt)), min(k - 1, max(0, yt))
        x0, y0 = xy(n, w)
        x1, y1 = xy(s_, e)
        return x0, x1, y0, y1

    def plan(self, b, zmin, zmax):
        total = 0
        for z in range(zmin, zmax + 1):
            x0, x1, y0, y1 = self.tile_range(b["s"], b["w"], b["n"], b["e"], z)
            total += (x1 - x0 + 1) * (y1 - y0 + 1)
        return total

    def download(self, src, b, zmin, zmax):
        if src not in TILE_SOURCES or not TILE_SOURCES[src][3]:
            raise RuntimeError("%s can't be saved for offline use - pick a USGS map" % TILE_SOURCES.get(src, ("that map",))[0])
        zmax = min(zmax, TILE_SOURCES[src][2])
        n = self.plan(b, zmin, zmax)
        if n > cfgi("TILE_MAX_DOWNLOAD", 20000):
            raise RuntimeError("that is %d tiles - zoom in, or lower the top zoom (limit TILE_MAX_DOWNLOAD %s)" % (n, cfg("TILE_MAX_DOWNLOAD")))
        with self.lock:
            if self.job and self.job.get("running"):
                raise RuntimeError("a map download is already running")
            self.job = {"running": True, "total": n, "done": 0, "saved": 0, "failed": 0, "src": src, "started": time.time()}
        self.measure()
        threading.Thread(target=self._run, args=(src, b, zmin, zmax), daemon=True).start()
        return "saving %d tiles of %s for offline use" % (n, TILE_SOURCES[src][0])

    def _run(self, src, b, zmin, zmax):
        j = self.job
        try:
            for z in range(zmin, zmax + 1):
                x0, x1, y0, y1 = self.tile_range(b["s"], b["w"], b["n"], b["e"], z)
                for x_ in range(x0, x1 + 1):
                    for y in range(y0, y1 + 1):
                        if not j.get("running"):
                            return
                        if not os.path.exists(self.path(src, z, x_, y)):
                            if self.size is not None and self.size >= cfgi("TILE_CACHE_MB", 500) * 1048576:
                                j["error"] = "tile cache is full (TILE_CACHE_MB)"
                                return
                            try:
                                self.fetch(src, z, x_, y)
                                j["saved"] += 1
                            except Exception:
                                j["failed"] += 1
                            time.sleep(0.05)
                        j["done"] += 1
        finally:
            j["running"] = False
            j["finished"] = time.time()
            log("map download: %d saved, %d failed, %d already there" % (j["saved"], j["failed"], j["done"] - j["saved"] - j["failed"]))

    def clear(self):
        shutil.rmtree(self.root(), ignore_errors=True)
        self.size = 0
        return "tile cache cleared"

    def status(self):
        if self.size is None:
            threading.Thread(target=self.measure, daemon=True).start()
            self.size = 0
        return {"root": self.root(), "mb": round((self.size or 0) / 1048576.0, 1), "limit_mb": cfgi("TILE_CACHE_MB", 500),
                "job": self.job, "sources": {k: v[0] for k, v in TILE_SOURCES.items()}, "source": cfg("MAP_SOURCE", "usgs_topo"),
                "offline_ok": {k: v[3] for k, v in TILE_SOURCES.items()}}


TILES = Tiles()


# ----------------------------------------------------------------------------------------------
# web console
# ----------------------------------------------------------------------------------------------
SESSIONS = {}


def hash_pw(pw, salt=None):
    salt = salt or binascii.hexlify(os.urandom(8)).decode()
    h = hashlib.pbkdf2_hmac("sha256", pw.encode(), salt.encode(), 60000)
    return "pbkdf2$%s$%s" % (salt, binascii.hexlify(h).decode())


def check_pw(pw, stored):
    try:
        _, salt, h = stored.split("$")
        return hmac.compare_digest(hash_pw(pw, salt), stored)
    except ValueError:
        return False


def state_json():
    with SL:
        now = time.time()
        p = S["pos"]
        contacts = []
        for u, c in S["contacts"].items():
            if u.startswith("TurtleMesh."):
                continue                                 # our own mesh nodes, shown from the mesh
            d = dict(c, uid=u, age=int(now - c["time"]))
            if p["lat"] is not None:
                d["dist"], d["brg"] = dist_brg(p["lat"], p["lon"], c["lat"], c["lon"])
            contacts.append(d)
        contacts.sort(key=lambda c: c.get("dist", 0))
        host, port, proto, cdir, _v, src = tak_target()
        out = {"version": VERSION, "edition": EDITION, "callsign": cfg("CALLSIGN"), "uid": my_uid(), "now": now,
               "uptime": now - S["started"], "tak": dict(S["tak"], host=host, port=port, proto=proto, source=src,
                                                         enabled=cfgb("TAK"), queued=queue_len()),
               "pos": p, "gps": S["gps"], "status": S["status"], "contacts": contacts[:300],
               "tak_chat": S["chat"][-100:], "alerts": [dict(a, source=a.get("source")) for a in all_alerts()[-100:][::-1]],
               "cert": S.get("cert", {}), "alert_kinds": ALERT_KINDS, "quiet": in_quiet_hours(), "tiles": TILES.status(),
               "sites": sites(), "status_text": status_text(),
               "certs": {f: os.path.exists(os.path.join(cdir, f)) for f in ("client.pem", "ca.pem")},
               "turtletak": {"installed": os.path.exists(os.path.join(TURTLETAK_BASE, "default.cfg")), "running": turtletak_running(),
                             "port": turtletak_cfg().get("WEB_PORT", "8484")}}
    with MESH.lock:
        chans = sorted(({"index": c["index"], "name": MESH.chan_label(c["index"]), "role": c.get("role"),
                         "private": MESH.chan_private(c["index"]), "key": c.get("psk_kind", "")}
                        for c in MESH.channels.values()), key=lambda c: c["index"])
        chat = list(MESH.chat[-300:])
    out["mesh"] = {"link": MESH.link, "error": MESH.error, "me": mp.node_id(MESH.my_num) if MESH.my_num else "",
                   "name": MESH.name_of(MESH.my_num) if MESH.my_num else "", "region": mp.REGIONS.get(MESH.region, ""),
                   "hop_limit": MESH.hop_limit, "conn": cfg("RADIO_CONN"), "host": cfg("RADIO_HOST"),
                   "firmware": MESH.metadata.get("firmware", ""), "channels": chans, "chat": chat,
                   "nodes": MESH.node_rows(), "learning": max(0, int(MESH.learn_until - now)), "known": len(MESH.known),
                   "sig": MESH.sig.stats(MESH.name_of) if hasattr(MESH.sig, "stats") else {}}
    out["bridge"] = dict(BRIDGE.stats, nodes=cfgb("BRIDGE_NODES"), chat_channel=cfgi("BRIDGE_CHAT_CHANNEL", -1),
                         atak=cfgb("BRIDGE_ATAK_PLUGIN"))
    out["mqtt"] = {"on": cfgb("MQTT_PROXY"), "state": MQTT.state, "error": MQTT.error, **MQTT.stats}
    lch = cfg("LORA_ALERT_CHANNEL").strip()
    out["lora"] = {"on": cfgb("LORA_ALERTS") and bool(cfg("LORA_ALERT_TO").strip() or lch), "min": cfg("LORA_ALERT_MIN"),
                   "to": cfg("LORA_ALERT_TO") or (MESH.chan_label(int(lch)) if lch.lstrip("-").isdigit() else "no channel chosen"),
                   "public": bool(lch.isdigit() and not cfg("LORA_ALERT_TO").strip() and not MESH.chan_private(int(lch)))}
    out["mesh_pos_channel"] = cfgi("MESH_POS_CHANNEL", -1)
    return json.dumps(out, default=str).encode()


def queue_len():
    try:
        return sum(1 for _ in open(QUEUE))
    except OSError:
        return 0


def dist_brg(a1, o1, a2, o2):
    r = 6371000.0
    p1, p2 = math.radians(a1), math.radians(a2)
    dp, dl = p2 - p1, math.radians(o2 - o1)
    a = math.sin(dp / 2) ** 2 + math.cos(p1) * math.cos(p2) * math.sin(dl / 2) ** 2
    d = 2 * r * math.asin(min(1, math.sqrt(a)))
    b = math.degrees(math.atan2(math.sin(dl) * math.cos(p2), math.cos(p1) * math.sin(p2) - math.sin(p1) * math.cos(p2) * math.cos(dl)))
    return round(d), round((b + 360) % 360)


SECRET_KEYS = {"WEB_PASS_HASH", "WIFI_KEY", "CLIENT_PASSWORD", "CA_PASSWORD", "MQTT_PASSWORD"}


def action(a, d):
    def node(v):
        try:
            return int(str(v).strip().lstrip("!"), 16)
        except ValueError:
            raise RuntimeError("bad node id")
    if a == "chat":                                     # TAK GeoChat
        text = (d.get("text") or "").strip()[:1000]
        if not text:
            raise RuntimeError("empty message")
        return "sent" if chat_send(text, d.get("to") or None) else "queued (TAK offline)"
    if a == "mesh_send":
        to = node(d["to"]) if d.get("to") else None
        ok, msg = MESH.send_text(d.get("text") or "", to=to, channel=int(d.get("channel") or 0))
        if not ok:
            raise RuntimeError(msg)
        return msg
    if a == "mesh_pos":
        ok, msg = MESH.send_position()
        if not ok:
            raise RuntimeError(msg)
        return msg
    if a == "node_meta":
        nid = "!%08x" % node(d["id"])
        set_node_meta(nid, name=d.get("name"), watch=d.get("watch"), sensor=d.get("sensor"))
        return "saved"
    if a == "traceroute":
        return MESH.traceroute(node(d["id"]))
    if a == "req_pos":
        return MESH.request_position(node(d["id"]))
    if a == "accept_nodes":
        return "%d nodes known" % MESH.accept_nodes()
    if a == "relearn":
        return MESH.relearn()
    if a == "radio_reconnect":
        MESH.reconnect()
        return "reconnecting to the radio"
    if a == "set_owner":
        return MESH.set_owner(d.get("long", ""), d.get("short", ""))
    if a == "set_radio":
        return MESH.set_radio(d.get("changes") or {})
    if a == "set_channel":
        kw = {k: d[k] for k in ("name", "psk", "role", "uplink", "downlink", "precision") if k in d and d[k] is not None}
        return MESH.set_channel(int(d["index"]), **kw)
    if a == "reboot_radio":
        return MESH.reboot()
    if a == "mqtt_radio_setup":
        return MESH.set_radio({"mqtt.enabled": True, "mqtt.proxy_to_client_enabled": True})
    if a == "clear_alerts":
        with SL:
            S["alerts"] = []
        save_state()
        return "cleared"
    if a == "test_alert":
        raise_alert("test", "warning", "Test alert", "This is a TurtleMesh test alert.", key=None)
        return "sent"
    if a == "reconnect":
        TAK.reconnect()
        return "reconnecting"
    if a == "send_sa":
        locate()
        return "sent" if TAK.send(sa_event()) else "TAK offline"
    if a == "set_pos":
        lat, lon = float(d["lat"]), float(d["lon"])
        if not (-90 <= lat <= 90 and -180 <= lon <= 180):
            raise RuntimeError("bad coordinates")
        ch = {"MANUAL_LAT": "%.7f" % lat, "MANUAL_LON": "%.7f" % lon}
        if d.get("site"):
            save_site(d["site"].strip()[:40], lat, lon)
            ch = {"SITE": d["site"].strip()[:40], "LOC_MODE": "site"}
        elif cfg("LOC_MODE") not in ("manual", "auto"):
            ch["LOC_MODE"] = "manual"
        cfg_set(ch)
        locate()
        TAK.send(sa_event())
        return "location set"
    if a == "uplinks":
        return "; ".join(uplinks_apply()) or "nothing configured"
    if a == "enroll":
        enroll(d.get("user", ""), d.get("password", ""))
        return "enrolled"
    if a == "set_password":
        pw = d.get("password", "")
        if len(pw) < 8:
            raise RuntimeError("use at least 8 characters")
        cfg_set({"WEB_PASS_HASH": hash_pw(pw)})
        return "password changed"
    if a == "tiles_download":
        b = {k: float(d["bounds"][k]) for k in ("s", "w", "n", "e")}
        return TILES.download(d.get("src") or cfg("MAP_SOURCE"), b, int(d.get("zmin", 1)), int(d.get("zmax", 15)))
    if a == "tiles_plan":
        b = {k: float(d["bounds"][k]) for k in ("s", "w", "n", "e")}
        src = d.get("src") or cfg("MAP_SOURCE")
        return "%d tiles" % TILES.plan(b, int(d.get("zmin", 1)), min(int(d.get("zmax", 15)), TILE_SOURCES.get(src, ("", "", 16))[2]))
    if a == "tiles_stop":
        if TILES.job:
            TILES.job["running"] = False
        return "stopping"
    if a == "tiles_clear":
        return TILES.clear()
    if a == "restore_certs":
        return restore_certs()
    if a == "diagnose":
        return "\n".join(diagnose())
    if a == "install_openssl":
        for mgr, cmd in (("opkg", "opkg update && opkg install openssl-util"), ("apk", "apk update && apk add openssl")):
            if have(mgr):
                p = subprocess.run(["sh", "-c", cmd], stdout=subprocess.PIPE, stderr=subprocess.STDOUT, timeout=300)
                out = p.stdout.decode("utf-8", "replace")
                log("%s: %s" % (cmd, out[-300:]))
                return "openssl installed" if have("openssl") else "install failed: %s" % out.strip()[-160:]
        return "no package manager (opkg/apk) found - openssl is optional, TurtleMesh works without it"
    if a == "boot":
        rc, out = hub("BOOT_PAYLOAD", "enable" if d.get("on") else "disable")
        cfg_set({"RUN_AT_BOOT": "1" if d.get("on") else "0"})
        return "run at boot %s" % ("on" if d.get("on") else "off")
    raise RuntimeError("unknown action")


def diagnose():
    """Step-by-step TAK connection check for the Setup page."""
    host, port, proto, cdir, verify, src = tak_target()
    out = ["Server: %s:%d (%s)%s" % (host, port, proto, " - TurtleTAK's settings" if src == "TurtleTAK" else "")]
    out.append("DNS servers: %s" % (", ".join(re.findall(r"^nameserver\s+(\S+)", rd("/etc/resolv.conf"), re.M)) or "none in /etc/resolv.conf"))
    try:
        socket.inet_aton(host)
        ips = [host]
        out.append("1. DNS: %s is an IP address - no lookup needed" % host)
    except OSError:
        detail = []
        for fam, name in ((socket.AF_UNSPEC, "any"), (socket.AF_INET, "IPv4"), (socket.AF_INET6, "IPv6")):
            try:
                r = _getaddrinfo(host, port, fam, socket.SOCK_STREAM)
                detail.append("%s ok (%s)" % (name, r[0][4][0]))
            except socket.gaierror as e:
                detail.append("%s failed (%s)" % (name, e.strerror or e))
        ns = _nslookup(host)
        detail.append("nslookup %s" % (ns[0] if ns else "failed"))
        try:
            ips = [ai[4][0] for ai in socket.getaddrinfo(host, port, 0, socket.SOCK_STREAM)]
            out.append("1. DNS: OK -> %s  [%s]" % (ips[0], "; ".join(detail)))
        except socket.gaierror as e:
            out.append("1. DNS: FAILED - %s  [%s]. Check the server name's spelling first, then try the server's IP address, or set SYSTEM_DNS on the Hub." % (e, "; ".join(detail)))
            return out
    if proto == "udp":
        out.append("2. UDP: send-only, nothing to test")
        return out
    try:
        t0 = time.time()
        raw = socket.create_connection((host, port), timeout=10)
        out.append("2. TCP %d: OK (%d ms, from %s)" % (port, (time.time() - t0) * 1000, raw.getsockname()[0]))
    except OSError as e:
        out.append("2. TCP %d: FAILED - %s. Check the port, a firewall, or the route (VPN?)." % (port, e))
        return out
    if proto != "tls":
        raw.close()
        out.append("3. TLS: not used (tcp)")
        return out
    client, ca = os.path.join(cdir, "client.pem"), os.path.join(cdir, "ca.pem")
    if not os.path.exists(client):
        raw.close()
        out.append("3. TLS: no client certificate loaded")
        return out
    try:
        ctx = ssl.SSLContext(ssl.PROTOCOL_TLS_CLIENT)
        try:
            ctx.load_cert_chain(client)
            out.append("3a. Client certificate file: OK (%s)" % pem_summary(client))
        except (ssl.SSLError, OSError) as e:
            out.append("3a. Client certificate file: BROKEN - %s (%s). Re-import it, or Restore previous certificates." % (e, pem_summary(client)))
            raw.close()
            return out
        if os.path.exists(ca):
            try:
                ssl.SSLContext(ssl.PROTOCOL_TLS_CLIENT).load_verify_locations(ca)
                out.append("3b. Truststore file: OK (%s)" % pem_summary(ca))
            except (ssl.SSLError, OSError) as e:
                out.append("3b. Truststore file: BROKEN - %s (%s). Re-import it, or Restore previous certificates." % (e, pem_summary(ca)))
                raw.close()
                return out
        if os.path.exists(ca):
            ctx.load_verify_locations(ca)
            ctx.check_hostname = verify
            ctx.verify_mode = ssl.CERT_REQUIRED
        else:
            ctx.check_hostname = False
            ctx.verify_mode = ssl.CERT_NONE
        s = ctx.wrap_socket(raw, server_hostname=host)
        peer = s.getpeercert(binary_form=False) or {}
        subj = ", ".join("%s=%s" % kv for rdn in peer.get("subject", ()) for kv in rdn)
        out.append("3. TLS: OK (%s, server cert %s%s)" % (s.version(), subj or "not checked", "" if os.path.exists(ca) else ", truststore not loaded"))
        s.settimeout(3)
        try:
            data = s.recv(4096)
            out.append("4. Server accepted the client certificate%s" % (" and sent data" if data else ""))
        except socket.timeout:
            out.append("4. Server accepted the client certificate (connection held open)")
        except (ssl.SSLError, OSError) as e:
            out.append("4. Server REJECTED the client certificate: %s (wrong CA / revoked / not enrolled?)" % e)
        s.close()
    except ssl.SSLCertVerificationError as e:
        out.append("3. TLS: server certificate NOT trusted by the truststore - %s (wrong truststore, or turn TAK_VERIFY_HOST off)" % e.verify_message)
    except (ssl.SSLError, OSError) as e:
        out.append("3. TLS: FAILED - %s" % e)
    return out


class Web(BaseHTTPRequestHandler):
    server_version = "TurtleMesh"
    protocol_version = "HTTP/1.0"

    def log_message(self, *a):
        pass

    def send(self, code, body=b"", ctype="application/json", extra=()):
        self.send_response(code)
        self.send_header("Content-Type", ctype)
        self.send_header("Content-Length", str(len(body)))
        if not any(k == "Cache-Control" for k, _ in extra):
            self.send_header("Cache-Control", "no-store")
        self.send_header("X-Frame-Options", "DENY")
        for k, v in extra:
            self.send_header(k, v)
        self.end_headers()
        self.wfile.write(body)

    def session(self):
        m = re.search(r"tm_session=([0-9a-f]{32})", self.headers.get("Cookie", ""))
        s = m and SESSIONS.get(m.group(1))
        return bool(s and s > time.time())

    def body(self, limit=64 * 1024):
        n = int(self.headers.get("Content-Length") or 0)
        if n > limit:
            raise RuntimeError("too large")
        return self.rfile.read(n)

    def do_GET(self):
        path = self.path.split("?")[0]
        if path in ("/", "/index.html"):
            return self.send(200, open(os.path.join(APP, "index.html"), "rb").read(), "text/html; charset=utf-8")
        if path == "/api/state":
            if not self.session():
                return self.send(401, b'{"login":true}')
            return self.send(200, state_json())
        if path == "/api/cfg":
            if not self.session():
                return self.send(401, b'{"login":true}')
            with CFG_LOCK:
                c = [{"key": k, "value": ("" if k in SECRET_KEYS and CFG.get(k) else CFG.get(k, v)) if v is not None else None,
                      "set": bool(CFG.get(k)), "secret": k in SECRET_KEYS, "section": v is None} for k, v in DEFAULTS]
            return self.send(200, json.dumps(c).encode())
        if path.startswith("/static/") and re.match(r"^/static/[a-z0-9_.-]+$", path):
            fp = os.path.join(APP, "static", path[8:])
            if os.path.exists(fp):
                ctype = "text/css" if fp.endswith(".css") else "application/javascript"
                return self.send(200, open(fp, "rb").read(), ctype, extra=[("Cache-Control", "max-age=86400")])
            return self.send(404, b"")
        m = re.match(r"^/tiles/([a-z_]+)/(\d+)/(\d+)/(\d+)$", path)
        if m:
            if not self.session():
                return self.send(401, b"")
            data = TILES.get(m.group(1), int(m.group(2)), int(m.group(3)), int(m.group(4)))
            if data is None:
                return self.send(404, b"")
            ctype = "image/png" if data[:4] == b"\x89PNG" else "image/jpeg"
            return self.send(200, data, ctype)
        if path in ("/api/sigint.pcap", "/api/sigint.csv"):
            if not self.session():
                return self.send(401, b'{"login":true}')
            if path.endswith(".pcap"):
                return self.send(200, MESH.sig.pcap(), "application/vnd.tcpdump.pcap",
                                 extra=[("Content-Disposition", 'attachment; filename="turtlemesh.pcap"')])
            return self.send(200, MESH.sig.csv().encode() if isinstance(MESH.sig.csv(), str) else MESH.sig.csv(), "text/csv",
                             extra=[("Content-Disposition", 'attachment; filename="turtlemesh-packets.csv"')])
        if path == "/api/radio":
            if not self.session():
                return self.send(401, b'{"login":true}')
            return self.send(200, json.dumps(MESH.radio_view(), default=lambda o: o.hex() if isinstance(o, bytes) else str(o)).encode())
        if path == "/api/log":
            if not self.session():
                return self.send(401, b'{"login":true}')
            with LOG_LOCK:
                return self.send(200, "\n".join(LOGQ[-250:]).encode(), "text/plain; charset=utf-8")
        self.send(404, b'{"error":"not found"}')

    def do_POST(self):
        path = self.path.split("?")[0]
        try:
            if path == "/api/login":
                d = json.loads(self.body() or b"{}")
                time.sleep(0.5)
                if check_pw(d.get("password", ""), cfg("WEB_PASS_HASH")):
                    sid = binascii.hexlify(os.urandom(16)).decode()
                    SESSIONS[sid] = time.time() + 12 * 3600
                    return self.send(200, b'{"ok":true}', extra=[("Set-Cookie", "tm_session=%s; HttpOnly; SameSite=Strict; Path=/" % sid)])
                log("web login failed from %s" % self.client_address[0], "warning")
                return self.send(403, b'{"error":"wrong password"}')
            if not self.session():
                return self.send(401, b'{"login":true}')
            if self.headers.get("X-TT") != "1":
                return self.send(403, b'{"error":"missing header"}')
            if path == "/api/logout":
                m = re.search(r"tm_session=([0-9a-f]{32})", self.headers.get("Cookie", ""))
                if m:
                    SESSIONS.pop(m.group(1), None)
                return self.send(200, b'{"ok":true}')
            if path == "/api/action":
                d = json.loads(self.body() or b"{}")
                return self.send(200, json.dumps({"ok": True, "msg": action(d.get("action"), d)}).encode())
            if path == "/api/cfg":
                d = json.loads(self.body() or b"{}")
                known = {k for k, v in DEFAULTS if v is not None} - {"WEB_PASS_HASH", "UID"}
                ch = {k: v for k, v in d.items() if k in known and not (k in SECRET_KEYS and v == "")}
                for key, what in (("BRIDGE_CHAT_CHANNEL", "the TAK chat bridge"), ("MESH_POS_CHANNEL", "the Hub's position")):
                    v = str(ch.get(key, "")).strip()
                    if v.isdigit() and not MESH.chan_private(int(v)):
                        return self.send(400, json.dumps({"ok": False, "error": "%s is a public channel (no key, the default key or a simple key) - %s only uses a channel with its own key" % (MESH.chan_label(int(v)), what)}).encode())
                cfg_set(ch)
                if set(ch) & {"TAK_HOST", "TAK_PORT", "TAK_PROTO", "TAK_VERIFY_HOST"}:
                    TAK.reconnect()
                if set(ch) & {"WIFI_SSID", "WIFI_KEY", "WIFI_ENC", "WG_CONF"}:
                    threading.Thread(target=uplinks_apply, daemon=True).start()
                if "LED" in ch:
                    LED_STATE["shown"] = None
                    led()
                log("settings changed in the web console: %s" % ", ".join(sorted(ch)))
                return self.send(200, json.dumps({"ok": True, "msg": "saved %d setting(s)" % len(ch)}).encode())
            if path == "/api/upload":
                name = os.path.basename(self.headers.get("X-Filename", "upload.bin"))
                name = re.sub(r"[^A-Za-z0-9._-]", "_", name)[:80]
                if not name.lower().endswith((".zip", ".p12", ".pfx", ".pem", ".key", ".conf")):
                    raise RuntimeError("upload a .zip connection package, .p12, .pem, .key or wg .conf")
                data = self.body(limit=8 * 1024 * 1024)
                dest = os.path.join(CERTS, name)
                if name.lower().endswith(".conf"):
                    dest = os.path.join(CERTS, "wg.conf")
                fd = os.open(dest, os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o600)
                with os.fdopen(fd, "wb") as fh:
                    fh.write(data)
                msg = "saved %s" % os.path.basename(dest)
                def hdr(k):
                    v = self.headers.get(k) or ""
                    return urllib.request.unquote(v) if v else None
                pw = hdr("X-Cert-Password")
                kind = (self.headers.get("X-Cert-Kind") or "").lower()
                if name.lower().endswith(".zip"):
                    import_package(dest, hdr("X-Client-Password"), hdr("X-CA-Password"))
                    TAK.reconnect()
                    msg = "connection package imported"
                elif name.lower().endswith((".p12", ".pfx")):
                    kind = kind if kind in ("client", "ca") else cert_kind(name)
                    setting = "CLIENT_PASSWORD" if kind == "client" else "CA_PASSWORD"
                    try:
                        used = p12_to_pem(dest, os.path.join(CERTS, kind + ".pem"), [pw, cfg(setting), "atakatak"],
                                          nokeys=(kind == "ca"))
                    except Exception:
                        os.unlink(dest)
                        raise
                    os.makedirs(os.path.join(CERTS, "imported"), exist_ok=True)
                    os.replace(dest, os.path.join(CERTS, "imported", name))
                    cfg_set({setting: used})
                    TAK.reconnect()
                    msg = "%s imported" % ("client certificate" if kind == "client" else "truststore")
                elif name.lower().endswith(".conf"):
                    cfg_set({"WG_CONF": dest})
                    msg = "; ".join(uplinks_apply())
                elif name.lower().endswith((".pem", ".key")):
                    if kind in ("client", "ca") and name.lower().endswith(".pem"):
                        text = open(dest).read()
                        os.unlink(dest)
                        save_cert_files(**{kind: text}, why=name)
                        msg = "saved as %s.pem" % kind
                    TAK.reconnect()
                return self.send(200, json.dumps({"ok": True, "msg": msg}).encode())
            self.send(404, b'{"error":"not found"}')
        except Exception as e:
            log("web %s: %s" % (path, e), "warning")
            self.send(400, json.dumps({"ok": False, "error": str(e)}).encode())


class WebServer(ThreadingMixIn, HTTPServer):
    daemon_threads = True
    allow_reuse_address = True


def web_run():
    if not cfgb("WEB"):
        return
    port = cfgi("WEB_PORT", 8485)
    if port == 1471:
        port = 8485
    try:
        srv = WebServer((cfg("WEB_BIND", "0.0.0.0"), port), Web)
    except OSError as e:
        log("web console could not use port %d: %s" % (port, e), "error")
        notify("error", "Web console port %d busy: %s" % (port, e))
        return
    scheme = "http"
    if cfgb("WEB_TLS") and have("openssl"):
        crt, key = os.path.join(BASE, "web.crt"), os.path.join(BASE, "web.key")
        if not os.path.exists(crt):
            run(["openssl", "req", "-x509", "-newkey", "rsa:2048", "-nodes", "-days", "3650", "-subj", "/CN=TurtleMesh",
                 "-keyout", key, "-out", crt], 120)
        ctx = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER)
        ctx.load_cert_chain(crt, key)
        srv.socket = ctx.wrap_socket(srv.socket, server_side=True)
        scheme = "https"
    log("web console on %s://<hub>:%d (all interfaces: %s)" % (scheme, port, cfg("WEB_BIND")))
    srv.serve_forever()


# ----------------------------------------------------------------------------------------------
def first_run_password():
    if cfg("WEB_PASS_HASH"):
        return
    pw = "".join(random.SystemRandom().choice("abcdefghjkmnpqrstuvwxyz23456789") for _ in range(10))
    cfg_set({"WEB_PASS_HASH": hash_pw(pw)})
    with open(os.path.join(BASE, "web-password.txt"), "w") as fh:
        fh.write("TurtleMesh web console first password: %s\nChange it in Setup > Web password, then delete this file.\n" % pw)
    os.chmod(os.path.join(BASE, "web-password.txt"), 0o600)
    notify("info", "Web console on port %s - first password: %s (change it in Setup)" % (cfg("WEB_PORT"), pw))
    log("web console first password written to %s/web-password.txt" % BASE)


def main():
    for d in (BASE, APP, CERTS, LOGS, LOOT):
        os.makedirs(d, exist_ok=True)
    os.chmod(CERTS, 0o700)
    cfg_load()
    load_state()
    log("%s %s %s starting (python %s)" % (PRODUCT, EDITION, VERSION, sys.version.split()[0]))
    led("SETUP")
    first_run_password()
    if MIGRATED:
        msg = "Mesh sharing is now off until you pick a channel: %s. Most channel 0s are public - choose a channel with its own key (Alerts, TAK and Radio tabs)." % ", ".join(MIGRATED)
        log(msg, "warning")
        notify("warning", msg)
    status_collect()
    if cfgb("RUN_AT_BOOT"):
        hub("BOOT_PAYLOAD", "enable")
    threading.Thread(target=uplinks_apply, daemon=True).start()
    scan_certs()
    locate()
    for target in (web_run, TAK.run, TAK.watchdog, sa_loop, housekeeping, Gps().run, MESH.run, MESH.watch_loop,
                   BRIDGE.loop, LORA.run, MQTT.run):
        threading.Thread(target=target, daemon=True, name=target.__name__).start()
    try:
        while True:
            time.sleep(3600)
    except KeyboardInterrupt:
        pass
    finally:
        save_state()
        hub("LED", "OFF") if not cfgb("LED") and not IN_SHELL else None


if __name__ == "__main__":
    main()
TURTLEMESH_PY
cat > "$APP/ttcrypto.py" <<'TTCRYPTO_PY'
# TurtleTAK certificate helpers in pure Python (stdlib only), for Hubs without openssl:
#   - RSA key generation + PKCS#10 CSR (for TAK Server enrollment)
#   - PKCS#12 (.p12) reader: PBES2 (PBKDF2 + AES-CBC) and legacy PKCS#12 PBE (3DES, RC2)
# Not a general crypto library: just enough for TAK client certificates.
import base64, hashlib, hmac, os, struct

# ---------------------------------------------------------------------------------------------
# DER
# ---------------------------------------------------------------------------------------------
def _len(n):
    if n < 0x80:
        return bytes([n])
    b = n.to_bytes((n.bit_length() + 7) // 8, "big")
    return bytes([0x80 | len(b)]) + b


def tlv(tag, body):
    return bytes([tag]) + _len(len(body)) + body


def d_int(v):
    b = v.to_bytes(max(1, (v.bit_length() + 8) // 8), "big", signed=False)
    if b[0] & 0x80:
        b = b"\0" + b
    while len(b) > 1 and b[0] == 0 and not b[1] & 0x80:
        b = b[1:]
    return tlv(0x02, b)


def d_seq(*items):
    return tlv(0x30, b"".join(items))


def d_set(*items):
    return tlv(0x31, b"".join(items))


def d_oid(s):
    p = [int(x) for x in s.split(".")]
    out = bytes([40 * p[0] + p[1]])
    for v in p[2:]:
        enc = [v & 0x7F]
        v >>= 7
        while v:
            enc.append(0x80 | (v & 0x7F))
            v >>= 7
        out += bytes(reversed(enc))
    return tlv(0x06, out)


def d_null():
    return b"\x05\x00"


def d_bits(b):
    return tlv(0x03, b"\0" + b)


def d_utf8(s):
    return tlv(0x0C, s.encode("utf-8"))


def d_printable(s):
    return tlv(0x13, s.encode("ascii"))


def parse(buf, i=0):
    """-> (tag, value_bytes, next_index)"""
    tag = buf[i]
    ln = buf[i + 1]
    i += 2
    if ln & 0x80:
        n = ln & 0x7F
        if n == 0:  # indefinite length (BER) - not used by the files we read
            raise ValueError("indefinite length")
        ln = int.from_bytes(buf[i:i + n], "big")
        i += n
    return tag, buf[i:i + ln], i + ln


def children(buf):
    out, i = [], 0
    while i < len(buf):
        t, v, i = parse(buf, i)
        out.append((t, v))
    return out


def oid_str(v):
    p = [v[0] // 40, v[0] % 40]
    acc = 0
    for b in v[1:]:
        acc = (acc << 7) | (b & 0x7F)
        if not b & 0x80:
            p.append(acc)
            acc = 0
    return ".".join(map(str, p))


def pem(kind, der):
    b = base64.b64encode(der).decode()
    return "-----BEGIN %s-----\n%s\n-----END %s-----\n" % (kind, "\n".join(b[i:i + 64] for i in range(0, len(b), 64)), kind)


# ---------------------------------------------------------------------------------------------
# RSA key + CSR
# ---------------------------------------------------------------------------------------------
_SMALL = [p for p in range(3, 2000, 2) if all(p % q for q in range(3, int(p ** .5) + 1, 2))]


def _probable_prime(n, rounds=24):
    for p in _SMALL:
        if n % p == 0:
            return n == p
    d, r = n - 1, 0
    while d % 2 == 0:
        d //= 2
        r += 1
    for _ in range(rounds):
        a = 2 + int.from_bytes(os.urandom(32), "big") % (n - 3)
        x = pow(a, d, n)
        if x in (1, n - 1):
            continue
        for _ in range(r - 1):
            x = pow(x, 2, n)
            if x == n - 1:
                break
        else:
            return False
    return True


def _prime(bits):
    while True:
        c = int.from_bytes(os.urandom(bits // 8), "big") | (3 << (bits - 2)) | 1
        if _probable_prime(c):
            return c


def rsa_generate(bits=2048, e=65537):
    while True:
        p, q = _prime(bits // 2), _prime(bits // 2)
        if p == q:
            continue
        phi = (p - 1) * (q - 1)
        if phi % e == 0:
            continue
        n = p * q
        if n.bit_length() != bits:
            continue
        d = pow(e, -1, phi)
        return {"n": n, "e": e, "d": d, "p": p, "q": q, "dp": d % (p - 1), "dq": d % (q - 1), "qi": pow(q, -1, p)}


def rsa_key_pem(k):
    der = d_seq(d_int(0), d_int(k["n"]), d_int(k["e"]), d_int(k["d"]), d_int(k["p"]), d_int(k["q"]),
                d_int(k["dp"]), d_int(k["dq"]), d_int(k["qi"]))
    return pem("RSA PRIVATE KEY", der)


def _rsa_sign_sha256(k, data):
    h = hashlib.sha256(data).digest()
    t = bytes.fromhex("3031300d060960864801650304020105000420") + h
    klen = (k["n"].bit_length() + 7) // 8
    em = b"\x00\x01" + b"\xff" * (klen - len(t) - 3) + b"\x00" + t
    m = int.from_bytes(em, "big")
    s1, s2 = pow(m, k["dp"], k["p"]), pow(m, k["dq"], k["q"])
    s = s2 + k["q"] * ((k["qi"] * (s1 - s2)) % k["p"])
    return s.to_bytes(klen, "big")


_NAME_OIDS = {"C": "2.5.4.6", "ST": "2.5.4.8", "L": "2.5.4.7", "O": "2.5.4.10", "OU": "2.5.4.11", "CN": "2.5.4.3"}


def csr_der(k, subject):
    """subject: list of (attr, value) e.g. [("O","TAK"),("OU","TAK"),("CN","user")]"""
    rdns = []
    for a, v in subject:
        oid = _NAME_OIDS.get(a.upper())
        if not oid:
            continue
        val = d_printable(v) if a.upper() == "C" else d_utf8(v)
        rdns.append(d_set(d_seq(d_oid(oid), val)))
    name = d_seq(*rdns)
    spki = d_seq(d_seq(d_oid("1.2.840.113549.1.1.1"), d_null()), d_bits(d_seq(d_int(k["n"]), d_int(k["e"]))))
    info = d_seq(d_int(0), name, spki, b"\xa0\x00")
    sig = _rsa_sign_sha256(k, info)
    return d_seq(info, d_seq(d_oid("1.2.840.113549.1.1.11"), d_null()), d_bits(sig))


# ---------------------------------------------------------------------------------------------
# AES (decrypt only, CBC)
# ---------------------------------------------------------------------------------------------
def _aes_tables():
    sbox = [0] * 256
    p = q = 1
    while True:
        p = p ^ ((p << 1) & 0xFF) ^ (0x1B if p & 0x80 else 0)
        q ^= q << 1
        q ^= q << 2
        q ^= q << 4
        q &= 0xFF
        if q & 0x80:
            q ^= 0x09
        x = q ^ ((q << 1) | (q >> 7)) ^ ((q << 2) | (q >> 6)) ^ ((q << 3) | (q >> 5)) ^ ((q << 4) | (q >> 4))
        sbox[p] = (x ^ 0x63) & 0xFF
        if p == 1:
            break
    sbox[0] = 0x63
    inv = [0] * 256
    for i, v in enumerate(sbox):
        inv[v] = i
    return sbox, inv


_SBOX, _INV = _aes_tables()


def _xt(a):
    return ((a << 1) ^ 0x1B) & 0xFF if a & 0x80 else a << 1


def _mul(a, b):
    r = 0
    while b:
        if b & 1:
            r ^= a
        a = _xt(a)
        b >>= 1
    return r


_M9 = [_mul(i, 9) for i in range(256)]
_M11 = [_mul(i, 11) for i in range(256)]
_M13 = [_mul(i, 13) for i in range(256)]
_M14 = [_mul(i, 14) for i in range(256)]


def _expand(key):
    nk = len(key) // 4
    nr = nk + 6
    w = [list(key[4 * i:4 * i + 4]) for i in range(nk)]
    rcon = 1
    for i in range(nk, 4 * (nr + 1)):
        t = list(w[i - 1])
        if i % nk == 0:
            t = t[1:] + t[:1]
            t = [_SBOX[b] for b in t]
            t[0] ^= rcon
            rcon = _xt(rcon)
        elif nk > 6 and i % nk == 4:
            t = [_SBOX[b] for b in t]
        w.append([a ^ b for a, b in zip(w[i - nk], t)])
    return [sum(w[4 * r:4 * r + 4], []) for r in range(nr + 1)], nr


def _aes_decrypt_block(rk, nr, blk):
    s = [b ^ k for b, k in zip(blk, rk[nr])]
    for rnd in range(nr - 1, -1, -1):
        # inverse shift rows (column-major state)
        s = [s[((c - r) % 4) * 4 + r] for c in range(4) for r in range(4)]
        s = [_INV[b] for b in s]
        s = [b ^ k for b, k in zip(s, rk[rnd])]
        if rnd:
            o = []
            for c in range(4):
                a0, a1, a2, a3 = s[4 * c:4 * c + 4]
                o += [_M14[a0] ^ _M11[a1] ^ _M13[a2] ^ _M9[a3], _M9[a0] ^ _M14[a1] ^ _M11[a2] ^ _M13[a3],
                      _M13[a0] ^ _M9[a1] ^ _M14[a2] ^ _M11[a3], _M11[a0] ^ _M13[a1] ^ _M9[a2] ^ _M14[a3]]
            s = o
    return bytes(s)


def aes_cbc_decrypt(key, iv, data):
    rk, nr = _expand(key)
    out, prev = bytearray(), iv
    for i in range(0, len(data), 16):
        blk = data[i:i + 16]
        out += bytes(a ^ b for a, b in zip(_aes_decrypt_block(rk, nr, blk), prev))
        prev = blk
    return _unpad(bytes(out), 16)


def _unpad(b, bs):
    n = b[-1] if b else 0
    if not 1 <= n <= bs or b[-n:] != bytes([n]) * n:
        raise ValueError("bad padding (wrong password?)")
    return b[:-n]


# ---------------------------------------------------------------------------------------------
# DES / 3DES (decrypt, CBC) - legacy PKCS#12
# ---------------------------------------------------------------------------------------------
_PC1 = [57, 49, 41, 33, 25, 17, 9, 1, 58, 50, 42, 34, 26, 18, 10, 2, 59, 51, 43, 35, 27, 19, 11, 3, 60, 52, 44, 36,
        63, 55, 47, 39, 31, 23, 15, 7, 62, 54, 46, 38, 30, 22, 14, 6, 61, 53, 45, 37, 29, 21, 13, 5, 28, 20, 12, 4]
_PC2 = [14, 17, 11, 24, 1, 5, 3, 28, 15, 6, 21, 10, 23, 19, 12, 4, 26, 8, 16, 7, 27, 20, 13, 2,
        41, 52, 31, 37, 47, 55, 30, 40, 51, 45, 33, 48, 44, 49, 39, 56, 34, 53, 46, 42, 50, 36, 29, 32]
_SHIFTS = [1, 1, 2, 2, 2, 2, 2, 2, 1, 2, 2, 2, 2, 2, 2, 1]
_IP = [58, 50, 42, 34, 26, 18, 10, 2, 60, 52, 44, 36, 28, 20, 12, 4, 62, 54, 46, 38, 30, 22, 14, 6, 64, 56, 48, 40, 32, 24, 16, 8,
       57, 49, 41, 33, 25, 17, 9, 1, 59, 51, 43, 35, 27, 19, 11, 3, 61, 53, 45, 37, 29, 21, 13, 5, 63, 55, 47, 39, 31, 23, 15, 7]
_FP = [40, 8, 48, 16, 56, 24, 64, 32, 39, 7, 47, 15, 55, 23, 63, 31, 38, 6, 46, 14, 54, 22, 62, 30, 37, 5, 45, 13, 53, 21, 61, 29,
       36, 4, 44, 12, 52, 20, 60, 28, 35, 3, 43, 11, 51, 19, 59, 27, 34, 2, 42, 10, 50, 18, 58, 26, 33, 1, 41, 9, 49, 17, 57, 25]
_E = [32, 1, 2, 3, 4, 5, 4, 5, 6, 7, 8, 9, 8, 9, 10, 11, 12, 13, 12, 13, 14, 15, 16, 17,
      16, 17, 18, 19, 20, 21, 20, 21, 22, 23, 24, 25, 24, 25, 26, 27, 28, 29, 28, 29, 30, 31, 32, 1]
_P = [16, 7, 20, 21, 29, 12, 28, 17, 1, 15, 23, 26, 5, 18, 31, 10, 2, 8, 24, 14, 32, 27, 3, 9, 19, 13, 30, 6, 22, 11, 4, 25]
_S = [
    [14, 4, 13, 1, 2, 15, 11, 8, 3, 10, 6, 12, 5, 9, 0, 7, 0, 15, 7, 4, 14, 2, 13, 1, 10, 6, 12, 11, 9, 5, 3, 8,
     4, 1, 14, 8, 13, 6, 2, 11, 15, 12, 9, 7, 3, 10, 5, 0, 15, 12, 8, 2, 4, 9, 1, 7, 5, 11, 3, 14, 10, 0, 6, 13],
    [15, 1, 8, 14, 6, 11, 3, 4, 9, 7, 2, 13, 12, 0, 5, 10, 3, 13, 4, 7, 15, 2, 8, 14, 12, 0, 1, 10, 6, 9, 11, 5,
     0, 14, 7, 11, 10, 4, 13, 1, 5, 8, 12, 6, 9, 3, 2, 15, 13, 8, 10, 1, 3, 15, 4, 2, 11, 6, 7, 12, 0, 5, 14, 9],
    [10, 0, 9, 14, 6, 3, 15, 5, 1, 13, 12, 7, 11, 4, 2, 8, 13, 7, 0, 9, 3, 4, 6, 10, 2, 8, 5, 14, 12, 11, 15, 1,
     13, 6, 4, 9, 8, 15, 3, 0, 11, 1, 2, 12, 5, 10, 14, 7, 1, 10, 13, 0, 6, 9, 8, 7, 4, 15, 14, 3, 11, 5, 2, 12],
    [7, 13, 14, 3, 0, 6, 9, 10, 1, 2, 8, 5, 11, 12, 4, 15, 13, 8, 11, 5, 6, 15, 0, 3, 4, 7, 2, 12, 1, 10, 14, 9,
     10, 6, 9, 0, 12, 11, 7, 13, 15, 1, 3, 14, 5, 2, 8, 4, 3, 15, 0, 6, 10, 1, 13, 8, 9, 4, 5, 11, 12, 7, 2, 14],
    [2, 12, 4, 1, 7, 10, 11, 6, 8, 5, 3, 15, 13, 0, 14, 9, 14, 11, 2, 12, 4, 7, 13, 1, 5, 0, 15, 10, 3, 9, 8, 6,
     4, 2, 1, 11, 10, 13, 7, 8, 15, 9, 12, 5, 6, 3, 0, 14, 11, 8, 12, 7, 1, 14, 2, 13, 6, 15, 0, 9, 10, 4, 5, 3],
    [12, 1, 10, 15, 9, 2, 6, 8, 0, 13, 3, 4, 14, 7, 5, 11, 10, 15, 4, 2, 7, 12, 9, 5, 6, 1, 13, 14, 0, 11, 3, 8,
     9, 14, 15, 5, 2, 8, 12, 3, 7, 0, 4, 10, 1, 13, 11, 6, 4, 3, 2, 12, 9, 5, 15, 10, 11, 14, 1, 7, 6, 0, 8, 13],
    [4, 11, 2, 14, 15, 0, 8, 13, 3, 12, 9, 7, 5, 10, 6, 1, 13, 0, 11, 7, 4, 9, 1, 10, 14, 3, 5, 12, 2, 15, 8, 6,
     1, 4, 11, 13, 12, 3, 7, 14, 10, 15, 6, 8, 0, 5, 9, 2, 6, 11, 13, 8, 1, 4, 10, 7, 9, 5, 0, 15, 14, 2, 3, 12],
    [13, 2, 8, 4, 6, 15, 11, 1, 10, 9, 3, 14, 5, 0, 12, 7, 1, 15, 13, 8, 10, 3, 7, 4, 12, 5, 6, 11, 0, 14, 9, 2,
     7, 11, 4, 1, 9, 12, 14, 2, 0, 6, 10, 13, 15, 3, 5, 8, 2, 1, 14, 7, 4, 10, 8, 13, 15, 12, 9, 0, 3, 5, 6, 11]]


def _perm(v, table, nbits):
    o = 0
    for t in table:
        o = (o << 1) | ((v >> (nbits - t)) & 1)
    return o


def _des_keys(key8):
    k = _perm(int.from_bytes(key8, "big"), _PC1, 64)
    c, d = k >> 28, k & 0xFFFFFFF
    ks = []
    for s in _SHIFTS:
        c = ((c << s) | (c >> (28 - s))) & 0xFFFFFFF
        d = ((d << s) | (d >> (28 - s))) & 0xFFFFFFF
        ks.append(_perm((c << 28) | d, _PC2, 56))
    return ks


def _des_block(ks, blk, decrypt):
    v = _perm(int.from_bytes(blk, "big"), _IP, 64)
    l, r = v >> 32, v & 0xFFFFFFFF
    for k in (reversed(ks) if decrypt else ks):
        x = _perm(r, _E, 32) ^ k
        f = 0
        for i in range(8):
            six = (x >> (42 - 6 * i)) & 0x3F
            f = (f << 4) | _S[i][((six & 0x20) >> 4 | (six & 1)) * 16 + ((six >> 1) & 0xF)]
        l, r = r, l ^ _perm(f, _P, 32)
    return _perm((r << 32) | l, _FP, 64).to_bytes(8, "big")


def des3_cbc_decrypt(key, iv, data):
    k1, k2, k3 = _des_keys(key[:8]), _des_keys(key[8:16]), _des_keys(key[16:24])
    out, prev = bytearray(), iv
    for i in range(0, len(data), 8):
        blk = data[i:i + 8]
        p = _des_block(k1, _des_block(k2, _des_block(k3, blk, True), False), True)
        out += bytes(a ^ b for a, b in zip(p, prev))
        prev = blk
    return _unpad(bytes(out), 8)


# ---------------------------------------------------------------------------------------------
# RC2 (decrypt, CBC) - legacy PKCS#12 certificate bags (RC2-40 / RC2-128)
# ---------------------------------------------------------------------------------------------
_PITABLE = bytes.fromhex(
    "d978f9c419ddb5ed28e9fd794aa0d89dc67e37832b76538e624c6488448bfba2179a59f587b34f1361456d8d09817d32"
    "bd8f40eb86b77b0bf09521225c6b4e8254d66593ce60b21c7356c014a78cf1dc1275ca1f3bbee4d1423dd430a33cb626"
    "6fbf0eda4669075727f21d9bbc944303f811c7f690ef3ee706c3d52fc8661ed708e8eade8052eef784aa72ac354d6a2a"
    "961ad2715a1549744b9fd05e0418a4ecc2e0416e0f51cbcc2491af50a1f47039997c3a8523b8b47afc02365b25559731"
    "2d5dfa98e38a92ae05df2910676cbac9d300e6cfe19ea82c6316013f58e289a90d38341bab33ffb0bb480c5fb9b1cd2e"
    "c5f3db47e5a59c770aa62068fe7fc1ad")


def _rc2_keyexp(key, bits):
    L = bytearray(key) + bytearray(128 - len(key))
    T = len(key)
    for i in range(T, 128):
        L[i] = _PITABLE[(L[i - 1] + L[i - T]) & 0xFF]
    T8 = (bits + 7) // 8
    TM = 0xFF % (1 << (8 + bits - 8 * T8))
    L[128 - T8] = _PITABLE[L[128 - T8] & TM]
    for i in range(127 - T8, -1, -1):
        L[i] = _PITABLE[L[i + 1] ^ L[i + T8]]
    return [L[2 * i] | (L[2 * i + 1] << 8) for i in range(64)]


def _rc2_decrypt_block(K, blk):
    R = list(struct.unpack("<4H", blk))
    s = [1, 2, 3, 5]
    j = 63
    for rnd in range(16):
        for i in (3, 2, 1, 0):
            R[i] = ((R[i] >> s[i]) | (R[i] << (16 - s[i]))) & 0xFFFF
            R[i] = (R[i] - K[j] - (R[(i - 1) % 4] & R[(i - 2) % 4]) - (~R[(i - 1) % 4] & R[(i - 3) % 4])) & 0xFFFF
            j -= 1
        if rnd in (4, 10):
            for i in (3, 2, 1, 0):
                R[i] = (R[i] - K[R[(i - 1) % 4] & 63]) & 0xFFFF
    return struct.pack("<4H", *R)


def rc2_cbc_decrypt(key, iv, data, bits):
    K = _rc2_keyexp(key, bits)
    out, prev = bytearray(), iv
    for i in range(0, len(data), 8):
        blk = data[i:i + 8]
        out += bytes(a ^ b for a, b in zip(_rc2_decrypt_block(K, blk), prev))
        prev = blk
    return _unpad(bytes(out), 8)


# ---------------------------------------------------------------------------------------------
# PKCS#12
# ---------------------------------------------------------------------------------------------
def _p12_kdf(pw_bmp, salt, iters, id_byte, n, hname="sha1"):
    """RFC 7292 appendix B.2"""
    h = getattr(hashlib, hname)
    u, v = h().digest_size, 64
    D = bytes([id_byte]) * v
    fill = lambda b: (b * ((v * ((len(b) + v - 1) // v)) // len(b) + 1))[:v * ((len(b) + v - 1) // v)] if b else b""
    I = bytearray(fill(salt) + fill(pw_bmp))
    out = b""
    while len(out) < n:
        A = h(D + bytes(I)).digest()
        for _ in range(iters - 1):
            A = h(A).digest()
        out += A
        B = (A * (v // u + 1))[:v]
        Bn = int.from_bytes(B, "big")
        for j in range(0, len(I), v):
            x = (int.from_bytes(I[j:j + v], "big") + Bn + 1) % (1 << (8 * v))
            I[j:j + v] = x.to_bytes(v, "big")
    return out[:n]


_HMAC = {"1.2.840.113549.2.7": "sha1", "1.2.840.113549.2.9": "sha256", "1.2.840.113549.2.10": "sha384",
         "1.2.840.113549.2.11": "sha512", "1.2.840.113549.2.8": "sha224"}
_AES = {"2.16.840.1.101.3.4.1.2": 16, "2.16.840.1.101.3.4.1.22": 24, "2.16.840.1.101.3.4.1.42": 32}


def _decrypt(alg, data, password):
    """alg = AlgorithmIdentifier bytes (SEQUENCE body)"""
    items = children(alg)
    oid = oid_str(items[0][1])
    pw_utf8 = password.encode("utf-8")
    pw_bmp = (password + "\0").encode("utf-16-be")
    if oid == "1.2.840.113549.1.5.13":  # PBES2
        kdf, enc = children(items[1][1])
        kdf_items = children(kdf[1])
        if oid_str(kdf_items[0][1]) != "1.2.840.113549.1.5.12":
            raise ValueError("unsupported key derivation")
        prm = children(kdf_items[1][1])
        salt = prm[0][1]
        iters = int.from_bytes(prm[1][1], "big")
        prf = "sha1"
        keylen = None
        for t, v in prm[2:]:
            if t == 0x02:
                keylen = int.from_bytes(v, "big")
            elif t == 0x30:
                prf = _HMAC.get(oid_str(children(v)[0][1]), "sha1")
        enc_items = children(enc[1])
        eoid = oid_str(enc_items[0][1])
        iv = enc_items[1][1]
        if eoid in _AES:
            kl = keylen or _AES[eoid]
            last = None
            for pw in (pw_utf8, pw_bmp[:-2]):
                try:
                    key = hashlib.pbkdf2_hmac(prf, pw, salt, iters, kl)
                    return aes_cbc_decrypt(key, iv, data)
                except ValueError as e:
                    last = e
            raise last
        if eoid == "1.2.840.113549.3.7":  # des-ede3-cbc
            key = hashlib.pbkdf2_hmac(prf, pw_utf8, salt, iters, 24)
            return des3_cbc_decrypt(key, iv, data)
        raise ValueError("unsupported cipher %s" % eoid)
    legacy = {"1.2.840.113549.1.12.1.3": ("3des", 24), "1.2.840.113549.1.12.1.4": ("2des", 16),
              "1.2.840.113549.1.12.1.5": ("rc2", 16), "1.2.840.113549.1.12.1.6": ("rc2", 5)}
    if oid in legacy:
        kind, kl = legacy[oid]
        prm = children(items[1][1])
        salt, iters = prm[0][1], int.from_bytes(prm[1][1], "big")
        key = _p12_kdf(pw_bmp, salt, iters, 1, kl)
        iv = _p12_kdf(pw_bmp, salt, iters, 2, 8)
        if kind == "3des":
            return des3_cbc_decrypt(key, iv, data)
        if kind == "2des":
            return des3_cbc_decrypt(key + key[:8], iv, data)
        return rc2_cbc_decrypt(key, iv, data, kl * 8)
    raise ValueError("unsupported encryption %s" % oid)


def _check_mac(pfx_items, auth_content, password):
    if len(pfx_items) < 3:
        return
    mac = children(pfx_items[2][1])
    digest_info = children(mac[0][1])
    alg = oid_str(children(digest_info[0][1])[0][1])
    want = digest_info[1][1]
    salt = mac[1][1]
    iters = int.from_bytes(mac[2][1], "big") if len(mac) > 2 else 1
    hname = {"1.3.14.3.2.26": "sha1", "2.16.840.1.101.3.4.2.1": "sha256", "2.16.840.1.101.3.4.2.2": "sha384",
             "2.16.840.1.101.3.4.2.3": "sha512"}.get(alg)
    if not hname:
        return
    n = hashlib.new(hname).digest_size
    for pw in ((password + "\0").encode("utf-16-be"), password.encode("utf-8")):
        key = _p12_kdf(pw, salt, iters, 3, n, hname)
        if hmac.compare_digest(hmac.new(key, auth_content, hname).digest(), want):
            return
    raise ValueError("wrong password for this .p12 (the integrity check failed)")


def read_p12(data, password):
    """-> (key_pem or None, [cert_pem, ...]). Raises ValueError with a readable reason."""
    try:
        t, pfx, _ = parse(data)
        items = children(pfx)
        ci = children(items[1][1])
        if oid_str(ci[0][1]) != "1.2.840.113549.1.7.1":
            raise ValueError("public-key protected .p12 files are not supported")
        auth_content = children(ci[1][1])[0][1]
    except (IndexError, ValueError) as e:
        if "supported" in str(e):
            raise
        raise ValueError("not a .p12 file (%s)" % e)
    _check_mac(items, auth_content, password)
    keys, certs = [], []

    def bags(safe_contents):
        for t, bag in children(parse(safe_contents)[1]):
            b = children(bag)
            bag_id = oid_str(b[0][1])
            val = children(b[1][1])[0]
            if bag_id == "1.2.840.113549.1.12.10.1.1":  # keyBag
                keys.append(tlv(val[0], val[1]))
            elif bag_id == "1.2.840.113549.1.12.10.1.2":  # pkcs8ShroudedKeyBag
                epki = children(val[1])
                keys.append(_decrypt(epki[0][1], epki[1][1], password))
            elif bag_id == "1.2.840.113549.1.12.10.1.3":  # certBag
                cb = children(val[1])
                if oid_str(cb[0][1]) == "1.2.840.113549.1.9.22.1":
                    certs.append(children(cb[1][1])[0][1])

    for t, ci in children(parse(auth_content)[1]):
        c = children(ci)
        ctype = oid_str(c[0][1])
        if ctype == "1.2.840.113549.1.7.1":
            bags(children(c[1][1])[0][1])
        elif ctype == "1.2.840.113549.1.7.6":
            ed = children(children(c[1][1])[0][1])
            eci = children(ed[1][1])
            alg = eci[1][1]
            enc = eci[2][1]
            if eci[2][0] == 0xA0:     # constructed [0]: concatenated OCTET STRINGs
                enc = b"".join(v for _, v in children(enc))
            bags(_decrypt(alg, enc, password))
    return (pem("PRIVATE KEY", keys[0]) if keys else None), [pem("CERTIFICATE", c) for c in certs]


def _rsa_n_from_cert(der):
    tbs = children(children(parse(der)[1])[0][1])
    off = 1 if tbs[0][0] == 0xA0 else 0
    spki = children(tbs[5 + off][1])
    pub = parse(spki[1][1][1:])[1]          # BIT STRING minus the unused-bits byte
    return int.from_bytes(children(pub)[0][1], "big")


def _rsa_n_from_key_pem(key_pem):
    der = base64.b64decode("".join(l for l in key_pem.splitlines() if not l.startswith("-----")))
    items = children(parse(der)[1])
    if items[0][0] == 0x02 and len(items) >= 3 and items[1][0] == 0x30:   # PKCS#8
        items = children(parse(items[2][1])[1])
    return int.from_bytes(items[1][1], "big")


def split_chain(key_pem, cert_pems):
    """-> (leaf_pem or None, [other cert pems]) - the leaf is the cert matching the private key."""
    if not key_pem:
        return None, list(cert_pems)
    try:
        n = _rsa_n_from_key_pem(key_pem)
    except Exception:
        return (cert_pems[0] if cert_pems else None), list(cert_pems[1:])
    leaf, rest = None, []
    for c in cert_pems:
        der = base64.b64decode("".join(l for l in c.splitlines() if not l.startswith("-----")))
        try:
            match = _rsa_n_from_cert(der) == n
        except Exception:
            match = False
        if match and leaf is None:
            leaf = c
        else:
            rest.append(c)
    return leaf, rest
TTCRYPTO_PY
cat > "$APP/meshproto.py" <<'MESHPROTO_PY'
# PagerMesh - Meshtastic TCP API protocol helpers (Python standard library only)
# SPDX-License-Identifier: GPL-3.0-or-later
#
# Stream framing (TCP API, same as the phone app uses): 0x94 0xC3, 2-byte
# big-endian length, then a protobuf ToRadio (to meshtasticd) or FromRadio
# (from meshtasticd). Field numbers follow meshtastic/protobufs (mesh.proto,
# portnums.proto, telemetry.proto, config.proto, channel.proto).

import os
import random
import select
import socket
import struct
import subprocess

MAGIC = b"\x94\xc3"
MAX_FRAME = 512
BROADCAST = 0xFFFFFFFF
MAX_TEXT_BYTES = 200            # Meshtastic data payload is ~233 bytes; leave room

# portnums.proto
PORT_TEXT = 1
PORT_POSITION = 3
PORT_NODEINFO = 4
PORT_ROUTING = 5
PORT_TELEMETRY = 67
PORT_ADMIN = 6
PORT_WAYPOINT = 8
PORT_TRACEROUTE = 70
PORT_NAMES = {0: "UNKNOWN", 1: "TEXT", 2: "REMOTE_HW", 3: "POSITION", 4: "NODEINFO", 5: "ROUTING", 6: "ADMIN",
              7: "TEXT_COMPRESSED", 8: "WAYPOINT", 10: "DETECTION", 32: "REPLY", 33: "IP_TUNNEL",
              34: "PAXCOUNTER", 64: "SERIAL", 65: "STORE_FORWARD", 66: "RANGE_TEST", 67: "TELEMETRY",
              68: "ZPS", 70: "TRACEROUTE", 71: "NEIGHBORINFO", 72: "ATAK_PLUGIN", 73: "MAP_REPORT"}

# config.proto LoRaConfig.RegionCode (names only for the status screen)
REGIONS = {0: "UNSET", 1: "US", 2: "EU_433", 3: "EU_868", 4: "CN", 5: "JP", 6: "ANZ", 7: "KR",
           8: "TW", 9: "RU", 10: "IN", 11: "NZ_865", 12: "TH", 13: "LORA_24", 14: "UA_433",
           15: "UA_868", 16: "MY_433", 17: "MY_919", 18: "SG_923", 19: "PH_433", 20: "PH_868",
           21: "PH_915", 22: "ANZ_433", 23: "KZ_433", 24: "KZ_863", 25: "NP_865", 26: "BR_902",
           27: "ITU1_2M", 28: "ITU2_2M", 29: "EU_866", 30: "EU_874", 31: "EU_917", 32: "EU_N_868",
           33: "ITU3_2M", 34: "ITU1_70CM"}

# config.proto LoRaConfig.ModemPreset
PRESETS = {0: "LONG_FAST", 1: "LONG_SLOW", 2: "VERY_LONG_SLOW", 3: "MEDIUM_SLOW", 4: "MEDIUM_FAST",
           5: "SHORT_SLOW", 6: "SHORT_FAST", 7: "LONG_MODERATE", 8: "SHORT_TURBO", 9: "LONG_TURBO",
           10: "LITE_FAST", 11: "LITE_SLOW", 12: "NARROW_FAST", 13: "NARROW_SLOW", 14: "TINY_FAST",
           15: "TINY_SLOW", 16: "MEDIUM_TURBO"}
# presets a normal US/EU radio offers (the phone app list); the scan uses these
COMMON_PRESETS = [0, 7, 1, 3, 4, 5, 6, 8]

# config.proto DeviceConfig.Role (deprecated 3 and 4 left out of pickers)
ROLES = {0: "CLIENT", 1: "CLIENT_MUTE", 2: "ROUTER", 3: "ROUTER_CLIENT", 4: "REPEATER", 5: "TRACKER",
         6: "SENSOR", 7: "TAK", 8: "CLIENT_HIDDEN", 9: "LOST_AND_FOUND", 10: "TAK_TRACKER",
         11: "ROUTER_LATE", 12: "CLIENT_BASE"}
ROLE_CHOICES = [0, 1, 12, 2, 11, 5, 6, 7, 10, 8, 9]

# channel.proto Channel.Role
CHAN_ROLES = {0: "DISABLED", 1: "PRIMARY", 2: "SECONDARY"}

# mesh.proto HardwareModel (names for the node details)
HW_MODELS = dict(enumerate((
    "UNSET TLORA_V2 TLORA_V1 TLORA_V2_1_1P6 TBEAM HELTEC_V2_0 TBEAM_V0P7 T_ECHO TLORA_V1_1P3 RAK4631 "
    "HELTEC_V2_1 HELTEC_V1 LILYGO_TBEAM_S3_CORE RAK11200 NANO_G1 TLORA_V2_1_1P8 TLORA_T3_S3 NANO_G1_EXPLORER "
    "NANO_G2_ULTRA LORA_TYPE WIPHONE WIO_WM1110 RAK2560 HELTEC_HRU_3601 HELTEC_WIRELESS_BRIDGE STATION_G1 "
    "RAK11310 MAKERFABS_TRACKER MAKERFABS_RESERVED CANARYONE RP2040_LORA STATION_G2 LORA_RELAY_V1 T_ECHO_PLUS "
    "PPR GENIEBLOCKS NRF52_UNKNOWN PORTDUINO ANDROID_SIM DIY_V1 NRF52840_PCA10059 DR_DEV M5STACK HELTEC_V3 "
    "HELTEC_WSL_V3 BETAFPV_2400_TX BETAFPV_900_NANO_TX RPI_PICO HELTEC_WIRELESS_TRACKER HELTEC_WIRELESS_PAPER "
    "T_DECK T_WATCH_S3 PICOMPUTER_S3 HELTEC_HT62 EBYTE_ESP32_S3 ESP32_S3_PICO CHATTER_2 "
    "HELTEC_WIRELESS_PAPER_V1_0 HELTEC_WIRELESS_TRACKER_V1_0 UNPHONE TD_LORAC CDEBYTE_EORA_S3 TWC_MESH_V4 "
    "NRF52_PROMICRO_DIY RADIOMASTER_900_BANDIT_NANO HELTEC_CAPSULE_SENSOR_V3 HELTEC_VISION_MASTER_T190 "
    "HELTEC_VISION_MASTER_E213 HELTEC_VISION_MASTER_E290 HELTEC_MESH_NODE_T114 SENSECAP_INDICATOR "
    "TRACKER_T1000_E RAK3172 WIO_E5 RADIOMASTER_900_BANDIT ME25LS01_4Y10TD RP2040_FEATHER_RFM95 "
    "M5STACK_COREBASIC M5STACK_CORE2 RPI_PICO2 M5STACK_CORES3 SEEED_XIAO_S3 MS24SF1 TLORA_C6 WISMESH_TAP "
    "ROUTASTIC MESH_TAB MESHLINK XIAO_NRF52_KIT THINKNODE_M1 THINKNODE_M2 T_ETH_ELITE HELTEC_SENSOR_HUB "
    "MUZI_BASE HELTEC_MESH_POCKET SEEED_SOLAR_NODE NOMADSTAR_METEOR_PRO CROWPANEL LINK_32 SEEED_WIO_TRACKER_L1 "
    "SEEED_WIO_TRACKER_L1_EINK MUZI_R1_NEO T_DECK_PRO T_LORA_PAGER M5STACK_RESERVED WISMESH_TAG RAK3312 "
    "THINKNODE_M5 HELTEC_MESH_SOLAR T_ECHO_LITE HELTEC_V4 M5STACK_C6L M5STACK_CARDPUTER_ADV "
    "HELTEC_WIRELESS_TRACKER_V2 T_WATCH_ULTRA THINKNODE_M3 WISMESH_TAP_V2 RAK3401 RAK6421 THINKNODE_M4 "
    "THINKNODE_M6 MESHSTICK_1262 TBEAM_1_WATT T5_S3_EPAPER_PRO TBEAM_BPF MINI_EPAPER_S3 TDISPLAY_S3_PRO "
    "HELTEC_MESH_NODE_T096 MESH_TRACKER_X1 THINKNODE_M7 THINKNODE_M8 THINKNODE_M9 HELTEC_V4_R8 "
    "HELTEC_MESH_NODE_T1 STATION_G3").split()))
HW_MODELS[255] = "PRIVATE_HW"


def hw_name(v):
    return HW_MODELS.get(v, "HW_%s" % v) if v is not None else ""

# --------------------------------------------------------------------------
# tiny protobuf reader / writer (only what PagerMesh needs)
# --------------------------------------------------------------------------

def _varint(buf, i):
    shift = val = 0
    while True:
        if i >= len(buf):
            raise ValueError("truncated varint")
        b = buf[i]
        i += 1
        val |= (b & 0x7F) << shift
        if not b & 0x80:
            return val, i
        shift += 7
        if shift > 63:
            raise ValueError("varint too long")


def fields(buf):
    """Yield (field_number, wire_type, value) for each field of a message."""
    i = 0
    while i < len(buf):
        key, i = _varint(buf, i)
        fn, wt = key >> 3, key & 7
        if wt == 0:
            v, i = _varint(buf, i)
        elif wt == 1:
            v = buf[i:i + 8]
            i += 8
        elif wt == 2:
            n, i = _varint(buf, i)
            v = buf[i:i + n]
            i += n
        elif wt == 5:
            v = buf[i:i + 4]
            i += 4
        else:
            raise ValueError("unsupported wire type %d" % wt)
        if i > len(buf):
            raise ValueError("truncated field")
        yield fn, wt, v


def raw_fields(buf):
    """Yield (field_number, wire_type, value, raw_bytes) - raw_bytes includes the tag, so a
    message can be rebuilt with unknown fields kept exactly as the radio sent them."""
    i = 0
    while i < len(buf):
        start = i
        key, i = _varint(buf, i)
        fn, wt = key >> 3, key & 7
        if wt == 0:
            v, i = _varint(buf, i)
        elif wt == 1:
            v, i = buf[i:i + 8], i + 8
        elif wt == 2:
            n, i = _varint(buf, i)
            v, i = buf[i:i + n], i + n
        elif wt == 5:
            v, i = buf[i:i + 4], i + 4
        else:
            raise ValueError("unsupported wire type %d" % wt)
        if i > len(buf):
            raise ValueError("truncated field")
        yield fn, wt, v, bytes(buf[start:i])


def patch(buf, changes):
    """Copy of a protobuf message with some fields replaced.
    changes: {field_number: encoded field bytes, or b"" to drop it}. Other fields stay as they were."""
    out, done = bytearray(), set()
    for fn, _wt, _v, raw in raw_fields(buf or b""):
        if fn in changes:
            if fn not in done:
                out += changes[fn]
                done.add(fn)
        else:
            out += raw
    for fn in sorted(changes):
        if fn not in done:
            out += changes[fn]
    return bytes(out)


def field_value(buf, fn):
    """(wire_type, value) of the first field fn, or (None, None)."""
    for f, wt, v in fields(buf or b""):
        if f == fn:
            return wt, v
    return None, None


def ev(v):
    """Encode a varint (negative int32/int64 use 10-byte two's complement)."""
    if v < 0:
        v += 1 << 64
    out = bytearray()
    while True:
        b = v & 0x7F
        v >>= 7
        if v:
            out.append(b | 0x80)
        else:
            out.append(b)
            return bytes(out)


def f_varint(fn, v):
    return ev(fn << 3) + ev(v)


def f_bytes(fn, b):
    if isinstance(b, str):
        b = b.encode("utf-8")
    return ev((fn << 3) | 2) + ev(len(b)) + b


def f_fixed32(fn, v):
    return ev((fn << 3) | 5) + struct.pack("<I", v & 0xFFFFFFFF)


def f_sfixed32(fn, v):
    return ev((fn << 3) | 5) + struct.pack("<i", v)


def f_float(fn, v):
    return ev((fn << 3) | 5) + struct.pack("<f", float(v))


def u32(b):
    return struct.unpack("<I", b)[0]


def s32(b):
    return struct.unpack("<i", b)[0]


def f32(b):
    return struct.unpack("<f", b)[0]


def text(b):
    return b.decode("utf-8", "replace")


def sint(v):
    """int32 sent as a plain varint (negative values arrive as 64-bit)."""
    return v - (1 << 64) if v >= (1 << 63) else v


def node_id(num):
    return "!%08x" % (num or 0)

# --------------------------------------------------------------------------
# decoders
# --------------------------------------------------------------------------

def dec_user(buf):
    u = {}
    for fn, wt, v in fields(buf):
        if fn == 1 and wt == 2:
            u["id"] = text(v)
        elif fn == 2 and wt == 2:
            u["long_name"] = text(v)
        elif fn == 3 and wt == 2:
            u["short_name"] = text(v)
        elif fn == 5 and wt == 0:
            u["hw_model"] = v
        elif fn == 7 and wt == 0:
            u["role"] = v
    return u


def dec_position(buf):
    p = {}
    for fn, wt, v in fields(buf):
        if fn == 1 and wt == 5:
            p["lat"] = s32(v) / 1e7
        elif fn == 2 and wt == 5:
            p["lon"] = s32(v) / 1e7
        elif fn == 3 and wt == 0:
            p["alt"] = sint(v)
        elif fn == 4 and wt == 5:
            p["time"] = u32(v)
        elif fn == 5 and wt == 0:
            p["src"] = v                     # location_source: 1 manual, 2 the radio's own GPS, 3 external
    if p.get("lat") == 0 and p.get("lon") == 0:
        p.pop("lat", None)
        p.pop("lon", None)
    return p


def dec_metrics(buf):
    m = {}
    for fn, wt, v in fields(buf):
        if fn == 1 and wt == 0:
            m["battery"] = v                 # 101 = on external power
        elif fn == 2 and wt == 5:
            m["voltage"] = round(f32(v), 2)
        elif fn == 3 and wt == 5:
            m["ch_util"] = round(f32(v), 1)
        elif fn == 4 and wt == 5:
            m["air_tx"] = round(f32(v), 1)
    return m


def dec_telemetry(buf):
    for fn, wt, v in fields(buf):
        if fn == 2 and wt == 2:              # Telemetry.device_metrics
            return dec_metrics(v)
    return {}


def dec_nodeinfo(buf):
    n = {}
    for fn, wt, v in fields(buf):
        if fn == 1 and wt == 0:
            n["num"] = v
        elif fn == 2 and wt == 2:
            n["user"] = dec_user(v)
            n["user_raw"] = bytes(v)
        elif fn == 3 and wt == 2:
            n["position"] = dec_position(v)
        elif fn == 4 and wt == 5:
            n["snr"] = round(f32(v), 2)
        elif fn == 5 and wt == 5:
            n["last_heard"] = u32(v)
        elif fn == 8 and wt == 0:
            n["via_mqtt"] = bool(v)
        elif fn == 10 and wt == 0:
            n["favorite"] = bool(v)
        elif fn == 6 and wt == 2:
            n["metrics"] = dec_metrics(v)
        elif fn == 9 and wt == 0:
            n["hops_away"] = v
    return n


def dec_data(buf):
    d = {"portnum": 0, "payload": b""}
    for fn, wt, v in fields(buf):
        if fn == 1 and wt == 0:
            d["portnum"] = v
        elif fn == 2 and wt == 2:
            d["payload"] = bytes(v)
        elif fn == 3 and wt == 0:
            d["want_response"] = bool(v)
        elif fn == 6 and wt == 5:
            d["request_id"] = u32(v)
        elif fn == 7 and wt == 5:
            d["reply_id"] = u32(v)
        elif fn == 8 and wt == 5:
            d["emoji"] = u32(v)
    return d


def dec_packet(buf):
    p = {}
    for fn, wt, v in fields(buf):
        if fn == 1 and wt == 5:
            p["from"] = u32(v)
        elif fn == 2 and wt == 5:
            p["to"] = u32(v)
        elif fn == 3 and wt == 0:
            p["channel"] = v
        elif fn == 4 and wt == 2:
            p["decoded"] = dec_data(v)
        elif fn == 5 and wt == 2:
            p["encrypted"] = len(v)          # a channel key we don't have
        elif fn == 6 and wt == 5:
            p["id"] = u32(v)
        elif fn == 7 and wt == 5:
            p["rx_time"] = u32(v)
        elif fn == 8 and wt == 5:
            p["rx_snr"] = round(f32(v), 2)
        elif fn == 9 and wt == 0:
            p["hop_limit"] = v
        elif fn == 12 and wt == 0:
            p["rx_rssi"] = sint(v)
        elif fn == 14 and wt == 0:
            p["via_mqtt"] = bool(v)
        elif fn == 15 and wt == 0:
            p["hop_start"] = v
        elif fn == 17 and wt == 0:
            p["pki"] = bool(v)
    return p


def dec_routing_error(buf):
    """Routing.error_reason (0 = NONE = delivered), or None when not an ack."""
    for fn, wt, v in fields(buf):
        if fn == 3 and wt == 0:
            return v
    return 0


def dec_channel(buf):
    """Channel without its key: psk_kind says what kind of key it has."""
    c = {"index": 0, "name": "", "role": 0, "psk_kind": "none", "uplink": False, "downlink": False,
         "precision": 0, "raw": bytes(buf)}
    for fn, wt, v in fields(buf):
        if fn == 1 and wt == 0:
            c["index"] = v
        elif fn == 2 and wt == 2:            # ChannelSettings (the key is never kept)
            c["settings_raw"] = bytes(v)
            for f2, w2, v2 in fields(v):
                if f2 == 3 and w2 == 2:
                    c["name"] = text(v2)
                elif f2 == 2 and w2 == 2:
                    c["psk_kind"] = psk_kind(v2)
                elif f2 == 5 and w2 == 0:
                    c["uplink"] = bool(v2)
                elif f2 == 6 and w2 == 0:
                    c["downlink"] = bool(v2)
                elif f2 == 7 and w2 == 2:
                    for f3, w3, v3 in fields(v2):
                        if f3 == 1 and w3 == 0:
                            c["precision"] = v3
        elif fn == 3 and wt == 0:
            c["role"] = v                    # 0 disabled, 1 primary, 2 secondary
    return c


def psk_kind(k):
    if not k:
        return "none"
    if len(k) == 1:
        return "default" if k[0] == 1 else "simple"
    return "AES-%d" % (len(k) * 8)


def dec_config(buf):
    """Only LoRa region and hop limit are kept."""
    out = {}
    for fn, wt, v in fields(buf):
        if fn == 6 and wt == 2:              # Config.lora
            for f2, w2, v2 in fields(v):
                if f2 == 7 and w2 == 0:
                    out["region"] = v2
                elif f2 == 8 and w2 == 0:
                    out["hop_limit"] = v2
                elif f2 == 9 and w2 == 0:
                    out["tx_enabled"] = bool(v2)
    return out


def dec_metadata(buf):
    m = {}
    for fn, wt, v in fields(buf):
        if fn == 1 and wt == 2:
            m["firmware"] = text(v)
        elif fn == 4 and wt == 0:
            m["has_wifi"] = bool(v)
        elif fn == 5 and wt == 0:
            m["has_bt"] = bool(v)
        elif fn == 9 and wt == 0:
            m["hw_model"] = v
    return m


def dec_route(buf):
    """RouteDiscovery: node numbers out and back, SNR (dB) per hop."""
    r = {"route": [], "snr_towards": [], "route_back": [], "snr_back": []}
    for fn, wt, v in fields(buf):
        key = {1: "route", 2: "snr_towards", 3: "route_back", 4: "snr_back"}.get(fn)
        if not key:
            continue
        if fn in (1, 3):
            if wt == 5:
                r[key].append(u32(v))
            elif wt == 2:
                r[key] += [u32(v[i:i + 4]) for i in range(0, len(v) - 3, 4)]
        else:
            vals = []
            if wt == 0:
                vals = [v]
            elif wt == 2:
                i = 0
                while i < len(v):
                    x, i = _varint(v, i)
                    vals.append(x)
            r[key] += [sint(x) / 4.0 for x in vals]
    return r


def dec_waypoint(buf):
    w = {"id": 0, "name": "", "description": "", "expire": 0, "icon": 0, "locked_to": 0}
    for fn, wt, v in fields(buf):
        if fn == 1 and wt == 0:
            w["id"] = v
        elif fn == 2 and wt == 5:
            w["lat"] = s32(v) / 1e7
        elif fn == 3 and wt == 5:
            w["lon"] = s32(v) / 1e7
        elif fn == 4 and wt == 0:
            w["expire"] = v
        elif fn == 5 and wt == 0:
            w["locked_to"] = v
        elif fn == 6 and wt == 2:
            w["name"] = text(v)
        elif fn == 7 and wt == 2:
            w["description"] = text(v)
        elif fn == 8 and wt == 5:
            w["icon"] = u32(v)
    return w


def dec_fromradio(buf):
    """Returns (kind, value) for the parts PagerMesh uses, else (None, None)."""
    for fn, wt, v in fields(buf):
        if fn == 2 and wt == 2:
            p = dec_packet(v)
            p["_raw"] = bytes(v)
            return "packet", p
        if fn == 3 and wt == 2:
            for f2, w2, v2 in fields(v):
                if f2 == 1 and w2 == 0:
                    return "my_info", v2
            return None, None
        if fn == 4 and wt == 2:
            return "node_info", dec_nodeinfo(v)
        if fn == 5 and wt == 2:
            c = dec_config(v)
            for f2, w2, v2 in fields(v):     # Config has one section set: keep it as the radio sent it
                if w2 == 2:
                    c["_section"], c["_raw"] = f2, bytes(v2)
            return "config", c
        if fn == 9 and wt == 2:              # ModuleConfig: one module section
            for f2, w2, v2 in fields(v):
                if w2 == 2:
                    return "module_config", (f2, bytes(v2))
            return None, None
        if fn == 13 and wt == 2:
            return "metadata", dec_metadata(v)
        if fn == 7 and wt == 0:
            return "config_complete", v
        if fn == 8 and wt == 0:
            return "rebooted", v
        if fn == 10 and wt == 2:
            return "channel", dec_channel(v)
    return None, None

# --------------------------------------------------------------------------
# encoders (ToRadio)
# --------------------------------------------------------------------------

def new_packet_id():
    return random.randint(1, 0xFFFFFFFF)


def want_config(nonce):
    return f_varint(3, nonce)


def heartbeat():
    return f_bytes(7, b"")


def disconnect():
    return f_varint(4, 1)


def _packet(to, channel, portnum, payload, pid, hop_limit, want_ack, want_response=False):
    data = f_varint(1, portnum) + f_bytes(2, payload)
    if want_response:
        data += f_varint(3, 1)
    mp = f_fixed32(2, to) + f_bytes(4, data) + f_fixed32(6, pid)
    if channel:
        mp = f_varint(3, channel) + mp
    if hop_limit:
        mp += f_varint(9, hop_limit)
    if want_ack:
        mp += f_varint(10, 1)
    return f_bytes(1, mp)                    # ToRadio.packet


def clip_text(msg):
    b = msg.encode("utf-8")[:MAX_TEXT_BYTES]
    return b.decode("utf-8", "ignore")


def text_packet(msg, to=BROADCAST, channel=0, hop_limit=0, pid=None):
    """Chat message. Direct messages ask for an ack, like the phone app."""
    return _packet(to, channel, PORT_TEXT, clip_text(msg).encode("utf-8"), pid or new_packet_id(),
                   hop_limit, to != BROADCAST)


def position_packet(lat, lon, alt=None, t=None, channel=0, hop_limit=0, pid=None, source=3):
    """Our position as a POSITION_APP broadcast. source: LOC_EXTERNAL (3) = Pager GPS,
    LOC_MANUAL (1) = set on the map."""
    pos = f_sfixed32(1, int(round(lat * 1e7))) + f_sfixed32(2, int(round(lon * 1e7)))
    if alt is not None:
        pos += f_varint(3, int(round(alt)))
    if t:
        pos += f_fixed32(4, int(t))
    pos += f_varint(5, source)
    return _packet(BROADCAST, channel, PORT_POSITION, pos, pid or new_packet_id(), hop_limit, False)

# --------------------------------------------------------------------------
# admin (settings of the connected radio), traceroute, position request, waypoints
# A local app (TCP / USB / BLE) sends AdminMessage to its own node with from = 0:
# the firmware trusts it and needs no session passkey.
# --------------------------------------------------------------------------

def admin_packet(my_num, admin, pid=None):
    return _packet(my_num, 0, PORT_ADMIN, admin, pid or new_packet_id(), 0, False, True)


def adm_set_owner(long_name, short_name):
    u = b""
    if long_name:
        u += f_bytes(2, long_name)
    if short_name:
        u += f_bytes(3, short_name)
    return f_bytes(32, u)


def adm_set_config(section, raw):
    return f_bytes(34, f_bytes(section, raw))


def adm_set_module(section, raw):
    return f_bytes(35, f_bytes(section, raw))


def adm_set_channel(raw):
    return f_bytes(33, raw)


def adm_begin():
    return f_varint(64, 1)


def adm_commit():
    return f_varint(65, 1)


def adm_reboot(secs=2):
    return f_varint(97, secs)


def adm_favorite(num, on=True):
    return f_varint(39 if on else 40, num)


def traceroute_packet(to, hop_limit=0, pid=None):
    return _packet(to, 0, PORT_TRACEROUTE, b"", pid or new_packet_id(), hop_limit, False, True)


def position_request(to, lat=None, lon=None, hop_limit=0, pid=None):
    """Ask a node for its position (want_response). Sends ours along when we have one, like the app."""
    pos = b""
    if lat is not None:
        pos = f_sfixed32(1, int(round(lat * 1e7))) + f_sfixed32(2, int(round(lon * 1e7))) + f_varint(5, 1)
    return _packet(to, 0, PORT_POSITION, pos, pid or new_packet_id(), hop_limit, False, True)


def waypoint_packet(w, channel=0, hop_limit=0, pid=None):
    b = f_varint(1, w["id"]) + f_sfixed32(2, int(round(w["lat"] * 1e7))) + f_sfixed32(3, int(round(w["lon"] * 1e7)))
    if w.get("expire"):
        b += f_varint(4, int(w["expire"]))
    if w.get("name"):
        b += f_bytes(6, w["name"][:29])
    if w.get("description"):
        b += f_bytes(7, w["description"][:99])
    if w.get("icon"):
        b += f_fixed32(8, int(w["icon"]))
    return _packet(BROADCAST, channel, PORT_WAYPOINT, b, pid or new_packet_id(), hop_limit, False)


def channel_url(settings_raws, lora_raw):
    """meshtastic.org share link (the QR code the phone app shows): ChannelSet, base64url."""
    import base64
    cs = b"".join(f_bytes(1, r) for r in settings_raws)
    if lora_raw:
        cs += f_bytes(2, lora_raw)
    return "https://meshtastic.org/e/#" + base64.urlsafe_b64encode(cs).decode().rstrip("=")

# --------------------------------------------------------------------------
# connection
# --------------------------------------------------------------------------

class Stream:
    def __init__(self, host, port, timeout=15):
        # host as bytes: a str host makes Python look up the "idna" codec, which
        # python3-light on the Pager does not include (LookupError: unknown encoding: idna)
        if isinstance(host, str):
            host = host.encode("ascii", "ignore")
        self.sock = socket.create_connection((host, int(port)), timeout=timeout)
        self.buf = b""

    def settimeout(self, t):
        self.sock.settimeout(t)

    def send(self, payload):
        self.sock.sendall(MAGIC + struct.pack(">H", len(payload)) + payload)

    def _take(self):
        """Next complete frame from the buffer, or None. Skips debug text."""
        while True:
            j = self.buf.find(MAGIC)
            if j < 0:
                self.buf = self.buf[-1:]
                return None
            self.buf = self.buf[j:]
            if len(self.buf) < 4:
                return None
            n = struct.unpack(">H", self.buf[2:4])[0]
            if n > MAX_FRAME:                # not a real header: resync
                self.buf = self.buf[1:]
                continue
            if len(self.buf) < 4 + n:
                return None
            payload, self.buf = self.buf[4:4 + n], self.buf[4 + n:]
            return payload

    def read(self):
        """One FromRadio payload. Raises socket.timeout when idle,
        ConnectionError when the server closed the connection."""
        while True:
            f = self._take()
            if f is not None:
                return f
            chunk = self.sock.recv(4096)
            if not chunk:
                raise ConnectionError("meshtasticd closed the connection")
            self.buf += chunk

    def close(self, polite=True):
        if polite:
            try:
                self.send(disconnect())
            except OSError:
                pass
        try:
            self.sock.close()
        except OSError:
            pass


def raw_tty(fd, dev, baud=115200):
    """Raw 8N1 serial: no echo, no line editing, no CR/LF translation, no flow control."""
    try:
        import termios
    except ImportError:
        termios = None
    if termios is not None:
        a = termios.tcgetattr(fd)
        a[0] &= ~(termios.IGNBRK | termios.BRKINT | termios.PARMRK | termios.ISTRIP | termios.INLCR
                  | termios.IGNCR | termios.ICRNL | termios.IXON | termios.IXOFF | termios.IXANY)
        a[1] &= ~termios.OPOST
        a[2] &= ~(termios.CSIZE | termios.PARENB | termios.CSTOPB | termios.HUPCL | getattr(termios, "CRTSCTS", 0))
        a[2] |= termios.CS8 | termios.CREAD | termios.CLOCAL
        a[3] &= ~(termios.ECHO | termios.ECHOE | termios.ECHOK | termios.ECHONL | termios.ICANON
                  | termios.ISIG | termios.IEXTEN)
        speed = getattr(termios, "B%d" % baud, termios.B115200)
        a[4] = a[5] = speed
        a[6][termios.VMIN] = 1
        a[6][termios.VTIME] = 0
        termios.tcsetattr(fd, termios.TCSANOW, a)
        termios.tcflush(fd, termios.TCIOFLUSH)
        return
    import shutil
    if not shutil.which("stty"):
        raise OSError("cannot set up %s: this Hub's Python has no termios module and there is no stty command" % dev)
    r = subprocess.run(["stty", "-F", dev, str(baud), "raw", "-echo", "-echoe", "-echok", "-hupcl", "clocal"],
                       stdout=subprocess.DEVNULL, stderr=subprocess.PIPE, timeout=10)
    if r.returncode != 0:
        r = subprocess.run(["stty", "-F", dev, str(baud), "raw", "-echo"],
                           stdout=subprocess.DEVNULL, stderr=subprocess.PIPE, timeout=10)
    if r.returncode != 0:
        raise OSError("cannot set up %s: %s" % (dev, r.stderr.decode("utf-8", "replace").strip()[:80]))


class SerialStream(Stream):
    """Meshtastic serial API on a USB radio (/dev/ttyUSB0, /dev/ttyACM0...): the same framing as TCP,
    at 115200 baud. The port is put in raw mode with Python's termios, or with stty when termios is
    missing (OpenWrt's busybox often has no stty, so termios comes first)."""

    def __init__(self, dev, timeout=15):
        # O_NONBLOCK so the open never waits for carrier detect; blocking again once set up
        try:
            self.fd = os.open(dev, os.O_RDWR | os.O_NOCTTY | os.O_NONBLOCK)
        except OSError as e:
            raise OSError("cannot open %s: %s" % (dev, e.strerror or e))
        try:
            raw_tty(self.fd, dev)
            os.set_blocking(self.fd, True)
        except Exception:
            os.close(self.fd)
            raise
        self.timeout = timeout
        self.buf = b""
        os.write(self.fd, bytes([0xC3]) * 32)      # wake the radio's serial API, like the phone app
        import time
        time.sleep(0.1)

    def settimeout(self, t):
        self.timeout = t

    def send(self, payload):
        data = MAGIC + struct.pack(">H", len(payload)) + payload
        while data:
            n = os.write(self.fd, data)
            data = data[n:]

    def read(self):
        while True:
            f = self._take()
            if f is not None:
                return f
            r, _, _ = select.select([self.fd], [], [], self.timeout)
            if not r:
                raise socket.timeout("serial idle")
            chunk = os.read(self.fd, 4096)
            if not chunk:
                raise ConnectionError("USB radio closed the connection")
            self.buf += chunk

    def close(self, polite=True):
        if polite:
            try:
                self.send(disconnect())
            except OSError:
                pass
        try:
            os.close(self.fd)
        except OSError:
            pass


def serial_ports():
    """USB serial devices that could be a Meshtastic radio."""
    import glob
    return sorted(glob.glob("/dev/ttyUSB*") + glob.glob("/dev/ttyACM*"))


def open_stream(conn, host="127.0.0.1", port=4403, dev="", timeout=15):
    if conn == "usb":
        if not dev:
            raise OSError("no USB radio selected")
        return SerialStream(dev, timeout)
    return Stream(host, port, timeout)
MESHPROTO_PY
cat > "$APP/radiocfg.py" <<'RADIOCFG_PY'
# PagerMesh - settings of the connected Meshtastic radio (Python standard library only)
# SPDX-License-Identifier: GPL-3.0-or-later
#
# The radio sends every settings section during want_config. PagerMesh keeps each
# section exactly as it arrived (raw protobuf) and, for a change, replaces only the
# fields that were edited (meshproto.patch). Everything else on the radio, including
# fields this version does not know, stays as it was.
#
# Secrets (Wi-Fi password, MQTT password, channel keys) are write-only here: the
# console shows "set" / "not set" and never the value.

import meshproto as mp

CFG, MOD = "cfg", "mod"
# Config sections (config.proto Config oneof) and ModuleConfig sections (module_config.proto)
DEVICE, POSITION, POWER, NETWORK, DISPLAY, LORA, BLUETOOTH = 1, 2, 3, 4, 5, 6, 7
MQTT, TELEMETRY = 1, 6
SECTION_NAMES = {(CFG, DEVICE): "Device", (CFG, POSITION): "Position", (CFG, POWER): "Power",
                 (CFG, NETWORK): "Network", (CFG, DISPLAY): "Display", (CFG, LORA): "LoRa",
                 (CFG, BLUETOOTH): "Bluetooth", (MOD, MQTT): "MQTT", (MOD, TELEMETRY): "Telemetry"}

UNITS = {0: "METRIC", 1: "IMPERIAL"}

# key, label, (kind, section), field, type, options
#   type: bool | uint | int | str | enum | secret
#   options: choices (enum), max (str length / number), risky (asks first), min
SETTINGS = [
    ("lora.region", "Region", (CFG, LORA), 7, "enum", {"choices": mp.REGIONS, "risky": True}),
    ("lora.modem_preset", "Modem preset", (CFG, LORA), 2, "enum", {"choices": mp.PRESETS, "risky": True}),
    ("lora.hop_limit", "Hop limit", (CFG, LORA), 8, "uint", {"min": 1, "max": 7}),
    ("lora.tx_power", "TX power (dBm, 0 = default)", (CFG, LORA), 10, "int", {"min": 0, "max": 30}),
    ("lora.tx_enabled", "Transmit enabled", (CFG, LORA), 9, "bool", {"risky": True}),
    ("device.role", "Role", (CFG, DEVICE), 1, "enum", {"choices": mp.ROLES, "pick": mp.ROLE_CHOICES}),
    ("device.node_info_broadcast_secs", "Node info broadcast (s)", (CFG, DEVICE), 7, "uint", {"min": 0, "max": 604800}),
    ("position.position_broadcast_secs", "Radio position broadcast (s)", (CFG, POSITION), 1, "uint", {"min": 0, "max": 604800}),
    ("position.position_broadcast_smart_enabled", "Smart position", (CFG, POSITION), 2, "bool", {}),
    ("position.gps_update_interval", "Radio GPS update (s)", (CFG, POSITION), 5, "uint", {"min": 0, "max": 604800}),
    ("telemetry.device_update_interval", "Device telemetry (s)", (MOD, TELEMETRY), 1, "uint", {"min": 0, "max": 604800}),
    ("telemetry.environment_update_interval", "Environment telemetry (s)", (MOD, TELEMETRY), 2, "uint", {"min": 0, "max": 604800}),
    ("network.wifi_enabled", "Wi-Fi on", (CFG, NETWORK), 1, "bool", {"risky": True}),
    ("network.wifi_ssid", "Wi-Fi network (SSID)", (CFG, NETWORK), 3, "str", {"max": 32, "risky": True}),
    ("network.wifi_psk", "Wi-Fi password", (CFG, NETWORK), 4, "secret", {"max": 63, "risky": True}),
    ("network.ntp_server", "NTP server", (CFG, NETWORK), 5, "str", {"max": 32}),
    ("bluetooth.enabled", "Bluetooth on", (CFG, BLUETOOTH), 1, "bool", {}),
    ("mqtt.enabled", "MQTT on", (MOD, MQTT), 1, "bool", {}),
    ("mqtt.address", "MQTT server", (MOD, MQTT), 2, "str", {"max": 63}),
    ("mqtt.username", "MQTT user", (MOD, MQTT), 3, "str", {"max": 63}),
    ("mqtt.password", "MQTT password", (MOD, MQTT), 4, "secret", {"max": 63}),
    ("mqtt.root", "MQTT root topic", (MOD, MQTT), 8, "str", {"max": 31}),
    ("mqtt.encryption_enabled", "MQTT encryption", (MOD, MQTT), 5, "bool", {}),
    ("mqtt.json_enabled", "MQTT JSON", (MOD, MQTT), 6, "bool", {}),
    ("mqtt.tls_enabled", "MQTT TLS", (MOD, MQTT), 7, "bool", {}),
    ("mqtt.proxy_to_client_enabled", "MQTT through the app", (MOD, MQTT), 9, "bool", {}),
    ("mqtt.map_reporting_enabled", "MQTT map report", (MOD, MQTT), 10, "bool", {}),
    ("display.screen_on_secs", "Screen on (s)", (CFG, DISPLAY), 1, "uint", {"min": 0, "max": 86400}),
    ("display.units", "Units", (CFG, DISPLAY), 6, "enum", {"choices": UNITS}),
    ("display.flip_screen", "Flip screen", (CFG, DISPLAY), 5, "bool", {}),
    ("power.is_power_saving", "Power saving", (CFG, POWER), 1, "bool", {}),
    ("power.on_battery_shutdown_after_secs", "Shut down on battery after (s)", (CFG, POWER), 2, "uint", {"min": 0, "max": 604800}),
]
BY_KEY = {s[0]: s for s in SETTINGS}


def _read(raw, fn, typ):
    wt, v = mp.field_value(raw, fn)
    if typ == "bool":
        return bool(v) if wt == 0 else False
    if typ in ("uint", "enum"):
        return v if wt == 0 else 0
    if typ == "int":
        return mp.sint(v) if wt == 0 else 0
    if typ == "str":
        return mp.text(v) if wt == 2 else ""
    if typ == "secret":
        return bool(wt == 2 and len(v))          # set or not; never the value
    return None


def current(sections):
    """{key: value} for the console. sections: {(kind, section): raw bytes}."""
    out = {}
    for key, _label, sec, fn, typ, _o in SETTINGS:
        if sec in sections:
            out[key] = _read(sections[sec], fn, typ)
    return out


def describe():
    """The settings list for the web console / Pager (no values)."""
    out = []
    for key, label, sec, _fn, typ, o in SETTINGS:
        d = {"key": key, "label": label, "type": typ, "group": SECTION_NAMES[sec],
             "risky": bool(o.get("risky"))}
        if typ == "enum":
            pick = o.get("pick") or sorted(o["choices"])
            d["choices"] = [[k, o["choices"][k]] for k in pick if k in o["choices"]]
        for k in ("min", "max"):
            if k in o:
                d[k] = o[k]
        out.append(d)
    return out


def _value(key, v):
    """Checked value for one setting, or raises ValueError with a readable reason."""
    _k, label, _sec, _fn, typ, o = BY_KEY[key]
    if typ == "bool":
        if isinstance(v, str):
            v = v.strip().lower() in ("1", "true", "yes", "on")
        return bool(v)
    if typ in ("uint", "int", "enum"):
        try:
            v = int(str(v).strip())
        except ValueError:
            raise ValueError("%s: enter a number" % label)
        if typ == "enum" and v not in o["choices"]:
            raise ValueError("%s: not a valid choice" % label)
        if "min" in o and v < o["min"] or "max" in o and v > o["max"]:
            raise ValueError("%s: %d to %d" % (label, o.get("min", 0), o.get("max", 0)))
        return v
    v = str(v)
    if any(ch < " " for ch in v):
        raise ValueError("%s: no control characters" % label)
    if len(v.encode("utf-8")) > o.get("max", 63):
        raise ValueError("%s: at most %d characters" % (label, o.get("max", 63)))
    return v


def _encode(fn, typ, v):
    if typ in ("bool", "uint", "enum", "int"):
        return mp.f_varint(fn, int(v))
    return mp.f_bytes(fn, v)


def build(sections, changes):
    """changes {key: value} -> ([(kind, section, new raw)], [labels changed], risky?)
    Raises ValueError for a bad value or a section the radio did not send."""
    per = {}
    labels, risky = [], False
    for key, v in changes.items():
        if key not in BY_KEY:
            raise ValueError("unknown setting %s" % key)
        _k, label, sec, fn, typ, o = BY_KEY[key]
        if sec not in sections:
            raise ValueError("%s: the radio did not send its %s settings" % (label, SECTION_NAMES[sec]))
        if typ == "secret" and v in (None, ""):
            continue                                # empty secret field = keep the current one
        val = _value(key, v)
        if typ != "secret" and _read(sections[sec], fn, typ) == val:
            continue                                # unchanged
        per.setdefault(sec, {})[fn] = _encode(fn, typ, val)
        if key == "lora.modem_preset":
            per[sec][1] = mp.f_varint(1, 1)         # use_preset = true, or the preset is ignored
        labels.append(label)
        risky = risky or bool(o.get("risky"))
    out = [(sec[0], sec[1], mp.patch(sections[sec], fl)) for sec, fl in per.items()]
    return out, labels, risky


# ---- channels -------------------------------------------------------------

def channel_raw(index, settings_raw, role):
    return mp.f_varint(1, index) + mp.f_bytes(2, settings_raw) + mp.f_varint(3, role)


def build_channel(cur, index, name=None, psk=None, role=None, uplink=None, downlink=None, precision=None, rand=None):
    """New Channel bytes. cur = decoded channel (meshproto.dec_channel) or None for a new one.
    psk: None = keep, "random" = new AES-256 key, "default" = the public default key, "none" = no encryption."""
    if not 0 <= index <= 7:
        raise ValueError("channel index 0 to 7")
    settings = (cur or {}).get("settings_raw", b"")
    role = (cur or {}).get("role", 2) if role is None else int(role)
    if index == 0 and role != 1:
        raise ValueError("channel 0 is always the primary channel")
    if index != 0 and role == 1:
        raise ValueError("only channel 0 can be primary")
    ch = {}
    if name is not None:
        name = str(name).strip()
        if len(name.encode("utf-8")) > 11:
            raise ValueError("channel name: at most 11 characters")
        if any(c < " " for c in name):
            raise ValueError("channel name: no control characters")
        if role == 2 and not name:
            raise ValueError("a secondary channel needs a name")
        ch[3] = mp.f_bytes(3, name)
    if psk == "random":
        ch[2] = mp.f_bytes(2, rand(32))
    elif psk == "default":
        ch[2] = mp.f_bytes(2, b"\x01")
    elif psk == "none":
        ch[2] = mp.f_bytes(2, b"")
    elif psk not in (None, "", "keep"):
        raise ValueError("unknown key choice")
    if uplink is not None:
        ch[5] = mp.f_varint(5, 1 if uplink else 0)
    if downlink is not None:
        ch[6] = mp.f_varint(6, 1 if downlink else 0)
    if precision is not None:
        p = int(precision)
        if not 0 <= p <= 32:
            raise ValueError("position precision 0 to 32")
        _wt, mod = mp.field_value(settings, 7)
        ch[7] = mp.f_bytes(7, mp.patch(mod or b"", {1: mp.f_varint(1, p)}))
    if not settings and 2 not in ch:
        ch[2] = mp.f_bytes(2, rand(32))             # a new channel gets its own key
    return channel_raw(index, mp.patch(settings, ch), role)
RADIOCFG_PY
cat > "$APP/sigint.py" <<'SIGINT_PY'
# PagerMesh - mesh SIGINT: what the radio hears, per packet and per node (standard library only)
# SPDX-License-Identifier: GPL-3.0-or-later
#
# Works at the mesh level, from what the radio passes to its app: every packet it
# decodes, and packets for channels it has no key for (shown as ENCRYPTED, with
# sender, size, RSSI and SNR). Raw LoRa capture needs radio firmware changes and is
# not part of PagerMesh.
#
# Export: pcap (LINKTYPE_USER0 = 147, one Meshtastic MeshPacket protobuf per record,
# for a Wireshark Meshtastic dissector or your own tools) and CSV.

import struct
import threading
import time

KEEP_PACKETS = 3000
TRAIL_POINTS = 200
TRAIL_AGE = 86400
LINKTYPE_USER0 = 147


class Sigint:
    def __init__(self, port_names, node_id):
        self.port_names, self.node_id = port_names, node_id
        self.lock = threading.Lock()
        self.packets = []                 # dicts, newest last
        self.nodes = {}                   # num -> stats
        self.ports = {}                   # name -> count
        self.minutes = {}                 # epoch minute -> count
        self.trails = {}                  # num -> [(t, lat, lon)]
        self.started = time.time()
        self.total = 0

    def add(self, p):
        """p: decoded MeshPacket (meshproto.dec_packet) with '_raw'."""
        t = time.time()
        d = p.get("decoded")
        if d:
            port = self.port_names.get(d["portnum"], str(d["portnum"]))
            size = len(d.get("payload", b""))
        elif "encrypted" in p:
            port, size = "ENCRYPTED", p["encrypted"]
        else:
            port, size = "EMPTY", 0
        hops = None
        if p.get("hop_start") and "hop_limit" in p:
            hops = max(0, p["hop_start"] - p["hop_limit"])
        rec = {"t": t, "from": p.get("from", 0), "to": p.get("to", 0), "ch": p.get("channel", 0),
               "id": p.get("id", 0), "port": port, "size": size, "rssi": p.get("rx_rssi"),
               "snr": p.get("rx_snr"), "hops": hops, "mqtt": bool(p.get("via_mqtt")),
               "pki": bool(p.get("pki")), "raw": p.get("_raw", b"")}
        m = int(t // 60)
        with self.lock:
            self.total += 1
            self.packets.append(rec)
            del self.packets[:-KEEP_PACKETS]
            self.ports[port] = self.ports.get(port, 0) + 1
            self.minutes[m] = self.minutes.get(m, 0) + 1
            for k in [k for k in self.minutes if k < m - 60]:
                del self.minutes[k]
            n = self.nodes.setdefault(rec["from"], {"packets": 0, "ports": {}, "first": t, "last": t,
                                                    "rssi_sum": 0, "rssi_n": 0, "snr_sum": 0.0, "snr_n": 0,
                                                    "rssi": None, "snr": None, "enc": 0, "mqtt": 0, "bytes": 0})
            n["packets"] += 1
            n["bytes"] += size
            n["last"] = t
            n["ports"][port] = n["ports"].get(port, 0) + 1
            if port == "ENCRYPTED":
                n["enc"] += 1
            if rec["mqtt"]:
                n["mqtt"] += 1
            if rec["rssi"] is not None and not rec["mqtt"]:
                n["rssi"] = rec["rssi"]
                n["rssi_sum"] += rec["rssi"]
                n["rssi_n"] += 1
            if rec["snr"] is not None and not rec["mqtt"]:
                n["snr"] = rec["snr"]
                n["snr_sum"] += rec["snr"]
                n["snr_n"] += 1
        return rec

    def add_point(self, num, lat, lon, t=None):
        t = t or time.time()
        with self.lock:
            tr = self.trails.setdefault(num, [])
            if tr and abs(tr[-1][1] - lat) < 1e-6 and abs(tr[-1][2] - lon) < 1e-6:
                return
            tr.append((int(t), lat, lon))
            cut = t - TRAIL_AGE
            while tr and (tr[0][0] < cut or len(tr) > TRAIL_POINTS):
                tr.pop(0)

    def line(self, r):
        """One packets.log line."""
        to = "ALL" if r["to"] == 0xFFFFFFFF else self.node_id(r["to"])
        extra = ""
        if r["rssi"] is not None:
            extra += " rssi=%d" % r["rssi"]
        if r["snr"] is not None:
            extra += " snr=%.1f" % r["snr"]
        if r["hops"] is not None:
            extra += " hops=%d" % r["hops"]
        if r["mqtt"]:
            extra += " mqtt"
        if r["pki"]:
            extra += " pki"
        return "%s from=%s to=%s ch=%s id=%08x %s %dB%s" % (
            time.strftime("%H:%M:%S", time.localtime(r["t"])), self.node_id(r["from"]), to, r["ch"], r["id"],
            r["port"], r["size"], extra)

    def stats(self, name_of):
        with self.lock:
            nodes = []
            for num, n in self.nodes.items():
                nodes.append({"id": self.node_id(num), "name": name_of(num), "packets": n["packets"],
                              "bytes": n["bytes"], "enc": n["enc"], "mqtt": n["mqtt"],
                              "rssi": n["rssi"], "snr": n["snr"],
                              "rssi_avg": round(n["rssi_sum"] / n["rssi_n"], 1) if n["rssi_n"] else None,
                              "snr_avg": round(n["snr_sum"] / n["snr_n"], 1) if n["snr_n"] else None,
                              "last": int(n["last"]),
                              "top": sorted(n["ports"].items(), key=lambda kv: -kv[1])[:3]})
            nodes.sort(key=lambda r: -r["packets"])
            now_m = int(time.time() // 60)
            per_min = [self.minutes.get(m, 0) for m in range(now_m - 59, now_m + 1)]
            return {"total": self.total, "since": int(self.started), "ports": sorted(self.ports.items(), key=lambda kv: -kv[1]),
                    "per_min": per_min, "nodes": nodes[:100]}

    def recent(self, n=200):
        with self.lock:
            rows = self.packets[-n:]
        return [{k: (v if k != "raw" else None) for k, v in r.items() if k != "raw"} for r in rows]

    def trail_list(self):
        with self.lock:
            return {self.node_id(num): [[a, b, c] for a, b, c in tr] for num, tr in self.trails.items() if len(tr) > 1}

    def pcap(self):
        out = bytearray(struct.pack("<IHHiIII", 0xA1B2C3D4, 2, 4, 0, 0, 65535, LINKTYPE_USER0))
        with self.lock:
            rows = list(self.packets)
        for r in rows:
            raw = r["raw"] or b""
            sec = int(r["t"])
            out += struct.pack("<IIII", sec, int((r["t"] - sec) * 1e6), len(raw), len(raw)) + raw
        return bytes(out)

    def csv(self):
        head = "time,from,to,channel,id,port,bytes,rssi,snr,hops,mqtt,pki\n"
        with self.lock:
            rows = list(self.packets)
        out = [head]
        for r in rows:
            out.append("%s,%s,%s,%s,%08x,%s,%d,%s,%s,%s,%d,%d\n" % (
                time.strftime("%Y-%m-%dT%H:%M:%S", time.localtime(r["t"])), self.node_id(r["from"]),
                "ALL" if r["to"] == 0xFFFFFFFF else self.node_id(r["to"]), r["ch"], r["id"], r["port"], r["size"],
                "" if r["rssi"] is None else r["rssi"], "" if r["snr"] is None else r["snr"],
                "" if r["hops"] is None else r["hops"], r["mqtt"], r["pki"]))
        return "".join(out)
SIGINT_PY
# Leaflet 1.9.4 (BSD-2-Clause, see THIRD-PARTY-LICENSES.txt), gzip + base64
"$PY" -c 'import base64,sys,zlib;open(sys.argv[1],"wb").write(zlib.decompress(base64.b64decode(sys.stdin.read()),31))' "$APP/static/leaflet.js" <<'LEAFLET_JS'
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
LEAFLET_JS
"$PY" -c 'import base64,sys,zlib;open(sys.argv[1],"wb").write(zlib.decompress(base64.b64decode(sys.stdin.read()),31))' "$APP/static/leaflet.css" <<'LEAFLET_CSS'
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
LEAFLET_CSS
cat > "$APP/index.html" <<'TURTLEMESH_HTML'
<!DOCTYPE html>
<html lang="en">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>TurtleMesh Hub Edition</title>
<style>
:root{--bg:#0e1411;--panel:#16201a;--line:#27382d;--text:#dfe8e1;--dim:#8fa396;--acc:#67ea94;--warn:#f2b631;--crit:#ff5c5c;--info:#4fb3ff}
*{box-sizing:border-box}
body{margin:0;background:var(--bg);color:var(--text);font:14px/1.45 system-ui,-apple-system,"Segoe UI",Roboto,sans-serif}
header{display:flex;align-items:center;gap:12px;padding:10px 16px;background:#0a0e0b;border-bottom:1px solid var(--line);flex-wrap:wrap}
header h1{font-size:17px;margin:0;letter-spacing:.5px}header h1 b{color:var(--acc)}header .ed{color:var(--dim);font-size:12px}
.pill{padding:2px 9px;border-radius:10px;font-size:12px;border:1px solid var(--line);white-space:nowrap}
.pill.ok{color:#0a0e0b;background:var(--acc);border-color:var(--acc)}.pill.bad{color:#fff;background:#8a2a2a;border-color:#a33}.pill.mid{color:#0a0e0b;background:var(--warn);border-color:var(--warn)}
nav{display:flex;gap:2px;padding:0 10px;background:#0a0e0b;border-bottom:1px solid var(--line);overflow-x:auto}
nav button{background:none;border:0;color:var(--dim);padding:10px 14px;cursor:pointer;font-size:14px;border-bottom:2px solid transparent;white-space:nowrap}
nav button.on{color:var(--text);border-bottom-color:var(--acc)}nav .n{background:var(--crit);color:#fff;border-radius:8px;padding:0 6px;font-size:11px;margin-left:4px}
main{padding:14px;max-width:1200px;margin:auto}section{display:none}section.on{display:block}
.grid{display:grid;grid-template-columns:repeat(auto-fit,minmax(260px,1fr));gap:12px}
.card{background:var(--panel);border:1px solid var(--line);border-radius:8px;padding:12px 14px}
.card h3{margin:0 0 8px;font-size:13px;text-transform:uppercase;letter-spacing:.6px;color:var(--dim)}
.kv{display:grid;grid-template-columns:auto minmax(0,1fr);gap:3px 12px}.kv div{overflow-wrap:anywhere}.kv div:nth-child(odd){color:var(--dim);white-space:nowrap}
table{width:100%;border-collapse:collapse;font-size:13px}th,td{text-align:left;padding:5px 6px;border-bottom:1px solid var(--line);vertical-align:top}th{color:var(--dim);font-weight:500}
button.b,.b{background:#1f4430;color:var(--text);border:1px solid #2f7048;border-radius:6px;padding:6px 12px;cursor:pointer;font-size:13px;text-decoration:none;display:inline-block}
button.b:hover{background:#28573c}button.b.red{background:#4a2020;border-color:#7a3030}button.b.sm{padding:3px 8px;font-size:12px}
input,select,textarea{background:#0b100d;color:var(--text);border:1px solid var(--line);border-radius:5px;padding:6px 8px;font:inherit}
input:focus,select:focus{outline:1px solid var(--acc)}input[type=file]{max-width:100%}
.row{display:flex;gap:8px;align-items:center;flex-wrap:wrap;margin:6px 0}
.dim{color:var(--dim)}.warn{color:var(--warn)}.crit{color:var(--crit)}.ok{color:var(--acc)}
.alert{background:var(--panel);border:1px solid var(--line);border-radius:6px;padding:8px 12px;margin-bottom:6px}
.alert.lvl-critical{border-left:4px solid var(--crit)}.alert.lvl-warning{border-left:4px solid var(--warn)}.alert.lvl-info{border-left:4px solid var(--info)}
#map{height:62vh;border-radius:8px;border:1px solid var(--line);background:#0b100d}
.chatwrap{display:grid;grid-template-columns:220px 1fr;gap:10px}@media(max-width:700px){.chatwrap{grid-template-columns:1fr}}
.convs{background:var(--panel);border:1px solid var(--line);border-radius:8px;overflow:auto;max-height:60vh}
.conv{padding:8px 10px;border-bottom:1px solid var(--line);cursor:pointer}.conv.on{background:#1f3a2a}.conv .dim{font-size:12px}
.chatlog{height:52vh;overflow-y:auto;background:#0b100d;border:1px solid var(--line);border-radius:8px;padding:8px}
.msg{white-space:pre-wrap;margin:4px 0;padding:6px 10px;border-radius:8px;max-width:80%;background:#1c2a21}.msg.out{margin-left:auto;background:#1f4430}.msg .h{font-size:11px;color:var(--dim)}
pre{white-space:pre-wrap;background:#0b100d;border:1px solid var(--line);border-radius:6px;padding:8px;font-size:12px;max-height:60vh;overflow:auto}
.cfg{display:grid;grid-template-columns:minmax(160px,220px) 1fr;gap:4px 10px;align-items:center}.cfg h4{grid-column:1/3;margin:14px 0 2px;color:var(--acc);font-size:13px}
.frm{display:grid;grid-template-columns:minmax(150px,190px) minmax(0,420px);gap:6px 10px;align-items:center;margin:8px 0}
.seg{display:inline-flex;border:1px solid var(--line);border-radius:6px;overflow:hidden;margin-bottom:8px}.seg button{background:#0b100d;color:var(--dim);border:0;padding:6px 12px;cursor:pointer}.seg button.on{background:#1f4430;color:var(--text)}
.toast{position:fixed;bottom:16px;right:16px;background:#1f4430;border:1px solid var(--acc);padding:9px 14px;border-radius:6px;display:none;max-width:80vw;z-index:9999}.toast.err{background:#4a2020;border-color:var(--crit)}
#login{max-width:340px;margin:12vh auto;text-align:center}
.tag{font-size:11px;padding:1px 6px;border-radius:4px;background:#27382d}.tag.new{background:var(--warn);color:#111}.tag.bad{background:var(--crit);color:#fff}.tag.g{background:#2f7048}
.wide{grid-column:span 2}@media(max-width:760px){.wide{grid-column:auto}}
footer{color:var(--dim);font-size:12px;text-align:center;padding:20px}details{margin:6px 0}
</style>
</head>
<body>
<div id="login" style="display:none" class="card"><h2>Turtle<b style="color:var(--acc)">Mesh</b></h2><p class="dim">Hub Edition web console</p>
  <form onsubmit="login(event)"><input type="password" id="pw" placeholder="Password" autofocus style="width:100%"><br><br><button class="b" style="width:100%">Sign in</button></form>
  <p class="dim" style="font-size:12px">First password: Hub notifications (bell icon) or /root/turtlemesh/web-password.txt</p></div>
<div id="app" style="display:none">
<header><h1>Turtle<b>Mesh</b></h1><span class="ed">Hub Edition</span>
  <span class="pill" id="p-radio">Radio</span><span class="pill" id="p-tak">TAK</span><span class="pill" id="p-nodes">Nodes</span>
  <span style="flex:1"></span><a id="tt-link" class="b sm" style="display:none" target="_blank">TurtleTAK console</a><span class="dim" id="h-cs"></span><button class="b" onclick="logout()">Sign out</button></header>
<nav id="nav"></nav>
<main>
<section id="t-status">
  <div class="grid">
    <div class="card"><h3>Radio</h3><div class="kv" id="k-radio"></div><div class="row"><button class="b" onclick="act('radio_reconnect')">Reconnect</button><button class="b" onclick="act('mesh_pos')">Send Hub position</button></div></div>
    <div class="card"><h3>Mesh</h3><div class="kv" id="k-mesh"></div></div>
    <div class="card"><h3>TAK Server</h3><div class="kv" id="k-tak"></div><div class="row"><button class="b" onclick="act('reconnect')">Reconnect</button></div></div>
    <div class="card"><h3>Alerts over LoRa / MQTT</h3><div class="kv" id="k-lora"></div></div>
  </div>
  <div class="card" style="margin-top:12px"><h3>What TAK sees (marker remarks)</h3><pre id="remarks"></pre></div>
</section>
<section id="t-map">
  <div class="row"><select id="mp-src" onchange="setCfg({MAP_SOURCE:this.value});mapSource(this.value)"></select><label class="dim">Save to zoom</label>
    <select id="mp-z"><option>13</option><option>14</option><option selected>15</option><option>16</option></select>
    <button class="b" onclick="saveArea()">Save this area offline</button><button class="b" onclick="act('tiles_stop')">Stop</button>
    <button class="b red" onclick="if(confirm('Delete every saved map tile on the Hub?'))act('tiles_clear')">Clear saved maps</button><span class="dim" id="mp-st"></span></div>
  <div id="map"></div>
  <p class="dim" id="mapnote">Green: mesh nodes, blue: TAK contacts, the Hub in the middle. Click the map to place the Hub there. Tiles come through the Hub and are kept there.</p>
</section>
<section id="t-chat">
  <div class="chatwrap"><div class="convs" id="convs"></div>
  <div><div class="chatlog" id="chatlog"></div>
    <form class="row" onsubmit="sendMesh(event)"><input id="m-text" style="flex:1;min-width:200px" maxlength="200" placeholder="Message (up to 200 bytes)"><span class="dim" id="m-len">0/200</span><button class="b">Send</button></form>
    <p class="dim">Any node can direct-message the Hub's radio: <b>status</b>, <b>alerts</b>, <b>where</b>, <b>nodes</b>, <b>help</b>.</p></div></div>
</section>
<section id="t-nodes">
  <div class="row"><input id="nd-q" placeholder="Filter nodes" oninput="render()"><label><input type="checkbox" id="nd-recent" onchange="render()" checked> heard in the last 24 h</label><span style="flex:1"></span>
    <button class="b" onclick="act('accept_nodes')">Mark all as known</button><button class="b" onclick="if(confirm('Start learning the mesh again? New-node alerts pause while learning.'))act('relearn')">Re-learn</button>
    <a class="b" href="/api/sigint.csv">Packets CSV</a><a class="b" href="/api/sigint.pcap">Packets pcap</a></div>
  <p class="dim" id="nd-learn"></p>
  <div class="card"><table id="tb-nodes"></table></div>
  <p class="dim"><b>Watch</b> a node to get <i>Node quiet</i> and <i>Low battery</i> alerts. Mark a node as a <b>Sensor</b> (a radio running the detection-sensor module, or one that sends a text when something trips) to turn what it sends into alerts on TAK.</p>
</section>
<section id="t-alerts">
  <div class="card" style="margin-bottom:12px"><h3>Alert settings</h3><div class="row" id="al-kinds"></div>
    <div class="frm"><label>Map marker from</label><select id="al-marker"><option>info</option><option>warning</option><option>critical</option></select>
      <label>TAK chat line from</label><select id="al-chat"><option>info</option><option>warning</option><option>critical</option></select>
      <label>Over LoRa from</label><select id="al-lora"><option>info</option><option>warning</option><option>critical</option></select>
      <label>Over LoRa to</label><div class="row" style="margin:0"><select id="al-dest" onchange="loraDest()"></select><input id="al-to" placeholder="!node id" size="12" style="display:none"></div>
      <span></span><div><p id="al-lnow" style="margin:0"></p><p class="warn" id="al-lwarn" style="display:none;margin:4px 0 0"></p></div>
      <label>Quiet hours</label><div class="row" style="margin:0"><input id="al-quiet" placeholder="e.g. 22-06" size="12"><label><input type="checkbox" id="al-qcrit"> critical still goes out</label></div></div>
    <div class="row"><button class="b" onclick="saveAlertCfg()">Save alert settings</button><span class="dim" id="al-qnow"></span></div></div>
  <div class="row"><button class="b" onclick="act('test_alert')">Send test alert</button><button class="b red" onclick="if(confirm('Clear TurtleMesh alerts?'))act('clear_alerts')">Clear list</button></div>
  <div id="alertlist"></div>
</section>
<section id="t-radio">
  <div class="grid">
    <div class="card"><h3>Connection</h3>
      <div class="frm"><label>Radio</label><select id="r-conn"><option value="wifi">Wi-Fi (network)</option><option value="usb">USB on the Hub</option></select>
        <label>Wi-Fi radio address</label><input id="r-host" placeholder="192.0.2.50"><label>USB device</label><input id="r-dev" placeholder="auto"></div>
      <div class="row"><button class="b" onclick="saveConn()">Save and connect</button></div>
      <p class="dim">USB: plug the radio into the Hub's dynamic USB port (nearest the USB-C cable); TurtleMesh claims and powers it.</p></div>
    <div class="card"><h3>Name</h3><div class="frm"><label>Long name</label><input id="r-long" maxlength="39"><label>Short name</label><input id="r-short" maxlength="4"></div>
      <div class="row"><button class="b" onclick="act('set_owner',{long:$('r-long').value,short:$('r-short').value})">Save name</button><button class="b red" onclick="if(confirm('Restart the radio?'))act('reboot_radio')">Restart radio</button></div>
      <div class="kv" id="k-meta"></div></div>
  </div>
  <div class="card" style="margin-top:12px"><h3>Channels</h3><table id="tb-ch"></table>
    <div class="row"><select id="c-idx"></select><input id="c-name" placeholder="name" maxlength="11" size="12"><select id="c-psk"><option value="">keep key</option><option value="random">new random key</option><option value="default">default key</option><option value="none">no encryption</option></select>
      <select id="c-role"><option value="">keep role</option><option value="1">primary</option><option value="2">secondary</option><option value="0">disabled</option></select><button class="b" onclick="saveChan()">Save channel</button></div>
    <p class="dim" id="share"></p>
    <div class="row"><label>Hub position on the mesh</label><select id="r-pos" onchange="setCfg({MESH_POS_CHANNEL:this.value})"></select><span class="dim">every MESH_POS_INTERVAL seconds, private channels only</span></div></div>
  <div class="card" style="margin-top:12px"><h3>Radio settings</h3><p class="dim">Only changed values are sent. Most changes restart the radio.</p><div class="cfg" id="r-set"></div>
    <div class="row"><button class="b" onclick="saveRadio()">Save radio settings</button></div></div>
</section>
<section id="t-tak">
  <div class="grid">
    <div class="card"><h3>Mesh &harr; TAK bridge</h3><div class="kv" id="k-bridge"></div>
      <div class="row"><label><input type="checkbox" id="br-nodes" onchange="setCfg({BRIDGE_NODES:this.checked?'1':'0'})"> Mesh nodes as TAK markers</label></div>
      <div class="row"><label><input type="checkbox" id="br-atak" onchange="setCfg({BRIDGE_ATAK_PLUGIN:this.checked?'1':'0'})"> Meshtastic ATAK plugin users on TAK</label></div>
      <div class="row"><label>Chat: mesh channel</label><select id="br-ch" onchange="setCfg({BRIDGE_CHAT_CHANNEL:this.value})"></select><span class="dim">&harr; TAK All Chat Rooms</span></div><p class="dim">Only a channel with its own key can be bridged, so TAK chat never goes out on a public channel.</p></div>
    <div class="card"><h3>MQTT proxy</h3><p class="dim">The Hub carries the radio's MQTT traffic to your own broker (useful for a USB radio with no Wi-Fi).</p>
      <div class="kv" id="k-mqtt"></div><div class="row"><button class="b" onclick="act('mqtt_radio_setup')">Set up the radio for it</button></div></div>
  </div>
  <div class="card" style="margin-top:12px"><h3>TAK chat</h3><div class="chatlog" id="takchat" style="height:30vh"></div>
    <form class="row" onsubmit="sendTak(event)"><select id="tk-to"><option value="">All Chat Rooms</option></select><input id="tk-text" style="flex:1" maxlength="1000" placeholder="Message to TAK"><button class="b">Send</button></form></div>
</section>
<section id="t-settings">
  <div class="row"><button class="b" onclick="saveCfg()">Save settings</button><span class="dim">Secrets show blank; leave them blank to keep them.</span></div>
  <div class="card"><div class="cfg" id="cfgform"></div></div><div class="row"><button class="b" onclick="saveCfg()">Save settings</button></div>
</section>
<section id="t-setup">
  <div class="grid">
    <div class="card" style="grid-column:1/-1"><h3>1. TAK Server connection</h3>
      <p id="tt-note" class="ok" style="display:none">TurtleTAK is installed on this Hub. With <b>TAK_FROM_TURTLETAK</b> on, TurtleMesh uses its server and certificates, so there is nothing to set up here.</p>
      <div class="seg" id="seg"><button class="on" onclick="pane('cp',this)">Connection package</button><button onclick="pane('cr',this)">Certificates</button><button onclick="pane('en',this)">Enroll</button></div>
      <div id="p-cp" class="pane"><p>The <b>.zip</b> data package from your TAK Server admin.</p><div class="row"><input type="file" id="cp-file" accept=".zip"></div>
        <details><summary class="dim">Package asks for passwords?</summary><div class="frm"><label>Client certificate password</label><input type="password" id="cp-cpw" placeholder="blank = from the package"><label>Truststore password</label><input type="password" id="cp-tpw" placeholder="blank = from the package"></div></details>
        <div class="row"><button class="b" onclick="importPkg()">Import and connect</button></div></div>
      <div id="p-cr" class="pane" style="display:none"><div class="frm"><label>Server address</label><input id="cr-host" placeholder="takserver.example.com"><label>Port / protocol</label><div class="row" style="margin:0"><input id="cr-port" size="6" placeholder="8089"><select id="cr-proto"><option value="tls">SSL/TLS</option><option value="tcp">TCP</option><option value="udp">UDP</option></select></div>
        <label>Client certificate</label><input type="file" id="cr-client" accept=".p12,.pfx,.pem"><label>Client password</label><input type="password" id="cr-cpw" placeholder="default atakatak">
        <label>Truststore (CA)</label><input type="file" id="cr-trust" accept=".p12,.pfx,.pem"><label>Truststore password</label><input type="password" id="cr-tpw" placeholder="default atakatak"></div>
        <div class="row"><button class="b" onclick="saveCerts()">Save and connect</button></div></div>
      <div id="p-en" class="pane" style="display:none"><div class="frm"><label>Server address</label><input id="en-host" placeholder="takserver.example.com"><label>Username</label><input id="en-u" autocomplete="off"><label>Password</label><input id="en-p" type="password" autocomplete="new-password"></div>
        <div class="row"><button class="b" onclick="enroll()">Enroll and connect</button></div></div>
      <div class="kv" id="k-certs" style="margin-top:10px"></div>
      <div class="row"><button class="b" onclick="diag()">Test connection</button><button class="b" onclick="if(confirm('Put back the previous certificates?'))act('restore_certs')">Restore previous certificates</button></div><pre id="diag" style="display:none"></pre></div>
    <div class="card wide"><h3>2. Location</h3>
      <div class="frm"><label>Primary source</label><select id="loc-mode"><option value="auto">Auto (in the order below)</option><option value="radio">Radio GPS</option><option value="gps">USB GPS on the Hub</option><option value="atak">My phone (ATAK)</option><option value="mesh">My phone (mesh node)</option><option value="site">Saved site</option><option value="manual">Manual</option><option value="ip">Network (public IP)</option></select>
        <label>My ATAK callsign</label><input id="loc-atak" placeholder="from the TAK Server">
        <label>My mesh node</label><select id="loc-node"><option value="">none</option></select></div>
      <div class="row"><button class="b" onclick="saveLoc()">Save location settings</button></div>
      <p class="dim">Auto order: radio GPS, USB GPS, my phone (ATAK), my phone (mesh), saved site, manual, network. A primary source goes first and the rest stay as fallback. GPS and phone positions count while they are fresh.</p>
      <div class="kv" id="k-loc"></div>
      <div class="row"><input id="lat" placeholder="Latitude" size="11"><input id="lon" placeholder="Longitude" size="11"><input id="site" placeholder="Save as site (optional)" size="16"><button class="b" onclick="setPos()">Set manual</button></div>
      <p class="dim">Without its own GPS fix, the radio sends the Hub's position on the mesh every MESH_POS_INTERVAL seconds.</p></div>
    <div class="card"><h3>3. Hub</h3><div class="row"><label><input type="checkbox" id="boot" onchange="act('boot',{on:this.checked})"> Run TurtleMesh at boot</label></div>
      <div class="row"><label><input type="checkbox" id="ledon" onchange="setCfg({LED:this.checked?'1':'0'})"> Use the LED</label></div>
      <div class="row"><input type="password" id="newpw" placeholder="New web password (8+)"><button class="b" onclick="act('set_password',{password:$('newpw').value});$('newpw').value=''">Change password</button></div></div>
  </div>
  <div class="card" style="margin-top:12px"><h3>Log</h3><div class="row"><button class="b" onclick="loadLog()">Refresh</button></div><pre id="log"></pre></div>
</section>
</main>
<footer>TurtleMesh Hub Edition <span id="ver"></span> &middot; SECT0101 &middot; Radio code from PagerMesh &middot; Meshtastic&reg; is a registered trademark of Meshtastic LLC.</footer>
</div>
<div class="toast" id="toast"></div>
<script>
const TABS=[["status","Status"],["map","Map"],["chat","Mesh Chat"],["nodes","Nodes"],["alerts","Alerts"],["radio","Radio"],["tak","TAK"],["settings","Settings"],["setup","Setup"]];
let ST=null,tab=lsg("tm_tab")||"status",map=null,layers=null,tileLayer=null,conv=lsg("tm_conv")||"ch:0",cfgLoaded=false,radioV=null,seen=+(lsg("tm_seen")||0);
function lsg(k){try{return localStorage.getItem(k)}catch(e){return null}}function lss(k,v){try{localStorage.setItem(k,v)}catch(e){}}
const $=id=>document.getElementById(id);
const esc=s=>String(s==null?"":s).replace(/[&<>"']/g,c=>({"&":"&amp;","<":"&lt;",">":"&gt;",'"':"&quot;","'":"&#39;"}[c]));
const ago=s=>s==null?"never":(s=Math.max(0,Math.round(s)),s<90?s+"s":s<5400?Math.round(s/60)+"m":s<172800?Math.floor(s/3600)+"h"+String(Math.floor(s%3600/60)).padStart(2,"0"):Math.floor(s/86400)+"d");
const tm=t=>new Date(t*1000).toLocaleString();
const kv=(id,rows)=>$(id).innerHTML=rows.filter(r=>r).map(([k,v])=>`<div>${esc(k)}</div><div>${v}</div>`).join("");
function toast(m,err){const t=$("toast");t.textContent=m;t.className="toast"+(err?" err":"");t.style.display="block";clearTimeout(t._h);t._h=setTimeout(()=>t.style.display="none",4500)}
async function api(path,opt={}){opt.headers=Object.assign({"X-TT":"1"},opt.headers||{});opt.credentials="same-origin";const r=await fetch(path,opt);if(r.status==401){showLogin();throw new Error("sign in")}
  const ct=r.headers.get("content-type")||"";const d=ct.includes("json")?await r.json():await r.text();if(!r.ok)throw new Error(d.error||r.statusText);return d}
function showLogin(){$("app").style.display="none";$("login").style.display="block"}
async function login(e){e.preventDefault();try{await api("/api/login",{method:"POST",body:JSON.stringify({password:$("pw").value})});$("pw").value="";$("login").style.display="none";$("app").style.display="block";await refresh();go(tab)}catch(x){toast(x.message,1)}}
async function logout(){try{await api("/api/logout",{method:"POST"})}catch(e){}showLogin()}
async function act(a,extra={}){try{const d=await api("/api/action",{method:"POST",body:JSON.stringify(Object.assign({action:a},extra))});toast(d.msg||"done");refresh()}catch(e){toast(e.message,1)}}
async function setCfg(o){try{const d=await api("/api/cfg",{method:"POST",body:JSON.stringify(o)});toast(d.msg);cfgLoaded=false;refresh()}catch(e){toast(e.message,1)}}
function nav(){$("nav").innerHTML=TABS.map(([k,l])=>`<button class="${k==tab?"on":""}" onclick="go('${k}')">${l}${k=="alerts"?'<span class="n" id="n-al" style="display:none"></span>':""}</button>`).join("");document.querySelectorAll("section").forEach(s=>s.classList.toggle("on",s.id=="t-"+tab))}
function go(k){tab=k;lss("tm_tab",k);nav();if(k=="map")setTimeout(initMap,50);if(k=="settings")loadCfg();if(k=="setup"){syncChecks();loadLog()}if(k=="radio")loadRadio();if(k=="alerts"&&ST){loadAlertCfg();if(ST.alerts.length){seen=ST.alerts[0].time;lss("tm_seen",seen)}}render()}
function pill(id,cls,txt){const p=$(id);p.className="pill "+cls;p.textContent=txt}
function render(){if(!ST)return;const s=ST,m=s.mesh,t=s.tak,st=s.status||{};$("ver").textContent=s.version;$("h-cs").textContent=s.callsign;
  pill("p-radio",m.link=="connected"?"ok":m.link=="connecting"?"mid":"bad","Radio "+m.link);pill("p-tak",!t.enabled?"":t.state=="connected"?"ok":"bad","TAK "+(t.enabled?t.state:"off"));
  const heard=m.nodes.filter(n=>!n.me&&n.age!=null&&n.age<3600).length;pill("p-nodes",heard?"ok":"mid",heard+" nodes 1h");
  const tl=$("tt-link");if(s.turtletak.running){tl.style.display="inline-block";tl.href=location.protocol+"//"+location.hostname+":"+s.turtletak.port}
  const na=s.alerts.filter(a=>a.time>seen&&a.level!="info").length,n=$("n-al");if(n){n.textContent=na;n.style.display=na?"inline":"none"}
  if(tab=="status"){kv("k-radio",[["Link",`<span class="${m.link=="connected"?"ok":"warn"}">${esc(m.link)}</span>`],m.error?["Error",`<span class="crit">${esc(m.error)}</span>`]:null,["Connection",esc(m.conn+(m.conn=="wifi"?" "+m.host:""))],["Radio",esc(m.name+" "+m.me)],["Region",esc(m.region)],["Firmware",esc(m.firmware)],["Hop limit",m.hop_limit]]);
    kv("k-mesh",[["Nodes",m.nodes.filter(n=>!n.me).length+" known, "+heard+" heard in 1 h"],["Channels",esc(m.channels.map(c=>c.name).join(", "))],["Mesh watch",m.learning?"learning ("+ago(m.learning)+" left)":m.known+" known nodes"],["Watched",m.nodes.filter(n=>n.watch).length+" nodes, "+m.nodes.filter(n=>n.sensor).length+" sensors"]]);
    kv("k-tak",[["Server",esc(t.host+":"+t.port+" ("+t.proto+")")+(t.source=="TurtleTAK"?' <span class="tag g">TurtleTAK</span>':"")],["State",`<span class="${t.state=="connected"?"ok":"warn"}">${esc(t.enabled?t.state:"off")}</span>`],t.error?["Error",`<span class="crit">${esc(t.error)}</span>`]:null,["Nodes sent",s.bridge.nodes_to_tak],["Chat mesh \u2192 TAK",s.bridge.chat_to_tak],["Chat TAK \u2192 mesh",s.bridge.chat_to_mesh]]);
    kv("k-lora",[["Alerts over LoRa",s.lora.on?"on, "+esc(s.lora.min)+" and up, to "+esc(s.lora.to)+(s.lora.public?' <span class="warn">(public channel)</span>':""):"off (Alerts tab)"],["MQTT proxy",s.mqtt.on?esc(s.mqtt.state)+" ("+s.mqtt.up+" up / "+s.mqtt.down+" down)":"off"],["TurtleTAK",s.turtletak.running?'<span class="ok">running</span> - its alerts go out over LoRa':s.turtletak.installed?"installed, not running":"not installed"]]);
    $("remarks").textContent=s.status_text}
  if(tab=="map")drawMap();
  if(tab=="chat")renderChat();
  if(tab=="nodes")renderNodes();
  if(tab=="alerts"){$("al-qnow").textContent=s.quiet?"Quiet hours now":"";const ln=$("al-lnow");if(ln)ln.innerHTML=loraNow();if($("al-dest").options.length)fillDest();$("alertlist").innerHTML=s.alerts.map(a=>`<div class="alert lvl-${a.level}"><b>${esc(a.title)}</b> <span class="dim">${tm(a.time)} &middot; ${esc(a.kind)} &middot; ${esc(a.source||"TurtleMesh")}</span><br>${esc(a.detail)}</div>`).join("")||'<p class="dim">No alerts.</p>'}
  if(tab=="tak"){const b=s.bridge;kv("k-bridge",[["Nodes to TAK",b.nodes_to_tak],["Chat mesh \u2192 TAK",b.chat_to_tak],["Chat TAK \u2192 mesh",b.chat_to_mesh],["ATAK plugin to TAK",b.atak_to_tak+(b.atak_compressed?" ("+b.atak_compressed+" compressed: position only)":"")]]);
    $("br-nodes").checked=b.nodes;$("br-atak").checked=b.atak;const sel=$("br-ch"),opts='<option value="-1">off</option>'+chanOpts(true);if(sel._o!=opts){sel._o=opts;sel.innerHTML=opts}sel.value=String(b.chat_channel);
    kv("k-mqtt",[["Proxy",s.mqtt.on?esc(s.mqtt.state):"off (MQTT_PROXY in Settings)"],s.mqtt.error?["Error",`<span class="crit">${esc(s.mqtt.error)}</span>`]:null,["Radio \u2192 broker",s.mqtt.up],["Broker \u2192 radio",s.mqtt.down]]);
    const tc=$("takchat"),sig=s.tak_chat.length+":"+(s.tak_chat.length?s.tak_chat[s.tak_chat.length-1].id:"");if(tc._s!=sig){tc._s=sig;tc.innerHTML=s.tak_chat.map(c=>`<div class="msg ${c.dir}"><div class="h">${esc(c.from)} &rarr; ${esc(c.room)} &middot; ${tm(c.time)}</div>${esc(c.text)}</div>`).join("")||'<p class="dim">No TAK chat yet.</p>';tc.scrollTop=1e9}
    const tk=$("tk-to"),nm=[...new Set(s.contacts.filter(c=>c.type.startsWith("a-f-G-U")).map(c=>c.callsign))].sort().join("|");if(tk._n!=nm){const cur=tk.value;tk._n=nm;tk.innerHTML='<option value="">All Chat Rooms</option>'+nm.split("|").filter(x=>x).map(x=>`<option>${esc(x)}</option>`).join("");tk.value=cur}}
  if(tab=="setup"){const p=s.pos;kv("k-loc",[["Using",esc(LOCN[p.src]||p.src)],["Position",p.lat!=null?p.lat.toFixed(5)+", "+p.lon.toFixed(5)+" (+/- "+(p.ce<9999999?Math.round(p.ce)+" m":"?")+")":"none"]]);$("tt-note").style.display=s.turtletak.installed&&t.source=="TurtleTAK"?"block":"none";
    kv("k-certs",[["Server",esc(t.host+":"+t.port+" ("+t.proto+")")+(t.source=="TurtleTAK"?" - TurtleTAK's":"")],["Client certificate",s.certs["client.pem"]?'<span class="ok">loaded</span>':'<span class="warn">not loaded</span>'],s.cert&&s.cert.days!=null?["Certificate expires",`<span class="${s.cert.days<0?"crit":s.cert.days<=30?"warn":"ok"}">${new Date(s.cert.expires*1000).toLocaleDateString()} (${s.cert.days} days)</span>`]:null,["Truststore",s.certs["ca.pem"]?'<span class="ok">loaded</span>':'<span class="dim">not loaded</span>'],["Status",t.state=="connected"?'<span class="ok">connected</span>':`<span class="warn">${esc(t.state)} ${esc(t.error)}</span>`]])}}
function convList(){const m=ST.mesh,map={};m.channels.forEach(c=>map["ch:"+c.index]={k:"ch:"+c.index,title:c.name,last:0,n:0});
  m.chat.forEach(c=>{const k=c.conv;if(!map[k])map[k]={k,title:c.label||k,last:0,n:0};map[k].last=Math.max(map[k].last,c.t);map[k].n++});return Object.values(map).sort((a,b)=>(a.k.startsWith("ch")?0:1)-(b.k.startsWith("ch")?0:1)||b.last-a.last)}
function renderChat(){const cl=convList(),cv=$("convs");const sig=JSON.stringify(cl.map(c=>[c.k,c.n]))+conv;if(cv._s!=sig){cv._s=sig;cv.innerHTML=cl.map(c=>`<div class="conv ${c.k==conv?"on":""}" onclick="conv='${c.k}';lss('tm_conv',conv);renderChat()"><b>${esc(c.title)}</b><br><span class="dim">${c.n} messages${c.last?" &middot; "+ago(ST.now-c.last)+" ago":""}</span></div>`).join("")}
  const msgs=ST.mesh.chat.filter(c=>c.conv==conv),log=$("chatlog"),s2=conv+msgs.length+(msgs.length?msgs[msgs.length-1].status:"");if(log._s!=s2){log._s=s2;log.innerHTML=msgs.map(c=>`<div class="msg ${c.dir}"><div class="h">${esc(c.from)} &middot; ${tm(c.t)}${c.snr!=null?" &middot; SNR "+c.snr:""}${c.dir=="out"?" &middot; "+esc(c.status||"")+(c.source&&c.source!="console"?" ("+esc(c.source)+")":""):""}</div>${esc(c.text)}</div>`).join("")||'<p class="dim">No messages.</p>';log.scrollTop=1e9}}
function renderNodes(){const m=ST.mesh,q=$("nd-q").value.toLowerCase(),recent=$("nd-recent").checked;$("nd-learn").textContent=m.learning?"Learning the mesh for "+ago(m.learning)+" more: nodes heard now count as known, and new-node alerts start after that.":m.known+" known nodes. A node not seen before raises a New mesh node alert.";
  const rows=m.nodes.filter(n=>!n.me&&(!recent||(n.age!=null&&n.age<86400))&&(!q||(n.name+n.id+n.short+n.hw).toLowerCase().includes(q))),tb=$("tb-nodes");const sig=JSON.stringify(rows.map(n=>[n.id,n.name,n.watch,n.sensor,Math.round((n.age||0)/60),n.battery,n.snr,n.trace,n.known,n.quiet]));
  if(tb._s==sig||tb.contains(document.activeElement))return;tb._s=sig;
  tb.innerHTML="<tr><th>Node</th><th>Label</th><th>Watch</th><th>Sensor</th><th>Heard</th><th>Battery</th><th>SNR / hops</th><th>Range</th><th></th></tr>"+rows.map(n=>`<tr><td><b>${esc(n.long||n.id)}</b> <span class="dim">${esc(n.short)} ${esc(n.id)}</span><br><span class="dim">${esc(n.hw)} ${esc(n.role)}</span>${n.known?"":' <span class="tag new">NEW</span>'}${n.quiet?' <span class="tag bad">QUIET</span>':""}${n.trace?'<br><span class="dim">'+esc(n.trace)+"</span>":""}</td>
   <td><input value="${esc(n.label)}" size="12" placeholder="label" onchange="act('node_meta',{id:'${n.id}',name:this.value})"></td><td><input type="checkbox" ${n.watch?"checked":""} onchange="act('node_meta',{id:'${n.id}',watch:this.checked})"></td><td><input type="checkbox" ${n.sensor?"checked":""} onchange="act('node_meta',{id:'${n.id}',sensor:this.checked})"></td>
   <td>${ago(n.age)}${n.age!=null?" ago":""}</td><td>${n.battery==null?"":n.battery>100?"powered":n.battery+"%"}</td><td>${n.snr==null?"":n.snr+" dB"} ${n.hops==null?"":"/ "+n.hops}</td><td>${n.dist==null?"":(n.dist<1000?n.dist+" m":(n.dist/1000).toFixed(1)+" km")+" "+n.brg+"&deg;"}</td>
   <td><button class="b sm" onclick="conv='dm:${n.id}';lss('tm_conv',conv);go('chat')">DM</button> <button class="b sm" onclick="act('traceroute',{id:'${n.id}'})">Trace</button> <button class="b sm" onclick="act('req_pos',{id:'${n.id}'})">Position</button></td></tr>`).join("")}
async function sendMesh(e){e.preventDefault();const t=$("m-text").value.trim();if(!t)return;const o={text:t};if(conv.startsWith("dm:"))o.to=conv.slice(3);else o.channel=+conv.slice(3);await act("mesh_send",o);$("m-text").value="";$("m-len").textContent="0/200"}
async function sendTak(e){e.preventDefault();const t=$("tk-text").value.trim();if(!t)return;await act("chat",{text:t,to:$("tk-to").value});$("tk-text").value=""}
function initMap(){if(map||!window.L){if(!window.L){const sc=document.createElement("script");sc.src="/static/leaflet.js";sc.onload=initMap;document.head.appendChild(sc);const ln=document.createElement("link");ln.rel="stylesheet";ln.href="/static/leaflet.css";document.head.appendChild(ln)}return}
  map=L.map("map");mapSource((ST&&ST.tiles&&ST.tiles.source)||"usgs_topo");layers=L.layerGroup().addTo(map);const p=ST&&ST.pos;map.setView(p&&p.lat!=null?[p.lat,p.lon]:[20,0],p&&p.lat!=null?13:2);
  map.on("click",e=>{if(confirm("Place the Hub at "+e.latlng.lat.toFixed(6)+", "+e.latlng.lng.toFixed(6)+"?"))act("set_pos",{lat:e.latlng.lat,lon:e.latlng.lng})});drawMap()}
function mapSource(src){if(!map)return;if(tileLayer)map.removeLayer(tileLayer);const osm=src=="osm";tileLayer=L.tileLayer("/tiles/"+src+"/{z}/{x}/{y}",{maxZoom:osm?19:16,attribution:osm?"&copy; OpenStreetMap contributors":"USGS The National Map"}).addTo(map)}
function dot(c,sz){sz=sz||14;return L.divIcon({className:"",html:`<div style="width:${sz}px;height:${sz}px;border-radius:50%;background:${c};border:2px solid #000"></div>`,iconSize:[sz,sz],iconAnchor:[sz/2,sz/2]})}
function drawMap(){const t2=ST.tiles||{},sel=$("mp-src");if(!sel.options.length){sel.innerHTML=Object.entries(t2.sources||{}).map(([k,v])=>`<option value="${k}">${esc(v)}</option>`).join("");sel.value=t2.source}
  const j=t2.job;$("mp-st").textContent=(j&&j.running?`Saving ${j.done}/${j.total} tiles... `:"")+`Saved maps: ${t2.mb} of ${t2.limit_mb} MB`;if(!map)return;layers.clearLayers();const p=ST.pos;
  if(p.lat!=null)L.marker([p.lat,p.lon],{icon:dot("#ffffff",16)}).bindTooltip(ST.callsign+" (Hub)",{permanent:true,direction:"right"}).addTo(layers);
  ST.mesh.nodes.filter(n=>!n.me&&n.lat!=null).forEach(n=>{const col=n.quiet?"#ff5c5c":n.sensor?"#f2b631":n.age!=null&&n.age<3600?"#67ea94":"#5f7d68";L.marker([n.lat,n.lon],{icon:dot(col)}).bindTooltip(esc(n.name)+(n.age!=null?" ("+ago(n.age)+")":"")).addTo(layers)});
  ST.contacts.forEach(c=>L.marker([c.lat,c.lon],{icon:dot("#4fb3ff",12)}).bindTooltip(esc(c.callsign)).addTo(layers))}
function bnds(){const b=map.getBounds();return {s:b.getSouth(),w:b.getWest(),n:b.getNorth(),e:b.getEast()}}
async function saveArea(){if(!map)return;const src=$("mp-src").value,zmax=+$("mp-z").value,zmin=Math.max(1,map.getZoom()-4);try{const r=await api("/api/action",{method:"POST",body:JSON.stringify({action:"tiles_plan",src,bounds:bnds(),zmin,zmax})});if(confirm("Save "+r.msg+" of this view on the Hub?"))act("tiles_download",{src,bounds:bnds(),zmin,zmax})}catch(e){toast(e.message,1)}}
async function loadRadio(){try{radioV=await api("/api/radio");const rp=$("r-pos");rp.innerHTML='<option value="-1">off</option>'+chanOpts(true);rp.value=String(ST?ST.mesh_pos_channel:-1);const r=radioV;$("r-long").value=r.owner.long;$("r-short").value=r.owner.short;kv("k-meta",[["Hardware",esc(r.metadata.hw)],["Firmware",esc(r.metadata.firmware)],["Region",esc(r.metadata.region)]]);
  $("tb-ch").innerHTML="<tr><th>#</th><th>Name</th><th>Role</th><th>Key</th><th>Uplink / downlink</th></tr>"+r.channels.map(c=>`<tr><td>${c.index}</td><td>${esc(c.name||(c.index==0?"(preset name)":""))}</td><td>${["disabled","primary","secondary"][c.role]||c.role}</td><td>${esc(c.psk_kind||"")}${c.role?(/^AES/.test(c.psk_kind||"")?' <span class="ok">(private)</span>':' <span class="warn">(public)</span>'):""}</td><td>${c.uplink?"up":""} ${c.downlink?"down":""}</td></tr>`).join("");
  $("c-idx").innerHTML=[0,1,2,3,4,5,6,7].map(i=>`<option value="${i}">Channel ${i}</option>`).join("");$("share").innerHTML=r.share_url?'Share link (carries the channel keys): <span style="word-break:break-all">'+esc(r.share_url)+"</span>":"";
  const v=r.values||{};$("r-set").innerHTML=(r.settings||[]).map(st=>{const cur=v[st.key];let inp;if(st.type=="bool")inp=`<select data-k="${st.key}"><option value="">${cur?"on":"off"} (current)</option><option value="true">on</option><option value="false">off</option></select>`;
    else if(st.type=="enum"){const lab=((st.choices||[]).find(c=>c[0]==cur)||[0,cur==null?"?":cur])[1];inp=`<select data-k="${st.key}"><option value="">${esc(lab)} (current)</option>`+(st.choices||[]).map(([k,l])=>`<option value="${k}">${esc(l)}</option>`).join("")+"</select>"}
    else if(st.type=="secret")inp=`<input type="password" data-k="${st.key}" placeholder="${cur?"set":"not set"} - blank keeps it">`;else inp=`<input data-k="${st.key}" placeholder="${esc(cur==null?"":cur)}">`;return `<label>${esc(st.label)}</label>${inp}`}).join("")
  const sr=$("r-conn");api("/api/cfg").then(c=>{const g=k=>(c.find(x=>x.key==k)||{}).value||"";sr.value=g("RADIO_CONN")||"wifi";$("r-host").value=g("RADIO_HOST");$("r-dev").value=g("RADIO_DEV")})}catch(e){toast(e.message,1)}}
function saveRadio(){const ch={};document.querySelectorAll("#r-set [data-k]").forEach(i=>{if(i.value==="")return;let v=i.value;if(v=="true")v=true;else if(v=="false")v=false;else if(/^-?\d+$/.test(v))v=+v;ch[i.dataset.k]=v});if(!Object.keys(ch).length)return toast("Nothing changed",1);if(confirm("Send "+Object.keys(ch).length+" change(s) to the radio? It may restart."))act("set_radio",{changes:ch}).then(loadRadio)}
function saveChan(){const o={index:+$("c-idx").value};if($("c-name").value)o.name=$("c-name").value;if($("c-psk").value)o.psk=$("c-psk").value;if($("c-role").value!=="")o.role=+$("c-role").value;act("set_channel",o).then(loadRadio)}
function saveConn(){setCfg({RADIO_CONN:$("r-conn").value,RADIO_HOST:$("r-host").value.trim(),RADIO_DEV:$("r-dev").value.trim()||"auto"}).then(()=>act("radio_reconnect"))}
async function loadCfg(){if(cfgLoaded)return;try{const c=await api("/api/cfg");cfgLoaded=true;$("cfgform").innerHTML=c.map(r=>r.section?`<h4>${esc(r.key.replace(/^#\s*/,""))}</h4>`:`<label>${esc(r.key)}</label><input data-k="${r.key}" ${r.key=="UID"?"readonly":""} ${r.secret?'type="password" placeholder="'+(r.set?"(set - blank keeps it)":"")+'"':""} value="${esc(r.value)}">`).join("")}catch(e){toast(e.message,1)}}
async function saveCfg(){const o={};document.querySelectorAll("#cfgform input").forEach(i=>{if(i.type=="password"&&i.value==="")return;o[i.dataset.k]=i.value});await setCfg(o)}
function chanOpts(privateOnly){return (ST?ST.mesh.channels:[]).map(c=>`<option value="${c.index}" ${privateOnly&&!c.private?"disabled":""}>Channel ${c.index}: ${esc(c.name)}${c.private?" (own key)":" (public key"+(privateOnly?" - not allowed)":")")}</option>`).join("")}
function fillDest(){const dest=$("al-dest"),cur=dest.value,chans=ST?ST.mesh.channels:[],sig=JSON.stringify(chans);if(dest._s===sig)return;dest._s=sig;
  dest.innerHTML='<option value="off">off</option>'+(chans.length?chanOpts(false):'<option value="" disabled>no channels yet - the radio is not connected</option>')+'<option value="dm">direct message to a node</option>';
  if(cur&&[...dest.options].some(o=>o.value==cur&&!o.disabled))dest.value=cur}
function loraNow(){const l=ST&&ST.lora;if(!l)return "";return l.on?"Right now: alerts go out over LoRa to <b>"+esc(l.to)+"</b>"+(l.public?' <span class="warn">(public channel)</span>':"")+", "+esc(l.min)+" and up. Change it here and Save.":"Right now: alerts are <b>not</b> sent on the mesh. Pick a channel or a node and Save to turn them on."}
function loraDest(){const d=$("al-dest").value,w=$("al-lwarn");$("al-lnow").innerHTML=loraNow();$("al-to").style.display=d=="dm"?"inline-block":"none";const c=(ST?ST.mesh.channels:[]).find(x=>String(x.index)==d);
  if(c&&!c.private){w.style.display="block";w.textContent=c.name+" uses a public key: anyone on it can read the alerts, which can include device names, IP and MAC addresses. A channel with its own key, or a direct message, is safer."}else w.style.display="none"}
function loraCfg(){const d=$("al-dest").value;if(d=="off")return {LORA_ALERTS:"0",LORA_ALERT_TO:""};if(d=="dm")return {LORA_ALERTS:"1",LORA_ALERT_TO:$("al-to").value.trim()};return {LORA_ALERTS:"1",LORA_ALERT_CHANNEL:d,LORA_ALERT_TO:""}}
async function loadAlertCfg(){try{const c=await api("/api/cfg"),g=k=>(c.find(r=>r.key==k)||{}).value||"";const on=g("ALERTS_ON").split(",");$("al-kinds").innerHTML=(ST.alert_kinds||[]).map(([k,l])=>`<label style="margin-right:12px"><input type="checkbox" class="al-k" value="${k}" ${on.includes(k)?"checked":""}> ${esc(l)}</label>`).join("");
  $("al-marker").value=g("MARKER_MIN_LEVEL")||"warning";$("al-chat").value=g("CHAT_MIN_LEVEL")||"info";$("al-lora").value=g("LORA_ALERT_MIN")||"warning";$("al-to").value=g("LORA_ALERT_TO");const dest=$("al-dest");fillDest();dest.value=g("LORA_ALERT_TO")?"dm":(g("LORA_ALERTS")=="1"&&g("LORA_ALERT_CHANNEL")!==""?g("LORA_ALERT_CHANNEL"):"off");loraDest();$("al-quiet").value=g("QUIET_HOURS");$("al-qcrit").checked=g("QUIET_CRITICAL")!="0"}catch(e){}}
function saveAlertCfg(){setCfg({ALERTS_ON:[...document.querySelectorAll(".al-k:checked")].map(i=>i.value).join(","),MARKER_MIN_LEVEL:$("al-marker").value,CHAT_MIN_LEVEL:$("al-chat").value,LORA_ALERT_MIN:$("al-lora").value,...loraCfg(),QUIET_HOURS:$("al-quiet").value.trim(),QUIET_CRITICAL:$("al-qcrit").checked?"1":"0"})}
function pane(k,btn){["cp","cr","en"].forEach(x=>$("p-"+x).style.display=x==k?"block":"none");document.querySelectorAll("#seg button").forEach(b=>b.classList.toggle("on",b==btn))}
async function sendFile(f,hdrs){const h=Object.assign({"X-Filename":f.name,"Content-Type":"application/octet-stream"},hdrs||{});for(const k in h)h[k]=encodeURIComponent(h[k]);return api("/api/upload",{method:"POST",headers:h,body:await f.arrayBuffer()})}
async function importPkg(){const f=$("cp-file").files[0];if(!f)return toast("Choose the .zip first",1);const h={};if($("cp-cpw").value)h["X-Client-Password"]=$("cp-cpw").value;if($("cp-tpw").value)h["X-CA-Password"]=$("cp-tpw").value;try{const d=await sendFile(f,h);toast(d.msg);refresh()}catch(e){toast(e.message,1)}}
async function saveCerts(){try{const cfg={TAK_FROM_TURTLETAK:"0",TAK_PROTO:$("cr-proto").value};if($("cr-host").value.trim())cfg.TAK_HOST=$("cr-host").value.trim();if($("cr-port").value.trim())cfg.TAK_PORT=$("cr-port").value.trim();
  for(const [id,kind,pw] of [["cr-client","client","cr-cpw"],["cr-trust","ca","cr-tpw"]]){const f=$(id).files[0];if(!f)continue;const h={"X-Cert-Kind":kind};if($(pw).value)h["X-Cert-Password"]=$(pw).value;await sendFile(f,h)}
  await api("/api/cfg",{method:"POST",body:JSON.stringify(cfg)});toast("Saved - connecting");refresh()}catch(e){toast(e.message,1)}}
async function enroll(){if($("en-host").value.trim())await setCfg({TAK_HOST:$("en-host").value.trim(),TAK_FROM_TURTLETAK:"0"});toast("Enrolling - up to a minute");await act("enroll",{user:$("en-u").value,password:$("en-p").value});$("en-p").value=""}
async function diag(){const d=$("diag");d.style.display="block";d.textContent="Testing...";try{d.textContent=(await api("/api/action",{method:"POST",body:JSON.stringify({action:"diagnose"})})).msg}catch(e){d.textContent=e.message}}
function setPos(){act("set_pos",{lat:$("lat").value,lon:$("lon").value,site:$("site").value})}
function syncChecks(){api("/api/cfg").then(c=>{const g=k=>(c.find(r=>r.key==k)||{}).value;$("boot").checked=g("RUN_AT_BOOT")=="1";$("ledon").checked=g("LED")!="0";
  $("loc-mode").value=g("LOC_MODE")||"auto";$("loc-atak").value=g("MY_ATAK")||"";const ln=$("loc-node"),cur=g("MY_NODE")||"";
  ln.innerHTML='<option value="">none</option>'+(ST?ST.mesh.nodes.filter(n=>!n.me):[]).map(n=>`<option value="${n.id}">${esc(n.name)} (${n.id})</option>`).join("");if(cur&&![...ln.options].some(o=>o.value==cur))ln.innerHTML+=`<option value="${esc(cur)}">${esc(cur)}</option>`;ln.value=cur}).catch(()=>{})}
function saveLoc(){setCfg({LOC_MODE:$("loc-mode").value,MY_ATAK:$("loc-atak").value.trim(),MY_NODE:$("loc-node").value})}
const LOCN={radio:"radio GPS",gps:"USB GPS",atak:"my phone (ATAK)",mesh:"my phone (mesh)",site:"saved site",manual:"manual",ip:"network (city level)","last known":"last known",none:"none yet"};
async function loadLog(){try{$("log").textContent=await api("/api/log");$("log").scrollTop=1e9}catch(e){}}
$("m-text").addEventListener("input",e=>$("m-len").textContent=new TextEncoder().encode(e.target.value).length+"/200");
async function refresh(){try{ST=await api("/api/state");$("login").style.display="none";$("app").style.display="block";render()}catch(e){}}
(async()=>{nav();await refresh();if(ST)go(tab);else showLogin()})();setInterval(refresh,4000);
</script>
</body>
</html>
TURTLEMESH_HTML

# ---- self-check: a cut-off or damaged payload.sh, or a missing Python module, is reported -------
fail() {
    TM_STARTED=1
    echo "$(date '+%Y-%m-%d %H:%M:%S') [error] $1" >> "$BASE/logs/console.log"
    echo "TurtleMesh: $1" >&2
    LED FAIL 2>/dev/null
    NOTIFY_ERROR TurtleMesh "$1" 2>/dev/null
    exit 1
}
END_MARK="$(tail -c 40 "$APP/index.html" 2>/dev/null)"
case "$END_MARK" in *"</html>"*) ;; *) fail "payload.sh is incomplete (cut off while copying?) - copy the whole file again" ;; esac
[ -s "$APP/static/leaflet.js" ] && [ -s "$APP/static/leaflet.css" ] || fail "map files did not unpack - payload.sh is damaged, copy it again"
ERR=$(cd "$APP" && "$PY" -c 'import ast, sys
for f in sys.argv[1:]:
    ast.parse(open(f, "rb").read(), f)' turtlemesh.py ttcrypto.py meshproto.py radiocfg.py sigint.py 2>&1) \
    || fail "payload.sh is damaged: $(echo "$ERR" | tail -n 1)"
ERR=$(cd "$APP" && "$PY" -c 'import collections, hashlib, json, select, socket, ssl, struct, subprocess, threading, uuid, zipfile, zlib
import meshproto, radiocfg, sigint, ttcrypto' 2>&1) \
    || fail "Python on this Hub is missing something: $(echo "$ERR" | tail -n 1)"

[ -n "$TURTLESHELL" ] || LED SETUP 2>/dev/null    # in TurtleShell, TurtleTAK owns the LED
cd "$APP" || fail "cannot open $APP"
TM_STARTED=1
trap - EXIT
echo $$ > "$BASE/turtlemesh.pid"
# exec keeps the PID, so the Hub's payload stop ends the service too
exec "$PY" -u "$APP/turtlemesh.py" >> "$BASE/logs/console.log" 2>&1
TURTLESHELL_MESH

for f in turtletak.sh turtlemesh.sh; do
    tail -c 2000 "$SHELL_BASE/$f" | grep -q "^exec " || {
        TS_STARTED=1; log "[error] $f is incomplete - copy the whole payload.sh again"
        LED FAIL 2>/dev/null; NOTIFY_ERROR TurtleShell "payload.sh is incomplete ($f) - copy the whole file again" 2>/dev/null; exit 1; }
done
TS_STARTED=1
trap - EXIT
echo $$ > "$SHELL_BASE/turtleshell.pid"
log "TurtleShell 1.0.1 starting: TurtleTAK 1.0.2 + TurtleMesh 1.0.2"

TT_PID=""; TM_PID=""; STOPPING=""
start_tak()  { bash "$SHELL_BASE/turtletak.sh" & TT_PID=$!; log "TurtleTAK started (pid $TT_PID)"; }
start_mesh() { TURTLESHELL=1 bash "$SHELL_BASE/turtlemesh.sh" & TM_PID=$!; log "TurtleMesh started (pid $TM_PID)"; }
stop_all() {
    STOPPING=1
    log "stopping both services"
    # each payload hands over to its Python service with exec, so these are the services themselves
    [ -n "$TT_PID" ] && kill "$TT_PID" 2>/dev/null
    [ -n "$TM_PID" ] && kill "$TM_PID" 2>/dev/null
    sleep 2
    [ -n "$TT_PID" ] && kill -9 "$TT_PID" 2>/dev/null
    [ -n "$TM_PID" ] && kill -9 "$TM_PID" 2>/dev/null
    rm -f "$SHELL_BASE/turtleshell.pid"
    exit 0
}
trap stop_all TERM INT HUP

start_tak
sleep 5                         # TurtleTAK first: it owns the LED and TurtleMesh reads its TAK settings
start_mesh

# Keep both running: a service that stops is started again (at most once a minute each)
TT_LAST=$(date +%s); TM_LAST=$TT_LAST
while [ -z "$STOPPING" ]; do
    sleep 15 & wait $!
    now=$(date +%s)
    if ! kill -0 "$TT_PID" 2>/dev/null && [ $((now - TT_LAST)) -ge 60 ]; then
        log "TurtleTAK stopped - starting it again"; TT_LAST=$now; start_tak
    fi
    if ! kill -0 "$TM_PID" 2>/dev/null && [ $((now - TM_LAST)) -ge 60 ]; then
        log "TurtleMesh stopped - starting it again"; TM_LAST=$now; start_mesh
    fi
done
