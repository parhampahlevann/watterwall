#!/bin/bash

# ============================================================================
# WaterWall Tunnel Manager (Updated & Fixed for v1.46.96)
# Release: https://github.com/radkesvat/WaterWall/releases/tag/v1.46.96
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

check_tunnel_status() {
    if systemctl is-active --quiet waterwall.service 2>/dev/null; then
        echo -e "${GREEN}Active (Running)${NC}"
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
    menu "| 1 - Install / Update Core ($WW_VERSION)\n| 2 - Config Tunnel\n| 3 - Status & Logs\n| 4 - Restart Tunnel Service\n| 9 - Uninstall\n| 0 - Exit"

    read -rp "Enter option number: " choice
    case $choice in
        1) install_core ;;
        2) tunnel_menu ;;
        3) status_tunnel ;;
        4) restart_service ;;
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

install_core() {
    echo -e "${CYAN}Detecting system architecture and fetching WaterWall ${WW_VERSION}...${NC}"
    cd "$INSTALL_DIR" || exit 1
    mkdir -p "$INSTALL_DIR/log" "$INSTALL_DIR/libs"

    local arch
    arch=$(uname -m)
    local preferred_asset=""
    local fallback_asset=""

    if [[ "$arch" == "x86_64" || "$arch" == "amd64" ]]; then
        if grep -q "avx512f" /proc/cpuinfo 2>/dev/null; then
            preferred_asset="Waterwall-linux-clang-avx512f-x64.zip"
            fallback_asset="Waterwall-linux-clang-x64.zip"
        elif ! grep -q "avx2" /proc/cpuinfo 2>/dev/null; then
            preferred_asset="Waterwall-linux-gcc-x64-old-cpu.zip"
            fallback_asset="Waterwall-linux-clang-x64.zip"
        else
            preferred_asset="Waterwall-linux-clang-x64.zip"
            fallback_asset="Waterwall-linux-gcc-x64.zip"
        fi
    elif [[ "$arch" == "aarch64" || "$arch" == "arm64" ]]; then
        preferred_asset="Waterwall-linux-gcc-arm64.zip"
        fallback_asset="Waterwall-linux-gcc-arm64-old-cpu.zip"
    else
        echo -e "${RED}Unsupported architecture: $arch${NC}"
        sleep 2
        init
        return
    fi

    local base_url="https://github.com/radkesvat/WaterWall/releases/download/${WW_VERSION}"
    local download_url="${base_url}/${preferred_asset}"

    echo -e "${YELLOW}Downloading ${preferred_asset} from release ${WW_VERSION}...${NC}"
    if ! wget -q --show-progress -O Waterwall.zip "$download_url"; then
        echo -e "${YELLOW}Primary asset not found, trying fallback (${fallback_asset})...${NC}"
        download_url="${base_url}/${fallback_asset}"
        if ! wget -q --show-progress -O Waterwall.zip "$download_url"; then
            # Dynamic lookup via GitHub API for tag v1.46.96
            echo -e "${YELLOW}Querying GitHub API for ${WW_VERSION} Linux assets...${NC}"
            download_url=$(curl -sS "https://api.github.com/repos/radkesvat/WaterWall/releases/tags/${WW_VERSION}" | \
                jq -r '.assets[].browser_download_url' | grep -i "linux" | head -n 1)
            if [[ -z "$download_url" ]] || ! wget -q --show-progress -O Waterwall.zip "$download_url"; then
                echo -e "${RED}Failed to download WaterWall ${WW_VERSION}. Check network connection.${NC}"
                sleep 3
                init
                return
            fi
        fi
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

    cat <<EOL > "$INSTALL_DIR/core.json"
{
    "log": {
        "path": "log/",
        "core": {
            "loglevel": "WARN",
            "file": "core.log",
            "console": false
        },
        "network": {
            "loglevel": "WARN",
            "file": "network.log",
            "console": false
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
    if [[ -f "$INSTALL_DIR/dev-ir.json" ]]; then
        systemctl start waterwall.service
    fi

    echo -e "${GREEN}WaterWall Core ${WW_VERSION} installed successfully!${NC}"
    sleep 2
    init
}

setup_systemd_service() {
    cat <<EOL > "$SERVICE_FILE"
[Unit]
Description=WaterWall Tunnel Service ($WW_VERSION)
After=network-online.target
Wants=network-online.target

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
            read -rp "Enter SNI (e.g., www.speedtest.net): " clear_sni
            clear_sni=${clear_sni:-www.speedtest.net}
            read -rp "Enter Kharej Server IP: " kharej_ip
            read -rp "Enter Tunnel Port between Iran & Kharej [default: 443]: " tunnel_port
            tunnel_port=${tunnel_port:-443}
            read -rp "Enter Reality Password [default: passwd]: " tunnel_pass
            tunnel_pass=${tunnel_pass:-passwd}

            # Build port ranges excluding tunnel_port soTcpListener never collides with kharej_inbound
            local port_before=$((tunnel_port - 1))
            local port_after=$((tunnel_port + 1))

            if [[ "$mode" == "mux" ]]; then
                cat <<EOL > "$INSTALL_DIR/dev-ir.json"
{
    "name": "reverse_reality_mux_hd_multiport_server",
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
                "password": "$tunnel_pass"
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
                "address": "$clear_sni",
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
                "password": "$tunnel_pass"
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
                "address": "$clear_sni",
                "port": 443
            }
        }
    ]
}
EOL
            fi

            restart_service
            ;;

        2)
            read -rp "Enter SNI (must match IRAN server): " clear_sni
            clear_sni=${clear_sni:-www.speedtest.net}
            read -rp "Enter IRAN Server IP: " iran_ip
            read -rp "Enter Tunnel Port between Iran & Kharej [default: 443]: " tunnel_port
            tunnel_port=${tunnel_port:-443}
            read -rp "Enter Reality Password [default: passwd]: " tunnel_pass
            tunnel_pass=${tunnel_pass:-passwd}

            if [[ "$mode" == "mux" ]]; then
                cat <<EOL > "$INSTALL_DIR/dev-ir.json"
{
    "name": "reverse_reality_mux_hd_multiport_client",
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
                "sni": "$clear_sni",
                "password": "$tunnel_pass"
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
                "host": "$clear_sni",
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
                "sni": "$clear_sni",
                "password": "$tunnel_pass"
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

restart_service() {
    if [[ ! -x "$INSTALL_DIR/Waterwall" ]]; then
        echo -e "${YELLOW}WaterWall Core is not installed yet! Installing now...${NC}"
        install_core
        return
    fi
    setup_systemd_service
    systemctl restart waterwall.service
    sleep 1
    if systemctl is-active --quiet waterwall.service; then
        echo -e "${GREEN}WaterWall tunnel service started and running successfully!${NC}"
    else
        echo -e "${RED}Service failed to start! Check Status & Logs (Option 3).${NC}"
    fi
    sleep 2
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

    echo ""
    read -rp "Press Enter to return to main menu..."
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
