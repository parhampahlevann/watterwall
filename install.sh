#!/bin/bash

# ============================================================================
# WaterWall Tunnel Manager (Fixed & Optimized for v1.46.96)
# Release: https://github.com/radkesvat/WaterWall/releases/tag/v1.46.96
# ============================================================================

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
NC='\033[0m'

WW_VERSION="v1.46.96"
DEFAULT_PSK="1234"
DEFAULT_SNI="digikala.com"
INSTALL_DIR="/root/waterwall"
SERVICE_FILE="/etc/systemd/system/waterwall.service"

# Check root privilege
if [[ $EUID -ne 0 ]]; then
    echo -e "${RED}Fatal error:${NC} Please run this script with root privilege (sudo)."
    exit 1
fi

mkdir -p "$INSTALL_DIR/log" "$INSTALL_DIR/libs"

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
        (( 10#$n >= 0 && 10#$n <= 255 )) || return 1
    done
    return 0
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
    ip_info=$(curl -sS --max-time 4 "http://ip-api.com/json" 2>/dev/null)
    SERVER_IP=$(echo "$ip_info" | jq -r '.query // empty' 2>/dev/null)
    [[ -z "$SERVER_IP" ]] && SERVER_IP=$(hostname -I 2>/dev/null | awk '{print $1}')
    SERVER_COUNTRY=$(echo "$ip_info" | jq -r '.country // "Unknown"' 2>/dev/null)
    [[ -z "$SERVER_COUNTRY" ]] && SERVER_COUNTRY="Unknown"
    SERVER_ISP=$(echo "$ip_info" | jq -r '.isp // "Unknown"' 2>/dev/null)
    [[ -z "$SERVER_ISP" ]] && SERVER_ISP="Unknown"
}

check_core_status() {
    if [[ -x "$INSTALL_DIR/Waterwall" && -f "$INSTALL_DIR/core.json" ]]; then
        echo -e "${GREEN}Installed ($WW_VERSION)${NC}"
    else
        echo -e "${RED}Not installed${NC}"
    fi
}

check_tunnel_status() {
    local active_state sub_state
    active_state=$(systemctl show -p ActiveState --value waterwall.service 2>/dev/null)
    sub_state=$(systemctl show -p SubState --value waterwall.service 2>/dev/null)

    if [[ "$active_state" == "active" && "$sub_state" == "running" ]]; then
        echo -e "${GREEN}Active (Running)${NC}"
    elif [[ "$active_state" == "failed" || "$sub_state" == "auto-restart" || "$sub_state" == "failed" ]]; then
        echo -e "${RED}Failed (Crashing - check Status & Logs / Test Run)${NC}"
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
    echo "|   \ \/  \/ /   / _  || __| / _ \| '__|  \ \/  \/ /   / _  || || |    | |   | | | || '_ \ | '_ \  / _ \| |             |"
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

# Verify that an extracted Waterwall binary can actually execute on this CPU/OS
# without dying from SIGILL (132), SIGSEGV (139), or missing shared libs (127).
verify_binary_compatibility() {
    local bin_path="$1"
    [[ -x "$bin_path" ]] || return 1

    if command -v ldd &>/dev/null; then
        if ldd "$bin_path" 2>&1 | grep -qi "not found"; then
            return 1
        fi
    fi

    local test_dir
    test_dir=$(mktemp -d)
    local rc=0
    if command -v timeout &>/dev/null; then
        (cd "$test_dir" && timeout 1 "$bin_path" >/dev/null 2>&1)
        rc=$?
    else
        (cd "$test_dir" && "$bin_path" >/dev/null 2>&1)
        rc=$?
    fi
    rm -rf "$test_dir"

    # 126/127 = exec/lib error, 132 = SIGILL (bad CPU instruction set like AVX512), 139 = SIGSEGV
    case $rc in
        126|127|132|134|136|139) return 1 ;;
        *) return 0 ;;
    esac
}

do_install_core() {
    echo -e "${CYAN}Detecting system architecture and fetching WaterWall ${WW_VERSION}...${NC}"
    mkdir -p "$INSTALL_DIR/log" "$INSTALL_DIR/libs"
    cd "$INSTALL_DIR" || return 1

    local arch
    arch=$(uname -m)
    local base_url="https://github.com/radkesvat/WaterWall/releases/download/${WW_VERSION}"
    local -a candidate_urls=()

    if [[ "$arch" == "x86_64" || "$arch" == "amd64" ]]; then
        if grep -qi "avx512f" /proc/cpuinfo 2>/dev/null; then
            candidate_urls+=(
                "${base_url}/Waterwall-linux-gcc-avx512f-x64.zip"
                "${base_url}/Waterwall-linux-clang-avx512f-x64.zip"
            )
        fi
        if grep -qi "avx2" /proc/cpuinfo 2>/dev/null; then
            candidate_urls+=(
                "${base_url}/Waterwall-linux-gcc-x64.zip"
                "${base_url}/Waterwall-linux-clang-x64.zip"
            )
        fi
        # Always include old-cpu builds as safe fallback (essential for KVM/QEMU virtual CPUs on Kharej VPS)
        candidate_urls+=(
            "${base_url}/Waterwall-linux-gcc-x64-old-cpu.zip"
            "${base_url}/Waterwall-linux-clang-x64-old-cpu.zip"
            "${base_url}/Waterwall-linux-gcc-x64.zip"
            "${base_url}/Waterwall-linux-clang-x64.zip"
        )
    elif [[ "$arch" == "aarch64" || "$arch" == "arm64" ]]; then
        candidate_urls+=(
            "${base_url}/Waterwall-linux-gcc-arm64.zip"
            "${base_url}/Waterwall-linux-gcc-arm64-old-cpu.zip"
            "${base_url}/Waterwall-linux-clang-arm64.zip"
        )
    else
        echo -e "${RED}Unsupported architecture: $arch${NC}"
        return 1
    fi

    systemctl stop waterwall.service 2>/dev/null

    local installed_ok=false url
    local tmp_extract="$INSTALL_DIR/tmp_extract"

    for url in "${candidate_urls[@]}"; do
        echo -e "${YELLOW}Trying: ${url}${NC}"
        rm -rf "$INSTALL_DIR/Waterwall.zip" "$tmp_extract"
        mkdir -p "$tmp_extract"

        if wget -q --show-progress --timeout=15 --tries=2 -O "$INSTALL_DIR/Waterwall.zip" "$url" && \
           unzip -tq "$INSTALL_DIR/Waterwall.zip" &>/dev/null; then

            unzip -oq "$INSTALL_DIR/Waterwall.zip" -d "$tmp_extract"
            local extracted_bin
            extracted_bin=$(find "$tmp_extract" -type f -iname "waterwall*" ! -name "*.zip" ! -name "*.json" ! -name "*.sh" | head -n 1)

            if [[ -n "$extracted_bin" ]]; then
                chmod +x "$extracted_bin"
                if verify_binary_compatibility "$extracted_bin"; then
                    mv -f "$extracted_bin" "$INSTALL_DIR/Waterwall"
                    chmod +x "$INSTALL_DIR/Waterwall"
                    installed_ok=true
                    echo -e "${GREEN}Binary verified compatible with this server's CPU.${NC}"
                    break
                else
                    echo -e "${YELLOW}Binary instruction set is not compatible with this CPU, trying next build...${NC}"
                fi
            fi
        fi
    done

    rm -rf "$INSTALL_DIR/Waterwall.zip" "$tmp_extract"

    if [[ "$installed_ok" != true || ! -x "$INSTALL_DIR/Waterwall" ]]; then
        echo -e "${RED}Failed to download a working WaterWall ${WW_VERSION} binary for (${arch}).${NC}"
        return 1
    fi

    cat <<EOL > "$INSTALL_DIR/core.json"
{
    "log": {
        "path": "log/",
        "internal": {
            "loglevel": "WARN",
            "file": "internal.log",
            "console": true
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

    setup_systemd_service
    echo -e "${GREEN}WaterWall Core ${WW_VERSION} installed successfully!${NC}"
    return 0
}

install_core() {
    if do_install_core; then
        if [[ -f "$INSTALL_DIR/dev-ir.json" ]]; then
            restart_service
            return
        fi
    fi
    sleep 2
    init
}

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
    menu "| 1 - Reverse Reality + HalfDuplex + gRPC/H2 (Recommended)\n| 2 - External Reverse Tunnel Script\n| 0 - Back to Main Menu"

    read -rp "Enter option number: " choice
    case $choice in
        1) config_halfduplex_tunnel ;;
        2) bash <(curl -Ls https://raw.githubusercontent.com/dev-ir/WaterWall-Tunnel/master/tunnels/reverse_tunnel.sh) ;;
        0) init ;;
        *)
            echo -e "${RED}Invalid option.${NC}"
            sleep 1
            tunnel_menu
            ;;
    esac
}

config_halfduplex_tunnel() {
    menu "${BLUE}| 1 - IRAN Server (Relay)\n| 2 - Kharej Server (Upstream)\n| 0 - Back${NC}"

    read -rp "Enter option number: " setup
    case $setup in
        1)
            read -rp "Enter SNI [default: ${DEFAULT_SNI}]: " clear_sni
            clear_sni=${clear_sni:-$DEFAULT_SNI}

            local kharej_ip=""
            while true; do
                read -rp "Enter Kharej Server IP: " kharej_ip
                validate_ipv4 "$kharej_ip" && break
                echo -e "${RED}Please enter a valid IPv4 address (e.g. 203.0.113.10).${NC}"
            done

            local tunnel_port=""
            while true; do
                read -rp "Enter Tunnel Port between Iran & Kharej [default: 443]: " tunnel_port
                tunnel_port=${tunnel_port:-443}
                if [[ "$tunnel_port" =~ ^[0-9]+$ ]] && (( tunnel_port >= 24 && tunnel_port <= 65534 )); then
                    break
                fi
                echo -e "${RED}Port must be a whole number between 24 and 65534.${NC}"
            done

            local tunnel_pass="$DEFAULT_PSK"
            echo -e "${GREEN}PSK (Password) is automatically set to: ${tunnel_pass}${NC}"

            local port_before=$((tunnel_port - 1))
            local port_after=$((tunnel_port + 1))

            local esc_sni esc_pass
            esc_sni=$(json_escape "$clear_sni")
            esc_pass=$(json_escape "$tunnel_pass")

            cat <<EOL > "$INSTALL_DIR/dev-ir.json"
{
    "name": "reverse_reality_grpc_hd_multiport_server",
    "config-version": 1,
    "core-minimum-version": 0,
    "nodes": [
        {
            "name": "users_inbound_low",
            "type": "TcpListener",
            "settings": {
                "address": "0.0.0.0",
                "port": [23, $port_before],
                "nodelay": true
            },
            "next": "header"
        },
        {
            "name": "users_inbound_high",
            "type": "TcpListener",
            "settings": {
                "address": "0.0.0.0",
                "port": [$port_after, 65535],
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
            "settings": {},
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
            read -rp "Enter SNI (must match IRAN server) [default: ${DEFAULT_SNI}]: " clear_sni
            clear_sni=${clear_sni:-$DEFAULT_SNI}

            local iran_ip=""
            while true; do
                read -rp "Enter IRAN Server IP: " iran_ip
                validate_ipv4 "$iran_ip" && break
                echo -e "${RED}Please enter a valid IPv4 address (e.g. 203.0.113.10).${NC}"
            done

            local tunnel_port=""
            while true; do
                read -rp "Enter Tunnel Port between Iran & Kharej [default: 443]: " tunnel_port
                tunnel_port=${tunnel_port:-443}
                if [[ "$tunnel_port" =~ ^[0-9]+$ ]] && (( tunnel_port >= 1 && tunnel_port <= 65535 )); then
                    break
                fi
                echo -e "${RED}Port must be a whole number between 1 and 65535.${NC}"
            done

            local tunnel_pass="$DEFAULT_PSK"
            echo -e "${GREEN}PSK (Password) is automatically set to: ${tunnel_pass}${NC}"

            local esc_sni esc_pass
            esc_sni=$(json_escape "$clear_sni")
            esc_pass=$(json_escape "$tunnel_pass")

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
                "minimum-unused": 16
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
            config_halfduplex_tunnel
            ;;
    esac
}

restart_service() {
    if [[ ! -x "$INSTALL_DIR/Waterwall" || ! -f "$INSTALL_DIR/core.json" ]]; then
        echo -e "${YELLOW}WaterWall Core is not installed yet! Installing now...${NC}"
        if ! do_install_core; then
            sleep 3
            init
            return
        fi
    fi

    if [[ ! -f "$INSTALL_DIR/dev-ir.json" ]]; then
        echo -e "${YELLOW}Tunnel is not configured yet (dev-ir.json missing). Please configure the tunnel first.${NC}"
        sleep 2
        init
        return
    fi

    setup_systemd_service
    systemctl reset-failed waterwall.service &>/dev/null
    systemctl restart waterwall.service

    echo -e "${CYAN}Waiting for WaterWall service to stabilize...${NC}"
    sleep 2

    local pid1 pid2 active_state sub_state
    pid1=$(systemctl show -p MainPID --value waterwall.service 2>/dev/null)
    sleep 1
    pid2=$(systemctl show -p MainPID --value waterwall.service 2>/dev/null)
    active_state=$(systemctl show -p ActiveState --value waterwall.service 2>/dev/null)
    sub_state=$(systemctl show -p SubState --value waterwall.service 2>/dev/null)

    if [[ "$active_state" == "active" && "$sub_state" == "running" && -n "$pid1" && "$pid1" != "0" && "$pid1" == "$pid2" ]]; then
        echo -e "${GREEN}WaterWall tunnel service started and running stably (PID: $pid2)!${NC}"
    else
        echo -e "${RED}Service failed to stay up! Recent diagnostics:${NC}"
        echo -e "${CYAN}--- systemctl status ---${NC}"
        systemctl --no-pager -l status waterwall.service | head -n 14
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
    (cd "$INSTALL_DIR" && ./Waterwall)
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
