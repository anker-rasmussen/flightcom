#!/bin/bash
# This script sets up repeating a 
set -e

echo "Running Flightcom setup."

# package installation & update.
apt update
apt install -y hostapd dnsmasq iptables

# services
systemctl unmask hostapd
systemctl enable hostapd
systemctl enable dnsmasq

# hotspot config (hostapd)
cat <<EOF > /etc/hostapd/hostapd.conf
interface=uap0
ssid=flightcom
hw_mode=g
channel=7
wmm_enabled=0
macaddr_acl=0
auth_algs=1
ignore_broadcast_ssid=0
wpa=2
wpa_passphrase=bridge
wpa_key_mgmt=WPA-PSK
rsn_pairwise=CCMP
EOF

sed -i 's|#DAEMON_CONF="".*|DAEMON_CONF="/etc/hostapd/hostapd.conf"|' /etc/default/hostapd

# dnsmasq for DHCP on uap0
mv /etc/dnsmasq.conf /etc/dnsmasq.conf.bak
cat <<EOF > /etc/dnsmasq.conf
interface=uap0
dhcp-range=192.168.50.10,192.168.50.50,255.255.255.0,24h
EOF

# static IP for uap0
cat <<EOF > /etc/systemd/network/10-uap0.network
[Match]
Name=uap0

[Network]
Address=192.168.50.1/24
DHCPServer=yes
EOF

# 5. systemd-networkd
systemctl enable systemd-networkd
systemctl restart systemd-networkd

# uap0 virtual interface at boot
cat <<'EOF' > /etc/systemd/network/create-uap0.sh
#!/bin/bash
iw dev wlan0 interface add uap0 type __ap
ip link set uap0 up
EOF

chmod +x /etc/systemd/network/create-uap0.sh

cat <<EOF > /etc/systemd/system/create-uap0.service
[Unit]
Description=Create virtual AP interface uap0
Before=hostapd.service
After=network.target

[Service]
Type=oneshot
ExecStart=/etc/systemd/network/create-uap0.sh
RemainAfterExit=yes

[Install]
WantedBy=multi-user.target
EOF

systemctl enable create-uap0.service

# optional NAT when wlan0 is connected
cat <<'EOF' > /usr/local/bin/check-wifi-nat.sh
#!/bin/bash

UPSTREAM_IF="wlan0"
AP_IF="uap0"

if ip addr show $UPSTREAM_IF | grep -q "inet "; then
    echo "[NAT] Enabling routing via $UPSTREAM_IF..."
    sysctl -w net.ipv4.ip_forward=1
    iptables -t nat -C POSTROUTING -o $UPSTREAM_IF -j MASQUERADE 2>/dev/null || \
    iptables -t nat -A POSTROUTING -o $UPSTREAM_IF -j MASQUERADE
else
    echo "[NAT] $UPSTREAM_IF not connected. Skipping NAT setup."
fi
EOF

chmod +x /usr/local/bin/check-wifi-nat.sh

cat <<EOF > /etc/systemd/system/enable-nat.service
[Unit]
Description=Enable NAT when upstream Wi-Fi is available
After=network-online.target
Wants=network-online.target

[Service]
Type=oneshot
ExecStart=/usr/local/bin/check-wifi-nat.sh

[Install]
WantedBy=multi-user.target
EOF

systemctl enable enable-nat.service

echo "finish your config and reboot"
