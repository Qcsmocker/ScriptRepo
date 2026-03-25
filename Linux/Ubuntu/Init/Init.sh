#!/usr/bin/env bash
# ============================================================
#  init.sh — First-pass hardening (tested for Ubuntu / 3/25/2026)
#  Run as root: sudo bash init.sh
#  Safe to re-run; idempotent where possible.
# ============================================================
set -euo pipefail

# ── Colours & helpers ────────────────────────────────────────
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; CYAN='\033[0;36m'; NC='\033[0m'
info()    { echo -e "${GREEN}[INFO]${NC}  $*"; }
warn()    { echo -e "${YELLOW}[WARN]${NC}  $*"; }
error()   { echo -e "${RED}[ERROR]${NC} $*"; exit 1; }
section() { echo -e "\n${CYAN}══════════════════════════════════════════════${NC}"; \
            echo -e "${CYAN}  $*${NC}"; \
            echo -e "${CYAN}══════════════════════════════════════════════${NC}"; }

# ── Root check ───────────────────────────────────────────────
[[ $EUID -ne 0 ]] && error "Must be run as root (sudo)."

# ── OS check ────────────────────────────────────────────────
PRETTY=$(lsb_release -ds 2>/dev/null || grep PRETTY_NAME /etc/os-release | cut -d= -f2 | tr -d '"')
info "Detected OS: $PRETTY"
UBUNTU_VER=$(lsb_release -rs 2>/dev/null | cut -d. -f1)
[[ "$UBUNTU_VER" -lt 20 ]] && warn "Script tested on Ubuntu 20+; proceed with caution."

# ── Configuration ────────────────────────────────────────────
SSH_PORT=${SSH_PORT:-22}
ADMIN_USER=${ADMIN_USER:-""}   # Optional: SSH AllowUsers restriction

# ─────────────────────────────────────────────────────────────
section "[1/8] System update & base packages"
# ─────────────────────────────────────────────────────────────
export DEBIAN_FRONTEND=noninteractive

apt-get update -qq
apt-get upgrade -y -qq
apt-get autoremove -y -qq
apt-get install -y -qq \
    ufw \
    fail2ban \
    python3-systemd \
    auditd \
    audispd-plugins \
    unattended-upgrades \
    apt-listchanges \
    libpam-pwquality \
    curl wget gnupg2 ca-certificates

dpkg-reconfigure -f noninteractive unattended-upgrades
info "Unattended security upgrades enabled."

# ─────────────────────────────────────────────────────────────
section "[2/8] SSH hardening"
# ─────────────────────────────────────────────────────────────
SSHD=/etc/ssh/sshd_config
SSHD_BAK="${SSHD}.bak.$(date +%F)"
[[ ! -f "$SSHD_BAK" ]] && cp "$SSHD" "$SSHD_BAK" && info "Backup: $SSHD_BAK"

# Helper: set or replace a directive (handles commented-out lines)
sshd_set() {
    local key="$1" val="$2"
    if grep -qE "^#?[[:space:]]*${key}[[:space:]]" "$SSHD"; then
        sed -i "s|^#\?[[:space:]]*${key}[[:space:]].*|${key} ${val}|" "$SSHD"
    else
        echo "${key} ${val}" >> "$SSHD"
    fi
}

sshd_set Port                              "$SSH_PORT"
sshd_set PermitRootLogin                   "no"
sshd_set PasswordAuthentication           "no"
sshd_set PubkeyAuthentication             "yes"
sshd_set AuthorizedKeysFile               ".ssh/authorized_keys"
sshd_set PermitEmptyPasswords             "no"
sshd_set ChallengeResponseAuthentication  "no"
sshd_set KbdInteractiveAuthentication     "no"   # OpenSSH 8.7+ replacement
sshd_set UsePAM                            "yes"
sshd_set X11Forwarding                    "no"
sshd_set PrintMotd                        "no"
sshd_set MaxAuthTries                     "3"
sshd_set MaxSessions                      "5"
sshd_set LoginGraceTime                   "30"
sshd_set ClientAliveInterval              "300"
sshd_set ClientAliveCountMax              "2"
sshd_set AllowAgentForwarding             "no"
sshd_set AllowTcpForwarding               "no"
sshd_set TCPKeepAlive                     "no"
sshd_set Compression                      "no"
sshd_set LogLevel                         "VERBOSE"
sshd_set Banner                           "none"
sshd_set DebianBanner                     "no"

# Optionally restrict to a specific admin user
[[ -n "$ADMIN_USER" ]] && sshd_set AllowUsers "$ADMIN_USER"

# Strong ciphers / MACs / KEX (drop anything pre-CTR/GCM/CBC)
sshd_set Ciphers        "chacha20-poly1305@openssh.com,aes256-gcm@openssh.com,aes128-gcm@openssh.com"
sshd_set MACs           "hmac-sha2-512-etm@openssh.com,hmac-sha2-256-etm@openssh.com"
sshd_set KexAlgorithms  "curve25519-sha256,curve25519-sha256@libssh.org,diffie-hellman-group16-sha512,diffie-hellman-group18-sha512"

# Ubuntu uses 'ssh.service'; RHEL/CentOS uses 'sshd.service'
SSH_SVC="ssh"
systemctl list-unit-files --quiet sshd.service &>/dev/null && SSH_SVC="sshd"

if sshd -t; then
    systemctl restart "$SSH_SVC"
    info "sshd restarted successfully on port $SSH_PORT."
else
    warn "sshd config test FAILED — changes not applied. Review $SSHD manually."
    cp "$SSHD_BAK" "$SSHD"
    warn "Restored original sshd_config from backup."
fi

# ─────────────────────────────────────────────────────────────
section "[3/8] Firewall (UFW)"
# ─────────────────────────────────────────────────────────────
ufw --force reset
ufw default deny incoming
ufw default allow outgoing
ufw default deny forward
ufw limit "$SSH_PORT"/tcp comment 'SSH (rate-limited)'
ufw --force enable
ufw status verbose
info "UFW enabled. Only SSH port $SSH_PORT is open inbound."

# ─────────────────────────────────────────────────────────────
section "[4/8] Fail2ban"
# ─────────────────────────────────────────────────────────────
cat > /etc/fail2ban/jail.local << 'EOF'
[DEFAULT]
bantime  = 1h
findtime = 10m
maxretry = 5
# 'auto' lets fail2ban pick systemd journal or log file as available
backend  = auto

[sshd]
enabled  = true
port     = ssh
# Explicit path avoids %(sshd_log)s resolution issues on some Ubuntu installs
logpath  = /var/log/auth.log
maxretry = 3
bantime  = 24h
EOF

systemctl enable fail2ban
systemctl restart fail2ban

# Wait for socket to become available (up to 10 s)
for i in $(seq 1 10); do
    sleep 1
    if systemctl is-active --quiet fail2ban; then
        fail2ban-client status
        break
    fi
    [[ $i -eq 10 ]] && warn "fail2ban may not be running. Check: journalctl -u fail2ban -n 30"
done

# ─────────────────────────────────────────────────────────────
section "[5/8] Kernel (sysctl) hardening"
# ─────────────────────────────────────────────────────────────
cat > /etc/sysctl.d/99-hardening.conf << 'EOF'
# ── Network ──────────────────────────────────────────────────
# Disable IP forwarding (enable if this host is a router/VPN gateway)
net.ipv4.ip_forward                     = 0
net.ipv6.conf.all.forwarding            = 0

# SYN flood protection
net.ipv4.tcp_syncookies                 = 1
net.ipv4.tcp_max_syn_backlog            = 2048
net.ipv4.tcp_synack_retries             = 2
net.ipv4.tcp_syn_retries                = 5

# Ignore ICMP redirects (prevent MITM via routing changes)
net.ipv4.conf.all.accept_redirects      = 0
net.ipv4.conf.default.accept_redirects  = 0
net.ipv4.conf.all.secure_redirects      = 0
net.ipv4.conf.default.secure_redirects  = 0
net.ipv6.conf.all.accept_redirects      = 0
net.ipv6.conf.default.accept_redirects  = 0

# Do not send ICMP redirects
net.ipv4.conf.all.send_redirects        = 0
net.ipv4.conf.default.send_redirects    = 0

# Smurf attack / broadcast ping mitigation
net.ipv4.icmp_echo_ignore_broadcasts    = 1
net.ipv4.icmp_ignore_bogus_error_responses = 1

# Disable source routing
net.ipv4.conf.all.accept_source_route   = 0
net.ipv4.conf.default.accept_source_route = 0
net.ipv6.conf.all.accept_source_route   = 0

# Log spoofed/martian packets
net.ipv4.conf.all.log_martians          = 1
net.ipv4.conf.default.log_martians      = 1

# Reverse-path filter (strict mode) — drop packets with impossible source IPs
net.ipv4.conf.all.rp_filter             = 1
net.ipv4.conf.default.rp_filter         = 1

# Ignore IPv6 router advertisements (not a router)
net.ipv6.conf.all.accept_ra             = 0
net.ipv6.conf.default.accept_ra         = 0

# Disable IPv6 if not needed — comment these three lines to keep IPv6
net.ipv6.conf.all.disable_ipv6         = 1
net.ipv6.conf.default.disable_ipv6     = 1
net.ipv6.conf.lo.disable_ipv6          = 1

# ── Memory / process ─────────────────────────────────────────
# Restrict dmesg to root
kernel.dmesg_restrict                   = 1

# Restrict ptrace (prevent process snooping by non-parents)
kernel.yama.ptrace_scope                = 1

# Hide kernel pointers from non-root
kernel.kptr_restrict                    = 2

# Address space layout randomisation (ASLR)
kernel.randomize_va_space               = 2

# Disable Magic SysRq key
kernel.sysrq                            = 0

# Restrict perf subsystem to root
kernel.perf_event_paranoid              = 3

# Prevent core dumps leaking setuid data
fs.suid_dumpable                        = 0
EOF

sysctl --system > /dev/null
info "sysctl parameters applied."

# ─────────────────────────────────────────────────────────────
section "[6/8] Disable unnecessary services"
# ─────────────────────────────────────────────────────────────
SERVICES_TO_DISABLE=(
    avahi-daemon   # mDNS — not needed on servers
    cups           # printing
    bluetooth      # Bluetooth
    whoopsie       # Ubuntu crash reporter
    apport         # crash reporting
    motd-news      # fetches news on login (phone-home)
    snapd          # remove if not using snaps
)
for svc in "${SERVICES_TO_DISABLE[@]}"; do
    if systemctl list-unit-files --quiet "$svc.service" &>/dev/null && \
       systemctl is-enabled "$svc" &>/dev/null; then
        systemctl disable --now "$svc" 2>/dev/null \
            && info "Disabled: $svc" \
            || warn "Could not disable $svc (may not be installed)"
    fi
done

# ─────────────────────────────────────────────────────────────
section "[7/8] Password policy & account hardening"
# ─────────────────────────────────────────────────────────────

# ── PAM password complexity ──────────────────────────────────
PAM_PQ=/etc/security/pwquality.conf
declare -A PQ_SETTINGS=(
    [minlen]=14
    [dcredit]=-1
    [ucredit]=-1
    [lcredit]=-1
    [ocredit]=-1
    [minclass]=3
    [maxrepeat]=3
    [gecoscheck]=1
)
for key in "${!PQ_SETTINGS[@]}"; do
    val="${PQ_SETTINGS[$key]}"
    if grep -qE "^#?[[:space:]]*${key}" "$PAM_PQ"; then
        sed -i "s|^#\?[[:space:]]*${key}.*|${key} = ${val}|" "$PAM_PQ"
    else
        echo "${key} = ${val}" >> "$PAM_PQ"
    fi
done
info "PAM pwquality configured."

# ── Password ageing ──────────────────────────────────────────
sed -i 's/^PASS_MAX_DAYS.*/PASS_MAX_DAYS   90/' /etc/login.defs
sed -i 's/^PASS_MIN_DAYS.*/PASS_MIN_DAYS   1/'  /etc/login.defs
sed -i 's/^PASS_WARN_AGE.*/PASS_WARN_AGE   14/' /etc/login.defs
# Require SHA-512 password hashing
sed -i 's/^ENCRYPT_METHOD.*/ENCRYPT_METHOD SHA512/' /etc/login.defs || \
    echo "ENCRYPT_METHOD SHA512" >> /etc/login.defs
info "Password ageing policy set (90-day max, 14-day warning)."

# ── Lock root account ────────────────────────────────────────
passwd -l root
info "Root account locked."

# ── Restrict su to sudo group ────────────────────────────────
if ! grep -q "pam_wheel" /etc/pam.d/su; then
    echo "auth required pam_wheel.so use_uid" >> /etc/pam.d/su
    info "su restricted to sudo group members."
fi

# ── Sudo hardening ───────────────────────────────────────────
SUDOERS_D=/etc/sudoers.d/99-hardening
if [[ ! -f "$SUDOERS_D" ]]; then
    cat > "$SUDOERS_D" << 'EOF'
Defaults  logfile=/var/log/sudo.log
Defaults  log_input, log_output
Defaults  !visiblepw
Defaults  use_pty
Defaults  timestamp_timeout=5
Defaults  secure_path="/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin"
EOF
    chmod 440 "$SUDOERS_D"
    visudo -c -f "$SUDOERS_D" && info "Sudo hardening applied." \
        || { warn "sudoers syntax error — removing $SUDOERS_D"; rm -f "$SUDOERS_D"; }
fi

# ── Home directory permissions ───────────────────────────────
info "Tightening home directory permissions..."
for dir in /home/*/; do
    [[ -d "$dir" ]] && chmod 750 "$dir" && info "  chmod 750 $dir"
done

# ─────────────────────────────────────────────────────────────
section "[8/8] Auditd rules"
# ─────────────────────────────────────────────────────────────
cat > /etc/audit/rules.d/99-hardening.rules << 'EOF'
## Delete existing rules
-D

## Buffer size (increase if audit events are dropped)
-b 8192

## Failure mode: 1 = printk (log), 2 = kernel panic
-f 1

## ── Privilege escalation ─────────────────────────────────────
-w /usr/bin/sudo -p x -k privilege_escalation
-w /usr/bin/su   -p x -k privilege_escalation
-w /usr/bin/newgrp -p x -k privilege_escalation

## ── Identity / authentication files ─────────────────────────
-w /etc/passwd   -p wa -k identity
-w /etc/shadow   -p wa -k identity
-w /etc/group    -p wa -k identity
-w /etc/gshadow  -p wa -k identity
-w /etc/security/opasswd -p wa -k identity

## ── SSH configuration ────────────────────────────────────────
-w /etc/ssh/sshd_config   -p wa -k sshd_config
-w /etc/ssh/sshd_config.d -p wa -k sshd_config

## ── Sudoers ──────────────────────────────────────────────────
-w /etc/sudoers   -p wa -k sudoers
-w /etc/sudoers.d -p wa -k sudoers

## ── Cron ─────────────────────────────────────────────────────
-w /etc/crontab    -p wa -k cron
-w /etc/cron.d     -p wa -k cron
-w /etc/cron.daily -p wa -k cron
-w /etc/cron.hourly -p wa -k cron
-w /var/spool/cron -p wa -k cron

## ── Login / logout tracking ──────────────────────────────────
-w /var/log/faillog  -p wa -k logins
-w /var/log/lastlog  -p wa -k logins
-w /var/log/wtmp     -p wa -k logins
-w /var/log/btmp     -p wa -k logins

## ── Kernel module loading ─────────────────────────────────────
-w /sbin/insmod   -p x -k modules
-w /sbin/rmmod    -p x -k modules
-w /sbin/modprobe -p x -k modules
-a always,exit -F arch=b64 -S init_module -S delete_module -k modules

## ── Syscalls: privilege escalation ───────────────────────────
-a always,exit -F arch=b64 -S setuid   -k setuid_calls
-a always,exit -F arch=b64 -S setgid   -k setgid_calls
-a always,exit -F arch=b64 -S execve   -k exec_calls

## ── Network configuration changes ────────────────────────────
-a always,exit -F arch=b64 -S sethostname -S setdomainname -k network_modifications
-w /etc/hosts      -p wa -k network_modifications
-w /etc/network    -p wa -k network_modifications
-w /etc/resolv.conf -p wa -k network_modifications

## ── Immutable flag: uncomment to lock rules until reboot ─────
## -e 2
EOF

if augenrules --load 2>/dev/null; then
    info "auditd rules loaded via augenrules."
else
    auditctl -R /etc/audit/rules.d/99-hardening.rules \
        && info "auditd rules loaded via auditctl."
fi
systemctl enable --now auditd
info "auditd enabled and running."

# ─────────────────────────────────────────────────────────────
# ── Summary ───────────────────────────────────────────────────
# ─────────────────────────────────────────────────────────────
echo ""
echo -e "${GREEN}╔══════════════════════════════════════════════════════╗${NC}"
echo -e "${GREEN}║  Hardening complete — summary                        ║${NC}"
echo -e "${GREEN}╠══════════════════════════════════════════════════════╣${NC}"
echo -e "${GREEN}║${NC}  1. System updated + unattended-upgrades enabled     ${GREEN}║${NC}"
echo -e "${GREEN}║${NC}  2. SSH: no root, key-only, strong ciphers           ${GREEN}║${NC}"
echo -e "${GREEN}║${NC}  3. UFW: default deny, SSH port ${SSH_PORT} rate-limited      ${GREEN}║${NC}"
echo -e "${GREEN}║${NC}  4. Fail2ban: SSH brute-force protection active       ${GREEN}║${NC}"
echo -e "${GREEN}║${NC}  5. Kernel: ASLR, SYN cookies, rp_filter, no redir   ${GREEN}║${NC}"
echo -e "${GREEN}║${NC}  6. Unused services disabled                          ${GREEN}║${NC}"
echo -e "${GREEN}║${NC}  7. Password policy + sudo logging + home perms       ${GREEN}║${NC}"
echo -e "${GREEN}║${NC}  8. Auditd: syscall + file-change + module logging    ${GREEN}║${NC}"
echo -e "${GREEN}╠══════════════════════════════════════════════════════╣${NC}"
echo -e "${GREEN}║${NC}  ${YELLOW}⚠  ACTION REQUIRED before closing this session:${NC}      ${GREEN}║${NC}"
echo -e "${GREEN}║${NC}  • Confirm your SSH public key is in               ${GREEN}║${NC}"
echo -e "${GREEN}║${NC}    ~/.ssh/authorized_keys                          ${GREEN}║${NC}"
echo -e "${GREEN}║${NC}  • Open a SECOND terminal and test SSH login now   ${GREEN}║${NC}"
echo -e "${GREEN}║${NC}  • Then reboot to apply all kernel parameters      ${GREEN}║${NC}"
echo -e "${GREEN}╚══════════════════════════════════════════════════════╝${NC}"
echo ""
warn "Do NOT close this session until you have verified SSH key login in a second terminal!"
