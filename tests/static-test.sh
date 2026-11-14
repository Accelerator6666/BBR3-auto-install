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
print('Static checks passed. (No VM integration test performed.)')
PY
