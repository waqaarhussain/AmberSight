#!/usr/bin/env bash
# Build on Ubuntu 24.04 and run with systemd. No container runtime is installed.
set -Eeuo pipefail
umask 022
trap 'printf "\nNative setup stopped at line %s. Settings and recordings were kept.\n" "$LINENO" >&2' ERR
fail() { printf 'Error: %s\n' "$*" >&2; exit 1; }
[[ $EUID -eq 0 ]] || fail 'Run with sudo bash.'
[[ $# -eq 0 ]] || fail 'No arguments are needed.'
. /etc/os-release
[[ ${ID:-} == ubuntu && ${VERSION_ID:-} == 24.04 ]] || fail 'Use Ubuntu 24.04.'
case "$(dpkg --print-architecture)" in amd64|arm64) ;; *) fail 'Use amd64 or arm64.' ;; esac
exec 9>/run/lock/ambersight-setup.lock
flock -n 9 || fail 'Another installer is running.'
BASE=/opt/ambersight
APP="$BASE/app"
BUILD="$BASE/build"
REPO=https://github.com/waqaarhussain/AmberSight.git
export DEBIAN_FRONTEND=noninteractive
apt-get update
apt-get install -y ca-certificates curl git build-essential pkg-config libssl-dev libstdc++6 ffmpeg python3 python3-argon2 python3-tomlkit
id ambersight >/dev/null 2>&1 || useradd --system --user-group --home-dir "$BASE/data" --no-create-home --shell /usr/sbin/nologin ambersight
id ambersight-build >/dev/null 2>&1 || useradd --system --user-group --home-dir "$BUILD" --no-create-home --shell /usr/sbin/nologin ambersight-build
install -d -m 0755 "$BASE" "$BASE/releases"
install -d -m 0755 -o ambersight-build -g ambersight-build "$BUILD"
if [[ -e "$APP" ]]; then
    [[ -d "$APP/.git" ]] || fail "$APP exists but is not a source checkout."
    [[ $(git -C "$APP" remote get-url origin) == "$REPO" ]] || fail 'Existing checkout has a different origin.'
    [[ -z $(git -C "$APP" status --porcelain) ]] || fail 'Source has local edits. Commit or move them before updating.'
    [[ $(git -C "$APP" branch --show-current) == master ]] || fail 'Source must be on master.'
    git -C "$APP" pull --ff-only origin master
else
    git clone --branch master --single-branch "$REPO" "$APP"
fi
# Keep compilation separate from both the service identity and its private data.
build_env=(runuser -u ambersight-build -- env CARGO_HOME="$BUILD/cargo" RUSTUP_HOME="$BUILD/rustup" CARGO_TARGET_DIR="$BUILD/target" CARGO_BUILD_JOBS=1)
if [[ ! -x "$BUILD/cargo/bin/rustup" ]]; then
    curl --proto '=https' --tlsv1.2 -fsSL --retry 3 https://sh.rustup.rs -o "$BUILD/rustup-init.sh"
    "${build_env[@]}" sh "$BUILD/rustup-init.sh" -y --no-modify-path --profile minimal --default-toolchain stable
else
    "${build_env[@]}" "$BUILD/cargo/bin/rustup" update stable --no-self-update
fi
printf '\nBuilding AmberSight natively. The first Rust build can take a while...\n'
# No dependency or application build script is run as root.
(cd "$APP"; "${build_env[@]}" "$BUILD/cargo/bin/cargo" +stable build --release --locked)
sha=$(git -C "$APP" rev-parse HEAD)
release=$(mktemp -d "$BASE/releases/${sha}.XXXXXX")
chmod 0755 "$release"
install -m 0755 "$BUILD/target/release/ambersight" "$release/ambersight"
# Most builds link the CPU runtime into the executable; retain any companion
# libraries produced by the toolchain as well.
shopt -s nullglob
for library in "$BUILD/target/release/"*.so*; do cp -L "$library" "$release/"; done
install -m 0644 "$APP/LICENSE" "$APP/THIRD-PARTY-NOTICES.txt" "$release/"
runuser -u ambersight -- env LD_LIBRARY_PATH="$release" "$release/ambersight" --version
# Build/loader failures above leave any existing installation running.
if command -v docker >/dev/null 2>&1 && docker info >/dev/null 2>&1; then
    containers=$(docker ps -aq --filter label=com.docker.compose.project=ambersight-vps)
    if [[ -n "$containers" ]]; then
        readarray -t container_ids <<< "$containers"
        docker update --restart=no "${container_ids[@]}"
        docker stop "${container_ids[@]}"
        printf 'Previous AmberSight containers stopped and retained.\n'
    fi
fi
systemctl stop ambersight-native.service 2>/dev/null || true
for path in "$BASE/config" "$BASE/data"; do
    mkdir -p "$path"
    chown -R ambersight:ambersight "$path"
    chmod 0700 "$path"
done
if [[ ! -f "$BASE/vps.env" ]]; then
    (umask 077; printf 'TZ=Europe/London\n' > "$BASE/vps.env")
fi
/usr/bin/python3 "$APP/scripts/configure-vps.py" prepare "$BASE/config/config.toml" "$BASE/vps.env" --template "$APP/config.example.toml" --native --uid "$(id -u ambersight)" --gid "$(id -g ambersight)"
ln -sfn "$release" "$BASE/current"
cat > /etc/systemd/system/ambersight-native.service <<'UNIT'
[Unit]
Description=AmberSight native NVR
Wants=network-online.target
After=network-online.target

[Service]
Type=simple
User=ambersight
Group=ambersight
WorkingDirectory=/opt/ambersight/data
Environment=TZ=Europe/London
Environment=LD_LIBRARY_PATH=/opt/ambersight/current
EnvironmentFile=/opt/ambersight/vps.env
ExecStart=/opt/ambersight/current/ambersight run --config /opt/ambersight/config/config.toml
Restart=on-failure
RestartSec=5
TimeoutStopSec=30
UMask=0077
NoNewPrivileges=yes
PrivateTmp=yes

[Install]
WantedBy=multi-user.target
UNIT
systemctl daemon-reload
systemctl start ambersight-native.service
ready=false
for ((attempt=0; attempt<60; attempt++)); do
    code=$(curl --silent --max-time 3 --cacert "$BASE/data/tls/ca.pem" -o /dev/null -w '%{http_code}' https://localhost:8090/api/cameras || true)
    if [[ $code == 401 ]]; then ready=true; break; fi
    sleep 2
done
if [[ $ready != true ]]; then
    systemctl stop ambersight-native.service || true
    fail 'HTTPS/authentication check failed. Service stopped. See: sudo journalctl -u ambersight-native -n 100 --no-pager'
fi
# Only the validated, authenticated configuration is changed to public binding.
systemctl stop ambersight-native.service
/usr/bin/python3 "$APP/scripts/configure-vps.py" publish "$BASE/config/config.toml" "$BASE/vps.env" --native --uid "$(id -u ambersight)" --gid "$(id -g ambersight)"
systemctl enable ambersight-native.service
systemctl start ambersight-native.service
sleep 2
systemctl is-active --quiet ambersight-native.service || fail 'Service did not stay running. Check its journal.'
cat > /usr/local/bin/ambersight-vps <<'HELPER'
#!/usr/bin/env bash
set -euo pipefail
case "${1:-status}" in
    status|ps) exec systemctl status ambersight-native.service ;;
    logs) exec journalctl -u ambersight-native.service -f -n 100 ;;
    start|stop|restart) exec systemctl "$1" ambersight-native.service ;;
    *) echo 'Usage: sudo ambersight-vps [status|logs|start|stop|restart]' >&2; exit 1 ;;
esac
HELPER
chmod 0755 /usr/local/bin/ambersight-vps
public_ip=$(sed -n 's/^AMBERSIGHT_PUBLIC_IP=//p' "$BASE/vps.env")
printf '\nNative installation running. Open https://%s:8090\nUsername: waqaar\n' "$public_ip"
cat <<'DONE'
Use the password you entered during setup. No SSH tunnel is needed.
Your browser warns until you trust AmberSight's own HTTPS certificate.
Allow inbound TCP 8090 in your VPS/provider firewall if needed.

Logs:    sudo ambersight-vps logs
Restart: sudo ambersight-vps restart
Update:  rerun this installer
Settings and recordings: /opt/ambersight/config and /opt/ambersight/data
The UI is unchanged. No Docker installation is required.
The VPS still needs a network route to the Reolink NVR before adding cameras.
DONE
