#!/usr/bin/env bash
# =============================================================================
# install_network_tools.sh
# Detects the current OS and installs a curated set of network tools.
# Supports: Debian/Ubuntu, RHEL/CentOS/Fedora, Arch Linux, and macOS.
# Usage: sudo bash install_network_tools.sh
# =============================================================================

set -euo pipefail

# ─── Colours ─────────────────────────────────────────────────────────────────
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
BOLD='\033[1m'
RESET='\033[0m'

# ─── Logging helpers ──────────────────────────────────────────────────────────
log_info()    { echo -e "${CYAN}[INFO]${RESET}  $*"; }
log_success() { echo -e "${GREEN}[OK]${RESET}    $*"; }
log_warn()    { echo -e "${YELLOW}[WARN]${RESET}  $*"; }
log_error()   { echo -e "${RED}[ERROR]${RESET} $*" >&2; }
log_section() { echo -e "\n${BOLD}${CYAN}══════════════════════════════════════════${RESET}"; \
                echo -e "${BOLD}${CYAN}  $*${RESET}"; \
                echo -e "${BOLD}${CYAN}══════════════════════════════════════════${RESET}"; }

# ─── Root / sudo check ───────────────────────────────────────────────────────
check_root() {
    if [[ $EUID -ne 0 ]]; then
        log_error "This script must be run as root or with sudo."
        exit 1
    fi
}

# =============================================================================
# OS DETECTION
# Reads /etc/os-release (Linux) or uses 'uname' (macOS / fallback).
# =============================================================================
detect_os() {
    log_section "Detecting Operating System"

    OS=""
    PKG_MANAGER=""

    if [[ -f /etc/os-release ]]; then
        # shellcheck disable=SC1091
        source /etc/os-release
        OS="${ID:-unknown}"
        log_info "Detected Linux distribution: ${PRETTY_NAME:-$OS}"
    elif [[ "$(uname -s)" == "Darwin" ]]; then
        OS="macos"
        log_info "Detected macOS $(sw_vers -productVersion)"
    else
        log_error "Unsupported operating system. Exiting."
        exit 1
    fi

    # Map distro ID to a package manager
    case "$OS" in
        ubuntu|debian|linuxmint|pop|kali|raspbian)
            PKG_MANAGER="apt"
            ;;
        rhel|centos|rocky|almalinux|ol)
            # RHEL 8+ uses dnf; fall back to yum for older releases
            PKG_MANAGER=$(command -v dnf &>/dev/null && echo "dnf" || echo "yum")
            ;;
        fedora)
            PKG_MANAGER="dnf"
            ;;
        arch|manjaro|endeavouros)
            PKG_MANAGER="pacman"
            ;;
        macos)
            PKG_MANAGER="brew"
            ;;
        *)
            log_warn "Unknown distro '$OS'. Attempting to auto-detect package manager."
            for pm in apt dnf yum pacman brew; do
                if command -v "$pm" &>/dev/null; then
                    PKG_MANAGER="$pm"
                    log_info "Found package manager: $pm"
                    break
                fi
            done
            if [[ -z "$PKG_MANAGER" ]]; then
                log_error "No supported package manager found. Exiting."
                exit 1
            fi
            ;;
    esac

    log_success "Package manager selected: ${PKG_MANAGER}"
}

# =============================================================================
# PACKAGE MANAGER BOOTSTRAP
# Updates package lists / ensures Homebrew is ready.
# =============================================================================
update_package_manager() {
    log_section "Updating Package Index"

    case "$PKG_MANAGER" in
        apt)
            apt-get update -y
            ;;
        dnf|yum)
            $PKG_MANAGER makecache -y
            ;;
        pacman)
            pacman -Sy --noconfirm
            ;;
        brew)
            # Install Homebrew if missing (macOS)
            if ! command -v brew &>/dev/null; then
                log_info "Homebrew not found. Installing..."
                /bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)"
            fi
            brew update
            ;;
    esac

    log_success "Package index updated."
}

# =============================================================================
# INSTALL HELPER
# Installs a single package and logs the outcome.
# Usage: install_pkg <package_name> [<alternative_name_for_brew_or_pacman>]
# =============================================================================
install_pkg() {
    local pkg="$1"
    log_info "Installing: ${pkg} ..."

    local exit_code=0
    case "$PKG_MANAGER" in
        apt)     apt-get install -y "$pkg" &>/dev/null || exit_code=$? ;;
        dnf|yum) $PKG_MANAGER install -y "$pkg" &>/dev/null || exit_code=$? ;;
        pacman)  pacman -S --noconfirm "$pkg" &>/dev/null || exit_code=$? ;;
        brew)    brew install "$pkg" &>/dev/null || exit_code=$? ;;
    esac

    if [[ $exit_code -eq 0 ]]; then
        log_success "${pkg} installed successfully."
    else
        log_warn "${pkg} could not be installed (exit code ${exit_code}). Skipping."
    fi
}

# =============================================================================
# NETWORK TOOLS INSTALLATION
# Each tool is documented with its purpose before installation.
# =============================================================================
install_network_tools() {
    log_section "Installing Network Tools"

    # ── nmap ──────────────────────────────────────────────────────────────────
    # Purpose : Network exploration and security auditing tool.
    #           Discovers hosts, open ports, services, and OS fingerprints.
    # Usage   : nmap -sV -O 192.168.1.0/24
    log_info "--- nmap: port scanner & host discovery ---"
    install_pkg "nmap"

    # ── netcat (nc) ───────────────────────────────────────────────────────────
    # Purpose : Swiss-army knife for TCP/UDP connections.
    #           Used for port scanning, banner grabbing, and piping data
    #           between hosts (also useful for simple chat / file transfer).
    # Usage   : nc -zv 192.168.1.1 1-1024
    log_info "--- netcat: TCP/UDP Swiss-army knife ---"
    case "$PKG_MANAGER" in
        apt)    install_pkg "netcat-openbsd" ;;   # modern, feature-rich variant
        pacman) install_pkg "openbsd-netcat" ;;
        *)      install_pkg "ncat" ;;              # ncat ships with nmap suite on RPM distros
    esac

    # ── curl ──────────────────────────────────────────────────────────────────
    # Purpose : Command-line HTTP/HTTPS/FTP client.
    #           Fetches URLs, tests REST APIs, downloads files, and supports
    #           dozens of protocols with full header/cookie control.
    # Usage   : curl -I https://example.com
    log_info "--- curl: multi-protocol data transfer ---"
    install_pkg "curl"

    # ── wget ──────────────────────────────────────────────────────────────────
    # Purpose : Non-interactive network downloader.
    #           Ideal for recursive downloads and mirroring websites.
    # Usage   : wget -r https://example.com
    log_info "--- wget: recursive web downloader ---"
    install_pkg "wget"

    # ── tcpdump ───────────────────────────────────────────────────────────────
    # Purpose : Packet capture and analysis on the command line.
    #           Captures live traffic or writes .pcap files for Wireshark.
    # Usage   : tcpdump -i eth0 -w capture.pcap
    log_info "--- tcpdump: CLI packet capture ---"
    install_pkg "tcpdump"

    # ── traceroute ────────────────────────────────────────────────────────────
    # Purpose : Traces the path packets take to reach a destination,
    #           revealing each router hop and round-trip latency.
    # Usage   : traceroute google.com
    log_info "--- traceroute: route path tracing ---"
    case "$PKG_MANAGER" in
        apt)    install_pkg "traceroute" ;;
        brew)   install_pkg "traceroute" ;;
        *)      install_pkg "traceroute" ;;
    esac

    # ── mtr ───────────────────────────────────────────────────────────────────
    # Purpose : Combines ping and traceroute into a real-time interactive
    #           display. Great for diagnosing packet loss per hop.
    # Usage   : mtr google.com
    log_info "--- mtr: real-time traceroute + ping hybrid ---"
    install_pkg "mtr"

    # ── dnsutils / bind-utils ─────────────────────────────────────────────────
    # Purpose : DNS lookup tools — dig, nslookup, host.
    #           Used to query DNS records, troubleshoot resolution issues,
    #           and perform zone transfers.
    # Usage   : dig +short MX gmail.com
    log_info "--- dig/nslookup: DNS interrogation tools ---"
    case "$PKG_MANAGER" in
        apt)    install_pkg "dnsutils" ;;
        dnf|yum) install_pkg "bind-utils" ;;
        pacman) install_pkg "bind" ;;
        brew)   install_pkg "bind" ;;
    esac

    # ── whois ─────────────────────────────────────────────────────────────────
    # Purpose : Queries WHOIS databases to retrieve domain registration info,
    #           IP ownership, and ASN details.
    # Usage   : whois 8.8.8.8
    log_info "--- whois: domain & IP ownership lookup ---"
    install_pkg "whois"

    # ── iputils / iproute2 ────────────────────────────────────────────────────
    # Purpose : Core Linux networking utilities — ip, ping, ss, arp.
    #           'ip' replaces the legacy ifconfig; 'ss' replaces netstat.
    # Usage   : ip addr show | ss -tulpn
    log_info "--- iproute2/iputils: core Linux net utilities (ping, ip, ss) ---"
    case "$PKG_MANAGER" in
        apt)
            install_pkg "iproute2"
            install_pkg "iputils-ping"
            ;;
        dnf|yum)
            install_pkg "iproute"
            install_pkg "iputils"
            ;;
        pacman)
            install_pkg "iproute2"
            install_pkg "iputils"
            ;;
        brew)
            log_info "iproute2/iputils are Linux-specific; skipping on macOS."
            ;;
    esac

    # ── net-tools (ifconfig, netstat, route) ──────────────────────────────────
    # Purpose : Legacy but still widely used networking tools.
    #           Useful for scripts that rely on ifconfig or netstat.
    # Usage   : netstat -tulpn
    log_info "--- net-tools: legacy ifconfig / netstat ---"
    case "$PKG_MANAGER" in
        apt)    install_pkg "net-tools" ;;
        dnf|yum) install_pkg "net-tools" ;;
        pacman) install_pkg "net-tools" ;;
        brew)   log_info "net-tools is Linux-only; skipping on macOS." ;;
    esac

    # ── iperf3 ────────────────────────────────────────────────────────────────
    # Purpose : Measures maximum achievable network bandwidth between two hosts.
    #           Run in server mode on one end, client mode on the other.
    # Usage   : iperf3 -s  (server) | iperf3 -c <server_ip>  (client)
    log_info "--- iperf3: bandwidth measurement ---"
    install_pkg "iperf3"

    # ── socat ─────────────────────────────────────────────────────────────────
    # Purpose : Multipurpose relay — like netcat but supports SSL/TLS,
    #           UNIX sockets, file descriptors, and bidirectional data relay.
    # Usage   : socat TCP-LISTEN:8080,fork TCP:192.168.1.1:80
    log_info "--- socat: advanced multipurpose relay ---"
    install_pkg "socat"

    # ── hping3 ────────────────────────────────────────────────────────────────
    # Purpose : Crafts custom TCP/UDP/ICMP packets for firewall testing,
    #           traceroute with custom protocols, and network scanning.
    # Usage   : hping3 -S --flood -p 80 192.168.1.1
    log_info "--- hping3: custom packet crafter ---"
    case "$PKG_MANAGER" in
        brew)   log_info "hping3 unavailable via Homebrew; consider installing from source." ;;
        *)      install_pkg "hping3" ;;
    esac

    # ── tshark ────────────────────────────────────────────────────────────────
    # Purpose : CLI front-end for Wireshark's dissection engine.
    #           Captures and decodes packets with full Wireshark protocol support.
    # Usage   : tshark -i eth0 -Y "http"
    log_info "--- tshark: CLI Wireshark packet analyser ---"
    case "$PKG_MANAGER" in
        apt)    install_pkg "tshark" ;;
        dnf|yum) install_pkg "wireshark-cli" ;;
        pacman) install_pkg "wireshark-cli" ;;
        brew)   install_pkg "wireshark" ;;
    esac

    # ── netdiscover ───────────────────────────────────────────────────────────
    # Purpose : ARP-based active/passive network host scanner.
    #           Quickly discovers live hosts on a local subnet.
    # Usage   : netdiscover -r 192.168.1.0/24
    log_info "--- netdiscover: ARP host scanner ---"
    case "$PKG_MANAGER" in
        apt)    install_pkg "netdiscover" ;;
        brew)   log_info "netdiscover unavailable on macOS; consider arp-scan instead." ;;
        *)      log_warn "netdiscover may not be available on this distro; skipping." ;;
    esac

    # ── arp-scan ──────────────────────────────────────────────────────────────
    # Purpose : Fast ARP scanner that resolves MAC addresses to vendors.
    #           Useful for inventory checks on local networks.
    # Usage   : arp-scan --localnet
    log_info "--- arp-scan: fast ARP + vendor lookup ---"
    install_pkg "arp-scan"

    # ── ngrep ─────────────────────────────────────────────────────────────────
    # Purpose : Network grep — applies regex pattern matching to live or
    #           captured network traffic payloads.
    # Usage   : ngrep -d eth0 "GET" tcp
    log_info "--- ngrep: regex pattern matching on packets ---"
    install_pkg "ngrep"

    # ── OpenSSL (CLI) ─────────────────────────────────────────────────────────
    # Purpose : Swiss-army knife for TLS/SSL — inspect certificates, test
    #           handshakes, generate keys, and benchmark crypto.
    # Usage   : openssl s_client -connect example.com:443
    log_info "--- openssl: TLS/SSL testing & certificate inspection ---"
    case "$PKG_MANAGER" in
        apt)    install_pkg "openssl" ;;
        dnf|yum) install_pkg "openssl" ;;
        pacman) install_pkg "openssl" ;;
        brew)   install_pkg "openssl" ;;
    esac

    # ── ssh / openssh-client ──────────────────────────────────────────────────
    # Purpose : Secure Shell client for encrypted remote login and tunnelling.
    #           Also enables SFTP, SCP, and port forwarding.
    # Usage   : ssh -L 8080:localhost:80 user@remote
    log_info "--- openssh-client: encrypted remote access & tunnelling ---"
    case "$PKG_MANAGER" in
        apt)     install_pkg "openssh-client" ;;
        dnf|yum) install_pkg "openssh-clients" ;;
        pacman)  install_pkg "openssh" ;;
        brew)    log_info "ssh ships with macOS; skipping." ;;
    esac
}

# =============================================================================
# SUMMARY
# Lists which tools were successfully installed.
# =============================================================================
print_summary() {
    log_section "Installation Summary"

    local tools=(nmap nc curl wget tcpdump traceroute mtr dig whois \
                 ip ping ss iperf3 socat tshark arp-scan ngrep openssl ssh)

    printf "%-20s %s\n" "TOOL" "STATUS"
    printf "%-20s %s\n" "----" "------"

    for tool in "${tools[@]}"; do
        if command -v "$tool" &>/dev/null; then
            printf "${GREEN}%-20s INSTALLED${RESET}\n" "$tool"
        else
            printf "${YELLOW}%-20s NOT FOUND${RESET}\n" "$tool"
        fi
    done

    echo ""
    log_success "Network toolkit setup complete. Happy hunting! 🔍"
}

# =============================================================================
# MAIN
# =============================================================================
main() {
    log_section "Network Tools Installer"
    log_info "Started at: $(date '+%Y-%m-%d %H:%M:%S')"

    check_root
    detect_os
    update_package_manager
    install_network_tools
    print_summary

    log_info "Finished at: $(date '+%Y-%m-%d %H:%M:%S')"
}

main "$@"
