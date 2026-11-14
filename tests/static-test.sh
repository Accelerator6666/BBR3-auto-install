#!/usr/bin/env bash
set -Eeuo pipefail
cd "$(dirname "$0")/.."
bash -n install.sh
bash install.sh --help | grep -Fq 'Debian 12'
bash install.sh --status >/dev/null
python3 - <<'PY'
import pathlib
import subprocess
p = pathlib.Path('install.sh').read_text()
start = "cat > \"$FINALIZER\" <<'FINALIZER_SCRIPT'\n"
assert start in p
finalizer = p.split(start, 1)[1].split('\nFINALIZER_SCRIPT', 1)[0]
subprocess.run(['bash', '-n'], input=finalizer, text=True, check=True)
assert 'protect_fallback_before_install\n    log' in p, 'Must pin fallback before dpkg'
assert p.index('protect_fallback_before_install\n    log') < p.index('dpkg -i "$CACHE_DIR/$IMAGE_NAME"')
assert 'grub-reboot "$new_full"' in p
assert 'grub-set-default "$NEW_ENTRY"' in finalizer
assert '0791ee3782ce935a3f984d38484a0d74b9651184390cb4bf71cccf28a07f903f' in p
assert '603a9d1f2dfacac6caa9cfee5a0f938604e93cd217148a35132c151ea0bb69e7' in p
assert 'Debian 12+' in p and 'Ubuntu 24.04+' in p
assert 'dpkg --compare-versions "$OS_VERSION_ID" ge 12' in p
assert 'dpkg --compare-versions "$OS_VERSION_ID" ge 24.04' in p
assert 'x86_64:amd64' in p
assert 'aarch64:arm64' in p
assert 'linux-image-${KREL}_${PKG_VERSION}_${DEB_ARCH}.deb' in p
assert '0ef3e4bc20726998b007a9574cead3854b9825948139bf54146e0ac4ef738317' in p
assert '4cd8fe06a7a48812f5d4e904c4ea7279c1f22f71863ac6a3764de75a4b8d26df' in p
# RAM-aware, idempotent swap provisioning and disk/fstab safety.
assert 'target_kb=$((2 * 1024 * 1024))' in p
assert 'target_kb=$((1024 * 1024))' in p
assert 'target_kb=$((512 * 1024))' in p
assert 'swapon --show --noheadings --raw --output NAME' in p
assert 'free_kb >= size_kb + reserve_kb' in p
assert 'cp -a /etc/fstab "$fstab_backup"' in p
assert 'sw,nofail 0 0' in p
assert 'fallocate -l "${size_mib}M" "$path"' in p
assert 'dd if=/dev/zero of="$path"' in p
assert 'RAM is at least 4 GiB' in p
assert 'ensure_swap\n    backup_existing' in p
assert 'MemTotal|SwapTotal' in p

print('Static checks passed. (No VM integration test performed.)')
PY
