#!/usr/bin/env bash
#
# Userspace-Treiber (cix-noe-umd) unter Ubuntu 26.04 einrichten.
#
# Behebt zwei Paketierungsfehler von CIX:
#
#  1. Das postinst von cix-noe-umd kennt nur die Codenamen noble/oracular/
#     plucky und setzt für "resolute" kein --break-system-packages. Der
#     pip3-Aufruf scheitert dann an PEP 668 ("externally-managed-environment").
#
#  2. Der wichtigere Punkt: --break-system-packages würde gar nichts lösen.
#     Das Wheel libnoe-3.1.2 deklariert Requires-Python ">=3.10, <3.14" und
#     enthält Binärmodule nur für CPython 3.10 bis 3.13. Ubuntu 26.04 nutzt
#     Python 3.14 — dort gibt es kein passendes Modul.
#
# Lösung: libnoe in eine eigene Python-3.13-Umgebung installieren und das
# postinst des Pakets entsprechend korrigieren, damit dpkg durchläuft.
#
# Ubuntu 26.04 hat KEIN python3.13-Paket — es wurde am 29.03.2026 aus
# "resolute" gelöscht:
#   https://launchpad.net/ubuntu/+source/python3.13/+publishinghistory
# Deshalb wird ein eigenständiger CPython-3.13-Build verwendet
# (astral-sh/python-build-standalone). Am Systempython 3.14 ändert sich nichts.
#
# REIHENFOLGE IST WICHTIG: Solange cix-noe-umd halb konfiguriert ist, schlägt
# JEDER apt-Aufruf fehl, weil apt dabei das fehlerhafte postinst erneut
# ausführt. Deshalb wird zuerst das postinst korrigiert und die
# Paketkonfiguration abgeschlossen — erst danach darf apt benutzt werden.

set -euo pipefail

VENV="${VENV:-/opt/cix-npu}"
PYROOT="${PYROOT:-/opt/cix-python3.13}"
HELPER="/usr/local/sbin/cix-noe-venv-install"
DPKG_POSTINST="/var/lib/dpkg/info/cix-noe-umd.postinst"

# Geprüfter eigenständiger CPython-Build (arm64, glibc).
PBS_TAG="20260901"
PBS_FILE="cpython-3.13.15+${PBS_TAG}-aarch64-unknown-linux-gnu-install_only.tar.gz"
PBS_URL="https://github.com/astral-sh/python-build-standalone/releases/download/${PBS_TAG}/${PBS_FILE}"
PBS_SHA256="76ed18125286d7dc96ce24023d1e319dbd55a89a767102411b1ea23846113f69"

info() { printf '\033[1;34m==>\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33mWarnung:\033[0m %s\n' "$*" >&2; }
die()  { printf '\033[1;31mFehler:\033[0m %s\n' "$*" >&2; exit 1; }

[[ $(id -u) -eq 0 ]] || die "Bitte mit sudo ausführen."
[[ "$(uname -m)" == "aarch64" ]] || die "Nur für arm64/aarch64."

# ---------------------------------------------------------------------------
# Schritt 1: Installationshelfer schreiben (braucht kein apt, kein Netz)
# ---------------------------------------------------------------------------

info "Installationshelfer nach $HELPER schreiben"

cat > "$HELPER" <<EOF
#!/bin/sh
# Installiert die CIX-Python-Wheels in die Umgebung unter $VENV.
# Wird vom korrigierten postinst von cix-noe-umd aufgerufen.
#
# Idempotent und absichtlich fehlertolerant: fehlt die Umgebung noch, endet
# das Skript mit 0, damit "dpkg --configure" nicht blockiert.
set -e

VENV="$VENV"

if [ ! -x "\$VENV/bin/pip" ]; then
    echo "cix-noe-venv-install: \$VENV fehlt noch - übersprungen."
    echo "cix-noe-venv-install: Einrichten mit install-umd.sh."
    exit 0
fi

for w in /usr/share/cix/pypi/libnoe-*-py3-none-manylinux2014_aarch64.whl \\
         /usr/share/cix/pypi/ZhouyiOperators_x2-*-py3-none-any.whl; do
    [ -f "\$w" ] || continue
    echo "cix-noe-venv-install: installiere \$(basename "\$w")"
    "\$VENV/bin/pip" install --quiet --force-reinstall --no-deps "\$w"
done

# Laufzeitabhängigkeiten des Beispielcodes.
"\$VENV/bin/pip" install --quiet numpy pillow || \\
    echo "cix-noe-venv-install: numpy/pillow konnten nicht geladen werden (Netz?)"

exit 0
EOF
chmod 755 "$HELPER"

# ---------------------------------------------------------------------------
# Schritt 2: postinst korrigieren und Paketzustand bereinigen
#            Muss VOR jedem apt-Aufruf passieren.
# ---------------------------------------------------------------------------

if [[ -f "$DPKG_POSTINST" ]]; then
    info "postinst von cix-noe-umd korrigieren"

    # Original nur beim ersten Mal sichern, damit ein zweiter Lauf nicht
    # unsere eigene Fassung als "Original" ablegt.
    if [[ ! -f "$DPKG_POSTINST.cix-orig" ]]; then
        cp -a "$DPKG_POSTINST" "$DPKG_POSTINST.cix-orig"
        echo "    Original gesichert als $(basename "$DPKG_POSTINST").cix-orig"
    fi

    cat > "$DPKG_POSTINST" <<EOF
#!/bin/sh
# Ersetzt durch install-umd.sh (ms-r1-npu-ubuntu2604).
# Grund: das Original ruft pip3 gegen das systemweite Python 3.14 auf, für das
# es kein libnoe-Binärmodul gibt. Stattdessen Installation nach $VENV.
set -e
$HELPER
exit 0
EOF
    chmod 755 "$DPKG_POSTINST"

    info "Paketkonfiguration abschließen"
    if dpkg --configure -a; then
        echo "    dpkg-Zustand ist wieder sauber"
    else
        die "dpkg --configure -a schlägt weiter fehl.
Vollständige Ausgabe prüfen; ggf. blockiert ein anderes Paket."
    fi
else
    warn "$DPKG_POSTINST nicht gefunden."
    warn "Ist cix-noe-umd installiert? Andernfalls zuerst:"
    warn "  sudo apt install ./cix-noe-umd_3.1.2_arm64.deb"
fi

# ---------------------------------------------------------------------------
# Schritt 3: Python 3.13 bereitstellen (ab hier ist apt wieder benutzbar)
# ---------------------------------------------------------------------------

info "Python 3.13 bereitstellen"

find_py313() {
    if [[ -n "${PY:-}" ]] &&
       "$PY" -c 'import sys; sys.exit(sys.version_info[:2] != (3, 13))' 2>/dev/null; then
        echo "$PY"; return 0
    fi
    if "$PYROOT/bin/python3.13" -V >/dev/null 2>&1; then
        echo "$PYROOT/bin/python3.13"; return 0
    fi
    if command -v python3.13 >/dev/null 2>&1; then
        command -v python3.13; return 0
    fi
    return 1
}

if PY313="$(find_py313)"; then
    echo "    vorhanden: $PY313"
else
    echo "    Ubuntu 26.04 führt kein python3.13 im Archiv."
    echo "    Eigenständigen CPython-3.13-Build nach $PYROOT installieren."

    if ! command -v curl >/dev/null 2>&1; then
        apt-get install -y --no-install-recommends curl ca-certificates ||
            die "curl konnte nicht installiert werden."
    fi

    TMP="$(mktemp -d)"
    trap 'rm -rf "$TMP"' EXIT

    echo "    lade $PBS_FILE (ca. 91 MB)"
    curl -fL --retry 3 -o "$TMP/py.tar.gz" "$PBS_URL" ||
        die "Download fehlgeschlagen: $PBS_URL"

    echo "    Prüfsumme vergleichen"
    echo "$PBS_SHA256  $TMP/py.tar.gz" | sha256sum -c - >/dev/null ||
        die "Prüfsumme stimmt nicht. Datei verworfen."

    rm -rf "$PYROOT"
    mkdir -p "$PYROOT"
    # Das Archiv entpackt nach ./python/ - diese Ebene entfernen.
    tar xzf "$TMP/py.tar.gz" -C "$PYROOT" --strip-components=1

    rm -rf "$TMP"; trap - EXIT

    PY313="$PYROOT/bin/python3.13"
    [[ -x "$PY313" ]] || die "Entpacken fehlgeschlagen: $PY313 fehlt."
fi

echo "    $("$PY313" -V)"

# ---------------------------------------------------------------------------
# Schritt 4: virtuelle Umgebung
# ---------------------------------------------------------------------------

info "Virtuelle Umgebung unter $VENV anlegen"

# Eine vorhandene Umgebung mit falscher Python-Version muss weichen, sonst
# scheitert der libnoe-Import später erneut.
if [[ -x "$VENV/bin/python" ]] &&
   ! "$VENV/bin/python" -c 'import sys; sys.exit(sys.version_info[:2] != (3, 13))' 2>/dev/null; then
    warn "$VENV nutzt $("$VENV/bin/python" -V 2>&1) - wird neu angelegt."
    rm -rf "$VENV"
fi

if [[ ! -x "$VENV/bin/python" ]]; then
    "$PY313" -m venv --copies "$VENV"
fi
"$VENV/bin/pip" install --quiet --upgrade pip wheel
echo "    $("$VENV/bin/python" -V)"

# ---------------------------------------------------------------------------
# Schritt 5: Wheels installieren
# ---------------------------------------------------------------------------

info "CIX-Wheels in die Umgebung installieren"

ls /usr/share/cix/pypi/libnoe-*.whl >/dev/null 2>&1 ||
    die "Kein libnoe-Wheel unter /usr/share/cix/pypi/ gefunden.
Ist cix-noe-umd entpackt? Notfalls:
    sudo dpkg --unpack cix-noe-umd_3.1.2_arm64.deb"

"$HELPER"

# ---------------------------------------------------------------------------
# Schritt 6: Bibliothekspfade
# ---------------------------------------------------------------------------

info "Bibliothekspfade registrieren"
{
    echo "# CIX-NPU-Bibliotheken (gesetzt von install-umd.sh)"
    [[ -d /usr/share/cix/lib ]] && echo "/usr/share/cix/lib"
    [[ -d /usr/share/cix/lib/onnxruntime ]] && echo "/usr/share/cix/lib/onnxruntime"
} > /etc/ld.so.conf.d/cix-npu.conf
ldconfig
echo "    /etc/ld.so.conf.d/cix-npu.conf geschrieben"

# ---------------------------------------------------------------------------
# Schritt 7: prüfen
# ---------------------------------------------------------------------------

info "Ergebnis prüfen"

echo -n "    Paketzustand: "
if dpkg-query -W -f='${Status}\n' cix-noe-umd 2>/dev/null | grep -q 'install ok installed'; then
    echo "cix-noe-umd ist vollständig konfiguriert"
else
    warn "cix-noe-umd ist noch nicht konfiguriert - Ausgabe oben prüfen"
fi

if "$VENV/bin/python" -c 'import libnoe; print("    libnoe geladen:", getattr(libnoe, "__file__", "?"))'; then
    :
else
    warn "Import von libnoe fehlgeschlagen. Nachsehen mit:"
    warn "  $VENV/bin/python -c 'import libnoe'"
fi

cat <<EOF

Fertig.

Die Python-Umgebung liegt unter $VENV, das dazugehörige Python unter $PYROOT.
Benutzen mit:

    $VENV/bin/python inference/infer_minimal.py
    # oder
    source $VENV/bin/activate

Hinweise:

* Nach einem Update von cix-noe-umd überschreibt dpkg das postinst wieder mit
  der fehlerhaften Fassung. Dann einfach dieses Skript erneut ausführen.
* Die Python-Bindings der ONNX-Runtime (onnxruntime_zhouyi, cp311) lassen sich
  unter Ubuntu 26.04 nicht nutzen - siehe README, Abschnitt
  "ONNX-Runtime: Einschränkung".
EOF
