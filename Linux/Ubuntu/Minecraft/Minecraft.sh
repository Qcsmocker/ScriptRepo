#!/bin/bash
# Minecraft Server Setup Script
# Sets up a vanilla Minecraft server with a dedicated user, systemd service, and UFW firewall rules.

set -e

# --- Config ---
MC_USER="minecraft"
MC_DIR="/opt/minecraft/server"
JAR_URL="https://piston-data.mojang.com/v1/objects/3872a7f07a1a595e651aef8b058dfc2bb3772f46/server.jar"
RAM_MIN="2G"
RAM_MAX="5G"
MC_PORT="36070"

echo "=== Minecraft Server Setup ==="

# 1. Install OpenJDK
echo "[+] Installing OpenJDK 25..."
sudo apt-get update -qq
sudo apt-get install -y openjdk-25-jre-headless
java -version

# 2. Create minecraft user
if id "$MC_USER" &>/dev/null; then
    echo "[INFO] User '$MC_USER' already exists, skipping."
else
    echo "[+] Creating user '$MC_USER'..."
    sudo useradd -r -m -U -d /opt/minecraft -s /bin/bash "$MC_USER"
fi

# 3. Create server directory
echo "[+] Setting up $MC_DIR..."
sudo mkdir -p "$MC_DIR"
sudo chown -R "$MC_USER":"$MC_USER" /opt/minecraft

# 4. Download server JAR
echo "[+] Downloading Minecraft server JAR..."
sudo -u "$MC_USER" wget -q --show-progress "$JAR_URL" -O "$MC_DIR/server.jar"

# 5. Accept EULA
echo "[+] Accepting EULA..."
sudo -u "$MC_USER" bash -c "echo 'eula=true' > $MC_DIR/eula.txt"

# 6. Create systemd service
echo "[+] Creating systemd service..."
sudo tee /etc/systemd/system/minecraft.service > /dev/null <<EOF
[Unit]
Description=Minecraft Server
After=network.target

[Service]
User=$MC_USER
WorkingDirectory=$MC_DIR
ExecStart=/usr/bin/java -Xmx$RAM_MAX -Xms$RAM_MIN -jar server.jar nogui
ExecStop=/bin/kill -SIGINT \$MAINPID
Restart=on-failure
RestartSec=5

[Install]
WantedBy=multi-user.target
EOF

# 7. Enable and start service
echo "[+] Enabling and starting Minecraft service..."
sudo systemctl daemon-reload
sudo systemctl enable minecraft
sudo systemctl start minecraft

# 8. UFW firewall rules
echo "[+] Configuring UFW firewall..."
sudo ufw allow 22/tcp
sudo ufw allow "$MC_PORT"/tcp
sudo ufw --force enable

echo ""
echo "=== Setup Complete ==="
echo "  Server directory : $MC_DIR"
echo "  Minecraft port   : $MC_PORT"
echo "  RAM allocation   : $RAM_MIN - $RAM_MAX"
echo "  Java version     : $(java -version 2>&1 | head -1)"
echo ""
echo "Useful commands:"
echo "  sudo systemctl status minecraft    # check status"
echo "  sudo journalctl -u minecraft -f    # live logs"
echo "  sudo systemctl restart minecraft   # restart"
echo "  sudo ufw status                    # firewall status"