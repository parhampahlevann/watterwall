#!/bin/bash

# ============================================================================
# WaterWall Tunnel Manager (Updated & Fixed for v1.46.96)
# Release: https://github.com/radkesvat/WaterWall/releases/tag/v1.46.96
#
# FIXED VERSION — changes are marked with "# FIX:" comments. Summary of what
# was actually wrong and was changed (see chat for full explanation):
#   1) install_core(): asset download now asks the GitHub API for the real
#      asset list of the tag and matches it to CPU/arch, instead of only
#      trying a few hardcoded filenames. Every downloaded zip is also
#      integrity-checked with `unzip -t` before we trust it.
#   2) config_halfduplex_tunnel(): user input (IP, port, SNI, password) is now
#      validated and JSON-escaped before being written into dev-ir.json, and
#      the resulting file is checked with `jq empty` before the service is
#      restarted. Previously an empty/invalid entry (e.g. just pressing Enter
#      at the IP prompt, or a tunnel port too close to 23/65535) silently
#      produced a broken config that made WaterWall refuse to start.
#   3) setup_systemd_service(): added StartLimitIntervalSec=0 so systemd
#      doesn't permanently mark the unit "failed" after a few quick restarts
#      while you're still dialing in the config.
#   4) restart_service(): waits properly for the service to come up (instead
#      of a flat 1-second sleep) and on failure prints the real error from
#      journalctl/core.log right there, instead of just "failed, check logs".
#   5) check_tunnel_status(): now distinguishes "crashing/failed" from
#      "configured but stopped", which used to look identical to the user.
#   6) core.json logging: raised core/network loglevel so startup errors are
#      actually written to core.log / the console instead of being filtered
#      out at WARN level.
#   7) New menu option "Test Run" runs WaterWall in the foreground with
#      --verbose so you can see the exact startup error live.
#   8) reverse-secret is now set (derived from your Reality password) on both
#      ReverseServer and ReverseClient, which was previously left at the
#      default/public value.
#   9) Reality password is now fixed to "1234" on both Iran and Kharej sides
#      and is no longer prompted for, so the two sides can't drift out of
#      sync by mistyping it on one side.
#  10) SNI default (used when you just press Enter) is now "digikala.com" on
#      both sides instead of "www.speedtest.net".
#  11) check_tunnel_status() / restart_service(): fixed a real bug where a
#      crash-looping WaterWall process (bad config, port already in use,
#      upstream unreachable, etc.) was silently reported as just
#      "Configured (Stopped)" with no indication anything was wrong. This is
#      a direct side effect of fix #3 (StartLimitIntervalSec=0): because
#      systemd is told to restart the service forever and never give up,
#      `systemctl is-failed` basically never becomes true during a crash
#      loop, so the old status check had no way to detect it and silently
#      fell through to the vague "Stopped" label. The status check and the
#      post-config restart now also look at the service's SubState and
#      restart count, so a crash loop is reported as "Crash-looping" with
#      the actual error shown, instead of pretending nothing happened. This
#      is almost certainly why the Kharej (foreign) side looked "stopped"
#      and never came up after install/config.
#  12) install_core(): /proc/cpuinfo-based CPU detection (avx512f/modern/
#      old-cpu) isn't always right on every VPS/VM — some hosts report CPU
#      flags the guest can't actually use. WaterWall's own binary detects
#      this correctly at startup and exits with "This Waterwall binary was
#      built for a newer x86-64 CPU than this machine/OS exposes", but the
#      old script never looked at that output, so it just crash-looped
#      forever. Install now smoke-tests the binary right after installing it
#      and automatically re-downloads the old-cpu build if that exact message
#      shows up, instead of leaving a tunnel that can never start.
#  13) config_halfduplex_tunnel(), IRAN server side: the previous config used
#      TWO TcpListener nodes (23..tunnel_port-1 and tunnel_port+1..65535)
#      both set to "next": "header". WaterWall v1.46.96 rejects this outright
#      at startup:
#        FATAL Node Map Failure: Node (users_inbound_high) wanted to bind to
#        (header) which is already bounded by users_inbound_low
#      — a node can only be the "next" target of ONE other node, so two
#      listeners can't both feed the same downstream node. There's no way to
#      carve a hole out of the middle of a single-range listener, so this is
#      now a SINGLE "users_inbound" listener covering 23..tunnel_port-1, and
#      the tunnel port's default moved from 443 to 65432 (a high, normally
#      unused port) so that one range still covers virtually every real port
#      users would connect on. This only matters on the IRAN side; the Kharej
#      (client) config was already a single linear chain with no fan-in.
# ============================================================================

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
NC='\033[0m'

WW_VERSION="v1.46.96"
INSTALL_DIR="/root/waterwall"
SERVICE_FILE="/etc/systemd/system/waterwall.service"

# Check root privilege
if [[ $EUID -ne 0 ]]; then
    echo -e "${RED}Fatal error:${NC} Please run this script with root privilege (sudo)."
    exit 1
fi

mkdir -p "$INSTALL_DIR/log" "$INSTALL_DIR/libs"

# FIX: small helpers used by the tunnel configurator so user input can never
# produce a syntactically-broken dev-ir.json (which made WaterWall refuse to
# start, with the systemd unit staying stuck in "inactive/failed").
json_escape() {
    local s="$1"
    s="${s//\\/\\\\}"
    s="${s//\"/\\\"}"
    printf '%s' "$s"
}

validate_ipv4() {
    local ip="$1"
    [[ "$ip" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]] || return 1
    local IFS='.'
    local -a o=($ip)
    local n
    for n in "${o[@]}"; do
        (( n >= 0 && n <= 255 )) || return 1
    done
    return 0
}

# FIX (#11): small helper to read one systemd property without repeating the
# `systemctl show -p ... --value` boilerplate everywhere.
systemd_prop() {
    local prop="$1"
    systemctl show -p "$prop" --value waterwall.service 2>/dev/null
}

install_dependencies() {
    local missing=()
    for cmd in jq curl wget unzip; do
        if ! command -v "$cmd" &> /dev/null; then
            missing+=("$cmd")
        fi
    done

    if [ ${#missing[@]} -gt 0 ]; then
        echo -e "${YELLOW}Installing required packages: ${missing[*]}...${NC}"
        if command -v apt-get &> /dev/null; then
            apt-get update -y && apt-get install -y "${missing[@]}"
        elif command -v dnf &> /dev/null; then
            dnf install -y "${missing[@]}"
        elif command -v yum &> /dev/null; then
            yum install -y "${missing[@]}"
        else
            echo -e "${RED}Error: Unsupported package manager. Please install manually: ${missing[*]}${NC}"
            exit 1
        fi
    fi
}

fetch_server_info() {
    local ip_info
    ip_info=$(curl -sS --max-time 4 "http://ip-api.com/json")
    SERVER_IP=$(echo "$ip_info" | jq -r '.query // empty')
    [[ -z "$SERVER_IP" ]] && SERVER_IP=$(hostname -I | awk '{print $1}')
    SERVER_COUNTRY=$(echo "$ip_info" | jq -r '.country // "Unknown"')
    SERVER_ISP=$(echo "$ip_info" | jq -r '.isp // "Unknown"')
}

check_core_status() {
    if [[ -x "$INSTALL_DIR/Waterwall" && -f "$INSTALL_DIR/core.json" ]]; then
        echo -e "${GREEN}Installed ($WW_VERSION)${NC}"
    else
        echo -e "${RED}Not installed${NC}"
    fi
}

# FIX (#5, revised in #11): previously this only distinguished "Active" vs
# "Configured (Stopped)" vs "Disabled", using `systemctl is-failed` to catch
# a crashing service. But setup_systemd_service() sets
# StartLimitIntervalSec=0 (fix #3) specifically so systemd keeps restarting
# the service forever instead of giving up — which also means systemd will
# essentially never mark the unit "failed" during a crash loop, so
# `is-failed` was not actually able to catch this case. We now additionally
# check the unit's SubState: while systemd is between crash-restarts the
# SubState is "auto-restart" (or "start"/"start-pre" momentarily), which is
# the real signal of a crash loop that the old code missed entirely.
check_tunnel_status() {
    local substate
    substate=$(systemd_prop SubState)

    if systemctl is-active --quiet waterwall.service 2>/dev/null; then
        echo -e "${GREEN}Active (Running)${NC}"
    elif [[ "$substate" == "auto-restart" || "$substate" == "start" || "$substate" == "start-pre" ]]; then
        echo -e "${RED}Crash-looping (auto-restarting) - see Status & Logs / Test Run${NC}"
    elif systemctl is-failed --quiet waterwall.service 2>/dev/null; then
        echo -e "${RED}Failed (crashing - see Status & Logs / Test Run)${NC}"
    elif [[ -f "$INSTALL_DIR/dev-ir.json" ]]; then
        echo -e "${YELLOW}Configured (Stopped)${NC}"
    else
        echo -e "${RED}Disabled${NC}"
    fi
}

menu() {
    clear
    WATER_CORE=$(check_core_status)
    WATER_TUNNEL=$(check_tunnel_status)

    echo "+-----------------------------------------------------------------------------------------------------------------------+"
    echo "| __          __        _               __          __        _  _   _______                             _              |"
    echo "| \ \        / /       | |              \ \        / /       | || | |__   __|                           | |             |"
    echo "|  \ \  /\  / /   __ _ | |_   ___  _ __  \ \  /\  / /   __ _ | || |    | |    _   _  _ __   _ __    ___ | |             |"
    echo "|   \ \/  \/ /   / _  || __| / _ \| '__|  \ \/  \/ /   / _  || || |    | |   | | | || '_ \ |  _ \  / _ \| |             |"
    echo "|    \  /\  /   | (_| || |_ |  __/| |      \  /\  /   | (_| || || |    | |   | |_| || | | || | | ||  __/| |             |"
    echo "|     \/  \/     \__,_| \__| \___||_|       \/  \/     \__,_||_||_|    |_|    \__,_||_| |_||_| |_| \___||_| ($WW_VERSION)  |"
    echo "+-----------------------------------------------------------------------------------------------------------------------+"
    echo -e "| ${GREEN}Server Country    |${NC} $SERVER_COUNTRY"
    echo -e "| ${GREEN}Server IP         |${NC} $SERVER_IP"
    echo -e "| ${GREEN}Server ISP        |${NC} $SERVER_ISP"
    echo -e "| ${GREEN}WaterWall CORE    |${NC} $WATER_CORE"
    echo -e "| ${GREEN}WaterWall Tunnel  |${NC} $WATER_TUNNEL"
    echo "+-----------------------------------------------------------------------------------------------------------------------+"
    echo -e "| ${YELLOW}Please choose an option:${NC}"
    echo "+-----------------------------------------------------------------------------------------------------------------------+"
    echo -e "$1"
    echo "+-----------------------------------------------------------------------------------------------------------------------+"
    echo -e "${NC}"
}

init() {
    menu "| 1 - Install / Update Core ($WW_VERSION)\n| 2 - Config Tunnel\n| 3 - Status & Logs\n| 4 - Restart Tunnel Service\n| 5 - Test Run (foreground debug)\n| 9 - Uninstall\n| 0 - Exit"

    read -rp "Enter option number: " choice
    case $choice in
        1) install_core ;;
        2) tunnel_menu ;;
        3) status_tunnel ;;
        4) restart_service ;;
        5) test_run_foreground ;;
        9) uninstall_waterwall ;;
        0)
            echo -e "${GREEN}Exiting program...${NC}"
            exit 0
            ;;
        *)
            echo -e "${RED}Invalid option.${NC}"
            sleep 1
            init
            ;;
    esac
}

# FIX (main install bug, kept as its own function for #12 below): the old
# script only ever tried 1-2 hardcoded asset filenames per arch, so if
# upstream ever renamed/reordered release assets the download (and therefore
# the whole install) would silently fail. We now ask the GitHub API for the
# REAL list of asset names/urls on this tag and pick the best match for the
# given CPU/arch; the old hardcoded names are kept only as a last-resort
# fallback. Every downloaded zip is integrity-checked with `unzip -t`, then
# extracted into $INSTALL_DIR and the binary normalized to ./Waterwall.
# Returns 0 and leaves an executable $INSTALL_DIR/Waterwall in place on
# success, 1 otherwise.
fetch_and_extract_waterwall() {
    local arch_tag="$1"
    local cpu_tag="$2"

    local -a candidate_urls=()
    local api_json
    api_json=$(curl -sSL --max-time 10 "https://api.github.com/repos/radkesvat/WaterWall/releases/tags/${WW_VERSION}" 2>/dev/null)

    if [[ -n "$api_json" ]] && echo "$api_json" | jq -e '.assets' &>/dev/null; then
        local pattern
        if [[ "$arch_tag" == "x64" ]]; then
            case "$cpu_tag" in
                avx512f) pattern='linux.*avx512f.*(x64|amd64)' ;;
                old-cpu) pattern='linux.*old.?cpu.*(x64|amd64)' ;;
                *)       pattern='linux.*(x64|amd64)' ;;
            esac
        else
            case "$cpu_tag" in
                old-cpu) pattern='linux.*old.?cpu.*(arm64|aarch64)' ;;
                *)       pattern='linux.*(arm64|aarch64)' ;;
            esac
        fi

        while IFS= read -r u; do
            [[ -n "$u" ]] && candidate_urls+=("$u")
        done < <(echo "$api_json" | jq -r --arg pat "$pattern" \
            '.assets[] | select(.name | test($pat; "i")) | .browser_download_url' 2>/dev/null)

        # Looser match inside the API data if the specific cpu-flavor wasn't found
        if [[ ${#candidate_urls[@]} -eq 0 ]]; then
            local generic_pat
            if [[ "$arch_tag" == "x64" ]]; then
                generic_pat='linux.*(x64|amd64)'
            else
                generic_pat='linux.*(arm64|aarch64)'
            fi
            while IFS= read -r u; do
                [[ -n "$u" ]] && candidate_urls+=("$u")
            done < <(echo "$api_json" | jq -r --arg pat "$generic_pat" \
                '.assets[] | select(.name | test($pat; "i")) | .browser_download_url' 2>/dev/null)
        fi
    fi

    # Last-resort fallback: previously-known fixed filenames, only used if the
    # GitHub API call above failed entirely (rate limit, DNS hiccup, etc.)
    local base_url="https://github.com/radkesvat/WaterWall/releases/download/${WW_VERSION}"
    if [[ "$arch_tag" == "x64" ]]; then
        case "$cpu_tag" in
            avx512f) candidate_urls+=("${base_url}/Waterwall-linux-clang-avx512f-x64.zip" "${base_url}/Waterwall-linux-clang-x64.zip") ;;
            old-cpu) candidate_urls+=("${base_url}/Waterwall-linux-gcc-x64-old-cpu.zip" "${base_url}/Waterwall-linux-clang-x64.zip") ;;
            *)       candidate_urls+=("${base_url}/Waterwall-linux-clang-x64.zip" "${base_url}/Waterwall-linux-gcc-x64.zip") ;;
        esac
    else
        candidate_urls+=("${base_url}/Waterwall-linux-gcc-arm64.zip" "${base_url}/Waterwall-linux-gcc-arm64-old-cpu.zip")
    fi

    local downloaded=false url
    cd "$INSTALL_DIR" || return 1
    for url in "${candidate_urls[@]}"; do
        echo -e "${YELLOW}Trying: ${url}${NC}"
        rm -f Waterwall.zip
        # FIX: previously a failed/garbage download (e.g. a 404 HTML page
        # saved under the .zip name) could slip through if wget's own exit
        # code happened to look fine; we now also verify the archive with
        # `unzip -t` before trusting it.
        if wget -q --show-progress -O Waterwall.zip "$url" && unzip -tq Waterwall.zip &>/dev/null; then
            downloaded=true
            break
        fi
    done

    if [[ "$downloaded" != true ]]; then
        rm -f Waterwall.zip
        return 1
    fi

    systemctl stop waterwall.service 2>/dev/null
    rm -f "$INSTALL_DIR/Waterwall"
    unzip -o Waterwall.zip -d "$INSTALL_DIR"
    rm -f Waterwall.zip

    # Normalize binary name in case the zip extracts a differently cased or suffixed executable
    if [[ ! -f "$INSTALL_DIR/Waterwall" ]]; then
        local extracted_bin
        extracted_bin=$(find "$INSTALL_DIR" -maxdepth 1 -type f -iname "waterwall*" ! -name "*.json" ! -name "*.sh" | head -n 1)
        if [[ -n "$extracted_bin" ]]; then
            mv "$extracted_bin" "$INSTALL_DIR/Waterwall"
        fi
    fi
    chmod +x "$INSTALL_DIR/Waterwall"

    [[ -x "$INSTALL_DIR/Waterwall" ]]
}

install_core() {
    echo -e "${CYAN}Detecting system architecture and fetching WaterWall ${WW_VERSION}...${NC}"
    cd "$INSTALL_DIR" || exit 1
    mkdir -p "$INSTALL_DIR/log" "$INSTALL_DIR/libs"

    local arch arch_tag cpu_tag
    arch=$(uname -m)

    if [[ "$arch" == "x86_64" || "$arch" == "amd64" ]]; then
        arch_tag="x64"
        if grep -qi "avx512f" /proc/cpuinfo 2>/dev/null; then
            cpu_tag="avx512f"
        elif ! grep -qi "avx2" /proc/cpuinfo 2>/dev/null; then
            cpu_tag="old-cpu"
        else
            cpu_tag="modern"
        fi
    elif [[ "$arch" == "aarch64" || "$arch" == "arm64" ]]; then
        arch_tag="arm64"
        cpu_tag="modern"
    else
        echo -e "${RED}Unsupported architecture: $arch${NC}"
        sleep 2
        init
        return
    fi

    if ! fetch_and_extract_waterwall "$arch_tag" "$cpu_tag"; then
        echo -e "${RED}Failed to download a working WaterWall ${WW_VERSION} archive for this system (${arch}). Check the server's internet/DNS, or that release still publishes a matching Linux asset.${NC}"
        sleep 3
        init
        return
    fi

    if [[ ! -x "$INSTALL_DIR/Waterwall" ]]; then
        echo -e "${RED}Download succeeded but no Waterwall executable was found after extraction. Aborting.${NC}"
        sleep 3
        init
        return
    fi

    # FIX: core logger was at WARN, which silently swallows WaterWall's own
    # startup/config-parsing messages (these are logged at INFO/DEBUG). That
    # made "why won't the service start" impossible to diagnose from core.log.
    # Also added the "internal" logger block, which core.json's own schema
    # supports but the original file omitted.
    cat <<EOL > "$INSTALL_DIR/core.json"
{
    "log": {
        "path": "log/",
        "internal": {
            "loglevel": "WARN",
            "file": "internal.log",
            "console": false
        },
        "core": {
            "loglevel": "INFO",
            "file": "core.log",
            "console": true
        },
        "network": {
            "loglevel": "WARN",
            "file": "network.log",
            "console": true
        },
        "dns": {
            "loglevel": "SILENT",
            "file": "dns.log",
            "console": false
        }
    },
    "dns": {},
    "misc": {
        "workers": 0,
        "ram-profile": "server",
        "libs-path": "libs/"
    },
    "configs": [
        "dev-ir.json"
    ]
}
EOL

    # FIX (#12): /proc/cpuinfo flags (used above to pick avx512f/modern/
    # old-cpu) aren't always trustworthy — some VPS/VM hosts report flags the
    # guest can't actually use, so the wrong build can get picked even though
    # detection "succeeded". WaterWall's own binary checks this properly at
    # startup and exits immediately with "This Waterwall binary was built for
    # a newer x86-64 CPU than this machine/OS exposes" if so — which, before
    # this fix, just crash-looped forever under systemd (restart counter
    # climbing indefinitely) with nothing telling the user why. We smoke-test
    # the binary for exactly that message right after install and, if seen,
    # automatically re-download the old-cpu build instead.
    local smoke_output
    smoke_output=$(cd "$INSTALL_DIR" && timeout 3 ./Waterwall --verbose 2>&1)
    if echo "$smoke_output" | grep -qi "built for a newer"; then
        if [[ "$cpu_tag" != "old-cpu" ]]; then
            echo -e "${YELLOW}This CPU/VM doesn't actually support the WaterWall build that was just installed. Re-downloading the compatible 'old-cpu' build instead...${NC}"
            cpu_tag="old-cpu"
            if ! fetch_and_extract_waterwall "$arch_tag" "$cpu_tag"; then
                echo -e "${RED}Failed to download the old-cpu WaterWall ${WW_VERSION} archive. Check the server's internet/DNS.${NC}"
                sleep 3
                init
                return
            fi
            smoke_output=$(cd "$INSTALL_DIR" && timeout 3 ./Waterwall --verbose 2>&1)
            if echo "$smoke_output" | grep -qi "built for a newer"; then
                echo -e "${RED}Even the old-cpu WaterWall build reports a CPU incompatibility on this machine. This usually points at the host CPU itself (or a restrictive hypervisor), not something this script can fix automatically — building WaterWall from source with advanced CPU instructions disabled is the next step.${NC}"
                sleep 4
                init
                return
            fi
            echo -e "${GREEN}old-cpu build runs correctly on this machine.${NC}"
        fi
    fi

    setup_systemd_service
    if [[ -f "$INSTALL_DIR/dev-ir.json" ]]; then
        systemctl restart waterwall.service
    fi

    echo -e "${GREEN}WaterWall Core ${WW_VERSION} installed successfully!${NC}"
    sleep 2
    init
}

# FIX: added StartLimitIntervalSec=0 at the [Unit] level. Without it, systemd's
# default start-rate limiting (a handful of restarts within ~10s) can flip the
# unit to "failed" permanently while you're still iterating on dev-ir.json,
# and it then silently ignores further `systemctl restart` attempts from this
# script until someone runs `systemctl reset-failed` by hand. Restart=always
# below is supposed to keep retrying forever, so let it. (See fix #11 above:
# the status-reporting code is now aware this means `is-failed` alone isn't
# enough to detect a crash loop.)
setup_systemd_service() {
    cat <<EOL > "$SERVICE_FILE"
[Unit]
Description=WaterWall Tunnel Service ($WW_VERSION)
After=network-online.target
Wants=network-online.target
StartLimitIntervalSec=0

[Service]
Type=simple
User=root
WorkingDirectory=$INSTALL_DIR
ExecStart=$INSTALL_DIR/Waterwall
Restart=always
RestartSec=2
LimitNOFILE=1048576
LimitNPROC=512000

[Install]
WantedBy=multi-user.target
EOL
    systemctl daemon-reload
    systemctl enable waterwall.service &>/dev/null
}

tunnel_menu() {
    menu "| 1 - Reverse Reality + HalfDuplex + Mux (Recommended for v1.46.96)\n| 2 - Reverse Reality + HalfDuplex + gRPC/H2 (Classic)\n| 3 - External Reverse Tunnel Script\n| 0 - Back to Main Menu"

    read -rp "Enter option number: " choice
    case $choice in
        1) config_halfduplex_tunnel "mux" ;;
        2) config_halfduplex_tunnel "h2" ;;
        3) bash <(curl -Ls https://raw.githubusercontent.com/dev-ir/WaterWall-Tunnel/master/tunnels/reverse_tunnel.sh) ;;
        0) init ;;
        *)
            echo -e "${RED}Invalid option.${NC}"
            sleep 1
            tunnel_menu
            ;;
    esac
}

config_halfduplex_tunnel() {
    local mode="$1"
    menu "${BLUE}| 1 - IRAN Server (Relay)\n| 2 - Kharej Server (Upstream)\n| 0 - Back${NC}"

    read -rp "Enter option number: " setup
    case $setup in
        1)
            read -rp "Enter SNI [default: digikala.com]: " clear_sni
            clear_sni=${clear_sni:-digikala.com}

            # FIX: no validation previously existed here. Pressing Enter past
            # this prompt used to silently write an empty address into the
            # TcpListener whitelist, which WaterWall would reject at startup
            # (service stays "inactive" with no obvious reason to the user).
            local kharej_ip=""
            while true; do
                read -rp "Enter Kharej Server IP: " kharej_ip
                validate_ipv4 "$kharej_ip" && break
                echo -e "${RED}Please enter a valid IPv4 address (e.g. 203.0.113.10).${NC}"
            done

            # FIX (#13): this used to split the public port range into TWO
            # TcpListener nodes (23..tunnel_port-1 and tunnel_port+1..65535),
            # both pointing "next" at the same "header" node. On this
            # WaterWall version that is a hard error at startup:
            #   FATAL Node Map Failure: Node (users_inbound_high) wanted to
            #   bind to (header) which is already bounded by users_inbound_low
            # i.e. a node can only be the "next" target of ONE other node, so
            # two listeners can't both feed the same downstream node. There's
            # no way to keep a hole in the middle of a single-range listener,
            # so instead we now use exactly ONE "users" listener covering
            # 23..tunnel_port-1, and tunnel_port defaults to a high, normally
            # unused port (65432) so that single range still covers virtually
            # every real port (80, 443, 2083, 8080, 8443, ...). Only picking a
            # LOW custom tunnel_port here would meaningfully shrink the usable
            # range, so the recommendation below steers away from that.
            local tunnel_port=""
            while true; do
                read -rp "Enter Tunnel Port between Iran & Kharej (pick a high, normally-unused port — it's an internal link, not a user-facing one) [default: 65432]: " tunnel_port
                tunnel_port=${tunnel_port:-65432}
                if [[ "$tunnel_port" =~ ^[0-9]+$ ]] && (( tunnel_port >= 24 && tunnel_port <= 65535 )); then
                    break
                fi
                echo -e "${RED}Port must be a whole number between 24 and 65535.${NC}"
            done

            # FIX (#9): Reality password is fixed to "1234" on both sides and
            # no longer prompted for, so Iran/Kharej can't drift out of sync.
            local tunnel_pass="1234"

            # Build the single port range excluding tunnel_port so the users
            # listener never collides with kharej_inbound (see FIX #13 above).
            local port_before=$((tunnel_port - 1))

            # FIX: escape free-text input before it lands inside JSON strings
            # (a password or SNI containing a quote/backslash used to corrupt
            # dev-ir.json silently).
            local esc_sni esc_pass
            esc_sni=$(json_escape "$clear_sni")
            esc_pass=$(json_escape "$tunnel_pass")

            if [[ "$mode" == "mux" ]]; then
                cat <<EOL > "$INSTALL_DIR/dev-ir.json"
{
    "name": "reverse_reality_mux_hd_multiport_server",
    "config-version": 1,
    "core-minimum-version": 0,
    "nodes": [
        {
            "name": "users_inbound",
            "type": "TcpListener",
            "settings": {
                "address": "0.0.0.0",
                "port": [23, $port_before],
                "nodelay": true
            },
            "next": "header"
        },
        {
            "name": "header",
            "type": "HeaderClient",
            "settings": {
                "data": "src_context->port"
            },
            "next": "bridge2"
        },
        {
            "name": "bridge2",
            "type": "Bridge",
            "settings": {
                "pair": "bridge1"
            }
        },
        {
            "name": "bridge1",
            "type": "Bridge",
            "settings": {
                "pair": "bridge2"
            }
        },
        {
            "name": "reverse_server",
            "type": "ReverseServer",
            "settings": {
                "reverse-secret": "$esc_pass"
            },
            "next": "bridge1"
        },
        {
            "name": "mux_server",
            "type": "MuxServer",
            "settings": {},
            "next": "reverse_server"
        },
        {
            "name": "halfs",
            "type": "HalfDuplexServer",
            "settings": {},
            "next": "mux_server"
        },
        {
            "name": "reality_server",
            "type": "RealityServer",
            "settings": {
                "destination": "reality_dest",
                "password": "$esc_pass"
            },
            "next": "halfs"
        },
        {
            "name": "kharej_inbound",
            "type": "TcpListener",
            "settings": {
                "address": "0.0.0.0",
                "port": $tunnel_port,
                "nodelay": true,
                "whitelist": [
                    "$kharej_ip/32"
                ]
            },
            "next": "reality_server"
        },
        {
            "name": "reality_dest",
            "type": "TcpConnector",
            "settings": {
                "nodelay": true,
                "address": "$esc_sni",
                "port": 443
            }
        }
    ]
}
EOL
            else
                cat <<EOL > "$INSTALL_DIR/dev-ir.json"
{
    "name": "reverse_reality_grpc_hd_multiport_server",
    "config-version": 1,
    "core-minimum-version": 0,
    "nodes": [
        {
            "name": "users_inbound",
            "type": "TcpListener",
            "settings": {
                "address": "0.0.0.0",
                "port": [23, $port_before],
                "nodelay": true
            },
            "next": "header"
        },
        {
            "name": "header",
            "type": "HeaderClient",
            "settings": {
                "data": "src_context->port"
            },
            "next": "bridge2"
        },
        {
            "name": "bridge2",
            "type": "Bridge",
            "settings": {
                "pair": "bridge1"
            }
        },
        {
            "name": "bridge1",
            "type": "Bridge",
            "settings": {
                "pair": "bridge2"
            }
        },
        {
            "name": "reverse_server",
            "type": "ReverseServer",
            "settings": {
                "reverse-secret": "$esc_pass"
            },
            "next": "bridge1"
        },
        {
            "name": "pbserver",
            "type": "ProtoBufServer",
            "settings": {},
            "next": "reverse_server"
        },
        {
            "name": "h2server",
            "type": "Http2Server",
            "settings": {},
            "next": "pbserver"
        },
        {
            "name": "halfs",
            "type": "HalfDuplexServer",
            "settings": {},
            "next": "h2server"
        },
        {
            "name": "reality_server",
            "type": "RealityServer",
            "settings": {
                "destination": "reality_dest",
                "password": "$esc_pass"
            },
            "next": "halfs"
        },
        {
            "name": "kharej_inbound",
            "type": "TcpListener",
            "settings": {
                "address": "0.0.0.0",
                "port": $tunnel_port,
                "nodelay": true,
                "whitelist": [
                    "$kharej_ip/32"
                ]
            },
            "next": "reality_server"
        },
        {
            "name": "reality_dest",
            "type": "TcpConnector",
            "settings": {
                "nodelay": true,
                "address": "$esc_sni",
                "port": 443
            }
        }
    ]
}
EOL
            fi

            # FIX: validate the generated config before touching the running
            # service. Previously a broken file (bad escaping, bad port math)
            # would go straight into `systemctl restart`, WaterWall would
            # refuse to start, and the script would just report "failed" with
            # no indication of why.
            local jq_err
            if ! jq_err=$(jq empty "$INSTALL_DIR/dev-ir.json" 2>&1); then
                echo -e "${RED}Generated dev-ir.json is not valid JSON, aborting before restart:${NC}"
                echo "$jq_err"
                sleep 3
                tunnel_menu
                return
            fi

            restart_service
            ;;

        2)
            read -rp "Enter SNI (must match IRAN server) [default: digikala.com]: " clear_sni
            clear_sni=${clear_sni:-digikala.com}

            local iran_ip=""
            while true; do
                read -rp "Enter IRAN Server IP: " iran_ip
                validate_ipv4 "$iran_ip" && break
                echo -e "${RED}Please enter a valid IPv4 address (e.g. 203.0.113.10).${NC}"
            done

            # FIX (#13): must match whatever the IRAN side was configured
            # with; default is now 65432, not 443 — see the note on the IRAN
            # side's prompt for why.
            local tunnel_port=""
            while true; do
                read -rp "Enter Tunnel Port between Iran & Kharej (must match the IRAN side) [default: 65432]: " tunnel_port
                tunnel_port=${tunnel_port:-65432}
                if [[ "$tunnel_port" =~ ^[0-9]+$ ]] && (( tunnel_port >= 1 && tunnel_port <= 65535 )); then
                    break
                fi
                echo -e "${RED}Port must be a whole number between 1 and 65535.${NC}"
            done

            # FIX (#9): Reality password is fixed to "1234" on both sides and
            # no longer prompted for, so Iran/Kharej can't drift out of sync.
            local tunnel_pass="1234"

            local esc_sni esc_pass
            esc_sni=$(json_escape "$clear_sni")
            esc_pass=$(json_escape "$tunnel_pass")

            if [[ "$mode" == "mux" ]]; then
                cat <<EOL > "$INSTALL_DIR/dev-ir.json"
{
    "name": "reverse_reality_mux_hd_multiport_client",
    "config-version": 1,
    "core-minimum-version": 0,
    "nodes": [
        {
            "name": "outbound_to_core",
            "type": "TcpConnector",
            "settings": {
                "nodelay": true,
                "address": "127.0.0.1",
                "port": "dest_context->port"
            }
        },
        {
            "name": "header",
            "type": "HeaderServer",
            "settings": {
                "override": "dest_context->port"
            },
            "next": "outbound_to_core"
        },
        {
            "name": "bridge1",
            "type": "Bridge",
            "settings": {
                "pair": "bridge2"
            },
            "next": "header"
        },
        {
            "name": "bridge2",
            "type": "Bridge",
            "settings": {
                "pair": "bridge1"
            },
            "next": "reverse_client"
        },
        {
            "name": "reverse_client",
            "type": "ReverseClient",
            "settings": {
                "minimum-unused": 16,
                "reverse-secret": "$esc_pass"
            },
            "next": "mux_client"
        },
        {
            "name": "mux_client",
            "type": "MuxClient",
            "settings": {
                "concurrency": 64
            },
            "next": "halfc"
        },
        {
            "name": "halfc",
            "type": "HalfDuplexClient",
            "settings": {},
            "next": "reality_client"
        },
        {
            "name": "reality_client",
            "type": "RealityClient",
            "settings": {
                "sni": "$esc_sni",
                "password": "$esc_pass"
            },
            "next": "outbound_to_iran"
        },
        {
            "name": "outbound_to_iran",
            "type": "TcpConnector",
            "settings": {
                "nodelay": true,
                "address": "$iran_ip",
                "port": $tunnel_port
            }
        }
    ]
}
EOL
            else
                cat <<EOL > "$INSTALL_DIR/dev-ir.json"
{
    "name": "reverse_reality_grpc_client_hd_multiport_client",
    "config-version": 1,
    "core-minimum-version": 0,
    "nodes": [
        {
            "name": "outbound_to_core",
            "type": "TcpConnector",
            "settings": {
                "nodelay": true,
                "address": "127.0.0.1",
                "port": "dest_context->port"
            }
        },
        {
            "name": "header",
            "type": "HeaderServer",
            "settings": {
                "override": "dest_context->port"
            },
            "next": "outbound_to_core"
        },
        {
            "name": "bridge1",
            "type": "Bridge",
            "settings": {
                "pair": "bridge2"
            },
            "next": "header"
        },
        {
            "name": "bridge2",
            "type": "Bridge",
            "settings": {
                "pair": "bridge1"
            },
            "next": "reverse_client"
        },
        {
            "name": "reverse_client",
            "type": "ReverseClient",
            "settings": {
                "minimum-unused": 16,
                "reverse-secret": "$esc_pass"
            },
            "next": "pbclient"
        },
        {
            "name": "pbclient",
            "type": "ProtoBufClient",
            "settings": {},
            "next": "h2client"
        },
        {
            "name": "h2client",
            "type": "Http2Client",
            "settings": {
                "host": "$esc_sni",
                "port": 443,
                "path": "/",
                "content-type": "application/grpc",
                "concurrency": 64
            },
            "next": "halfc"
        },
        {
            "name": "halfc",
            "type": "HalfDuplexClient",
            "settings": {},
            "next": "reality_client"
        },
        {
            "name": "reality_client",
            "type": "RealityClient",
            "settings": {
                "sni": "$esc_sni",
                "password": "$esc_pass"
            },
            "next": "outbound_to_iran"
        },
        {
            "name": "outbound_to_iran",
            "type": "TcpConnector",
            "settings": {
                "nodelay": true,
                "address": "$iran_ip",
                "port": $tunnel_port
            }
        }
    ]
}
EOL
            fi

            local jq_err
            if ! jq_err=$(jq empty "$INSTALL_DIR/dev-ir.json" 2>&1); then
                echo -e "${RED}Generated dev-ir.json is not valid JSON, aborting before restart:${NC}"
                echo "$jq_err"
                sleep 3
                tunnel_menu
                return
            fi

            restart_service
            ;;

        0)
            tunnel_menu
            ;;
        *)
            echo -e "${RED}Invalid option.${NC}"
            sleep 1
            config_halfduplex_tunnel "$mode"
            ;;
    esac
}

# FIX: the old version did `systemctl restart` then slept exactly 1 second
# before deciding pass/fail, with no diagnostic output at all on failure.
# That's often not long enough, and gives the user nothing to act on beyond
# "failed, check option 3". Now it polls for up to 6s, clears any stale
# "failed (start-limit-hit)" state first, and on failure prints the actual
# systemd/journalctl/core.log error inline.
#
# FIX (#11): on top of that, it now also tracks NRestarts across the wait
# window. Because the unit is Restart=always with StartLimitIntervalSec=0,
# a bad config can make WaterWall crash and get instantly relaunched by
# systemd over and over — `systemctl is-active` can catch it mid-relaunch and
# report "active" even though it's actually crash-looping, which is exactly
# the "says it installed fine but the tunnel never really comes up" symptom.
# If restarts happened during the wait, we now show the same diagnostics
# instead of declaring success.
restart_service() {
    if [[ ! -x "$INSTALL_DIR/Waterwall" ]]; then
        echo -e "${YELLOW}WaterWall Core is not installed yet! Installing now...${NC}"
        install_core
        return
    fi

    setup_systemd_service
    systemctl reset-failed waterwall.service &>/dev/null
    systemctl restart waterwall.service

    local waited=0
    local is_up=false
    local initial_restarts cur_restarts restarts_seen=0
    initial_restarts=$(systemd_prop NRestarts)
    initial_restarts=${initial_restarts:-0}

    while (( waited < 6 )); do
        sleep 1
        waited=$((waited + 1))
        if systemctl is-active --quiet waterwall.service; then
            is_up=true
        fi
        cur_restarts=$(systemd_prop NRestarts)
        cur_restarts=${cur_restarts:-0}
        if (( cur_restarts > initial_restarts )); then
            restarts_seen=$((cur_restarts - initial_restarts))
        fi
    done

    if [[ "$is_up" == true && "$restarts_seen" -eq 0 ]]; then
        echo -e "${GREEN}WaterWall tunnel service started and running successfully!${NC}"
    else
        if [[ "$is_up" == true && "$restarts_seen" -gt 0 ]]; then
            echo -e "${RED}WaterWall is crash-looping: it restarted $restarts_seen time(s) in the last ${waited}s, even though it currently looks 'active'. Recent diagnostics:${NC}"
        else
            echo -e "${RED}Service failed to start! Recent diagnostics:${NC}"
        fi
        echo -e "${CYAN}--- systemctl status ---${NC}"
        systemctl --no-pager -l status waterwall.service | head -n 12
        echo -e "${CYAN}--- journalctl (last 15 lines) ---${NC}"
        journalctl -u waterwall.service --no-pager -n 15 2>/dev/null
        if [[ -f "$INSTALL_DIR/log/core.log" ]]; then
            echo -e "${CYAN}--- core.log (last 15 lines) ---${NC}"
            tail -n 15 "$INSTALL_DIR/log/core.log"
        fi
        echo -e "${YELLOW}Tip: run option 5 (Test Run) from the main menu to see the exact startup error live.${NC}"
    fi
    sleep 3
    init
}

status_tunnel() {
    clear
    echo -e "${CYAN}=== WaterWall Systemd Service Status ===${NC}"
    systemctl status waterwall.service --no-pager -l | head -n 18

    echo -e "\n${CYAN}=== Recent Core Logs ($INSTALL_DIR/log/core.log) ===${NC}"
    if [[ -f "$INSTALL_DIR/log/core.log" ]]; then
        tail -n 15 "$INSTALL_DIR/log/core.log"
    else
        echo "No core.log generated yet."
    fi

    echo -e "\n${CYAN}=== Recent Network Logs ($INSTALL_DIR/log/network.log) ===${NC}"
    if [[ -f "$INSTALL_DIR/log/network.log" ]]; then
        tail -n 15 "$INSTALL_DIR/log/network.log"
    else
        echo "No network.log generated yet."
    fi

    echo -e "\n${CYAN}=== journalctl (last 20 lines) ===${NC}"
    journalctl -u waterwall.service --no-pager -n 20 2>/dev/null

    echo ""
    read -rp "Press Enter to return to main menu..."
    init
}

# FIX (new): runs WaterWall directly in the foreground with --verbose, which
# per WaterWall's own docs forces full console logging regardless of the
# loglevel/console settings in core.json. This is the fastest way to see the
# exact reason a config is rejected (bad port range, JSON error, etc.)
# instead of guessing from a "failed" systemd status.
test_run_foreground() {
    clear
    if [[ ! -x "$INSTALL_DIR/Waterwall" ]]; then
        echo -e "${RED}WaterWall is not installed yet.${NC}"
        sleep 2
        init
        return
    fi
    echo -e "${CYAN}Stopping the systemd service (if running) and starting WaterWall in the foreground...${NC}"
    echo -e "${YELLOW}Press Ctrl+C to stop and return to the menu.${NC}\n"
    systemctl stop waterwall.service 2>/dev/null
    (cd "$INSTALL_DIR" && ./Waterwall --verbose)
    echo -e "\n${YELLOW}WaterWall exited. Returning to menu...${NC}"
    sleep 2
    init
}

uninstall_waterwall() {
    echo -e "${YELLOW}Uninstalling WaterWall in 3 seconds...${NC}"
    sleep 3
    systemctl stop waterwall.service 2>/dev/null
    systemctl disable waterwall.service 2>/dev/null
    rm -f "$SERVICE_FILE"
    systemctl daemon-reload
    screen -S WaterWal -X quit &>/dev/null
    screen -S WaterWall -X quit &>/dev/null
    rm -rf "$INSTALL_DIR"
    clear
    echo -e "${GREEN}WaterWall uninstalled cleanly.${NC}"
    sleep 2
    mkdir -p "$INSTALL_DIR/log" "$INSTALL_DIR/libs"
    init
}

loader() {
    install_dependencies
    fetch_server_info
    init
}

loader
