#!/usr/bin/env bash
#
# Prüft, ob der NPU-Kerneltreiber korrekt geladen und angebunden ist.
# Gibt 0 zurück, wenn alle Pflichtprüfungen bestehen.

set -uo pipefail

pass=0
fail=0

check() {
    local label="$1"; shift
    if "$@" >/dev/null 2>&1; then
        printf '  \033[1;32m[ok]\033[0m   %s\n' "$label"
        pass=$((pass + 1))
    else
        printf '  \033[1;31m[fehlt]\033[0m %s\n' "$label"
        fail=$((fail + 1))
    fi
}

echo "NPU-Status"
echo

check "NPU-Gerät (CIXH4000:00) erkannt" test -e /sys/bus/acpi/devices/CIXH4000:00
check "NPU-Kern 0 (CIXH4010:00) erkannt" test -e /sys/bus/acpi/devices/CIXH4010:00
check "NPU-Kern 1 (CIXH4010:01) erkannt" test -e /sys/bus/acpi/devices/CIXH4010:01
check "NPU-Kern 2 (CIXH4010:02) erkannt" test -e /sys/bus/acpi/devices/CIXH4010:02
check "Kernelmodul aipu geladen" sh -c 'lsmod | grep -q "^aipu "'
check "Zeichengerät /dev/aipu vorhanden" test -e /dev/aipu

echo
echo "Details"
echo

if lsmod 2>/dev/null | grep -q '^aipu '; then
    printf '  Modulversion:  %s\n' "$(modinfo -F version aipu 2>/dev/null || echo unbekannt)"
    printf '  force_dma32:   %s\n' \
        "$(cat /sys/module/aipu/parameters/force_dma32 2>/dev/null || echo 'nicht verfügbar')"
fi

if command -v dkms >/dev/null 2>&1; then
    printf '  DKMS:          %s\n' \
        "$(dkms status aipu 2>/dev/null | tr '\n' ' ' | sed 's/ *$//' || echo 'kein Eintrag')"
fi

echo
echo "  Kernelmeldungen (NPU):"
if ! dmesg 2>/dev/null | grep -iE 'aipu|sky1_npu|npu core' | tail -15 | sed 's/^/    /'; then
    echo "    (keine gefunden; ggf. sudo nötig)"
fi

echo
if [[ $fail -eq 0 ]]; then
    printf '\033[1;32mAlle %d Prüfungen bestanden.\033[0m\n' "$pass"
    exit 0
fi

printf '\033[1;33m%d von %d Prüfungen fehlgeschlagen.\033[0m\n' "$fail" "$((pass + fail))"
exit 1
