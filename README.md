# VLESS + Reality Auto Installer (Ubuntu 24)

One command sets up a VLESS+Reality server on a fresh Ubuntu 24 box — built and tested for Amazon Lightsail, but works on any VPS.

## What it does

1. Updates Ubuntu
2. Asks you for a port (press Enter for 443)
3. Asks for a masking site / SNI (press Enter for www.microsoft.com)
4. Installs Xray-core
5. Generates UUID, key pair, and short ID automatically
6. Writes the Xray config and starts the service
7. Opens the port in the firewall
8. Prints your server IP, UUID, keys, short ID, and a ready-to-import client link + QR code

## Requirements

- Ubuntu 24.04 VPS (Lightsail, EC2, DigitalOcean, whatever)
- Root access

## Usage

```bash
curl -O https://raw.githubusercontent.com/YOUR-USERNAME/YOUR-REPO/main/install.sh
sudo bash install.sh
```

Or clone the repo:

```bash
git clone https://github.com/YOUR-USERNAME/YOUR-REPO.git
cd YOUR-REPO
sudo bash install.sh
```

## Important: open the port on Lightsail too

The script opens the port in `ufw` on the server, but Lightsail also has its own separate firewall. Go to:

**Lightsail console → your instance → Networking tab → Add rule → Custom TCP → your port**

Without this step, the connection won't reach the server even if Xray is running fine.

## After install

Your client info is printed on screen and also saved to:

```
/root/vless-client-info.txt
```

Import the `vless://` link directly into apps like v2rayNG, NekoBox, or Streisand, or scan the QR code shown in the terminal.

## Useful commands

Check status:
```bash
systemctl status xray
```

View logs:
```bash
journalctl -u xray -e
```

Restart:
```bash
systemctl restart xray
```

Edit config:
```bash
nano /usr/local/etc/xray/config.json
systemctl restart xray
```

## Uninstall

```bash
bash -c "$(curl -L https://github.com/XTLS/Xray-install/raw/main/install-release.sh)" @ remove --purge
```
