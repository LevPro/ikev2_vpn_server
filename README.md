# VPN Server Setup

Automated IKEv2 VPN server installation script for Linux.

## Features

- IKEv2 with certificate-based authentication
- StrongSwan-based implementation
- Automatic firewall configuration (nftables)
- Fail2ban intrusion prevention
- Multi-OS support (Debian, Ubuntu, CentOS, RHEL, Rocky, Alma, Fedora, Arch, Manjaro)

## Usage

```bash
chmod +x vpn.sh
sudo ./vpn.sh -d vpn.example.com -s 10.20.30.0/24 -n 1.1.1.1,9.9.9.9 -c client1
```

### Options

| Flag | Description | Default |
|------|-------------|---------|
| `-d` | VPN domain | vpn.example.com |
| `-s` | Client subnet | 10.20.30.0/24 |
| `-n` | DNS servers | 1.1.1.1,9.9.9.9 |
| `-c` | Client name | client1 |
| `-h` | Help | - |

## Supported OS

| OS Family | Distributions |
|----------|---------------|
| Debian | Debian, Ubuntu, Linux Mint |
| RHEL | CentOS, RHEL, Rocky, Alma, Fedora |
| Arch | Arch Linux, Manjaro, EndeavourOS |

## Output Files

After running, the following files are generated in `/root/`:

- `client1.p12` - PKCS#12 for iOS/macOS import
- `client1.mobileconfig` - Apple profile
- `client1.sswan` - StrongSwan config for Android

## Security Notes

- The Root CA (`/root/pki/root/`) should be moved off the server after setup
- Server certs are in `/etc/ipsec.d/`
- Firewall blocks all inbound except UDP 500/4500 and TCP 22

## Uninstall

```bash
systemctl stop strongswan-starter
systemctl disable strongswan-starter
systemctl stop nftables
systemctl disable nftables
rm -rf /etc/ipsec.d/* /root/pki /root/*.p12 /root/*.mobileconfig /root/*.sswan
```

## Support Author

If you find this project useful, you can support the author:

- [Donate via Yoomoney](https://yoomoney.ru/to/41001881102770)