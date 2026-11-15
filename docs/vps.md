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

After the build, setup prompts privately for waqaar's password and confirmation.
Use at least 12 characters. The password is hashed with Argon2 before it is
written to config.toml; it is never sent to GitHub or placed in process arguments.
Ubuntu's python3-argon2 and python3-tomlkit packages provide the bootstrap tools.

Re-running updates this checkout from its own master branch and rebuilds.
An existing waqaar password hash is preserved, so updates do not prompt again.
Uncommitted local source edits or a divergent branch stop the update.
Settings, users and recordings are kept outside the source checkout:

| Path | Contents |
|---|---|
| `/opt/ambersight/app` | Source |
| `/opt/ambersight/config` | Application config and camera credentials |
| `/opt/ambersight/data` | Database, recordings, models and backups |
| `/opt/ambersight/vps.env` | Dashboard host bind address, public IP and timezone |

## First access

After setup, open the address printed by the installer:

```text
https://YOUR_VPS_IP:8090
```

Sign in as **waqaar** using the password you entered on the VPS. No SSH tunnel
is needed. Existing accounts, camera settings and recordings are retained.
The installer enables HTTPS and checks that unauthenticated camera access is
refused while bound to localhost. It publishes port 8090 on all IPv4 interfaces
only after that check succeeds. Setup briefly stops an existing container after
the build to safely update configuration. A failed authentication check leaves
the listener restricted to localhost.

AmberSight creates its own private certificate authority. Your browser shows a
certificate warning until you trust its certificate. Verify you are connecting
to your own VPS; follow docs/install.md for trusting the server. The public IP
is added to the certificate names before the first HTTPS start. For a NAT VPS,
setup may query https://api.ipify.org to discover its public IPv4 address; if
discovery fails, it asks you to enter the IP. Later installs reuse the saved IP.
If you already used HTTPS with a CA limited to different names, the existing
CA is preserved; see the upstream HTTPS guide before changing its trust limits.

If the page times out, allow inbound TCP 8090 in the VPS provider firewall.

The timezone defaults to Europe/London. Edit vps.env and run
`sudo ambersight-vps up -d` to apply deployment settings. The installer keeps
other deployment settings but sets the host bind address to 0.0.0.0 for direct
IP access after every successful authentication check. It keeps the application
config's other sections and creates config.toml.before-vps before changing it.
To use a domain with a public HTTPS certificate, configure a reverse proxy and
the appropriate trusted_proxies setting documented in docs/docker.md.

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
