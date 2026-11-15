# Native Ubuntu 24.04 VPS installation

Run on the VPS:

```bash
curl -fsSL https://raw.githubusercontent.com/waqaarhussain/AmberSight/master/scripts/setup-native.sh -o /tmp/ambersight-native.sh && sudo bash /tmp/ambersight-native.sh
```

This compiles the unchanged application and UI on Ubuntu 24.04 with stable Rust
and runs it directly as a systemd service. No Docker installation is required.
Upstream binaries target a newer distribution; compiling on the VPS avoids
depending on the build machine's newer C library. The first build downloads
dependencies and takes time. Compilation uses one job; very small VPSs may still
need more RAM or swap and free disk for the toolchain/cache.

amd64 and arm64 are accepted. A full native Ubuntu build has not been tested here.

## Sign in

After building, setup privately prompts for a password and confirmation for
**waqaar**. Use at least 12 characters. Only its Argon2 hash is saved. Updates
keep your existing password hash without prompting again.

Open **https://YOUR_VPS_IP:8090**. No SSH tunnel is needed. Allow inbound TCP 8090
in the host/provider firewall if needed; setup does not modify firewall rules.
The IP is detected from the VPS interfaces, or via https://api.ipify.org for NAT
VPSs. If detection fails, setup asks for the public IPv4 address.

The service initially binds to localhost. Setup verifies HTTPS against its
locally generated CA and requires unauthenticated camera access to return 401
before enabling public access. A failed initial check stops the service.

AmberSight creates its own certificate authority, so browsers warn until you
trust the certificate. Verify this is your VPS and follow docs/install.md.
Existing CAs are preserved; a CA created for other permitted names may need
attention using the upstream HTTPS guide.

## Files and service

Runtime uses the system account `ambersight`; compilation uses a separate
`ambersight-build` account, without access to the service's private data.

| Path | Purpose |
|---|---|
| `/opt/ambersight/app` | Source checkout |
| `/opt/ambersight/build` | Rust toolchain and build cache |
| `/opt/ambersight/releases` | Compiled versions and original licence notices |
| `/opt/ambersight/current` | Active version |
| `/opt/ambersight/config` | Config, password hashes and camera credentials |
| `/opt/ambersight/data` | Recordings, database, models and private CA |
| `/opt/ambersight/vps.env` | Timezone and discovered IP |
| `/etc/systemd/system/ambersight-native.service` | Native systemd unit |

```bash
sudo ambersight-vps status
sudo ambersight-vps logs
sudo ambersight-vps restart
sudo ambersight-vps stop
sudo ambersight-vps start
```

Rerun the curl command to update. Local source edits or a divergent branch stop
updates. Build/loader failures leave the old installation running. After a
successful build the service is stopped briefly to safely update its config.
Settings and recordings stay in place; config changes get a
`config.toml.before-vps` backup. Earlier compiled versions are kept.

## Moving from the previous Docker installer

The same config/data folders are reused. Only containers labelled with the
`ambersight-vps` Compose project are stopped, and their restart policy is
disabled to avoid port conflicts after reboot. Containers and Docker itself
are retained. Docker is used only for this optional migration step.

Standard `/data` and `/config` paths are translated to their host locations.
Other custom mounts need manual adjustment. Data ownership moves to the native
service account. Do not run the old container against the same database.

The default `scripts/setup-vps.sh` command now invokes native setup as well.
The earlier Docker installer remains at `scripts/setup-docker.sh`.

## Reolink

The VPS still needs a route to your home NVR, such as a VPN gateway or Tailscale
subnet router. Enable RTSP on a supported Reolink NVR and add its camera channels
through the existing UI, using stream addresses for your model. Routed VPNs
normally do not carry home-LAN multicast discovery; add channels by address.
AmberSight records incoming streams rather than importing the NVR's historical
recording library. Set recording limits for your VPS disk and back up config/data.
