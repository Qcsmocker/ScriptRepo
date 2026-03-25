#!/bin/bash

# Robust Chrony Initialize Script — VM / Firewall friendly
# Installs Chrony, fixes first-time clock offsets, and ensures proper NTP connectivity
# Works on Debian/Ubuntu and RHEL/CentOS
# Sets timezone to Montreal (America/Toronto)

set -e

echo "=== Detecting OS ==="
if [ -f /etc/debian_version ]; then
    OS="debian"
elif [ -f /etc/redhat-release ]; then
    OS="redhat"
else
    echo "Unsupported OS"
    exit 1
fi

echo "=== Setting timezone to Montreal (America/Toronto) ==="
sudo timedatectl set-timezone America/Toronto

echo "=== Installing Chrony and required tools ==="
if [ "$OS" = "debian" ]; then
    sudo apt update
    sudo apt install -y chrony netcat-openbsd
elif [ "$OS" = "redhat" ]; then
    sudo dnf install -y chrony || sudo yum install -y chrony
fi

echo "=== Backing up existing configuration ==="
CONF_FILE="/etc/chrony/chrony.conf"
[ -f "$CONF_FILE" ] || CONF_FILE="/etc/chrony.conf"
sudo cp "$CONF_FILE" "$CONF_FILE.backup"

echo "=== Configuring NTP servers ==="
sudo sed -i 's/^pool/#pool/g' "$CONF_FILE"
sudo sed -i 's/^server/#server/g' "$CONF_FILE"
for i in 0 1 2 3; do
    echo "pool $i.pool.ntp.org iburst" | sudo tee -a "$CONF_FILE"
done

echo "=== Ensuring ephemeral UDP ports are allowed for NTP (UFW only) ==="
# Chrony uses high-numbered ephemeral source ports to reach UDP 123
if command -v ufw >/dev/null 2>&1; then
    sudo ufw allow out 123/udp
    sudo ufw allow out 49152:65535/udp
    sudo ufw reload
fi

echo "=== Restarting Chrony service ==="
sudo systemctl enable chrony || sudo systemctl enable chronyd
sudo systemctl restart chrony || sudo systemctl restart chronyd

echo "=== Checking connectivity to NTP servers ==="
for server in 0.pool.ntp.org 1.pool.ntp.org 2.pool.ntp.org 3.pool.ntp.org; do
    nc -vzu "$server" 123 >/dev/null 2>&1 && echo "Can reach $server" || echo "Cannot reach $server"
done

echo "=== Fixing large clock offsets (first run) ==="
if timedatectl status | grep -q "System clock synchronized: no"; then
    echo "Stopping Chrony temporarily..."
    sudo systemctl stop chrony
    # Set approximate current time
    CURRENT_TIME=$(date +"%Y-%m-%d %H:%M:%S")
    echo "Setting system clock to: $CURRENT_TIME"
    sudo date -s "$CURRENT_TIME"
    sudo systemctl start chrony
    sudo chronyc makestep
fi

echo "=== Final status ==="
chronyc sources -v
chronyc tracking
timedatectl
echo "=== Chrony initialization complete! Time should now be correct and syncing automatically. ==="