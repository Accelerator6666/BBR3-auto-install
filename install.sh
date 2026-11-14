#!/usr/bin/env bash
# BBR3-auto-install v0.2.0 — auto-detect Debian/Ubuntu release and x86_64/ARM64.
# Pinned third-party kernel: byJoey/Actions-bbr-v3 x86_64-7.3.4.
set -Eeuo pipefail
umask 077

readonly INSTALLER_VERSION=0.2.0
readonly KERNEL_VERSION=7.3.4
readonly KREL="${KERNEL_VERSION}-joeyblog-bbrv3"
readonly PKG_VERSION=7.3.4-g7595a62d45ee-1
readonly UPSTREAM=https://github.com/byJoey/Actions-bbr-v3/releases/download
readonly BASE_DIR=/var/lib/bbr3-auto-install
readonly CACHE_DIR=/var/cache/bbr3-auto-install
readonly LOG_FILE=/var/log/bbr3-auto-install.log
readonly CONFIG_FILE=/etc/sysctl.d/99-bbrv3.conf
readonly FINALIZER=/usr/local/sbin/bbr3-finalize
readonly SERVICE=/etc/systemd/system/bbr3-finalize.service

OS_ID=''
OS_VERSION_ID=''
OS_CODENAME=''
OS_PRETTY_NAME=''
MACHINE_ARCH=''
DEB_ARCH=''
RELEASE_ARCH=''
TAG=''
IMAGE_NAME=''
HEADERS_NAME=''
IMAGE_SHA=''
HEADERS_SHA=''

ASSUME_YES=0
BACKUP_CONFIRMED=0
AUTO_REBOOT=1
STATUS_ONLY=0
CURRENT_KERNEL=''
OLD_ENTRY=''
NEW_ENTRY=''
NEED_ENA=0

usage() {
    cat <<EOF
BBR3-auto-install ${INSTALLER_VERSION}
Usage: sudo bash install.sh [--yes] [--backup-confirmed] [--no-reboot] [--status]

  --yes                Non-interactive installation
  --backup-confirmed   Confirm a restorable cloud snapshot/backup exists
  --no-reboot          Stage a one-time BBRv3 boot without rebooting now
  --status             Print kernel, BBR, FQ and install status (no changes)
  -h, --help           Show this help

Supported OS: Debian 12+ / Ubuntu 24.04+; CPU: x86_64/AMD64 or ARM64/AArch64.
BIOS + GRUB + systemd only in this revision. UEFI, containers, RPM/APK
systems and other architectures are rejected until separately validated.

The default successful install REBOOTS the host. A confirmed recovery
snapshot is mandatory, but the installer cannot verify one automatically.
EOF
}

log() { printf '[BBR3] %s\n' "$*"; }
die() { printf '[BBR3] ERROR: %s\n' "$*" >&2; exit 1; }
error_handler() { printf '[BBR3] FAILED at line %s (exit %s). Do NOT blindly reboot. Log: %s\n' "$1" "$2" "$LOG_FILE" >&2; }
trap 'error_handler "$LINENO" "$?"' ERR

for arg in "$@"; do
    case "$arg" in
        --yes) ASSUME_YES=1 ;;
        --backup-confirmed) BACKUP_CONFIRMED=1 ;;
        --no-reboot) AUTO_REBOOT=0 ;;
        --status) STATUS_ONLY=1 ;;
        -h|--help) usage; exit 0 ;;
        *) die "Unknown option: $arg" ;;
    esac
done

status() {
    if [[ -r /etc/os-release ]]; then
        # shellcheck disable=SC1091
        . /etc/os-release
        printf 'OS: %s (ID=%s VERSION_ID=%s CODENAME=%s)\n' "${PRETTY_NAME:-unknown}" "${ID:-unknown}" "${VERSION_ID:-unknown}" "${VERSION_CODENAME:-unknown}"
    fi
    printf 'Machine architecture: %s\n' "$(uname -m)"
    if command -v dpkg >/dev/null 2>&1; then printf 'Package architecture: %s\n' "$(dpkg --print-architecture)"; fi
    echo "Kernel: $(uname -r)"
    sysctl net.ipv4.tcp_congestion_control net.core.default_qdisc 2>/dev/null || true
    if command -v grub-editenv >/dev/null 2>&1; then grub-editenv list 2>/dev/null || true; fi
    if [[ -r "$BASE_DIR/result" ]]; then cat "$BASE_DIR/result"; fi
    if command -v tc >/dev/null 2>&1; then tc qdisc show 2>/dev/null || true; fi
}
if (( STATUS_ONLY )); then status; exit 0; fi

require_cmd() { command -v "$1" >/dev/null 2>&1 || die "Required command missing: $1"; }
detect_platform() {
    [[ -r /etc/os-release ]] || die 'Missing /etc/os-release'
    # shellcheck disable=SC1091
    . /etc/os-release
    OS_ID="${ID:-unknown}"
    OS_VERSION_ID="${VERSION_ID:-}"
    OS_CODENAME="${VERSION_CODENAME:-}"
    OS_PRETTY_NAME="${PRETTY_NAME:-$OS_ID}"

    case "$OS_ID" in
        debian)
            if [[ "$OS_VERSION_ID" =~ ^[0-9]+([.][0-9]+)*$ ]]; then
                dpkg --compare-versions "$OS_VERSION_ID" ge 12 || die "Debian 12+ required; detected Debian $OS_VERSION_ID"
            else
                case "$OS_CODENAME" in
                    bookworm|trixie|forky|sid) ;;
                    *) die "Unsupported Debian release: VERSION_ID=${OS_VERSION_ID:-unset}, VERSION_CODENAME=${OS_CODENAME:-unset}" ;;
                esac
            fi
            ;;
        ubuntu)
            [[ "$OS_VERSION_ID" =~ ^[0-9]+([.][0-9]+)*$ ]] || die "Cannot parse Ubuntu VERSION_ID: ${OS_VERSION_ID:-unset}"
            dpkg --compare-versions "$OS_VERSION_ID" ge 24.04 || die "Ubuntu 24.04+ required; detected Ubuntu $OS_VERSION_ID"
            ;;
        *)
            die "Unsupported distribution: ID=$OS_ID VERSION_ID=${OS_VERSION_ID:-unset}. Supported: Debian 12+ / Ubuntu 24.04+"
            ;;
    esac

    MACHINE_ARCH=$(uname -m)
    DEB_ARCH=$(dpkg --print-architecture)
    case "$MACHINE_ARCH:$DEB_ARCH" in
        x86_64:amd64)
            RELEASE_ARCH=x86_64
            IMAGE_SHA=0791ee3782ce935a3f984d38484a0d74b9651184390cb4bf71cccf28a07f903f
            HEADERS_SHA=603a9d1f2dfacac6caa9cfee5a0f938604e93cd217148a35132c151ea0bb69e7
            ;;
        aarch64:arm64)
            RELEASE_ARCH=arm64
            IMAGE_SHA=0ef3e4bc20726998b007a9574cead3854b9825948139bf54146e0ac4ef738317
            HEADERS_SHA=4cd8fe06a7a48812f5d4e904c4ea7279c1f22f71863ac6a3764de75a4b8d26df
            ;;
        *)
            die "Unsupported or mismatched CPU architecture: uname -m=$MACHINE_ARCH, dpkg architecture=$DEB_ARCH (supported: x86_64/amd64, aarch64/arm64)"
            ;;
    esac

    TAG="${RELEASE_ARCH}-${KERNEL_VERSION}"
    IMAGE_NAME="linux-image-${KREL}_${PKG_VERSION}_${DEB_ARCH}.deb"
    HEADERS_NAME="linux-headers-${KREL}_${PKG_VERSION}_${DEB_ARCH}.deb"

    log "Detected OS: $OS_PRETTY_NAME (ID=$OS_ID, VERSION_ID=${OS_VERSION_ID:-unset}, codename=${OS_CODENAME:-unset})"
    log "Detected CPU: $MACHINE_ARCH -> Debian package architecture $DEB_ARCH"
    log "Selected upstream release: $TAG"
}

preflight() {
    [[ ${EUID} -eq 0 ]] || die 'Run as root: sudo bash install.sh ...'
    detect_platform
    [[ ! -d /sys/firmware/efi ]] || die 'UEFI not yet supported (Secure Boot and EFI need dedicated validation)'
    [[ "$(cat /proc/1/comm)" == systemd ]] || die 'systemd must be PID 1'
    if command -v systemd-detect-virt >/dev/null 2>&1 && systemd-detect-virt --container --quiet; then
        die 'Containers cannot replace the host kernel'
    fi
    for c in curl sha256sum dpkg dpkg-deb uname tar awk sed grep findmnt df swapon mkswap fallocate \
             ip readlink grub-editenv grub-set-default grub-reboot grub-script-check \
             grub-probe update-grub lsinitramfs modinfo systemctl sysctl tee; do
        require_cmd "$c"
    done
    [[ -s /boot/grub/grub.cfg && -f /etc/default/grub ]] || die 'GRUB boot configuration not found'
    grub-script-check /boot/grub/grub.cfg || die 'Existing GRUB config invalid'
    [[ "$(grub-probe --target=fs /boot)" == ext2 ]] || die 'Expected ext-family /boot filesystem'
    [[ -z "$(dpkg --audit)" ]] || die 'dpkg contains broken/incomplete packages'
    CURRENT_KERNEL=$(uname -r)
    [[ -s "/boot/vmlinuz-$CURRENT_KERNEL" && -s "/boot/initrd.img-$CURRENT_KERNEL" ]] || die 'Original kernel or initrd missing; no safe fallback'
    grep -Fq "gnulinux-$CURRENT_KERNEL-advanced-" /boot/grub/grub.cfg || die 'Current kernel missing from GRUB advanced menu'
    local free_kb
    free_kb=$(df -Pk / | awk 'NR==2 {print $4}')
    (( free_kb >= 3 * 1024 * 1024 )) || die 'At least 3 GiB free on / required'
    if [[ -e /etc/kernel/postinst.d/zz-update-grub ]]; then
        log 'Kernel GRUB hook found.'
    else
        die 'Missing kernel GRUB update hook'
    fi
    local iface driver
    iface=$(ip -4 route show default | awk 'NR==1 {for(i=1;i<=NF;i++) if($i=="dev") {print $(i+1); exit}}')
    [[ -n "$iface" ]] || die 'No default IPv4 route, refusing remote kernel upgrade'
    driver=$(readlink -f "/sys/class/net/$iface/device/driver" 2>/dev/null || true)
    [[ "$driver" == */ena ]] && NEED_ENA=1
    log "Current kernel: $CURRENT_KERNEL; NIC: $iface (${driver##*/}); ENA required: $NEED_ENA"
}

ensure_swap() {
    local mem_kb swap_kb path
    mem_kb=$(awk '/^MemTotal:/ {print $2}' /proc/meminfo)
    swap_kb=$(awk '/^SwapTotal:/ {print $2}' /proc/meminfo)
    if (( mem_kb >= 786432 || swap_kb >= 524288 )); then return; fi
    path=/swapfile-bbr3
    [[ ! -e "$path" ]] || die "$path exists but usable swap was not detected: inspect it manually"
    log 'Low-memory VPS detected: creating a persistent 1 GiB swapfile.'
    fallocate -l 1G "$path"
    chmod 600 "$path"
    mkswap "$path" >/dev/null
    swapon "$path"
    grep -Eq '^[[:space:]]*/swapfile-bbr3[[:space:]]' /etc/fstab || \
        printf '%s\n' '/swapfile-bbr3 none swap sw,nofail 0 0' >> /etc/fstab
}

fetch_verified() {
    local name=$1 sha=$2 dest="$CACHE_DIR/$1" tmp
    mkdir -p "$CACHE_DIR"
    if [[ -f "$dest" ]] && printf '%s  %s\n' "$sha" "$dest" | sha256sum -c --status; then
        log "Using cached, verified $name"
        return 0
    fi
    tmp="${dest}.part"
    rm -f "$tmp"
    log "Downloading and SHA256-verifying $name"
    curl --fail --location --silent --show-error --retry 3 --connect-timeout 15 --max-time 600 \
        "$UPSTREAM/$TAG/$name" --output "$tmp"
    printf '%s  %s\n' "$sha" "$tmp" | sha256sum -c --status || die "SHA256 mismatch: $name"
    mv -f "$tmp" "$dest"
}

inspect_packages() {
    local image="$CACHE_DIR/$IMAGE_NAME" headers="$CACHE_DIR/$HEADERS_NAME" cfg="$CACHE_DIR/config-$KREL"
    [[ "$(dpkg-deb -f "$image" Package)" == "linux-image-$KREL" ]] || die 'Unexpected image package'
    [[ "$(dpkg-deb -f "$headers" Package)" == "linux-headers-$KREL" ]] || die 'Unexpected headers package'
    for p in "$image" "$headers"; do
        [[ "$(dpkg-deb -f "$p" Architecture)" == "$DEB_ARCH" ]] || die "Unexpected architecture: $p"
        [[ "$(dpkg-deb -f "$p" Version)" == "$PKG_VERSION" ]] || die "Unexpected package version: $p"
    done
    dpkg-deb --fsys-tarfile "$image" | tar -xOf - "./boot/config-$KREL" > "$cfg" || die 'Unable to extract kernel config'
    for key in CONFIG_TCP_CONG_BBR CONFIG_NET_SCH_FQ CONFIG_NVME_CORE CONFIG_BLK_DEV_NVME CONFIG_EXT4_FS; do
        grep -Fxq "$key=y" "$cfg" || die "Missing required built-in $key=y"
    done
    if (( NEED_ENA )); then
        grep -Fxq 'CONFIG_ENA_ETHERNET=m' "$cfg" || die 'Missing CONFIG_ENA_ETHERNET=m'
        dpkg-deb -c "$image" | grep -E '/ena\.ko(\.(xz|gz|zst))?$' > "$CACHE_DIR/ena-file-list" || die 'ENA driver absent from package'
    fi
    log 'Pinned package metadata, kernel config and AWS driver checks passed.'
}

# Never let dpkg's automatic update-grub make an untested kernel the default.
protect_fallback_before_install() {
    local sub_id old_id old_full
    sub_id=$(extract_entry 'gnulinux-advanced-')
    old_id=$(extract_entry "gnulinux-${CURRENT_KERNEL}-advanced-")
    [[ -n "$sub_id" && -n "$old_id" ]] || die 'Cannot identify currently running kernel in GRUB'
    old_full="$sub_id>$old_id"
    if grep -Eq '^GRUB_DEFAULT=' /etc/default/grub; then
        sed -i 's/^GRUB_DEFAULT=.*/GRUB_DEFAULT=saved/' /etc/default/grub
    else
        printf '%s\n' 'GRUB_DEFAULT=saved' >> /etc/default/grub
    fi
    if grep -Eq '^GRUB_SAVEDEFAULT=' /etc/default/grub; then
        sed -i 's/^GRUB_SAVEDEFAULT=.*/GRUB_SAVEDEFAULT=false/' /etc/default/grub
    else
        printf '%s\n' 'GRUB_SAVEDEFAULT=false' >> /etc/default/grub
    fi
    update-grub
    grub-script-check /boot/grub/grub.cfg
    grub-set-default "$old_full"
    grep -Fxq "saved_entry=$old_full" <(grub-editenv list) || die 'Could not secure old kernel as default'
    log "Old kernel pinned as default BEFORE package installation: $CURRENT_KERNEL"
}

backup_existing() {
    local dest
    dest="$BASE_DIR/backups/$(date +%Y%m%d-%H%M%S)"
    mkdir -p "$dest"
    cp -a /etc/default/grub /boot/grub/grub.cfg /boot/grub/grubenv "$dest/"
    cp -a "/boot/vmlinuz-$CURRENT_KERNEL" "/boot/initrd.img-$CURRENT_KERNEL" "$dest/"
    dpkg-query -W > "$dest/packages.txt"
    log "Boot configuration backup: $dest"
}

write_finalizer() {
    mkdir -p "$BASE_DIR"
    cat > "$FINALIZER" <<'FINALIZER_SCRIPT'
#!/usr/bin/env bash
set -Eeuo pipefail
umask 077
BASE=/var/lib/bbr3-auto-install
LOG=/var/log/bbr3-auto-install.log
exec >> "$LOG" 2>&1
printf '[BBR3 finalize] %s starting; kernel=%s\n' "$(date -Is)" "$(uname -r)"
# The state file is installed root-owned, mode 0600.
# shellcheck disable=SC1091
. "$BASE/boot.env"
if [[ "$(uname -r)" != "$KREL" ]]; then
    printf '[BBR3 finalize] Old kernel booted. Fallback remains default.\n'
    printf '%s\n' 'status=fallback' > "$BASE/result"
    systemctl disable bbr3-finalize.service || true
    exit 0
fi
sysctl -p /etc/sysctl.d/99-bbrv3.conf
[[ "$(sysctl -n net.ipv4.tcp_congestion_control)" == bbr ]]
[[ "$(sysctl -n net.core.default_qdisc)" == fq ]]
[[ -n "$(ip -4 route show default)" ]]
[[ -n "$(findmnt -no SOURCE /)" ]]
if [[ "$NEED_ENA" == 1 ]]; then
    iface=$(ip -4 route show default | awk 'NR==1 {for(i=1;i<=NF;i++) if($i=="dev") {print $(i+1); exit}}')
    [[ "$(readlink -f "/sys/class/net/$iface/device/driver")" == */ena ]]
fi
# Only commit the kernel after successful post-boot checks.
grub-set-default "$NEW_ENTRY"
grep -Fxq "saved_entry=$NEW_ENTRY" <(grub-editenv list)
printf 'status=success\nkernel=%s\nchecked_at=%s\n' "$KREL" "$(date -Is)" > "$BASE/result"
systemctl disable bbr3-finalize.service || true
printf '[BBR3 finalize] SUCCESS; BBRv3 is now GRUB default.\n'
FINALIZER_SCRIPT
    chmod 700 "$FINALIZER"

    cat > "$SERVICE" <<'UNIT'
[Unit]
Description=Validate BBRv3 boot and commit GRUB default only on success
Wants=network-online.target
After=network-online.target systemd-sysctl.service
ConditionPathExists=/var/lib/bbr3-auto-install/boot.env

[Service]
Type=oneshot
ExecStart=/usr/local/sbin/bbr3-finalize
TimeoutStartSec=90

[Install]
WantedBy=multi-user.target
UNIT
    systemctl daemon-reload
    systemctl enable bbr3-finalize.service
}

extract_entry() {
    local pattern=$1
    sed -nE "s/.*'(${pattern}[^']+)'.*/\\1/p" /boot/grub/grub.cfg | head -n 1
}

prepare_boot() {
    local sub_id old_id new_id old_full new_full
    # Saved-by-ID is stable across menu ordering changes; do not use menu index 0.
    sub_id=$(extract_entry 'gnulinux-advanced-')
    old_id=$(extract_entry "gnulinux-${CURRENT_KERNEL}-advanced-")
    new_id=$(extract_entry "gnulinux-${KREL}-advanced-")
    [[ -n "$sub_id" && -n "$old_id" && -n "$new_id" ]] || die 'Could not locate old/new GRUB advanced menu IDs'
    old_full="$sub_id>$old_id"
    new_full="$sub_id>$new_id"

    if grep -Eq '^GRUB_DEFAULT=' /etc/default/grub; then
        sed -i 's/^GRUB_DEFAULT=.*/GRUB_DEFAULT=saved/' /etc/default/grub
    else
        printf '%s\n' 'GRUB_DEFAULT=saved' >> /etc/default/grub
    fi
    if grep -Eq '^GRUB_SAVEDEFAULT=' /etc/default/grub; then
        sed -i 's/^GRUB_SAVEDEFAULT=.*/GRUB_SAVEDEFAULT=false/' /etc/default/grub
    else
        printf '%s\n' 'GRUB_SAVEDEFAULT=false' >> /etc/default/grub
    fi
    update-grub
    grub-script-check /boot/grub/grub.cfg
    # Set fallback first. If anything goes wrong, the normal boot stays old.
    grub-set-default "$old_full"
    OLD_ENTRY=$old_full
    NEW_ENTRY=$new_full
    {
        printf 'KREL=%q\n' "$KREL"
        printf 'OLD_ENTRY=%q\n' "$OLD_ENTRY"
        printf 'NEW_ENTRY=%q\n' "$NEW_ENTRY"
        printf 'NEED_ENA=%q\n' "$NEED_ENA"
    } > "$BASE_DIR/boot.env"
    chmod 600 "$BASE_DIR/boot.env"
    write_finalizer
    grub-reboot "$new_full"
    grep -Fxq "saved_entry=$old_full" <(grub-editenv list) || die 'Fallback default verification failed'
    grep -Fxq "next_entry=$new_full" <(grub-editenv list) || die 'One-shot BBRv3 GRUB entry verification failed'
    log 'Safe boot staged: old kernel is default; BBRv3 selected for NEXT BOOT ONLY.'
}

configure_tcp() {
    cat > "$CONFIG_FILE" <<'SYSCTL'
# BBR3-auto-install: requires a verified BBRv3-patched kernel
net.core.default_qdisc=fq
net.ipv4.tcp_congestion_control=bbr
SYSCTL
    if [[ "$(uname -r)" == "$KREL" ]]; then
        sysctl -p "$CONFIG_FILE"
    else
        log 'Saved BBR/FQ sysctl settings for new kernel; leaving old kernel running configuration unchanged.'
    fi
}

main() {
    preflight
    if (( ! BACKUP_CONFIRMED )); then
        if (( ASSUME_YES )); then die '--backup-confirmed is mandatory with --yes'; fi
        printf '%s\n' 'WARNING: A restorable snapshot/backup AND console recovery access are required.'
        read -r -p 'Do you have both? Type YES: ' reply
        [[ "$reply" == YES ]] || die 'Backup/recovery not confirmed'
    fi
    if (( ! ASSUME_YES )); then
        read -r -p "Install $KREL and reboot after staging? Type INSTALL: " reply
        [[ "$reply" == INSTALL ]] || die 'Cancelled by user'
    fi
    mkdir -p "$BASE_DIR"
    touch "$LOG_FILE"
    chmod 600 "$LOG_FILE"
    exec > >(tee -a "$LOG_FILE") 2>&1
    log "Starting installer $INSTALLER_VERSION on $(uname -r) for $OS_PRETTY_NAME / $MACHINE_ARCH"

    if [[ "$(uname -r)" == "$KREL" ]]; then
        log 'Target kernel already running; checking configuration without reinstalling.'
        configure_tcp
        if [[ -r "$BASE_DIR/boot.env" ]]; then
            # shellcheck disable=SC1090
            . "$BASE_DIR/boot.env"
            grub-set-default "$NEW_ENTRY"
        fi
        log 'Already on BBRv3; no reboot required.'
        return 0
    fi
    ensure_swap
    backup_existing
    fetch_verified "$IMAGE_NAME" "$IMAGE_SHA"
    fetch_verified "$HEADERS_NAME" "$HEADERS_SHA"
    inspect_packages
    protect_fallback_before_install
    log 'Installing verified image and headers (does not replace old kernel).'
    dpkg -i "$CACHE_DIR/$IMAGE_NAME" "$CACHE_DIR/$HEADERS_NAME"
    [[ -s "/boot/vmlinuz-$KREL" && -s "/boot/initrd.img-$KREL" ]] || die 'Missing new kernel/initrd'
    [[ -z "$(dpkg --audit)" ]] || die 'dpkg package state invalid after install'
    modinfo -k "$KREL" ena >/dev/null || die 'New ENA module missing after install'
    if (( NEED_ENA )); then
        lsinitramfs "/boot/initrd.img-$KREL" | grep -E '/ena\.ko(\.(xz|gz|zst))?$' > "$CACHE_DIR/ena-initrd-list" || die 'ENA missing from initramfs'
    fi
    configure_tcp
    prepare_boot
    log "Installer completed; log: $LOG_FILE"
    if (( AUTO_REBOOT )); then
        log 'Rebooting for one-time BBRv3 test. On failure, manually reboot via console to revert.'
        systemctl reboot
    else
        log 'No reboot (--no-reboot). A later reboot will test BBRv3 once.'
    fi
}

main
