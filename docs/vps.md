# Ubuntu 24.04 VPS

The VPS installer builds AmberSight from this repository with its original UI.
No GPU or host Rust installation is needed. Docker uses a Debian container,
so the Ubuntu host does not need the newer libraries required by the native package.
amd64 and arm64 are accepted; arm64 has not been validated here.

## Install or update

Run on the VPS:

```bash
curl -fsSL https://raw.githubusercontent.com/waqaarhussain/AmberSight/master/scripts/setup-vps.sh -o /tmp/ambersight-setup.sh && sudo bash /tmp/ambersight-setup.sh
```

Installs Docker from its official apt repository if needed, builds the application,
and starts it with an automatic restart policy. Existing Docker installations are
reused when Compose v2 is available. Other container packages are never removed
automatically. The first build needs free disk and memory for Rust compilation;
out-of-memory build failures require more memory or administrator-managed swap.

Re-running updates this checkout from its own master branch and rebuilds.
Uncommitted local source edits or a divergent branch stop the update.
Settings, users and recordings are kept outside the source checkout:

| Path | Contents |
|---|---|
| `/opt/ambersight/app` | Source |
| `/opt/ambersight/config` | Application config and camera credentials |
| `/opt/ambersight/data` | Database, recordings, models and backups |
| `/opt/ambersight/vps.env` | Dashboard host bind address and timezone |

## First access

Run this on your own computer, replacing the SSH user and VPS IP:

```bash
ssh -N -L 18090:127.0.0.1:8090 YOUR_SSH_USER@YOUR_VPS_IP
```

Leave it open and visit http://localhost:18090. Add an administrator under
Settings > Users & security. AmberSight initially has no accounts, so the
installer publishes its web port only on the VPS loopback address.
If you enable AmberSight HTTPS later, visit https://localhost:18090 and follow
the upstream install guide for trusting its private certificate authority.

The timezone defaults to Europe/London. Edit vps.env and run
`sudo ambersight-vps up -d` to apply deployment settings. A pre-existing env
file and application config are never overwritten by the installer.

For ongoing private access, connect your computer and VPS through a VPN, then
bind to the VPS VPN IPv4 address in vps.env instead of 127.0.0.1. Create your
account first. Do not use 0.0.0.0 for an unprotected public dashboard. A public
domain needs a separately configured HTTPS reverse proxy and the appropriate
trusted_proxies setting documented in docs/docker.md.

## Reolink NVR

The VPS needs a route to the NVR's private address. An SSH tunnel to the dashboard
does not provide that route. A home VPN gateway or Tailscale subnet router can
provide it; the VPS must accept the route and the VPN policy must allow access.
The exact setup depends on your home equipment and NVR model.

Enable RTSP on a supported NVR. Add each NVR camera channel through AmberSight's
existing camera settings using the model's RTSP address and NVR credentials.
Use a lower bitrate substream for live preview/analysis if the VPS or home upload
cannot handle all main streams. No UI changes are needed.

This bridge-network deployment does not carry ONVIF multicast discovery from
your home LAN. Add channels by address. RTSP support does not mean importing
the NVR's historical recording library; AmberSight stores its own recordings
from the incoming streams. Do not expose the NVR's RTSP port to the internet.

Set a recording limit in Settings > Recording appropriate for your VPS disk.
Keep settings/database on a local disk, and back up both config and data.

## Commands

```bash
sudo ambersight-vps ps
sudo ambersight-vps logs -f --tail 100
sudo ambersight-vps restart
sudo ambersight-vps stop
sudo ambersight-vps up -d
```

Application source, copyright notices and the original licence are retained.
