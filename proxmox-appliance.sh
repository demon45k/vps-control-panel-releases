#!/bin/bash
# Build the panel as a virtual machine, on the Proxmox host, in one command.
#
#   curl -fsSL https://<host>/proxmox-appliance.sh | bash
#
# The other installer assumes a healthy machine: a working apt, a network
# mirror, curl, sudo. Somebody who has just installed Debian by hand from a DVD
# has none of those, and spends an evening on `sources.list` before they reach
# anything this project wrote. That evening is not a thing to document better.
# It is a thing to delete.
#
# So this does not install onto a machine. It makes the machine: Debian's own
# cloud image, which arrives with apt, curl, sudo and cloud-init already
# working, and first-boot instructions that run the platform installer. What an
# operator does is run this and read the address it prints.
#
# It uses `qm` and `pvesh` and nothing else — Proxmox stays the authority for
# its own objects, and /etc/pve is never written by hand.
set -euo pipefail

RELEASES="${PLATFORM_RELEASES:-https://raw.githubusercontent.com/demon45k/vps-control-panel-releases/main}"
IMAGE_URL="${PLATFORM_CLOUD_IMAGE:-https://cloud.debian.org/images/cloud/bookworm/latest/debian-12-generic-amd64.qcow2}"
VMID="${PLATFORM_VMID:-}"
STORAGE="${PLATFORM_STORAGE:-}"
BRIDGE="${PLATFORM_BRIDGE:-vmbr0}"
CORES="${PLATFORM_CORES:-4}"
MEMORY="${PLATFORM_MEMORY:-4096}"
DISK="${PLATFORM_DISK:-40G}"
NAME="${PLATFORM_NAME:-platform-panel}"
ADMIN_EMAIL="${PLATFORM_ADMIN_EMAIL:-}"
SSH_KEY="${PLATFORM_SSH_KEY:-}"

if [ -t 1 ] && [ -z "${NO_COLOR:-}" ]; then
    C_RESET=$'\033[0m'; C_DIM=$'\033[2m'; C_BOLD=$'\033[1m'
    C_OK=$'\033[32m'; C_WARN=$'\033[33m'; C_ERR=$'\033[31m'
else
    C_RESET=''; C_DIM=''; C_BOLD=''; C_OK=''; C_WARN=''; C_ERR=''
fi
say()  { printf '  %s\n' "$*"; }
ok()   { printf '  %s✓%s %s\n' "$C_OK" "$C_RESET" "$*"; }
warn() { printf '  %s!%s %s\n' "$C_WARN" "$C_RESET" "$*"; }
fail() { printf '\n  %s✗ %s%s\n\n' "$C_ERR" "$*" "$C_RESET" >&2; exit 1; }

# The first-boot instructions, as a function so they can be printed and
# checked without a Proxmox host anywhere near them.
emit_user_data() {
        echo "#cloud-config"
        echo "hostname: $NAME"
        echo "manage_etc_hosts: true"
        echo "package_update: true"
        echo "packages: [qemu-guest-agent, curl, ca-certificates]"
        echo "users:"
        echo "  - name: platform"
        echo "    sudo: ALL=(ALL) NOPASSWD:ALL"
        echo "    shell: /bin/bash"
        echo "    lock_passwd: false"
        echo "    passwd: '$CONSOLE_HASH'"
        if [ -n "$SSH_KEY" ]; then
            echo "    ssh_authorized_keys: ['$SSH_KEY']"
        fi
        echo "runcmd:"
        echo "  - systemctl enable --now qemu-guest-agent"
        # The marker files are how the host watches without guessing: one when the
        # install starts, one when it ends, and the exit status in it. Polling for
        # "is the panel answering yet" would report success for a panel that is up
        # and an install that failed halfway.
        echo "  - [ sh, -c, 'touch /root/.platform-install-started' ]"
        # Said on the console too, so somebody watching `qm terminal` sees progress
        # rather than a blank screen — which is all the guest offers when the agent
        # never comes up, and the agent never comes up when the network is broken.
        echo "  - [ sh, -c, 'echo \"platform: fetching the installer\" > /dev/console' ]"
        # Fetched with python3, which cloud-init itself is written in and which is
        # therefore certainly present, rather than with curl, which is installed by
        # the apt run three lines above. A bootstrap step that depends on the step
        # before it having worked is a bootstrap step that fails silently the one
        # time it matters.
        echo "  - [ sh, -c, 'python3 -c \"import urllib.request;open(\\\"/root/install.sh\\\",\\\"wb\\\").write(urllib.request.urlopen(\\\"$RELEASES/install.sh\\\").read())\" >> /root/platform-install.out 2>&1' ]"
        # Downloaded to a file and then run, rather than piped. In "VAR=x curl … |
        # bash" the variable is set for curl and for nothing else, so the installer
        # ran with no administrator email and created no account to sign in with.
        echo "  - [ sh, -c, 'PLATFORM_ADMIN_EMAIL=$ADMIN_EMAIL bash /root/install.sh >> /root/platform-install.out 2>&1; echo \$? > /root/.platform-install-done' ]"
        echo "  - [ sh, -c, 'echo \"platform: install finished with \$(cat /root/.platform-install-done)\" > /dev/console' ]"
}

# ------------------------------------------------------------------ refuse early

# Print the first-boot instructions and stop, without touching anything.
#
# For an operator who wants to read what will run on their machine before it
# runs, and for CI, which parses the result: cloud-init silently does nothing at
# all when its input is malformed, and "nothing happened and the guest never
# came up" is indistinguishable from a broken network. A generator whose output
# is never parsed is a generator nobody has checked.
if [ -n "${PLATFORM_PRINT_USER_DATA:-}" ]; then
    NAME="${NAME:-platform-panel}"
    ADMIN_EMAIL="${ADMIN_EMAIL:-you@example.com}"
    CONSOLE_PASSWORD="not-generated-in-this-mode"
    CONSOLE_HASH='$6$example$hash'
    emit_user_data
    exit 0
fi

[ "$(id -u)" -eq 0 ] || fail "run this as root on the Proxmox host"

# The mirror image of the other installer's first refusal. That one refuses to
# install the control plane ON Proxmox; this one has to BE on Proxmox, because
# it is Proxmox it asks to build the machine.
command -v qm >/dev/null 2>&1 || fail "this runs on a Proxmox VE host: qm was not found.
  To install onto a machine you already have, use install.sh instead."

# Storage: whatever the operator said, or the first one that can hold a disk.
# Guessed rather than demanded, because a first-time operator does not yet know
# what their storages are called, and the guess is stated so it can be corrected.
#
# Local before networked, and that ordering is the point rather than a detail.
# "The first active storage" put the panel's disk on an NFS export from a NAS
# that had crashed the day before — the machine that runs the billing database
# and holds the cluster's credentials, depending for every write on a box that
# is not part of the cluster. A control plane must not share fate with
# something it does not manage.
pick_storage() {
    local want
    for want in lvmthin zfspool btrfs dir lvm; do
        pvesm status -content images 2>/dev/null |
            awk -v t="$want" 'NR>1 && $2==t && $3=="active" {print $1; exit}'
    done | head -1
}
if [ -z "$STORAGE" ]; then
    STORAGE="$(pick_storage)"
    if [ -n "$STORAGE" ]; then
        say "storage: $STORAGE ${C_DIM}(local; PLATFORM_STORAGE to choose another)${C_RESET}"
    else
        # Nothing local. Networked storage is allowed rather than refused — a
        # cluster may genuinely have only shared storage — but it is said out
        # loud, because it is a decision and not a detail.
        STORAGE="$(pvesm status -content images 2>/dev/null | awk 'NR>1 && $3=="active" {print $1; exit}')"
        [ -n "$STORAGE" ] || fail "no active storage can hold a VM disk.
  Name one with PLATFORM_STORAGE=<storage>."
        warn "storage: $STORAGE — this is not local to this node."
        warn "The panel will depend on it for every write. Local storage is better."
    fi
fi

# Snippets are how cloud-init is given a file rather than a handful of options,
# and a storage carries them only if somebody ticked the box. On a stock
# Proxmox install nothing does, which is why this says where the box is.
SNIPPET_STORE="${PLATFORM_SNIPPET_STORAGE:-}"
if [ -z "$SNIPPET_STORE" ]; then
    SNIPPET_STORE="$(pvesm status -content snippets 2>/dev/null | awk 'NR>1 && $3=="active" {print $1; exit}')"
    [ -n "$SNIPPET_STORE" ] || fail "no storage accepts snippets, which cloud-init needs.
  In the Proxmox UI: Datacenter > Storage > local > Edit > Content > add Snippets.
  Or name one with PLATFORM_SNIPPET_STORAGE=<storage>."
    say "snippets: $SNIPPET_STORE"
fi

[ -n "$VMID" ] || VMID="$(pvesh get /cluster/nextid)"
qm status "$VMID" >/dev/null 2>&1 && fail "VM $VMID already exists. Choose another with PLATFORM_VMID=<id>."

if [ -z "$ADMIN_EMAIL" ] && [ -e /dev/tty ]; then
    printf '\n  Email address for the first administrator: ' >/dev/tty
    IFS= read -r ADMIN_EMAIL </dev/tty || true
fi
[ -n "$ADMIN_EMAIL" ] || fail "an administrator email is required: PLATFORM_ADMIN_EMAIL=you@example.com
  Without one the panel installs and nobody can sign in to it."

printf '\n%s  Building the panel as VM %s on %s%s\n\n' "$C_BOLD" "$VMID" "$(hostname)" "$C_RESET"

# --------------------------------------------------------------- the disk image

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

# Cached between runs: the image is ~350 MB and an operator building a second
# panel should not download it again.
CACHE="/var/lib/vz/template/qemu"
mkdir -p "$CACHE"
IMAGE="$CACHE/$(basename "$IMAGE_URL")"
if [ -s "$IMAGE" ]; then
    ok "cloud image already downloaded"
else
    say "downloading Debian's cloud image (about 350 MB)"
    curl -fsSL --retry 3 -o "$IMAGE.part" "$IMAGE_URL" || fail "downloading the cloud image failed"
    mv "$IMAGE.part" "$IMAGE"
    ok "cloud image downloaded"
fi

# ------------------------------------------------------------ first-boot recipe

# Written as a file rather than as --ciuser/--cipassword options: this has to
# run a script on first boot, and only user-data can say that.
#
# The installer is fetched at first boot rather than baked in, so a panel built
# today from an image cached last month is still the current release.
# Asked of Proxmox rather than assumed: a snippets storage may be a directory,
# an NFS export or anything else with a path, and /var/lib/vz is only where it
# lands when the storage happens to be `local`.
SNIPPET_BASE="$(pvesh get "/storage/$SNIPPET_STORE" --output-format json 2>/dev/null |
    grep -o '"path"[[:space:]]*:[[:space:]]*"[^"]*"' | head -1 |
    sed 's/.*"\([^"]*\)"$/\1/')"
[ -n "$SNIPPET_BASE" ] || fail "storage $SNIPPET_STORE has no filesystem path, so it cannot hold a snippet.
  Name a directory or NFS storage with PLATFORM_SNIPPET_STORAGE=<storage>."
SNIPPET_DIR="$SNIPPET_BASE/snippets"
mkdir -p "$SNIPPET_DIR"
USERDATA="$SNIPPET_DIR/platform-$VMID-user-data.yml"

# A console password, and it is not optional.
#
# Debian's cloud image has root locked and no password anywhere: the intended
# way in is an SSH key. Built without one, the first version of this script
# produced a machine that could fail and then could not be looked at — the
# install did not finish, and the operator had a serial console with no
# credentials for it. A recovery path that only exists when nothing went wrong
# is not a recovery path.
#
# Hashed here rather than written in the clear, because the snippet is a file
# on shared storage that outlives the install.
CONSOLE_PASSWORD="$(head -c 18 /dev/urandom | base64 | tr -d '+/=' | cut -c1-20)"
CONSOLE_HASH="$(openssl passwd -6 "$CONSOLE_PASSWORD" 2>/dev/null)" \
    || fail "openssl could not hash the console password"


emit_user_data > "$USERDATA"
chmod 0600 "$USERDATA"
ok "first-boot instructions written"

# ------------------------------------------------------------------ the machine

qm create "$VMID" --name "$NAME" --cores "$CORES" --memory "$MEMORY" \
    --net0 "virtio,bridge=$BRIDGE" --ostype l26 --agent 1 \
    --scsihw virtio-scsi-single --serial0 socket --vga serial0 >/dev/null \
    || fail "creating the VM failed"

# --vga serial0 above: a cloud image has no graphical console, and an operator
# who opens the Proxmox console on a black screen concludes the machine is dead.

qm importdisk "$VMID" "$IMAGE" "$STORAGE" >/dev/null 2>&1 || fail "importing the disk failed"
# The imported volume's name is the storage's business, not this script's: a
# thin-LVM volume, an RBD image and a qcow2 file are not named alike, and
# guessing "vm-<id>-disk-0" works until somebody points this at Ceph. Proxmox
# parks it as unused0 and that is what gets attached.
IMPORTED="$(qm config "$VMID" | sed -n 's/^unused0: //p')"
[ -n "$IMPORTED" ] || fail "the imported disk did not appear on VM $VMID"
qm set "$VMID" --scsi0 "$IMPORTED,iothread=1" >/dev/null || fail "attaching the disk failed"
qm resize "$VMID" scsi0 "$DISK" >/dev/null || fail "resizing the disk to $DISK failed"
qm set "$VMID" --ide2 "$STORAGE:cloudinit" --boot order=scsi0 >/dev/null \
    || fail "attaching the cloud-init drive failed"
qm set "$VMID" --ipconfig0 ip=dhcp \
    --cicustom "user=$SNIPPET_STORE:snippets/$(basename "$USERDATA")" >/dev/null \
    || fail "attaching the first-boot instructions failed"
ok "VM $VMID created: $CORES cores, $MEMORY MB, $DISK"

qm start "$VMID" >/dev/null || fail "starting the VM failed"
ok "started"

# ----------------------------------------------------------------- watch it run

say ""
say "installing — this takes about five minutes"

guest() { qm guest exec "$VMID" -- "$@" 2>/dev/null; }
guest_out() { guest "$@" | sed -n 's/.*"out-data" : "\(.*\)"/\1/p' | head -1; }

# The agent answers only once the guest has booted and installed it, so the
# first minute of silence is expected rather than a fault.
deadline=$(( $(date +%s) + 900 ))
state="booting"
while [ "$(date +%s)" -lt "$deadline" ]; do
    if guest test -f /root/.platform-install-done >/dev/null 2>&1; then
        state="done"; break
    fi
    if [ "$state" = "booting" ] && guest test -f /root/.platform-install-started >/dev/null 2>&1; then
        state="installing"
        ok "guest is up; the platform installer is running"
    fi
    sleep 10
done

if [ "$state" != "done" ]; then
    # Two different failures wearing the same timeout, and telling them apart is
    # the difference between one command and an evening. If the agent never
    # answered, nothing inside ever ran and the guest almost certainly has no
    # network; if it answered and the install did not finish, the installer is
    # the thing to read.
    printf '\n'
    if [ "$state" = "booting" ]; then
        warn "the guest never answered: qemu-guest-agent is not running in VM $VMID."
        warn "It is installed by apt on first boot, so this usually means the VM"
        warn "has no working network — the same thing that stops the installer."
        printf '\n  %sCheck, from inside:%s\n' "$C_BOLD" "$C_RESET"
        printf '    ip -br addr        does it have an address on %s?\n' "$BRIDGE"
        printf '    ip route           is there a default route?\n'
        printf '    getent hosts deb.debian.org    does DNS answer?\n'
    else
        warn "the guest is up and the installer did not finish within fifteen minutes."
        printf '\n  %sRead the log, from inside:%s\n' "$C_BOLD" "$C_RESET"
        printf '    cat /root/platform-install.out\n'
        printf '    cat /var/log/cloud-init-output.log\n'
    fi
    printf '\n  %sGet in:%s\n' "$C_BOLD" "$C_RESET"
    printf '    qm terminal %s      %s(Ctrl+O to leave)%s\n' "$VMID" "$C_DIM" "$C_RESET"
    printf '    user: platform   password: %s%s%s\n\n' "$C_BOLD" "$CONSOLE_PASSWORD" "$C_RESET"
    printf '  %sStart over:%s  qm stop %s && qm destroy %s\n\n' \
        "$C_BOLD" "$C_RESET" "$VMID" "$VMID"
    exit 1
fi

status="$(guest_out cat /root/.platform-install-done | tr -dc '0-9')"
if [ "${status:-1}" != "0" ]; then
    fail "the platform installer failed inside the VM (exit ${status:-unknown}).
  Look inside:  qm terminal $VMID   (then: cat /root/platform-install.out)"
fi
ok "platform installed"

IP="$(guest_out sh -c "ip -4 -br addr show scope global | awk '{print \$3}' | cut -d/ -f1 | head -1")"
PASSWORD="$(guest_out cat /root/platform-admin-password | tr -d '\\\\n')"
# Read once and removed: the installer's own contract is that this is shown one
# time, and a plaintext password left on a disk is a plaintext password left on
# a disk however it got there.
guest rm -f /root/platform-admin-password >/dev/null 2>&1 || true

printf '\n%s┌──────────────────────────────────────────────┐%s\n' "$C_OK" "$C_RESET"
printf '%s│%s  %sThe panel is running%s                        %s│%s\n' \
    "$C_OK" "$C_RESET" "$C_BOLD" "$C_RESET" "$C_OK" "$C_RESET"
printf '%s└──────────────────────────────────────────────┘%s\n\n' "$C_OK" "$C_RESET"

printf '  %sPanel:%s     https://%s/\n' "$C_DIM" "$C_RESET" "${IP:-<the VM has no address yet>}"
printf '  %sEmail:%s     %s\n' "$C_DIM" "$C_RESET" "$ADMIN_EMAIL"
if [ -n "$PASSWORD" ]; then
    printf '  %sPassword:%s  %s%s%s\n' "$C_DIM" "$C_RESET" "$C_BOLD" "$PASSWORD" "$C_RESET"
    printf '  %sShown once. It is not stored anywhere and cannot be recovered.%s\n' "$C_WARN" "$C_RESET"
else
    warn "the password could not be read back; run inside the VM:"
    warn "  platformctl bootstrap --email $ADMIN_EMAIL"
fi

cat <<NEXT

  ${C_BOLD}The certificate is self-signed${C_RESET}, so the browser will warn once. Point a
  name at ${IP:-the VM} and the panel can get a real one.

  ${C_BOLD}Next${C_RESET}
    1. Sign in.
    2. Register this Proxmox cluster, so the panel can build machines.
    3. Escrow the keys — inside the VM: platform-escrow-keys /root/keys.tar.gz.gpg

  ${C_BOLD}The VM${C_RESET}
    console:  qm terminal $VMID        ${C_DIM}(Ctrl+O to leave)${C_RESET}
    login:    platform / $CONSOLE_PASSWORD
    log:      /root/platform-install.out inside it

  That console login is for this machine's own shell, not for the panel. It is
  shown here because a machine you cannot get into is a machine you cannot fix.
NEXT
