#!/usr/bin/env bash
#
# Sammelt alle für die Fehlersuche relevanten Informationen zur CIX-NPU.
# Verändert nichts. Ausgabe kann direkt weitergegeben werden.

set -uo pipefail

section() { printf '\n=== %s ===\n' "$1"; }

section "Zeitpunkt"
date -R

section "Betriebssystem und Kernel"
. /etc/os-release 2>/dev/null && echo "$PRETTY_NAME"
uname -srm

section "Board und BIOS"
for f in board_vendor board_name product_name bios_version bios_date; do
    printf '%-14s %s\n' "$f:" "$(cat "/sys/class/dmi/id/$f" 2>/dev/null || echo '-')"
done

section "ACPI-Geräte der NPU"
ls -d /sys/bus/acpi/devices/CIXH40*  2>/dev/null || echo "keine gefunden"

section "Kernelmodul"
modinfo aipu 2>/dev/null | sed -n '1,12p' || echo "Modul aipu nicht installiert"
echo "--- geladen? ---"
lsmod 2>/dev/null | grep -E '^(aipu|Module)' || echo "aipu nicht geladen"

section "Modulparameter"
if [[ -d /sys/module/aipu/parameters ]]; then
    for p in /sys/module/aipu/parameters/*; do
        printf '%-16s %s\n' "$(basename "$p"):" "$(cat "$p" 2>/dev/null)"
    done
else
    echo "keine (Modul nicht geladen)"
fi

section "DKMS"
dkms status 2>/dev/null || echo "dkms nicht verfügbar"

section "Geräteknoten"
ls -l /dev/aipu 2>/dev/null || echo "/dev/aipu fehlt"

section "Relevante Pakete"
dpkg-query -W -f='${binary:Package}\t${Version}\n' 2>/dev/null |
    grep -Ei 'cix|aipu|noe|npu|linux-image|linux-headers' || echo "keine"

section "IOMMU / SMMU"
ls /sys/class/iommu 2>/dev/null || echo "kein IOMMU sichtbar"

section "Kernelmeldungen: NPU"
dmesg 2>/dev/null | grep -iE 'aipu|sky1_npu|npu' | tail -40 ||
    echo "keine (ggf. sudo nötig)"

section "Kernelmeldungen: SMMU-Fehler"
dmesg 2>/dev/null | grep -iE 'smmu|iommu.*fault|arm-smmu' | tail -25 ||
    echo "keine"

section "Userspace-Treiber (libnoe)"
ldconfig -p 2>/dev/null | grep -i noe || echo "libnoe nicht im Bibliothekspfad"

printf '\n=== Ende ===\n'
