#!/usr/bin/env bash
#
# Entfernt den selbst gebauten NPU-Treiber vollständig.
# Der Auslieferungszustand von Ubuntu wird wiederhergestellt.

set -euo pipefail

info() { printf '\033[1;34m==>\033[0m %s\n' "$*"; }

[[ $(id -u) -eq 0 ]] || { echo "Bitte mit sudo ausführen." >&2; exit 1; }

info "Modul entladen"
modprobe -r aipu 2>/dev/null || echo "    (war nicht geladen)"

info "Paket entfernen"
if dpkg-query -W cix-npu-driver-dkms >/dev/null 2>&1; then
    apt-get remove --purge -y cix-npu-driver-dkms
else
    echo "    (cix-npu-driver-dkms nicht installiert)"
fi

info "DKMS-Reste aufräumen"
while read -r ver; do
    [[ -n "$ver" ]] || continue
    echo "    entferne aipu/$ver"
    dkms remove -m aipu -v "$ver" --all 2>/dev/null || true
    rm -rf "/usr/src/aipu-$ver"
done < <(dkms status aipu 2>/dev/null | sed -n 's|^aipu[/,] *\([^,:]*\).*|\1|p' | sort -u)

info "Modulabhängigkeiten neu aufbauen"
depmod -a

# Userspace-Teile nur auf ausdrücklichen Wunsch entfernen, da sie unabhängig
# vom Kerneltreiber genutzt werden können.
if [[ "${1:-}" == "--also-umd" ]]; then
    info "Userspace-Umgebung entfernen"
    rm -rf /opt/cix-npu /opt/cix-python3.13
    rm -f /usr/local/sbin/cix-noe-venv-install /etc/ld.so.conf.d/cix-npu.conf
    ldconfig
    echo "    /opt/cix-npu und /opt/cix-python3.13 entfernt"
    echo "    Die Pakete cix-noe-umd und cix-npu-onnxruntime bleiben bestehen;"
    echo "    entfernen mit: sudo apt remove cix-noe-umd cix-npu-onnxruntime"
fi

cat <<'EOF'

Rückbau abgeschlossen.

Der ausgelieferte Ubuntu-Kernel und dessen Module sind unverändert — dieses
Projekt hat nie etwas an /boot, an der initrd oder an ACPI-Tabellen geändert.
Ein Neustart ist nicht erforderlich, schadet aber nicht.

Das Build-Verzeichnis ./build kann gelöscht werden.
EOF
