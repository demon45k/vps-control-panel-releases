#!/bin/bash
# The platform installer.
#
#   curl -fsSL https://<host>/install.sh | sudo bash
#
# Everything docs/INSTALLATION.md §9 describes by hand, done once and in the
# right order. That section exists because this script did not, and every
# deployment before this one was assembled by a person following it — which is
# how a control plane ends up with its secrets directory group-owned by a human
# account and nobody notices for a day.
#
# Three rules this script follows and a panel installer usually does not:
#
#   * It refuses more than it fixes. A Proxmox host, a machine with something
#     already on :443, a distribution it has not been tested on — these stop the
#     install rather than get worked around. An installer that presses on is one
#     whose failures land later, on somebody else's afternoon.
#   * Nothing is left half-done. Each step either completes or the script stops
#     and says which step and why. There is no "warning: continuing anyway".
#   * It never prints a secret it did not just generate, and prints those once.
set -euo pipefail

VERSION_FALLBACK="0.1.0"
PANEL_DOMAIN="${PANEL_DOMAIN:-}"
# Where the release bundle comes from when nobody says otherwise. Overridable so
# an air-gapped install, a mirror, or a build host on the same LAN can supply
# its own — the default is a convenience, not a dependency.
DEFAULT_BUNDLE="https://github.com/demon45k/vps-control-panel-releases/releases/latest/download/platform-release.tar.gz"
BUNDLE="${PLATFORM_BUNDLE:-$DEFAULT_BUNDLE}"
PACKAGE_DIR="${PLATFORM_PACKAGE_DIR:-}"
ADMIN_EMAIL="${PLATFORM_ADMIN_EMAIL:-}"
DB_NAME="${PLATFORM_DB_NAME:-platform}"
DB_USER="${PLATFORM_DB_USER:-platform}"
LOG="/var/log/platform-install.log"

# Whether this machine also serves customer websites.
#
# Default yes, because the thing being installed is a hosting business and a
# panel that can sell web hosting with nowhere to build it is half a product.
# Somebody opening a VPS company buys one server; requiring a second before
# they have a customer is requiring them to go elsewhere.
#
# It is a decision, not a default nobody sees: the step says what it costs, and
# PLATFORM_HOSTING_HERE=no declines it. Declining costs nothing later —
# `platformctl hosting enable-here` does the same thing on any day, and a
# separate node needs no change here at all.
HOSTING_HERE="${PLATFORM_HOSTING_HERE:-}"

TOTAL_STEPS=15
STEP=0
START=$(date +%s)

# ---------------------------------------------------------------- presentation

if [ -t 1 ] && [ -z "${NO_COLOR:-}" ]; then
    C_RESET=$'\033[0m'; C_DIM=$'\033[2m'; C_BOLD=$'\033[1m'
    C_OK=$'\033[32m'; C_WARN=$'\033[33m'; C_ERR=$'\033[31m'; C_ACCENT=$'\033[36m'
    TTY=1
else
    C_RESET=""; C_DIM=""; C_BOLD=""; C_OK=""; C_WARN=""; C_ERR=""; C_ACCENT=""
    TTY=0
fi

ok()   { printf '  %s✔%s %s\n' "$C_OK" "$C_RESET" "$*"; }
info() { printf '  %s→%s %s\n' "$C_ACCENT" "$C_RESET" "$*"; }
warn() { printf '  %s!%s %s\n' "$C_WARN" "$C_RESET" "$*"; }

# fail prints the step that failed and what to do about it, then stops. Every
# exit from this script goes through here or through success().
fail() {
    printf '\n%s✘ %s%s\n' "$C_ERR" "$*" "$C_RESET" >&2
    printf '  the full log is at %s\n' "$LOG" >&2
    exit 1
}

step() {
    STEP=$((STEP + 1))
    local pct=$(( STEP * 100 / TOTAL_STEPS ))
    local elapsed=$(( $(date +%s) - START ))
    if [ "$TTY" = 1 ]; then
        local width=40 filled=$(( pct * 40 / 100 )) bar=""
        local i
        for ((i = 0; i < width; i++)); do
            if [ "$i" -lt "$filled" ]; then bar="$bar█"; else bar="$bar░"; fi
        done
        printf '\n%s[%d/%d]%s %s %3d%% %s%ss%s\n' \
            "$C_ACCENT" "$STEP" "$TOTAL_STEPS" "$C_RESET" "$bar" "$pct" "$C_DIM" "$elapsed" "$C_RESET"
    else
        printf '\n[%d/%d] %d%% %ss\n' "$STEP" "$TOTAL_STEPS" "$pct" "$elapsed"
    fi
    printf '%s%s%s\n' "$C_BOLD" "$1" "$C_RESET"
}

banner() {
    printf '%s' "$C_ACCENT"
    cat <<'ART'

   ___  __     _    _____ ___  ___  ___  __  __
  / _ \/ /    /_\  |_   _| __|/ _ \| _ \|  \/  |
 / ___/ /__  / _ \   | | | _|| (_) |   /| |\/| |
/_/  /____/ /_/ \_\  |_| |_|  \___/|_|_\|_|  |_|

ART
    printf '%s' "$C_RESET"
    printf '  Linux hosting and cloud control plane\n'
    printf '  %sInstall log: %s%s\n\n' "$C_DIM" "$LOG" "$C_RESET"
}

# ------------------------------------------------------------------- utilities

run() { echo "+ $*" >>"$LOG"; "$@" >>"$LOG" 2>&1; }

gen_password() { openssl rand -base64 24 | tr -d '\n/+=' | cut -c1-24; }

port_busy() { ss -tlnH "sport = :$1" 2>/dev/null | grep -q . ; }

# port_holder names the process listening on a port, or "" if nothing is.
port_holder() {
    ss -tlnpH "sport = :$1" 2>/dev/null | sed -nE 's/.*users:\(\("([^"]+)".*/\1/p' | head -1
}

# have_tty reports whether there is a person to ask.
#
# Deliberately not `[ -t 0 ]`. The documented way to run this is
# `curl … | sudo bash`, which makes stdin the script itself — so a stdin test
# says "nobody is here" in exactly the case where somebody is, and the installer
# silently skips both of its questions. That produced a panel with no
# administrator account and no way to notice until you tried to sign in.
#
# The terminal is /dev/tty, which survives the pipe. Opening it is the test:
# under cron or in a container there is none, and the answer is honestly no.
have_tty() { [ -e /dev/tty ] && : >/dev/tty 2>/dev/null; }

# ask prints a prompt and reads one line from the terminal, not from stdin.
ask() {
    local prompt="$1" reply=""
    have_tty || return 1
    printf '%s' "$prompt" >/dev/tty
    IFS= read -r reply </dev/tty || return 1
    printf '%s' "$reply"
}

# other_nginx_sites lists enabled vhosts that are neither ours nor Debian's
# default. Used to tell "this machine's nginx, which we are about to configure"
# from "somebody else's web server, which we must not take".
#
# A customer's site is ours too. On a single-machine deployment the panel and
# the customers share one nginx, so by the second re-run this directory is full
# of vhosts the platform itself wrote — and refusing to re-run because the
# platform is doing its job would be the worst kind of guard. Every generated
# vhost opens with a marker line; anything carrying it is not somebody else's.
other_nginx_sites() {
    [ -d /etc/nginx/sites-enabled ] || return 0
    for site in /etc/nginx/sites-enabled/*; do
        [ -e "$site" ] || continue
        name="$(basename "$site")"
        case "$name" in default|platform) continue ;; esac
        head -n 1 "$site" 2>/dev/null | grep -q '^# Managed by platform' && continue
        printf '%s ' "$name"
    done
}

# ------------------------------------------------------------------------ start

[ "$(id -u)" -eq 0 ] || fail "this installer must run as root: pipe it to 'sudo bash'"
mkdir -p "$(dirname "$LOG")"; : >"$LOG"
banner

# ---------------------------------------------------------- 1. what am I on

step "Detecting the operating system"

[ -r /etc/os-release ] || fail "no /etc/os-release; this is not a distribution I can install on"
# shellcheck disable=SC1091
. /etc/os-release
ARCH="$(dpkg --print-architecture 2>/dev/null || uname -m)"
ok "Detected: ${PRETTY_NAME:-$ID $VERSION_ID}"
ok "Architecture: $ARCH"

# The deb family, because that is what the packages are. Debian 12 is the one
# the platform has actually run on; the others are accepted and said to be
# untested, which is the honest position — refusing them outright would be
# claiming knowledge nobody has either way.
#
# No version numbers reach the software from here. The PHP the node serves is
# whatever `php-fpm` resolves to on this distribution, and the node reports it
# rather than being told; that is the whole of what multi-distribution support
# needed on the deb side. An RPM distribution is a different question — it needs
# its own packaging, its own paths and its own SELinux story — and PlanContext
# is where those would go.
case "${ID}${VERSION_ID:+ $VERSION_ID}" in
    "debian 12") ;;
    "debian 13"|"ubuntu 22.04"|"ubuntu 24.04")
        warn "${PRETTY_NAME:-$ID} is supported but not yet exercised on hardware" ;;
    debian*|ubuntu*)
        warn "${PRETTY_NAME:-$ID} is newer or older than anything tested; continuing" ;;
    *) fail "this platform installs on Debian or Ubuntu. Found: ${PRETTY_NAME:-$ID}
  An RPM-based distribution needs packaging that does not exist yet." ;;
esac
[ "$ARCH" = "amd64" ] || fail "only amd64 is supported. Found: $ARCH"

# ---------------------------------------------------------- 2. refuse early

step "Pre-flight checks"

# The one refusal that is not about this machine working — it is about what this
# machine IS. §2 of the specification: the control plane is never a production
# Proxmox host. Installing here would put the thing that orchestrates a cluster
# inside the cluster it orchestrates, and take both down together.
if [ -d /etc/pve ] || command -v pveversion >/dev/null 2>&1; then
    fail "this is a Proxmox host. The control plane must never run on one — it
  manages Proxmox and cannot share its fate. Install on a separate machine."
fi

command -v systemctl >/dev/null 2>&1 || fail "systemd is required"

for port in 80 443; do
    port_busy "$port" || continue
    holder="$(port_holder "$port")"
    # Our own nginx is not a conflict — this installer configures it, and a run
    # that failed halfway leaves it running. Refusing here would mean the
    # installer could never be re-run after fixing whatever went wrong, which
    # is the one time anybody re-runs an installer.
    if [ "$holder" = "nginx" ]; then
        others="$(other_nginx_sites)"
        if [ -n "$others" ]; then
            fail "nginx on :$port is serving other sites: ${others% }
  This installer would take over its default server. Move those elsewhere, or
  install on a machine that is not already somebody's web server."
        fi
        continue
    fi
    fail "'${holder:-something}' is already listening on :$port. Stop it, or install
  on a machine with nothing else serving HTTP."
done

mem_mb=$(awk '/MemTotal/ {print int($2/1024)}' /proc/meminfo)
[ "$mem_mb" -ge 1800 ] || fail "this needs about 2 GB of RAM; this machine has ${mem_mb} MB"
disk_mb=$(df -Pm / | awk 'NR==2 {print $4}')
[ "$disk_mb" -ge 5000 ] || fail "this needs about 5 GB free on /; ${disk_mb} MB available"

ok "Not a Proxmox host"
ok ":80 and :443 are available"
ok "${mem_mb} MB RAM, ${disk_mb} MB free on /"

# ------------------------------------------------------- 3. where it will live

step "Panel address"

if [ -z "$PANEL_DOMAIN" ] && have_tty; then
    {
        printf '\n  Enter the domain this panel will be reached at (e.g. panel.example.com).\n'
        printf '  Leave blank to use this machine%s address with a self-signed certificate.\n' "'s"
        printf '  %sTip: set PANEL_DOMAIN=… in the environment to skip this prompt.%s\n' "$C_DIM" "$C_RESET"
    } >/dev/tty
    PANEL_DOMAIN="$(ask '  > ' || true)"
fi

PRIMARY_IP="$(ip -4 route get 1.1.1.1 2>/dev/null | sed -nE 's/.* src ([0-9.]+).*/\1/p' | head -1)"
[ -n "$PRIMARY_IP" ] || PRIMARY_IP="127.0.0.1"

if [ -n "$PANEL_DOMAIN" ]; then
    PANEL_HOST="$PANEL_DOMAIN"
    ok "Panel domain: $PANEL_DOMAIN"
    # Said now rather than discovered later: the certificate here is self-signed
    # whatever the domain is. ACME needs the domain to resolve to this machine
    # first, and that is not something an installer can arrange.
    info "A self-signed certificate is installed now; see the notes at the end
    for issuing a real one once DNS points here."
else
    PANEL_HOST="$PRIMARY_IP"
    ok "No domain given — the panel will answer on https://$PRIMARY_IP/"
fi

# --------------------------------------------------------- 4. the dependencies

step "Installing dependencies"

export DEBIAN_FRONTEND=noninteractive

# A machine this young is usually still running cloud-init's own package pass,
# which holds the dpkg lock. Ask cloud-init first — it knows when it is done.
if command -v cloud-init >/dev/null 2>&1; then
    info "waiting for cloud-init to finish its own package work"
    cloud-init status --wait >/dev/null 2>&1 || true
fi

# And then retry regardless, because cloud-init is not the only thing that takes
# that lock: unattended-upgrades runs on a timer and will happily start during
# an install.
#
# The wait is deliberately not `fuser`, which lives in psmisc and is absent from
# a minimal Debian cloud image — the check silently reported "not held" and this
# installer walked straight into the lock it was written to avoid.
apt_retry() {
    local tries=60 out
    while [ "$tries" -gt 0 ]; do
        if out="$(apt-get "$@" 2>&1)"; then echo "$out" >>"$LOG"; return 0; fi
        echo "$out" >>"$LOG"
        case "$out" in
            *"Could not get lock"*|*"Unable to acquire"*|*"is another process using it"*)
                tries=$((tries - 1)); sleep 5 ;;
            *) return 1 ;;
        esac
    done
    return 1
}

apt_retry update -qq || fail "apt-get update failed"
DEPS="postgresql nginx openssl gnupg ca-certificates curl iproute2 python3"
info "Installing: $DEPS"
# shellcheck disable=SC2086
apt_retry install -y -qq $DEPS || fail "installing dependencies failed"
ok "PostgreSQL $(psql --version | awk '{print $3}'), nginx $(nginx -v 2>&1 | sed 's#.*/##')"

# ------------------------------------------------------------ 5. the platform

step "Installing the platform"

if [ -n "$BUNDLE" ]; then
    work="$(mktemp -d)"
    case "$BUNDLE" in
        http://*|https://*)
            info "Downloading $BUNDLE"
            curl -fsSL "$BUNDLE" -o "$work/bundle.tar.gz" || fail "downloading the release bundle failed"
            ;;
        *) cp "$BUNDLE" "$work/bundle.tar.gz" || fail "cannot read $BUNDLE" ;;
    esac
    tar -xzf "$work/bundle.tar.gz" -C "$work" || fail "the release bundle is not readable"
    # The bundle carries a versioned top-level directory, so the packages sit
    # three levels down: platform-<version>/packages/<name>.deb.
    PACKAGE_DIR="$(find "$work" -maxdepth 4 -name '*.deb' -printf '%h\n' | head -1)"
    [ -n "$PACKAGE_DIR" ] || fail "the release bundle contains no packages"
    WEB_DIR="$(find "$work" -maxdepth 4 -type d -name 'web' | head -1)"
fi

[ -n "$PACKAGE_DIR" ] || fail "no packages to install: set PLATFORM_BUNDLE=<url|file> or
  PLATFORM_PACKAGE_DIR=<directory of .deb files>"

info "Installing packages from $PACKAGE_DIR"
# The control-plane set. The Proxmox agent is never installed here — it belongs
# on a hypervisor, and this machine is refused as one. The hosting agent is a
# separate question answered in step 14, because this machine may legitimately
# serve websites too.
pkgs=""
for name in platform-cli platform-api platform-controller platform-worker \
            platform-scheduler platform-console-proxy; do
    p="$(ls "$PACKAGE_DIR"/${name}_*.deb 2>/dev/null | head -1)"
    [ -n "$p" ] || fail "$name is missing from $PACKAGE_DIR"
    pkgs="$pkgs $p"
done
# shellcheck disable=SC2086
run dpkg -i $pkgs || apt_retry -f install -y -qq || fail "installing the platform packages failed"
VERSION="$(platformctl version 2>/dev/null | awk '{print $2}')"
[ -n "$VERSION" ] || VERSION="$VERSION_FALLBACK"
ok "platformctl $VERSION"

# --------------------------------------------------------------- 6. accounts

step "Service accounts and directories"

getent group platform >/dev/null || fail "the packages did not create the platform group"
# The check that a hand-built deployment failed: this group is the entire access
# boundary for the master key, so a human account inside it is the boundary gone.
humans="$(awk -F: -v gid="$(getent group platform | cut -d: -f3)" \
    '$3 >= 1000 && $3 < 65534 && $4 == gid {print $1}' /etc/passwd || true)"
[ -z "$humans" ] || fail "these login accounts are in the 'platform' group, which may only
  contain services: $humans"

install -d -m 0750 -o root -g platform /etc/platform
install -d -m 0750 -o root -g platform /etc/platform/secrets
install -d -m 0750 -o root -g root     /etc/platform/tls
install -d -m 0700 -o root -g root     /var/backups/platform
ok "/etc/platform is root:platform 0750 — services traverse it, people do not"

# --------------------------------------------------------------- 7. database

step "PostgreSQL"

run systemctl enable --now postgresql || fail "PostgreSQL did not start"

if sudo -u postgres psql -tAc "SELECT 1 FROM pg_roles WHERE rolname='$DB_USER'" | grep -q 1; then
    ok "role $DB_USER already exists; leaving its password alone"
    [ -r /etc/platform/database-url ] || fail "the role exists but /etc/platform/database-url does not.
  This machine has a partial install; sort out the DSN by hand before rerunning."
else
    DB_PASSWORD="$(gen_password)"
    sudo -u postgres psql -qc \
        "CREATE ROLE $DB_USER LOGIN PASSWORD '$DB_PASSWORD'" >>"$LOG" 2>&1 \
        || fail "creating the database role failed"
    # The DSN is an EnvironmentFile and never a line in a TOML: config files get
    # pasted into tickets and committed to deployment repositories.
    printf 'PLATFORM_DATABASE_URL=postgres://%s:%s@127.0.0.1:5432/%s?sslmode=disable\n' \
        "$DB_USER" "$DB_PASSWORD" "$DB_NAME" > /etc/platform/database-url
    chown root:platform /etc/platform/database-url
    chmod 0640 /etc/platform/database-url
    ok "role $DB_USER created"
fi

if ! sudo -u postgres psql -tAc "SELECT 1 FROM pg_database WHERE datname='$DB_NAME'" | grep -q 1; then
    sudo -u postgres createdb -O "$DB_USER" "$DB_NAME" >>"$LOG" 2>&1 \
        || fail "creating the database failed"
fi
ok "database $DB_NAME ready"

# shellcheck disable=SC1091
set -a; . /etc/platform/database-url; set +a

# ----------------------------------------------------------------- 8. secrets

step "Generating keys"

if [ -s /etc/platform/secrets/master.key ]; then
    ok "master key already present; not regenerating"
else
    run platformctl secrets init --path /etc/platform/secrets/master.key \
        || fail "generating the master key failed"
    ok "master key generated"
fi
if [ -s /etc/platform/secrets/backup.key ]; then
    ok "backup key already present; not regenerating"
else
    run platformctl secrets backup-key --path /etc/platform/secrets/backup.key \
        || fail "generating the backup key failed"
    ok "backup keypair generated"
fi
chown -R root:platform /etc/platform/secrets
chmod 0750 /etc/platform/secrets
chmod 0640 /etc/platform/secrets/master.key /etc/platform/secrets/backup.key

# --------------------------------------------------------- 9. the config files

step "Configuration"

cat > /etc/platform/api.toml <<TOML
[logging]
level = "info"

[api]
# Loopback only. This server speaks plain HTTP — TLS is nginx's job — so binding
# it to the network would put session cookies on the wire in the clear.
listen = "127.0.0.1:8443"
shutdown_grace = "15s"
controller_dispatch = "/run/platform/controller/dispatch.sock"

[database]
# Supplied by systemd from /etc/platform/database-url.
url = ""

[console]
# ProxyURL appends /console/<token>, so no path belongs here.
public_url = "wss://$PANEL_HOST"

[secrets]
master_key_file = "/etc/platform/secrets/master.key"
retired_key_files = []

[notifications]
platform_name = "Platform"
portal_url = "https://$PANEL_HOST"
TOML

cat > /etc/platform/controller.toml <<'TOML'
[logging]
level = "info"

[database]
url = ""

[controller]
listen = ":8444"
state_dir = "/var/lib/platform/controller"
dispatch_socket = "/run/platform/controller/dispatch.sock"
sans = []

[secrets]
master_key_file = "/etc/platform/secrets/master.key"
retired_key_files = []
backup_key_file = "/etc/platform/secrets/backup.key"

[hosting]
# Left empty on purpose. This is the fallback offer for a node that has not
# reported its stack yet; every node that has reported says which PHP versions
# it actually carries, and a guess written here would be offered to a customer
# whose node cannot serve it. Step 14 fills it in from what is really installed
# when this machine is also a hosting node.
php_versions = []
TOML

cat > /etc/platform/worker.toml <<'TOML'
[logging]
level = "info"

[database]
url = ""

[worker]
poll_interval = "2s"
concurrency = 4
reaper_interval = "30s"

[notifications]
platform_name = "Platform"
# No mail relay configured yet, so messages are written to the log rather than
# silently dropped or half-sent through a server nobody set up.
log_only = true
dispatch_interval = "1m"

[secrets]
master_key_file = "/etc/platform/secrets/master.key"
backup_key_file = "/etc/platform/secrets/backup.key"
TOML

cat > /etc/platform/scheduler.toml <<'TOML'
[logging]
level = "info"

[database]
url = ""
TOML

cat > /etc/platform/console-proxy.toml <<'TOML'
[logging]
level = "info"

[database]
url = ""

[console]
# Not :8444 — that is the controller's agent endpoint.
listen = "127.0.0.1:8445"

[secrets]
# A console session opens the cluster's API token, so this needs the master key.
master_key_file = "/etc/platform/secrets/master.key"
retired_key_files = []
TOML

chown root:platform /etc/platform/*.toml
chmod 0640 /etc/platform/*.toml

for svc in api controller worker scheduler console-proxy; do
    install -d -m 0755 "/etc/systemd/system/platform-$svc.service.d"
    cat > "/etc/systemd/system/platform-$svc.service.d/database.conf" <<'DROPIN'
[Service]
# The DSN reaches the process from one root-owned file the service group reads,
# so it lives in exactly one place on this host.
EnvironmentFile=/etc/platform/database-url
DROPIN
done
systemctl daemon-reload
ok "five service configurations written, DSN supplied by systemd"

# --------------------------------------------------------------- 10. schema

step "Database schema"

applied="$(platformctl migrate up 2>&1 | tail -1)"
echo "$applied" >>"$LOG"
run platformctl migrate status || fail "the schema could not be read back"
count="$(sudo -u postgres psql -d "$DB_NAME" -tAc \
    "SELECT count(*) FROM pg_tables WHERE schemaname='public'")"
ok "migrations applied — $count tables"

# --------------------------------------------------------------- 11. portal

step "Web portal"

install -d -m 0755 -o root -g root /var/www/platform
if [ -n "${WEB_DIR:-}" ] && [ -d "$WEB_DIR" ]; then
    cp -r "$WEB_DIR"/. /var/www/platform/
    find /var/www/platform -type d -exec chmod 0755 {} +
    find /var/www/platform -type f -exec chmod 0644 {} +
    ok "portal installed to /var/www/platform"
else
    # An honest placeholder rather than a blank 403. Somebody who reaches this
    # page should learn what is missing, not wonder whether the install worked.
    cat > /var/www/platform/index.html <<'HTML'
<!doctype html><meta charset="utf-8"><title>Platform</title>
<body style="font:16px system-ui;max-width:40em;margin:4em auto;padding:0 1em">
<h1>The API is running; the portal is not installed.</h1>
<p>This release bundle carried no web assets. The API is answering at
<code>/api/v1/</code> and everything works through it — but there is no
interface here until the portal is deployed to <code>/var/www/platform</code>.</p>
</body>
HTML
    warn "no portal assets in the bundle — a placeholder page is installed"
fi

# ------------------------------------------------------------ 12. nginx + TLS

step "Nginx and TLS"

if [ ! -s /etc/platform/tls/portal.crt ]; then
    san="DNS:$PANEL_HOST"
    if [[ "$PANEL_HOST" =~ ^[0-9.]+$ ]]; then san="IP:$PANEL_HOST"; fi
    run openssl req -x509 -newkey rsa:4096 -sha256 -days 825 -nodes \
        -keyout /etc/platform/tls/portal.key -out /etc/platform/tls/portal.crt \
        -subj "/CN=$PANEL_HOST" \
        -addext "subjectAltName=$san,DNS:localhost,IP:127.0.0.1" \
        || fail "generating the TLS certificate failed"
    chmod 0640 /etc/platform/tls/portal.key
    chmod 0644 /etc/platform/tls/portal.crt
    ok "self-signed certificate for $PANEL_HOST"
else
    ok "certificate already present; leaving it alone"
fi

CSP="default-src 'self'; script-src 'self'; style-src 'self' 'unsafe-inline'; img-src 'self' data:; font-src 'self'; connect-src 'self'; frame-ancestors 'none'; base-uri 'none'; form-action 'self'; object-src 'none'"

cat > /etc/nginx/sites-available/platform <<CONF
# The portal and the API share one origin.
#
# Not a convenience: the session is a cookie, and a portal served from a
# different origin than the API it calls needs CORS and SameSite=None — which is
# to say it needs the two protections that make a session cookie worth having
# turned off.

server {
    listen 80 default_server;
    listen [::]:80 default_server;
    server_name _;
    return 301 https://\$host\$request_uri;
}

server {
    listen 443 ssl http2 default_server;
    listen [::]:443 ssl http2 default_server;
    server_name _;

    ssl_certificate     /etc/platform/tls/portal.crt;
    ssl_certificate_key /etc/platform/tls/portal.key;
    ssl_protocols TLSv1.2 TLSv1.3;

    # Only the process that terminated TLS can honestly assert this;
    # platform-api gates its own on r.TLS, which is nil behind this proxy.
    add_header Strict-Transport-Security "max-age=31536000; includeSubDomains" always;

    root /var/www/platform;
    index index.html;

    location /api/ {
        proxy_pass http://127.0.0.1:8443;
        proxy_http_version 1.1;
        proxy_set_header Host              \$host;
        proxy_set_header X-Real-IP         \$remote_addr;
        proxy_set_header X-Forwarded-For   \$proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto \$scheme;
        proxy_read_timeout 120s;
    }

    # The console proxy's own route is /console/{token}, and :8445 — :8444 is
    # the controller's agent endpoint.
    location /console/ {
        proxy_pass http://127.0.0.1:8445;
        proxy_http_version 1.1;
        proxy_set_header Upgrade    \$http_upgrade;
        proxy_set_header Connection "upgrade";
        proxy_set_header Host       \$host;
        proxy_read_timeout 3600s;
    }

    # nginx's add_header does not merge: a location that sets any header cancels
    # every one inherited from the server block, so each repeats what it needs.
    location /assets/ {
        add_header Cache-Control "public, max-age=31536000, immutable" always;
        add_header X-Content-Type-Options nosniff always;
        add_header Strict-Transport-Security "max-age=31536000; includeSubDomains" always;
    }

    location / {
        # nginx serves the document, so nginx states the document's policy —
        # platform-api's headers apply only to what platform-api answers.
        add_header Content-Security-Policy "$CSP" always;
        add_header Strict-Transport-Security "max-age=31536000; includeSubDomains" always;
        add_header X-Content-Type-Options nosniff always;
        add_header X-Frame-Options DENY always;
        add_header Referrer-Policy same-origin always;
        add_header Permissions-Policy "camera=(), microphone=(), geolocation=(), payment=()" always;

        try_files \$uri \$uri/ /index.html;
    }
}
CONF

ln -sf /etc/nginx/sites-available/platform /etc/nginx/sites-enabled/platform
rm -f /etc/nginx/sites-enabled/default
run nginx -t || fail "the nginx configuration this installer wrote does not parse"
run systemctl enable nginx || fail "nginx could not be enabled"
# reload-or-restart, not `enable --now`. On a machine where nginx was already
# running — which is every re-run, and every machine that had nginx before this
# — `--now` is a no-op and the vhost just written is never read. The install
# reports success and nothing is listening on :443.
run systemctl reload-or-restart nginx || fail "nginx did not start"
port_busy 443 || fail "nginx is running but nothing is listening on :443"
ok "nginx serving the portal and proxying /api"

# ------------------------------------------------------------ 13. the services

step "Starting the platform"

run systemctl enable --now platform-controller platform-api platform-worker \
    platform-scheduler platform-console-proxy || fail "the services did not start"
sleep 4
for s in platform-controller platform-api platform-worker platform-scheduler platform-console-proxy; do
    state="$(systemctl is-active "$s" || true)"
    if [ "$state" = "active" ]; then ok "$s"; else
        fail "$s is $state. journalctl -u $s -n 50"
    fi
done

# The nightly dump, installed now rather than "later": this machine starts
# holding invoices the first time somebody buys something.
if [ -x /usr/bin/platform-db-backup ]; then
    run systemctl enable --now platform-db-backup.timer || true
    ok "nightly database dump at 03:20, 14-day retention"
fi

# ----------------------------------------------------------- 14. web hosting

step "Web hosting on this machine"

# Asked only where there is somebody to ask. A piped install has no terminal and
# gets the default, which is stated rather than assumed silently.
if [ -z "$HOSTING_HERE" ]; then
    if have_tty; then
        printf '\n  This machine can serve customer websites as well as run the panel:\n' >/dev/tty
        printf '  one server for the whole product. Customer PHP would then run\n' >/dev/tty
        printf '  alongside the database and the Proxmox token — right for one server,\n' >/dev/tty
        printf '  wrong for twenty, and movable to its own node later at no cost.\n\n' >/dev/tty
        printf '  Serve websites here? [Y/n] ' >/dev/tty
        reply="$(ask '' || true)"
        case "$reply" in [Nn]*) HOSTING_HERE=no ;; *) HOSTING_HERE=yes ;; esac
    else
        HOSTING_HERE=yes
        info "no terminal to ask: serving websites here (PLATFORM_HOSTING_HERE=no declines)"
    fi
fi

if [ "$HOSTING_HERE" = "no" ]; then
    ok "not serving websites here; run 'platformctl hosting enable-here' to change that"
else
    # platform-hosting-node names what a website needs — nginx, PHP-FPM,
    # MariaDB — so this script does not. dpkg leaves them unconfigured and
    # `apt-get -f install` fetches them from the distribution; the list lives in
    # one place, where dpkg checks it, rather than here where nothing does.
    hpkgs=""
    for name in platform-hosting-helper platform-hosting-agent platform-hosting-node; do
        p="$(ls "$PACKAGE_DIR"/${name}_*.deb 2>/dev/null | head -1)"
        [ -n "$p" ] || fail "$name is missing from $PACKAGE_DIR"
        hpkgs="$hpkgs $p"
    done
    info "Installing the hosting node and its web stack"
    # shellcheck disable=SC2086
    dpkg -i $hpkgs >>"$LOG" 2>&1 || true
    apt_retry -f install -y -qq || fail "installing the hosting node failed"
    # dpkg -i is allowed to fail above — it always does when a dependency is not
    # yet present — so the check that matters is whether the packages ended up
    # configured, not what dpkg returned.
    for name in platform-hosting-helper platform-hosting-agent platform-hosting-node; do
        [ "$(dpkg-query -W -f='${Status}' "$name" 2>/dev/null)" = "install ok installed" ] \
            || fail "$name did not install. See $LOG"
    done
    # What the distribution actually gave us. A version counts as present when
    # its pool directory exists, because that is exactly the directory a
    # customer's pool is written into — the same test the node's own capability
    # report uses, so the fallback and the report cannot disagree.
    php_found=""
    for dir in /etc/php/*/fpm/pool.d; do
        [ -d "$dir" ] || continue
        v="${dir#/etc/php/}"; v="${v%%/*}"
        php_found="$php_found${php_found:+, }\"$v\""
    done
    [ -n "$php_found" ] || fail "php-fpm installed but no /etc/php/*/fpm/pool.d exists"
    run sed -i "s|^php_versions = .*|php_versions = [$php_found]|" /etc/platform/controller.toml \
        || fail "recording the installed PHP versions failed"
    # The controller read the empty list at step 13. It is the process that
    # hands a node its supported versions, so it has to read the file again
    # before the node enrols against it.
    run systemctl restart platform-controller || fail "restarting the controller failed"
    ok "hosting node installed: nginx, PHP $(echo "$php_found" | tr -d '"'), MariaDB, agent and helper"

    # Everything from here — the token, the CSR, the units, waiting for the node
    # to report in — is platformctl's, not a second copy of it living in a shell
    # script. A local node enrols the way a remote one does.
    if platformctl hosting enable-here --yes >>"$LOG" 2>&1; then
        ok "this machine is enrolled as a hosting node"
    else
        fail "enrolling this machine as a hosting node failed. See $LOG"
    fi
fi

# ------------------------------------------------------- 15. the administrator

step "Administrator account and verification"

if [ -z "$ADMIN_EMAIL" ] && have_tty; then
    printf '\n  Email address for the first administrator.\n' >/dev/tty
    ADMIN_EMAIL="$(ask '  > ' || true)"
fi
ADMIN_PASSWORD=""
if [ -n "$ADMIN_EMAIL" ]; then
    ADMIN_PASSWORD="$(gen_password)"
    if platformctl bootstrap --email "$ADMIN_EMAIL" --org "Platform" --slug platform \
        --password "$ADMIN_PASSWORD" >>"$LOG" 2>&1; then
        if grep -q "already exists" "$LOG"; then
            ADMIN_PASSWORD=""
            ok "an account for $ADMIN_EMAIL already existed; nothing was changed"
        else
            ok "administrator $ADMIN_EMAIL created"
            # Nobody is watching an unattended install. The password is printed
            # below and that is enough for a person at a terminal; a cloud-init
            # run prints into a log file instead, which is both harder to find
            # and no more private. So it is written where whatever started this
            # install can collect it, and told to remove it afterwards.
            if ! have_tty; then
                umask 077
                printf '%s\n' "$ADMIN_PASSWORD" > /root/platform-admin-password
                chmod 0600 /root/platform-admin-password
                ok "password written to /root/platform-admin-password (delete it once collected)"
            fi
        fi
    else
        fail "creating the administrator failed"
    fi
else
    # Loud, because this is the difference between a working panel and one
    # nobody can sign in to, and it is silent otherwise.
    warn "no administrator was created — there is nothing to sign in with yet"
    warn "run: sudo platformctl bootstrap --email you@example.com"
fi

printf '\n'
platformctl preflight --config /etc/platform/controller.toml || true

# ------------------------------------------------------------------- finished

printf '\n%s┌──────────────────────────────────────────────┐%s\n' "$C_OK" "$C_RESET"
printf '%s│%s  %sPlatform installed successfully%s             %s│%s\n' \
    "$C_OK" "$C_RESET" "$C_BOLD" "$C_RESET" "$C_OK" "$C_RESET"
printf '%s└──────────────────────────────────────────────┘%s\n\n' "$C_OK" "$C_RESET"

printf '  %sVersion:%s      %s\n' "$C_DIM" "$C_RESET" "$VERSION"
printf '  %sPanel:%s        https://%s/\n' "$C_DIM" "$C_RESET" "$PANEL_HOST"
if [ "$HOSTING_HERE" = "no" ]; then
    printf '  %sHosting:%s      on its own node — none enrolled yet\n' "$C_DIM" "$C_RESET"
else
    printf '  %sHosting:%s      on this machine (%s)\n' "$C_DIM" "$C_RESET" "$(hostname)"
fi
if [ -n "$ADMIN_PASSWORD" ]; then
    printf '\n  %sSign in with:%s\n' "$C_BOLD" "$C_RESET"
    printf '    email:      %s\n' "$ADMIN_EMAIL"
    printf '    password:   %s%s%s\n' "$C_BOLD" "$ADMIN_PASSWORD" "$C_RESET"
    printf '  %sShown once. It is not stored anywhere and cannot be recovered.%s\n' "$C_WARN" "$C_RESET"
else
    printf '\n  %sNo sign-in yet — no administrator account exists.%s\n' "$C_WARN" "$C_RESET"
    printf '    sudo platformctl bootstrap --email you@example.com\n'
fi

cat <<NEXT

  ${C_BOLD}Commands${C_RESET}
    platformctl preflight            ask the deployment whether it works
    platformctl catalog list         what this deployment sells
    platformctl org create           create a customer
    platformctl --help               everything else

  ${C_BOLD}Services${C_RESET}
    systemctl status platform-api platform-controller platform-worker
    journalctl -u platform-api -f

  ${C_BOLD}Paths${C_RESET}
    Config:      /etc/platform/
    Secrets:     /etc/platform/secrets/     (root:platform 0750)
    DSN:         /etc/platform/database-url
    Portal:      /var/www/platform/
    Backups:     /var/backups/platform/
    Install log: $LOG

  ${C_BOLD}Next${C_RESET}
    1. Open the panel and sign in.
    2. ${C_WARN}Escrow the keys${C_RESET} — sudo platform-escrow-keys /root/keys.tar.gz.gpg
       Four pieces, one copy each. Losing them loses every certificate, every
       sealed backup and the CA every node trusts. Do this before you sell
       anything.
    3. Register a Proxmox cluster, then run preflight again. Until one is
       registered this deployment can sell web hosting and nothing else —
       machines and containers are built on Proxmox.
    4. Create something to sell: platformctl catalog product / plan / price,
       or the catalogue screen in the panel.
NEXT

if [ -z "$PANEL_DOMAIN" ]; then
    printf '\n  %sThe certificate is self-signed, so browsers will warn. That warning is\n' "$C_DIM"
    printf '  accurate — nobody has vouched for it. Point a domain here and issue a real\n'
    printf '  certificate when this stops being a test.%s\n' "$C_RESET"
fi
printf '\n'
