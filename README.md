# misc scripts and what have you

# Logitech c920 scripts
These won't work with your webcam if it doesnt support "zoom_absolute"

## dramatic_squirrel.sh
  recreates the zoom effect from the Dramatic Squirrel meme

## extreme_closeup.sh
  recreates the Waynes World "Extreme Closeup" effect
  
## 00-kinit.sh
  Drop into /etc/NetworkManager/dispatcher.d/ to launch krb5-auth-dialog on VPN connect

## Configuring Radarr on Fedora / RHEL
https://www.reddit.com/r/radarr/comments/11bvg5b/running_on_fedora/

## Configuring Sonarr on Fedora / RHEL
https://www.reddit.com/r/sonarr/comments/11sg1ly/setup_on_fedora_server_36/

## Sabnzbd
RHEL - after you create a user for sabnzbd, su to the user and use pip to install required python extensions that don't ship with RHEL. If you do it as root, you'll bang up all the stuff.

# Personal tools (bin/)
Day-to-day tools for a Fedora laptop that travels. `./install-bin.sh` links
everything in `bin/` into `~/.local/bin` and the units in `systemd/user/` into
`~/.config/systemd/user`, so this repo stays the single source of truth
(`--dry-run` to preview; replaced files go to `~/.local/share/misc-backup/`).
Nothing here carries host names, network names or credentials: anything
site-specific lives in a local config file named in the tool's section.

## roam-guard
Locks the laptop down and tunes Wi-Fi on every network it joins, from a
NetworkManager dispatcher hook. Untrusted networks: firewalld `drop` zone,
avahi masked, wsdd stopped, LLMNR/mDNS off, opportunistic DNS-over-TLS, DHCP
NTP ignored, no hostname in DHCP, open (and OWE) networks stop auto-joining.
Every network: per-network random MAC, IPv6 privacy addresses, NTS time
sources, regulatory domain from the access points, timezone from that
country when it has a single zone. Every change is a desktop notification
and a journal entry.
```
roam-guard install          # asks for sudo; root-owned copy in /usr/local/sbin + hook
roam-guard status | log     # what's in effect / what it changed
roam-guard trust [NAME]     # trust a network (default: the current one)
```
Settings: `/etc/roam-guard/config`, trusted networks: `/etc/roam-guard/trusted`.
Needs NetworkManager, firewalld, systemd-resolved, chrony, iw. Re-run
`roam-guard install` after editing the script.

## vm-run
Rate-limited launcher for test VMs: `vm-run [--name N] qemu-system-x86_64 ...`.
Admits a VM only when its vCPUs fit a budget (lower while an OpenShift Local
`crc` VM runs) and runs every VM in a capped, low-priority systemd user slice,
so parallel test matrices can't take the desktop down. `vm-run --status`
shows usage. Env overrides: `VM_VCPU_BUDGET`, `VM_CPU_QUOTA`, `VM_MEM_MAX`.

## pqc-rancher-lab
Rootless three-VM Rancher + RKE2 lab (Ubuntu 26.04, Rocky 10, Leap 16) on
qemu through `vm-run`, with a private 10.77.0.0/24 lab segment.
`pqc-rancher-lab start|stop|status|ssh <vm>|console <vm>`. Expects cloud
images in `~/.cache/pqc-vm-matrix/images/<alias>.qcow2`.

## sync-vm-images-saturn
Files locally downloaded cloud images into a NAS image store over SSH, verifying
each SHA-256 there; runs hourly from `sync-vm-images-saturn.timer` and exits
quietly when the store isn't reachable. Configure in
`~/.config/sync-vm-images-saturn/config` (not in this repo):
```
SATURN_HOST=nas.example.lan
SATURN_ROOT=/srv/iso/linux
```

## audit-open-shares
Self-audit of a network you own: anonymous SMB/NFS/FTP/rsync, unauthenticated
databases, legacy remote-access services, admin panels and UPnP port forwards.
Passive; never supplies credentials. `audit-open-shares [CIDR]`. Needs
smbclient and showmount; nmap strongly recommended.

## PIV and Federal/DoD PKI
- `import-dod-cas.sh`: DoD PKI roots (trusted) and intermediates into `~/.pki/nssdb`.
- `import-federal-cas.sh`: Federal Common Policy CA G2 plus a PIV issuer branch,
  card-free. Set `BRANCH_FILTER` (default `entrust`) to your card's issuer.
- `import-piv-cas.sh`: walks the chain up from an inserted PIV card and imports it.
- `piv-card-recon.sh`: read-only report of the card, its chain and local trust;
  suggests `BRANCH_FILTER`.
- `verify-pki-trust.sh [leaf.pem]`: card-free pass/fail check for a host; exit
  code usable across a fleet over SSH.

Needs nss-tools, openssl, curl (and opensc for the card tools).

## update-signal-appimage.sh
Downloads the Signal Desktop AppImage to `~/Applications` only if its
signature is from Signal's pinned release key. Weekly via `update-signal.timer`.

