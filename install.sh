#!/usr/bin/env bash
#
# NPU-Treiber für CIX P1 (ZHOUYI V3) unter Ubuntu 26.04 bauen und installieren.
#
# Baut den aktuellen CIX-Kerneltreiber 6.2.0 aus den offiziellen Quellen als
# DKMS-Paket und wendet dabei nur die Patches an, die auf diesem System noch
# nötig sind.
#
# Quelle: https://github.com/cixtech/cix_opensource__npu_driver (cix_mainline_dev)
#
# Lizenz: BSD-2-Clause-Patent für die Skripte dieses Projekts.
# Der Treiber selbst behält seine Lizenz (Apache-2.0 / GPL-2.0).

set -euo pipefail

# --- Konfiguration ----------------------------------------------------------

# Offizielle CIX-Treiberquellen.
DRIVER_REPO="https://github.com/cixtech/cix_opensource__npu_driver.git"
DRIVER_BRANCH="cix_mainline_dev"

# Auf diesen Commit gepinnt: "DPTSW-23705: update to new version 6.2.0-1"
# (09.07.2026). Das ist der Stand, gegen den die Patches dieses Projekts
# erzeugt und geprüft wurden.
DRIVER_COMMIT="31ee26f0b5f768d20d1fea65c2360eed7303a0a1"

# Versionssuffix, damit das eigene Paket von einem späteren CIX-Paket
# unterscheidbar bleibt.
LOCAL_SUFFIX="+msr1.1"

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
WORK_DIR="${WORK_DIR:-$REPO_DIR/build}"

# --- Optionen ---------------------------------------------------------------

LEGACY_UMD=0
SKIP_DEPS=0
BUILD_ONLY=0
FORCE_PIN=1

usage() {
    cat <<'EOF'
Aufruf: sudo ./install.sh [Optionen]

Optionen:
  --legacy-umd    Zusätzlich den ABI-Kompatibilitätspatch für alte
                  Userspace-Treiber (cix-noe-umd 2.0.2 und älter) anwenden.
                  Nur nötig, wenn kein aktueller UMD verfügbar ist.
                  Achtung: schließt die Nutzung eines aktuellen UMD aus.
  --build-only    Nur das .deb bauen, nicht installieren.
  --skip-deps     Installation der Build-Abhängigkeiten überspringen.
  --latest        Nicht auf den geprüften Commit pinnen, sondern die
                  Zweigspitze verwenden (Patches können dann scheitern).
  -h, --help      Diese Hilfe anzeigen.
EOF
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        --legacy-umd) LEGACY_UMD=1 ;;
        --build-only) BUILD_ONLY=1 ;;
        --skip-deps)  SKIP_DEPS=1 ;;
        --latest)     FORCE_PIN=0 ;;
        -h|--help)    usage; exit 0 ;;
        *) echo "Unbekannte Option: $1" >&2; usage >&2; exit 2 ;;
    esac
    shift
done

# --- Hilfsfunktionen --------------------------------------------------------

info()  { printf '\033[1;34m==>\033[0m %s\n' "$*"; }
warn()  { printf '\033[1;33mWarnung:\033[0m %s\n' "$*" >&2; }
die()   { printf '\033[1;31mFehler:\033[0m %s\n' "$*" >&2; exit 1; }

# --- Vorprüfungen -----------------------------------------------------------

info "Umgebung prüfen"

[[ $(id -u) -eq 0 ]] || die "Bitte mit sudo ausführen."
[[ "$(uname -m)" == "aarch64" ]] || die "Dieses Projekt ist nur für arm64/aarch64."

KVER="$(uname -r)"
echo "    Kernel:       $KVER"
echo "    Distribution: $(. /etc/os-release && echo "$PRETTY_NAME")"

HDR_DIR="/lib/modules/$KVER/build"
[[ -d "$HDR_DIR" ]] || die "Kernel-Header für $KVER fehlen. Installieren mit:
    sudo apt install linux-headers-$KVER"

# Die drei NPU-Kerne müssen als ACPI-Geräte auftauchen. Fehlen sie, hat das
# BIOS die _HID-Angaben nicht gesetzt und es braucht zusätzlich einen
# ACPI-Override (siehe README, Abschnitt "Wenn die NPU-Kerne fehlen").
core_count=0
for d in /sys/bus/acpi/devices/CIXH4010:*; do
    [[ -e "$d" ]] && core_count=$((core_count + 1))
done

if [[ -e /sys/bus/acpi/devices/CIXH4000:00 ]]; then
    echo "    NPU-Gerät:    CIXH4000:00 vorhanden"
else
    die "Kein NPU-Gerät (CIXH4000:00) gefunden. Ist das ein CIX-P1-System und
ist ACPI im UEFI aktiv?"
fi

if [[ $core_count -ge 3 ]]; then
    echo "    NPU-Kerne:    $core_count erkannt"
else
    warn "Nur $core_count von 3 NPU-Kernen erkannt (CIXH4010:*)."
    warn "Ohne die Kerne kann der Treiber nicht anbinden. Siehe README,"
    warn "Abschnitt \"Wenn die NPU-Kerne fehlen\" (ACPI-Override)."
fi

# --- Build-Abhängigkeiten ---------------------------------------------------

if [[ $SKIP_DEPS -eq 0 ]]; then
    info "Build-Abhängigkeiten installieren"
    apt-get update
    apt-get install -y --no-install-recommends \
        git build-essential dkms debhelper dh-dkms dh-exec devscripts \
        fakeroot "linux-headers-$KVER"
else
    info "Build-Abhängigkeiten übersprungen (--skip-deps)"
fi

# --- Quellen holen ----------------------------------------------------------

info "Treiberquellen holen"

mkdir -p "$WORK_DIR"
SRC_DIR="$WORK_DIR/cix_npu_driver"

if [[ -d "$SRC_DIR/.git" ]]; then
    git -C "$SRC_DIR" fetch --quiet origin "$DRIVER_BRANCH"
else
    rm -rf "$SRC_DIR"
    git clone --quiet --branch "$DRIVER_BRANCH" "$DRIVER_REPO" "$SRC_DIR"
fi

# Sauberer, reproduzierbarer Ausgangszustand.
git -C "$SRC_DIR" reset --quiet --hard
git -C "$SRC_DIR" clean -qfdx

if [[ $FORCE_PIN -eq 1 ]]; then
    git -C "$SRC_DIR" checkout --quiet "$DRIVER_COMMIT"
    echo "    Stand: $DRIVER_COMMIT (geprüft)"
else
    git -C "$SRC_DIR" checkout --quiet "origin/$DRIVER_BRANCH"
    echo "    Stand: Spitze von $DRIVER_BRANCH (ungeprüft)"
fi

UPSTREAM_VER="$(dpkg-parsechangelog -l "$SRC_DIR/debian/changelog" -S Version)"
echo "    Treiberversion: $UPSTREAM_VER"

# --- Patches anwenden -------------------------------------------------------

info "Patches anwenden"

apply_patch() {
    local p="$1"
    if ! git -C "$SRC_DIR" apply --check "$p" 2>/dev/null; then
        die "Patch lässt sich nicht anwenden: $(basename "$p")
Der Treiberstand passt nicht zu diesem Projekt. Ohne --latest erneut versuchen."
    fi
    git -C "$SRC_DIR" apply "$p"
    echo "    angewendet: $(basename "$p")"
}

apply_patch "$REPO_DIR/patches/0001-msr1-constrain-v3-iova-to-32-bit.patch"

if [[ $LEGACY_UMD -eq 1 ]]; then
    apply_patch "$REPO_DIR/patches/0002-legacy-umd-abi-compat.patch"
    LOCAL_SUFFIX="${LOCAL_SUFFIX}.legacyumd"
else
    echo "    übersprungen: 0002-legacy-umd-abi-compat.patch (kein --legacy-umd)"
fi

# --- Paketversion setzen ----------------------------------------------------

NEW_VER="${UPSTREAM_VER}${LOCAL_SUFFIX}"
info "Paketversion auf $NEW_VER setzen"

# Eigenen Changelog-Eintrag voranstellen, ohne devscripts-Interaktion.
CL="$SRC_DIR/debian/changelog"
{
    printf 'cix-npu-driver (%s) stable; urgency=medium\n\n' "$NEW_VER"
    printf '  * Lokaler Build für CIX P1 / ZHOUYI V3 unter Ubuntu 26.04.\n'
    printf '  * IOVA-Fenster auf 32 Bit begrenzt (force_dma32).\n'
    if [[ $LEGACY_UMD -eq 1 ]]; then
        printf '  * ABI-Kompatibilität für alte Userspace-Treiber ergänzt.\n'
    fi
    printf '\n -- Lokaler Build <root@%s>  %s\n\n' "$(hostname)" "$(date -R)"
    cat "$CL"
} > "$CL.new"
mv "$CL.new" "$CL"

# --- Bauen ------------------------------------------------------------------

info "DKMS-Paket bauen"
( cd "$SRC_DIR" && dpkg-buildpackage --no-sign -b )

DEB="$(ls -t "$WORK_DIR"/cix-npu-driver-dkms_*.deb 2>/dev/null | head -1 || true)"
[[ -n "$DEB" ]] || die "Kein .deb erzeugt. Bitte die Build-Ausgabe oben prüfen."
echo "    Paket: $DEB"

if [[ $BUILD_ONLY -eq 1 ]]; then
    info "Fertig (--build-only). Installation mit:"
    echo "    sudo apt install $DEB"
    exit 0
fi

# --- Installieren -----------------------------------------------------------

info "Paket installieren (DKMS baut das Modul jetzt)"
apt-get install -y "$DEB"

# --- Modul laden ------------------------------------------------------------

info "Modul laden"
modprobe aipu || die "modprobe aipu fehlgeschlagen. Diagnose:
    sudo dmesg | grep -iE 'aipu|npu'"

# --- Prüfen -----------------------------------------------------------------

info "Ergebnis prüfen"
"$REPO_DIR/scripts/verify.sh" || true

cat <<EOF

Der Kerneltreiber ist installiert. Für echte Inferenz fehlt noch der
Userspace-Treiber (UMD) — siehe README, Abschnitt "Userspace-Treiber".

DKMS baut das Modul bei jedem Kernel-Update automatisch neu.
Rückbau: sudo ./uninstall.sh
EOF
