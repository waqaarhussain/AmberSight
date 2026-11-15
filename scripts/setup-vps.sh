#!/usr/bin/env bash
# Ubuntu 24.04 VPS installer. Application code and UI are unchanged.
set -Eeuo pipefail
umask 022
trap 'printf "\nSetup stopped at line %s. Existing settings and recordings are kept.\n" "$LINENO" >&2' ERR

fail() { printf 'Error: %s\n' "$*" >&2; exit 1; }
[[ $EUID -eq 0 ]] || fail 'Run this installer with sudo bash.'
[[ $# -eq 0 ]] || fail 'This installer takes no arguments.'
. /etc/os-release
[[ ${ID:-} == ubuntu && ${VERSION_ID:-} == 24.04 ]] || fail 'This installer supports Ubuntu 24.04.'
case "$(dpkg --print-architecture)" in
    amd64|arm64) ;;
    *) fail 'Use an amd64 or arm64 VPS.' ;;
esac

exec 9>/run/lock/ambersight-setup.lock
flock -n 9 || fail 'Another AmberSight setup is already running.'
BASE=/opt/ambersight
APP="$BASE/app"
REPO=https://github.com/waqaarhussain/AmberSight.git
export DEBIAN_FRONTEND=noninteractive
printf '\nInstalling prerequisites...\n'
apt-get update
apt-get install -y ca-certificates curl git

if ! command -v docker >/dev/null 2>&1; then
    # Never uninstall another container runtime automatically.
    for package in docker.io docker-compose docker-compose-v2 docker-doc docker-buildx podman-docker containerd runc; do
        if [[ $(dpkg-query -W -f='${Status}' "$package" 2>/dev/null || true) == 'install ok installed' ]]; then
            fail "Existing $package installation found. Resolve Docker package conflicts first; nothing was removed."
        fi
    done
    printf '\nInstalling Docker from its official Ubuntu repository...\n'
    install -m 0755 -d /etc/apt/keyrings
    curl -fsSL --retry 3 https://download.docker.com/linux/ubuntu/gpg -o /etc/apt/keyrings/docker.asc
    chmod a+r /etc/apt/keyrings/docker.asc
    cat > /etc/apt/sources.list.d/docker.sources <<EOF
Types: deb
URIs: https://download.docker.com/linux/ubuntu
Suites: noble
Components: stable
Architectures: $(dpkg --print-architecture)
Signed-By: /etc/apt/keyrings/docker.asc
EOF
    apt-get update
    apt-get install -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin
fi
docker compose version >/dev/null 2>&1 || fail 'Docker is installed but Compose v2 is missing. Install its Compose plugin, then rerun.'
systemctl enable --now docker
docker info >/dev/null

install -d -m 0755 "$BASE"
if [[ -e "$APP" ]]; then
    [[ -d "$APP/.git" ]] || fail "$APP already exists and is not this checkout."
    [[ $(git -C "$APP" remote get-url origin) == "$REPO" ]] || fail 'The existing checkout has a different origin.'
    [[ -z $(git -C "$APP" status --porcelain) ]] || fail 'The checkout has local edits. Commit or move them before updating.'
    [[ $(git -C "$APP" branch --show-current) == master ]] || fail 'The checkout must be on master.'
    git -C "$APP" pull --ff-only origin master
else
    git clone --branch master --single-branch "$REPO" "$APP"
fi
for path in "$BASE/config" "$BASE/data"; do
    if [[ ! -d "$path" ]]; then
        install -d -m 0700 -o 1000 -g 1000 "$path"
    fi
done

# Only deployment settings go here. Camera credentials stay in config/config.toml.
if [[ ! -f "$BASE/vps.env" ]]; then
    (umask 077; printf 'TZ=Europe/London\nAMBERSIGHT_BIND_IP=127.0.0.1\n' > "$BASE/vps.env")
fi
compose=(docker compose --project-name ambersight-vps --env-file "$BASE/vps.env" -f "$APP/docker/compose.vps.yaml")
"${compose[@]}" config --quiet
printf '\nBuilding AmberSight. The initial Rust build can take a while...\n'
"${compose[@]}" build
# The running container is replaced only after a successful build.
"${compose[@]}" up -d --remove-orphans

cat > /usr/local/bin/ambersight-vps <<'HELPER'
#!/usr/bin/env bash
set -Eeuo pipefail
[[ $EUID -eq 0 ]] || { echo 'Run with sudo.' >&2; exit 1; }
exec docker compose --project-name ambersight-vps --env-file /opt/ambersight/vps.env -f /opt/ambersight/app/docker/compose.vps.yaml "$@"
HELPER
chmod 0755 /usr/local/bin/ambersight-vps

printf '\nWaiting for the web server...\n'
ready=false
for ((attempt=0; attempt<60; attempt++)); do
    # Check inside the container, so changing its host bind address or enabling
    # HTTPS later does not make an otherwise working update appear broken.
    if "${compose[@]}" exec -T ambersight bash -c 'exec 3<>/dev/tcp/127.0.0.1/8090' 2>/dev/null; then
        ready=true
        break
    fi
    sleep 2
done
if [[ $ready != true ]]; then
    "${compose[@]}" ps
    fail 'The web port did not become ready. Check: sudo ambersight-vps logs --tail 100'
fi

cat <<'DONE'

AmberSight is running. The original UI is unchanged.

First access, from PowerShell/Terminal on your own computer:
  ssh -N -L 18090:127.0.0.1:8090 YOUR_SSH_USER@YOUR_VPS_IP
Leave that window open, then browse to http://localhost:18090
(If you already enabled AmberSight HTTPS, use https://localhost:18090.)

Create your account under Settings > Users & security before adding cameras.
The dashboard is initially bound to localhost, so it is not publicly exposed.
If vps.env was changed previously, its existing bind address is preserved.

Settings:   /opt/ambersight/config
Recordings: /opt/ambersight/data
Logs:       sudo ambersight-vps logs -f --tail 100
Restart:    sudo ambersight-vps restart
Update:     rerun the same curl installer command

Your VPS needs a VPN route to your home NVR before camera streams can work.
See /opt/ambersight/app/docs/vps.md for access and Reolink notes.
DONE
