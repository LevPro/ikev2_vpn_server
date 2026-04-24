#!/usr/bin/env bash
set -Eeuo pipefail

### DEFAULTS ###
VPN_DOMAIN="vpn.example.com"
VPN_SUBNET="10.20.30.0/24"
VPN_DNS="1.1.1.1,9.9.9.9"
CLIENT_NAME="client1"

### CLI ###
usage() {
  echo "Usage: $0 [-d domain] [-s subnet] [-n dns] [-c client]"
  exit 1
}

while getopts ":d:s:n:c:h" opt; do
  case ${opt} in
    d ) VPN_DOMAIN="$OPTARG" ;;
    s ) VPN_SUBNET="$OPTARG" ;;
    n ) VPN_DNS="$OPTARG" ;;
    c ) CLIENT_NAME="$OPTARG" ;;
    h ) usage ;;
    \? ) usage ;;
  esac
done

### VALIDATION ###
[[ -z "$VPN_DOMAIN" || -z "$CLIENT_NAME" ]] && exit 1

### ENV DETECT ###
detect_os() {
  if [[ -f /etc/os-release ]]; then
    . /etc/os-release
    case "$ID" in
      debian|ubuntu|linuxmint)
        OS_FAMILY="debian"
        ;;
      centos|rhel|rocky|alma|fedora)
        OS_FAMILY="rhel"
        ;;
      arch|manjaro|endeavouros)
        OS_FAMILY="arch"
        ;;
      *)
        echo "[!] Unsupported OS: $ID"
        exit 1
        ;;
    esac
  else
    echo "[!] Cannot detect OS"
    exit 1
  fi
}

detect_os

PUB_IF=$(ip route get 1 | awk '{print $5; exit}')
VPN_IP=$(curl -4 -s ifconfig.me)

echo "[*] OS: $ID ($OS_FAMILY)"
echo "[*] Interface: $PUB_IF"
echo "[*] IP: $VPN_IP"

### INSTALL ###
echo "[*] Installing packages..."

case "$OS_FAMILY" in
  debian)
    apt update
    apt install -y strongswan strongswan-pki nftables fail2ban openssl uuid-runtime curl
    ;;
  rhel)
    if command -v dnf &>/dev/null; then
      dnf install -y strongswan strongswan-pki nftables fail2ban openssl uuidgen curl
    else
      yum install -y strongswan strongswan-pki nftables fail2ban openssl uuidgen curl
    fi
    ;;
  arch)
    pacman -Sy --noconfirm strongswan openssl nftables fail2ban uuidutils curl
    ;;
esac

### FIREWALL MIGRATION ###
echo "[*] Configuring firewall..."

case "$OS_FAMILY" in
  debian)
    if systemctl is-active --quiet ufw; then
      echo "[!] UFW detected → disabling safely"
      ufw allow 22/tcp || true
      ufw disable
    fi
    update-alternatives --set iptables /usr/sbin/iptables-nft || true
    ;;
  rhel)
    if systemctl is-active --quiet firewalld; then
      echo "[!] Firewalld detected → configuring"
      firewall-cmd --permanent --add-port=500/udp
      firewall-cmd --permanent --add-port=4500/udp
      firewall-cmd --permanent --add-service=ipsec
      firewall-cmd --reload
    fi
    update-alternatives --set iptables /usr/sbin/iptables-nft || true
    ;;
  arch)
    if systemctl is-active --quiet firewalld; then
      echo "[!] Firewalld detected → configuring"
      firewall-cmd --permanent --add-port=500/udp
      firewall-cmd --permanent --add-port=4500/udp
      firewall-cmd --permanent --add-service=ipsec
      firewall-cmd --reload
    fi
    update-alternatives --set iptables /usr/sbin/iptables-nft || true
    ;;
esac

### NFTABLES ###
cat > /etc/nftables.conf <<EOF
flush ruleset

table inet filter {
 chain input {
   type filter hook input priority 0;
   policy drop;

   ct state established,related accept
   iif lo accept

   tcp dport 22 accept
   udp dport {500,4500} accept
   ip protocol icmp accept
 }

 chain forward {
   type filter hook forward priority 0;
   policy drop;
   ip saddr $VPN_SUBNET accept
 }
}

table inet nat {
 chain postrouting {
   type nat hook postrouting priority 100;
   oif "$PUB_IF" ip saddr $VPN_SUBNET masquerade
 }
}
EOF

case "$OS_FAMILY" in
  debian)
    systemctl enable nftables
    systemctl restart nftables
    ;;
  rhel)
    systemctl enable nftables.service
    systemctl restart nftables.service
    ;;
  arch)
    systemctl enable nftables
    systemctl restart nftables
    ;;
esac

### SYSCTL ###
cat > /etc/sysctl.d/90-vpn.conf <<EOF
net.ipv4.ip_forward=1
net.ipv4.conf.all.accept_redirects=0
net.ipv4.conf.all.send_redirects=0
net.ipv4.conf.all.rp_filter=1
EOF

sysctl --system

### PKI ###
mkdir -p /root/pki/{root,intermediate,certs,private}
chmod 700 /root/pki/private

openssl genrsa -out /root/pki/root/rootCA.key 4096
openssl req -x509 -new -nodes \
  -key /root/pki/root/rootCA.key \
  -days 3650 -subj "/CN=VPN Root CA" \
  -out /root/pki/root/rootCA.pem

openssl genrsa -out /root/pki/intermediate/intermediate.key 4096
openssl req -new -key /root/pki/intermediate/intermediate.key \
  -subj "/CN=VPN Issuing CA" \
  -out /root/pki/intermediate/intermediate.csr

openssl x509 -req \
  -in /root/pki/intermediate/intermediate.csr \
  -CA /root/pki/root/rootCA.pem \
  -CAkey /root/pki/root/rootCA.key \
  -CAcreateserial \
  -out /root/pki/intermediate/intermediate.pem \
  -days 1825

openssl genrsa -out /root/pki/private/server.key 4096

openssl req -new -key /root/pki/private/server.key \
  -subj "/CN=$VPN_DOMAIN" \
  -out /root/pki/server.csr

openssl x509 -req \
  -in /root/pki/server.csr \
  -CA /root/pki/intermediate/intermediate.pem \
  -CAkey /root/pki/intermediate/intermediate.key \
  -CAcreateserial \
  -out /root/pki/certs/server.pem \
  -days 825 \
  -extfile <(printf "subjectAltName=IP:$VPN_IP,DNS:$VPN_DOMAIN")

cp /root/pki/certs/server.pem /etc/ipsec.d/certs/
cp /root/pki/private/server.key /etc/ipsec.d/private/
cp /root/pki/intermediate/intermediate.pem /etc/ipsec.d/cacerts/

chmod 600 /etc/ipsec.d/private/server.key

### STRONGSWAN ###
cat > /etc/ipsec.conf <<EOF
config setup
  uniqueids=never

conn ikev2-cert
  auto=add
  keyexchange=ikev2
  type=tunnel

  ike=aes256gcm16-prfsha384-ecp384!
  esp=aes256gcm16-ecp384!

  left=%any
  leftid=@$VPN_DOMAIN
  leftcert=server.pem
  leftsendcert=always
  leftsubnet=0.0.0.0/0

  right=%any
  rightauth=pubkey
  rightsourceip=$VPN_SUBNET
  rightdns=$VPN_DNS

  fragmentation=yes
EOF

echo ": RSA server.key" > /etc/ipsec.secrets

systemctl enable strongswan-starter
systemctl restart strongswan-starter

### FAIL2BAN ###
case "$OS_FAMILY" in
  debian)
    cat > /etc/fail2ban/jail.d/ipsec.local <<EOF
[ipsec]
enabled = true
port = 500,4500
filter = ipsec
logpath = /var/log/syslog
maxretry = 3
bantime = 7200
EOF
    systemctl enable fail2ban
    systemctl restart fail2ban
    ;;
  rhel)
    cat > /etc/fail2ban/jail.local <<EOF
[ipsec]
enabled = true
port = 500,4500
filter = ipsec
logpath = /var/log/audit/audit.log
maxretry = 3
bantime = 7200
EOF
    systemctl enable fail2ban
    systemctl restart fail2ban
    ;;
  arch)
    cat > /etc/fail2ban/jail.local <<EOF
[ipsec]
enabled = true
port = 500,4500
filter = ipsec
logpath = /var/log/messages
maxretry = 3
bantime = 7200
EOF
    systemctl enable fail2ban
    systemctl restart fail2ban
    ;;
esac

### CLIENT ###
openssl genrsa -out /root/pki/private/$CLIENT_NAME.key 4096
openssl req -new -key /root/pki/private/$CLIENT_NAME.key \
  -subj "/CN=$CLIENT_NAME" \
  -out /root/pki/$CLIENT_NAME.csr

openssl x509 -req \
  -in /root/pki/$CLIENT_NAME.csr \
  -CA /root/pki/intermediate/intermediate.pem \
  -CAkey /root/pki/intermediate/intermediate.key \
  -CAcreateserial \
  -out /root/pki/certs/$CLIENT_NAME.pem \
  -days 825

openssl pkcs12 -export \
  -inkey /root/pki/private/$CLIENT_NAME.key \
  -in /root/pki/certs/$CLIENT_NAME.pem \
  -certfile /root/pki/intermediate/intermediate.pem \
  -out /root/$CLIENT_NAME.p12 \
  -passout pass:

UUID=$(uuidgen)

cat > /root/$CLIENT_NAME.mobileconfig <<EOF
<?xml version="1.0"?>
<plist version="1.0">
<dict>
 <key>PayloadUUID</key><string>$UUID</string>
 <key>PayloadType</key><string>com.apple.vpn.managed</string>
 <key>VPNType</key><string>IKEv2</string>
 <key>RemoteAddress</key><string>$VPN_IP</string>
 <key>AuthenticationMethod</key><string>Certificate</string>
</dict>
</plist>
EOF

cat > /root/$CLIENT_NAME.sswan <<EOF
{
 "uuid": "$UUID",
 "type": "ikev2-cert",
 "remote": "$VPN_IP"
}
EOF

echo "=================================="
echo "READY ✅"
echo "Import files:"
echo "/root/$CLIENT_NAME.p12"
echo "/root/$CLIENT_NAME.mobileconfig"
echo "/root/$CLIENT_NAME.sswan"
echo "=================================="
echo "⚠️ Move Root CA OFF server!"