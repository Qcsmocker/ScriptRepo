#!/usr/bin/env bash
# ============================================================
#  harden-ubuntu.sh — First-pass hardening for Ubuntu 20.04+
#  Run as root: sudo bash harden-ubuntu.sh
#  Safe to re-run; idempotent where possible.
# ============================================================
set -euo pipefail

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; NC='\033[0m'
info()  { echo -e "${GREEN}[INFO]${NC}  $*"; }
warn()  { echo -e "${YELLOW}[WARN]${NC}  $*"; }
error() { echo -e "${RED}[ERROR]${NC} $*"; exit 1; }

[[ $EUID -ne 0 ]] && error "Must be run as root (sudo)."

# ── 0. Sanity ────────────────────────────────────────────────
info "Detected OS: $(lsb_release -ds 2>/dev/null || cat /etc/os-release | grep PRETTY)"
UBUNTU_VER=$(lsb_release -rs 2>/dev/null | cut -d. -f1)
[[ "$UBUNTU_VER" -lt 20 ]] && warn "Script tested on Ubuntu 20+; proceed with caution."

SSH_PORT=${SSH_PORT:-22}          # Override: SSH_PORT=2222 sudo bash harden-ubuntu.sh

# ── 1. System update ────────────────────────────────────────
info "=== [1/8] System update ==="
export DEBIAN_FRONTEND=noninteractive
apt-get update -qq
apt-get upgrade -y -qq
apt-get autoremove -y -qq
apt-get install -y -qq \
    ufw fail2ban auditd audispd-plugins \
    unattended-upgrades apt-listchanges \
    libpam-pwquality \
    curl wget gnupg2 ca-certificates

# Enable unattended security upgrades
dpkg-reconfigure -f noninteractive unattended-upgrades

# ── 2. SSH hardening ────────────────────────────────────────
info "=== [2/8] SSH hardening ==="
SSHD=/etc/ssh/sshd_config
cp -n "$SSHD" "${SSHD}.bak.$(date +%F)" 2>/dev/null || true

sshd_set() {
    local key="$1" val="$2"
    if grep -qE "^#?[[:space:]]*${key}" "$SSHD"; then
        sed -i "s|^#\?[[:space:]]*${key}.*|${key} ${val}|" "$SSHD"
    else
        echo "${key} ${val}" >> "$SSHD"
    fi
}

sshd_set Port                  "$SSH_PORT"
sshd_set PermitRootLogin       "no"
sshd_set PasswordAuthentication "no"
sshd_set PubkeyAuthentication  "yes"
sshd_set AuthorizedKeysFile    ".ssh/authorized_keys"
sshd_set PermitEmptyPasswords  "no"
sshd_set ChallengeResponseAuthentication "no"
sshd_set UsePAM                "yes"
sshd_set X11Forwarding         "no"
sshd_set PrintMotd             "no"
sshd_set MaxAuthTries          "3"
sshd_set MaxSessions           "5"
sshd_set LoginGraceTime        "30"
sshd_set ClientAliveInterval   "300"
sshd_set ClientAliveCountMax   "2"
sshd_set AllowAgentForwarding  "no"
sshd_set AllowTcpForwarding    "no"
sshd_set TCPKeepAlive          "no"
sshd_set Compression           "no"
sshd_set LogLevel              "VERBOSE"

# Strong ciphers / MACs / KEX
sshd_set Ciphers               "chacha20-poly1305@openssh.com,aes256-gcm@openssh.com,aes128-gcm@openssh.com"
sshd_set MACs                  "hmac-sha2-512-etm@openssh.com,hmac-sha2-256-etm@openssh.com"
sshd_set KexAlgorithms         "curve25519-sha256,curve25519-sha256@libssh.org,diffie-hellman-group16-sha512,diffie-hellman-group18-sha512"

sshd -t && systemctl restart sshd || warn "sshd config test failed — check $SSHD manually."

# ── 3. Firewall (UFW) ───────────────────────────────────────
info "=== [3/8] Firewall (UFW) ==="
ufw --force reset
ufw default deny incoming
ufw default allow outgoing
ufw allow "$SSH_PORT"/tcp comment 'SSH'
ufw --force enable
ufw status verbose

# ── 4. Fail2ban ─────────────────────────────────────────────
info "=== [4/8] Fail2ban ==="
cat > /etc/fail2ban/jail.local << 'EOF'
[DEFAULT]
bantime  = 1h
findtime = 10m
maxretry = 5
backend  = systemd

[sshd]
enabled  = true
port     = ssh
logpath  = %(sshd_log)s
maxretry = 3
bantime  = 24h
EOF

systemctl enable --now fail2ban
systemctl restart fail2ban
fail2ban-client status

# ── 5. Kernel (sysctl) hardening ────────────────────────────
info "=== [5/8] Kernel sysctl parameters ==="
cat > /etc/sysctl.d/99-hardening.conf << 'EOF'
# ── Network ─────────────────────────────────────────────────
# Disable IP forwarding (enable if this is a router)
net.ipv4.ip_forward = 0
net.ipv6.conf.all.forwarding = 0

# SYN flood protection
net.ipv4.tcp_syncookies = 1
net.ipv4.tcp_max_syn_backlog = 2048
net.ipv4.tcp_synack_retries = 2
net.ipv4.tcp_syn_retries = 5

# Ignore ICMP redirects and bogus error responses
net.ipv4.conf.all.accept_redirects = 0
net.ipv4.conf.default.accept_redirects = 0
net.ipv4.conf.all.secure_redirects = 0
net.ipv4.conf.default.secure_redirects = 0
net.ipv6.conf.all.accept_redirects = 0
net.ipv6.conf.default.accept_redirects = 0

net.ipv4.conf.all.send_redirects = 0
net.ipv4.conf.default.send_redirects = 0

# Ignore broadcast pings (smurf attack mitigation)
net.ipv4.icmp_echo_ignore_broadcasts = 1
net.ipv4.icmp_ignore_bogus_error_responses = 1

# Source routing
net.ipv4.conf.all.accept_source_route = 0
net.ipv4.conf.default.accept_source_route = 0
net.ipv6.conf.all.accept_source_route = 0

# Log martian packets (spoofed source IPs)
net.ipv4.conf.all.log_martians = 1
net.ipv4.conf.default.log_martians = 1

# Disable IPv6 if not needed (comment out to keep IPv6)
net.ipv6.conf.all.disable_ipv6 = 1
net.ipv6.conf.default.disable_ipv6 = 1
net.ipv6.conf.lo.disable_ipv6 = 1

# ── Memory / process ────────────────────────────────────────
# Restrict dmesg to root
kernel.dmesg_restrict = 1

# Restrict ptrace (prevent process snooping)
kernel.yama.ptrace_scope = 1

# Hide kernel pointers from non-root
kernel.kptr_restrict = 2

# Randomise address space (ASLR)
kernel.randomize_va_space = 2

# Disable Magic SysRq key
kernel.sysrq = 0

# Restrict access to kernel logs
kernel.perf_event_paranoid = 3
EOF

sysctl --system > /dev/null
info "sysctl parameters applied."

# ── 6. Disable unnecessary services ────────────────────────
info "=== [6/8] Disabling unnecessary services ==="
SERVICES_TO_DISABLE=(
    avahi-daemon   # mDNS — not needed on servers
    cups           # printing
    bluetooth
    whoopsie       # Ubuntu crash reporter
    apport         # crash reporting
    motd-news      # fetches news on login
)
for svc in "${SERVICES_TO_DISABLE[@]}"; do
    if systemctl is-enabled "$svc" &>/dev/null; then
        systemctl disable --now "$svc" 2>/dev/null && info "Disabled: $svc" || true
    fi
done

# ── 7. User / password policy ───────────────────────────────
info "=== [7/8] Password policy & account hardening ==="

# Password complexity via PAM
PAM_PWQUALITY=/etc/security/pwquality.conf
sed -i 's/^# minlen.*/minlen = 14/'     "$PAM_PWQUALITY" 2>/dev/null || echo "minlen = 14" >> "$PAM_PWQUALITY"
sed -i 's/^# dcredit.*/dcredit = -1/'   "$PAM_PWQUALITY" 2>/dev/null || echo "dcredit = -1" >> "$PAM_PWQUALITY"
sed -i 's/^# ucredit.*/ucredit = -1/'   "$PAM_PWQUALITY" 2>/dev/null || echo "ucredit = -1" >> "$PAM_PWQUALITY"
sed -i 's/^# lcredit.*/lcredit = -1/'   "$PAM_PWQUALITY" 2>/dev/null || echo "lcredit = -1" >> "$PAM_PWQUALITY"
sed -i 's/^# ocredit.*/ocredit = -1/'   "$PAM_PWQUALITY" 2>/dev/null || echo "ocredit = -1" >> "$PAM_PWQUALITY"

# Password ageing for local accounts
sed -i 's/^PASS_MAX_DAYS.*/PASS_MAX_DAYS   90/' /etc/login.defs
sed -i 's/^PASS_MIN_DAYS.*/PASS_MIN_DAYS   1/'  /etc/login.defs
sed -i 's/^PASS_WARN_AGE.*/PASS_WARN_AGE   14/' /etc/login.defs

# Lock root login (already blocked via SSH; also lock locally)
passwd -l root

# Restrict su to wheel/sudo group
if ! grep -q "pam_wheel" /etc/pam.d/su; then
    echo "auth required pam_wheel.so use_uid" >> /etc/pam.d/su
fi

# Sudo logging
if ! grep -q "log_output" /etc/sudoers.d/hardening 2>/dev/null; then
    cat > /etc/sudoers.d/hardening << 'EOF'
Defaults  logfile=/var/log/sudo.log
Defaults  log_input, log_output
Defaults  !visiblepw
Defaults  secure_path="/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin"
EOF
    chmod 440 /etc/sudoers.d/hardening
fi

# ── 8. Audit logging (auditd) ────────────────────────────────
info "=== [8/8] Auditd rules ==="
cat > /etc/audit/rules.d/99-hardening.rules << 'EOF'
## Delete existing rules
-D

## Buffer size
-b 8192

## Failure mode: 1 = printk, 2 = panic
-f 1

## Log sudo / su usage
-w /usr/bin/sudo -p x -k privilege_escalation
-w /usr/bin/su   -p x -k privilege_escalation

## Monitor passwd and shadow changes
-w /etc/passwd  -p wa -k identity
-w /etc/shadow  -p wa -k identity
-w /etc/group   -p wa -k identity
-w /etc/gshadow -p wa -k identity

## Monitor SSH config changes
-w /etc/ssh/sshd_config -p wa -k sshd_config

## Monitor sudoers changes
-w /etc/sudoers   -p wa -k sudoers
-w /etc/sudoers.d -p wa -k sudoers

## Monitor cron
-w /etc/crontab      -p wa -k cron
-w /etc/cron.d       -p wa -k cron
-w /var/spool/cron   -p wa -k cron

## Detect logins / logouts
-w /var/log/faillog   -p wa -k logins
-w /var/log/lastlog   -p wa -k logins

## System calls: privilege escalation
-a always,exit -F arch=b64 -S setuid   -k setuid_calls
-a always,exit -F arch=b64 -S setgid   -k setgid_calls
-a always,exit -F arch=b64 -S execve   -k exec_calls

## Make audit config immutable until reboot (comment out to allow live changes)
-e 2
EOF

augenrules --load 2>/dev/null || auditctl -R /etc/audit/rules.d/99-hardening.rules
systemctl enable --now auditd

# ── Done ─────────────────────────────────────────────────────
echo ""
echo -e "${GREEN}╔══════════════════════════════════════════════════╗${NC}"
echo -e "${GREEN}║  Hardening complete — summary                    ║${NC}"
echo -e "${GREEN}╠══════════════════════════════════════════════════╣${NC}"
echo -e "${GREEN}║${NC}  1. System updated + unattended-upgrades enabled ${GREEN}║${NC}"
echo -e "${GREEN}║${NC}  2. SSH: no root, key-only, strong ciphers       ${GREEN}║${NC}"
echo -e "${GREEN}║${NC}  3. UFW: default deny, SSH port $SSH_PORT open      ${GREEN}║${NC}"
echo -e "${GREEN}║${NC}  4. Fail2ban: SSH brute-force protection active   ${GREEN}║${NC}"
echo -e "${GREEN}║${NC}  5. Kernel: ASLR, SYN cookies, no redirects      ${GREEN}║${NC}"
echo -e "${GREEN}║${NC}  6. Unused services disabled                      ${GREEN}║${NC}"
echo -e "${GREEN}║${NC}  7. Password policy + sudo logging                ${GREEN}║${NC}"
echo -e "${GREEN}║${NC}  8. Auditd: syscall + file-change logging         ${GREEN}║${NC}"
echo -e "${GREEN}╠══════════════════════════════════════════════════╣${NC}"
echo -e "${GREEN}║${NC}  ${YELLOW}ACTION REQUIRED:${NC} ensure your SSH public key    ${GREEN}║${NC}"
echo -e "${GREEN}║${NC}  is in ~/.ssh/authorized_keys BEFORE rebooting   ${GREEN}║${NC}"
echo -e "${GREEN}╚══════════════════════════════════════════════════╝${NC}"
echo ""
warn "A reboot is recommended to apply all kernel parameters."
warn "Test your SSH key login in a second terminal before closing this session!"