# CIX-NPU unter Ubuntu 26.04 (Minisforum MS-R1)

Aktueller CIX-NPU-Treiber (Version 6.2.0) als DKMS-Paket für Ubuntu 26.04 auf
dem Minisforum MS-R1 (CIX P1 / Sky1, ZHOUYI V3).

Dies ist ein Umbau von
[FyrbyAdditive/ms-r1-npu-hack](https://github.com/FyrbyAdditive/ms-r1-npu-hack),
angepasst an den neuesten Treiberstand und an Ubuntu 26.04 mit Kernel 7.0.

(An English version of this file is available at `README.en.md`.)

---

## Was sich gegenüber dem Ursprungsprojekt geändert hat

Das Ursprungsprojekt richtete sich an Armbian 26.2 mit Kernel 6.18 und
lieferte ein fertiges `.deb` des Treibers **6.1.1** sowie vier Einzelkorrekturen
mit. Auf deinem System (Ubuntu 26.04.1, Kernel `7.0.0-41-cix`) sind drei dieser
vier Korrekturen nicht mehr nötig — der aktuelle CIX-Treiber und der
Ubuntu-Kernel erledigen das bereits selbst.

| Korrektur im Ursprungsprojekt | Status auf deinem System |
|---|---|
| ACPI-/SSDT-Override, damit die drei NPU-Kerne eine `_HID` erhalten | **Entfällt.** Dein Kernel meldet `CIXH4010:00`, `:01` und `:02` bereits von sich aus. |
| `MODULE_IMPORT_NS(DMA_BUF)` für Kernel ≥ 6.13 als String schreiben | **Entfällt.** Der Treiber 6.2.0 enthält diese Fallunterscheidung in `aipu_dma_buf.c` selbst. |
| `CONFIG_ARCH_CIX`-Abfragen umgehen, die auf Nicht-CIX-Kerneln fehlschlagen | **Entfällt.** Im Treiber 6.2.0 gibt es keine `CONFIG_ARCH_CIX`-Abfrage mehr. |
| IOVA-Fenster auf 32 Bit begrenzen | **Weiterhin nötig** — siehe unten. Als Modulparameter umgesetzt statt fest verdrahtet. |

Zusätzlich neu:

* **Aktuelle Quelle.** Die im Ursprungsprojekt verlinkte Upstream-Adresse
  (`cixtech/cix_opensource__release__npu_driver`) existiert nicht mehr. Richtig
  ist jetzt [cixtech/cix_opensource__npu_driver](https://github.com/cixtech/cix_opensource__npu_driver).
* **Richtiger Zweig.** Gebaut wird aus `cix_mainline_dev`, Commit `31ee26f`
  („DPTSW-23705: update to new version 6.2.0-1“, 09.07.2026). Das ist der Stand
  für Kernel 7.0. Der zeitlich neuere Zweig `cix_k6.6.89_2026q3` ist hier
  **ungeeignet**: dessen `dkms.conf` enthält ein `BUILD_EXCLUSIVE_KERNEL`, das
  auf `CONFIG_ARCH_CIX=[ym]` prüft und den Bau auf dem Ubuntu-Kernel sonst
  stillschweigend überspringt.
* **Kein Binär-Blob.** Statt eines mitgelieferten `.deb` wird aus den
  offiziellen Quellen gebaut, mit der im Repo vorhandenen Debian-Paketierung
  (`dh-dkms`). Bei jedem Kernel-Update baut DKMS automatisch neu.
* **Keine Eingriffe in Boot-Pfad, initrd oder ACPI-Tabellen.**

---

## Der verbleibende Patch: 32-Bit-IOVA-Fenster

Der NPU-Block des CIX P1 führt auf dem Adressbus nur 32 Bit. Der Treiber
fordert in `aipu_mm_add_iova_region()` zuerst ein 35-Bit-Fenster an
(`bus_dma_limit = 0x800000000`, `dma_mask = 35`). Die IOMMU vergibt daraufhin
IOVAs ab `0x700000000`. Die NPU schneidet diese Adressen ab, und jeder Zugriff
läuft in einen SMMU-Fehler.

Der Treiber 6.2.0 fällt zwar auf 32 Bit zurück — aber nur, wenn das Anlegen des
35-Bit-Fensters *fehlschlägt*. Auf dem MS-R1 gelingt es, und der Fehler tritt
erst später als abgeschnittener Zugriff auf. Deshalb bleibt die Begrenzung
nötig.

`patches/0001-msr1-constrain-v3-iova-to-32-bit.patch` setzt das als
Modulparameter um, statt es fest zu verdrahten:

```
force_dma32 = -1   Automatik: nur bei ZHOUYI V3 begrenzen (Standard)
force_dma32 =  0   nie begrenzen (unverändertes Upstream-Verhalten)
force_dma32 =  1   immer begrenzen
```

Zur Laufzeit umschalten, ohne neu zu bauen:

```bash
echo "options aipu force_dma32=0" | sudo tee /etc/modprobe.d/aipu.conf
sudo modprobe -r aipu && sudo modprobe aipu
```

Damit lässt sich direkt nachmessen, ob die Begrenzung auf deinem Gerät
tatsächlich gebraucht wird.

---

## Installation

```bash
cd ms-r1-npu-ubuntu2604
chmod +x install.sh uninstall.sh scripts/*.sh
sudo ./install.sh
```

Das Skript prüft Architektur, Kernel-Header und ACPI-Geräte, installiert die
Build-Abhängigkeiten, holt die Treiberquellen auf dem geprüften Commit, wendet
den Patch an, baut `cix-npu-driver-dkms` und installiert es.

Nützliche Optionen:

| Option | Wirkung |
|---|---|
| `--build-only` | Nur das `.deb` bauen, nicht installieren |
| `--skip-deps` | Abhängigkeiten nicht per apt installieren |
| `--legacy-umd` | Zusätzlich den ABI-Patch für alte Userspace-Treiber anwenden (siehe unten) |
| `--latest` | Zweigspitze statt geprüftem Commit (Patches können dann scheitern) |

### Ergebnis prüfen

```bash
sudo ./scripts/verify.sh
```

Erwartet:

* `aipu` in `lsmod`
* `/dev/aipu` vorhanden
* alle drei `CIXH4010:*` erkannt
* in `dmesg` eine Meldung mit `NPU core num is 3`

Bei Problemen liefert `sudo ./scripts/diagnose.sh` einen vollständigen,
weitergebbaren Zustandsbericht.

### Rückbau

```bash
sudo ./uninstall.sh
```

---

## Userspace-Treiber

Der Kerneltreiber allein rechnet nichts. Für Inferenz braucht es den
Userspace-Treiber (UMD, `libnoe`) und optional die ONNX-Runtime.

Aktuell öffentlich verfügbar über
[radxa-pkg/cix-prebuilt](https://github.com/radxa-pkg/cix-prebuilt/releases),
Release `26Q2-2607` (08.07.2026) — dieselbe Generation wie der Treiber 6.2.0
und daher die passende Wahl:

* `cix-noe-umd_3.1.2_arm64.deb`
* `cix-npu-onnxruntime_1.2.0_arm64.deb`

```bash
B=https://github.com/radxa-pkg/cix-prebuilt/releases/download/26Q2-2607
wget "$B/cix-noe-umd_3.1.2_arm64.deb" "$B/cix-npu-onnxruntime_1.2.0_arm64.deb"
sudo apt install ./cix-noe-umd_3.1.2_arm64.deb ./cix-npu-onnxruntime_1.2.0_arm64.deb

# Zwei Paketierungsfehler von CIX geradeziehen (siehe unten):
sudo ./install-umd.sh
```

Das dort ebenfalls enthaltene `cix-npu-driver_3.0.3_arm64.deb` ist ein
**Kerneltreiber-Paket für die CIX-eigene Kernel-Linie** und wird hier **nicht**
installiert — an seine Stelle tritt das selbst gebaute DKMS-Paket.

### Warum `install-umd.sh` nötig ist

Die CIX-Pakete brechen unter Ubuntu 26.04 bei der Konfiguration ab:

```
Detected Ubuntu (resolute), no option needed
error: externally-managed-environment
dpkg: Fehler beim Bearbeiten des Paketes cix-noe-umd (--configure)
```

Zwei voneinander unabhängige Ursachen:

1. **Der offensichtliche Fehler.** Das `postinst` von `cix-noe-umd` enthält eine
   fest verdrahtete Liste von Codenamen (`noble`, `oracular`, `plucky`) und
   setzt nur für diese `--break-system-packages`. `resolute` fehlt, also ruft es
   `pip3` ohne diese Option auf — und PEP 668 blockt die systemweite
   Installation. (`cix-npu-onnxruntime` setzt die Option unbedingt, deshalb kam
   `ZhouyiOperators` durch.)

2. **Der eigentliche Fehler.** `--break-system-packages` würde hier gar nichts
   lösen. Das Wheel `libnoe-3.1.2` deklariert `Requires-Python >=3.10, <3.14`
   und enthält Binärmodule ausschließlich für CPython 3.10 bis 3.13:

   ```
   libnoe/libnoe.cpython-310-aarch64-linux-gnu.so
   libnoe/libnoe.cpython-311-aarch64-linux-gnu.so
   libnoe/libnoe.cpython-312-aarch64-linux-gnu.so
   libnoe/libnoe.cpython-313-aarch64-linux-gnu.so
   ```

   Ubuntu 26.04 nutzt Python 3.14. Dafür gibt es kein Modul — ein erzwungener
   Einbau würde zwar durchlaufen, aber `import libnoe` scheitern.

### Woher Python 3.13 kommt

**Ubuntu 26.04 hat kein `python3.13`-Paket.** Es war zeitweise im Archiv, wurde
aber am 29.03.2026 aus `resolute` gelöscht — nachvollziehbar in der
[Veröffentlichungshistorie von python3.13](https://launchpad.net/ubuntu/+source/python3.13/+publishinghistory)
(Status `Deleted` für `release` und `proposed`). `apt install python3.13`
scheitert daher mit ‚Paket kann nicht gefunden werden‘. Aktuell gepflegt ist
3.13 nur noch in Plucky und Questing.

`install-umd.sh` lädt deshalb einen eigenständigen CPython-3.13-Build von
[astral-sh/python-build-standalone](https://github.com/astral-sh/python-build-standalone/releases)
nach `/opt/cix-python3.13`:

* `cpython-3.13.15+20260901-aarch64-unknown-linux-gnu-install_only.tar.gz`
* SHA256 `76ed18125286d7dc96ce24023d1e319dbd55a89a767102411b1ea23846113f69`
  (wird vor dem Entpacken geprüft; bei Abweichung bricht das Skript ab)

Das sind vorgebaute, gegen glibc gelinkte CPython-Builds — dieselbe Quelle, die
auch `uv` für seine Python-Versionen nutzt. Am Systempython 3.14 wird nichts
verändert. Ist bereits ein Python 3.13 vorhanden (etwa über pyenv), wird das
verwendet; mit `PY=/pfad/zu/python3.13 sudo ./install-umd.sh` lässt sich eines
vorgeben.

### Was das Skript tut — und in welcher Reihenfolge

Die Reihenfolge ist nicht beliebig. Solange `cix-noe-umd` halb konfiguriert ist,
schlägt **jeder** apt-Aufruf fehl, weil apt dabei das fehlerhafte `postinst`
erneut ausführt. Ein Skript, das zuerst Pakete nachinstalliert, stirbt also an
genau dem Fehler, den es reparieren soll. Deshalb:

1. Installationshelfer nach `/usr/local/sbin/cix-noe-venv-install` schreiben
   (ohne apt, ohne Netz). Er endet bewusst mit 0, wenn die Umgebung noch fehlt —
   sonst könnte dpkg nicht durchlaufen.
2. `postinst` durch eine korrigierte Fassung ersetzen (Original wird als
   `.cix-orig` gesichert) und `dpkg --configure -a` ausführen. **Ab hier ist der
   Paketzustand sauber und apt wieder benutzbar.**
3. Python 3.13 bereitstellen (vorhandenes nutzen oder den eigenständigen Build
   laden).
4. Virtuelle Umgebung unter `/opt/cix-npu` anlegen; eine bereits vorhandene mit
   falscher Python-Version wird neu erstellt.
5. `libnoe` und `ZhouyiOperators` samt `numpy`/`pillow` dort installieren.
6. `/usr/share/cix/lib` per `ld.so.conf.d` registrieren, da die Bibliotheken
   außerhalb des Standardsuchpfads liegen.
7. Paketzustand und `import libnoe` prüfen.

### Wenn es trotzdem klemmt

Die beiden entscheidenden Schritte lassen sich auch von Hand ausführen:

```bash
# 1. Fehlerhaftes postinst stilllegen und Paketzustand bereinigen
sudo cp -a /var/lib/dpkg/info/cix-noe-umd.postinst \
           /var/lib/dpkg/info/cix-noe-umd.postinst.cix-orig
sudo tee /var/lib/dpkg/info/cix-noe-umd.postinst >/dev/null <<'EOF'
#!/bin/sh
exit 0
EOF
sudo chmod 755 /var/lib/dpkg/info/cix-noe-umd.postinst
sudo dpkg --configure -a

# 2. Danach das Skript laufen lassen
sudo ./install-umd.sh
```

Benutzung danach:

```bash
/opt/cix-npu/bin/python inference/infer_minimal.py
# oder
source /opt/cix-npu/bin/activate
```

Nach einem Update von `cix-noe-umd` überschreibt dpkg das `postinst` wieder mit
der fehlerhaften Fassung — dann `sudo ./install-umd.sh` erneut ausführen.

### ONNX-Runtime: Einschränkung

Die **Python-Bindings** der CIX-ONNX-Runtime sind unter Ubuntu 26.04 nicht
nutzbar. Das Wheel `onnxruntime_zhouyi-1.22.0-cp311-cp311-linux_aarch64.whl`
ist auf CPython 3.11 festgelegt, und Ubuntu 26.04 führt kein `python3.11` im
Archiv (nur 3.13 und 3.14). Praktisch bedeutet das:

* **Nutzbar:** `libnoe` über die 3.13-Umgebung, die C/C++-Bibliotheken unter
  `/usr/share/cix/lib/` sowie die mitgelieferten Programme
  `/usr/share/cix/bin/onnxruntime/onnx_test_runner` und `onnxruntime_perf_test`.
  `inference/infer_minimal.py` braucht nur `libnoe`, `numpy` und `pillow` — der
  Weg funktioniert also.
* **Nicht nutzbar:** `import onnxruntime` mit NPU-Beschleunigung. Wer das
  braucht, kommt um einen Container mit Ubuntu 24.04 (Python 3.11 via
  `python3.11` aus dem dortigen Archiv) nicht herum. Ein eigenständiger
  3.11-Build wäre theoretisch auch möglich, aber die ONNX-Runtime bringt
  umfangreiche C++-Abhängigkeiten mit, weshalb der Container der verlässlichere
  Weg ist.

### Wenn nur ein alter UMD verfügbar ist

Ältere UMDs (`cix-noe-umd 2.0.2`, Release `rc3.3-2601`) wurden gegen die
Strukturen der Kernel-6.6-Reihe gebaut. Weil die ioctl-Nummer die Strukturgröße
mitkodiert, sprechen sie den Treiber 6.2.0 nicht mehr korrekt an. Für diesen
Fall liegt `patches/0002-legacy-umd-abi-compat.patch` bereit
(`sudo ./install.sh --legacy-umd`): er nimmt die alten ioctl-Nummern als eigene
Fälle an und übersetzt die Strukturen.

**Gegenseitig ausschließend:** dieser Patch verbreitert `struct aipu_cap`, wodurch
sich die Nummer von `AIPU_IOCTL_QUERY_CAP` ändert. Ein aktueller UMD 3.1.2
funktioniert dann nicht mehr. Nimm den Patch also nur, wenn du auf 2.0.2
festgelegt bist — ansonsten ist der aktuelle UMD der bessere Weg.

---

## Inferenztest

`inference/infer_minimal.py` (aus dem Ursprungsprojekt übernommen) führt eine
minimale Inferenz aus. Passendes Modell:

```bash
sudo apt install git-lfs && git lfs install
git clone https://www.modelscope.cn/cix/ai_model_hub_25_Q3.git
# Modell unter models/ComputeVision/Image_Classification/onnx_mobilenet_v2
```

`smoketest/npu_smoketest.c` öffnet lediglich `/dev/aipu` und fragt die
Fähigkeiten ab — brauchbar, um den Kerneltreiber ohne UMD zu testen.

Als Größenordnung nennt das Ursprungsprojekt rund 640 Inferenzen/s bzw.
etwa 1,5 ms je Durchlauf für MobileNet v2 — gemessen allerdings auf Armbian
26.2 mit Kernel 6.18.25, also nicht direkt auf diesen Aufbau übertragbar.

---

## Wenn die NPU-Kerne fehlen

Auf deinem MS-R1 (BIOS 1.0) melden sich alle drei Kerne bereits korrekt. Sollte
`verify.sh` auf einem anderen Gerät oder nach einem BIOS-Update weniger als drei
`CIXH4010:*` finden, fehlt die `_HID`-Zuweisung in der ACPI-Tabelle. Dann wird
zusätzlich ein SSDT-Override gebraucht; die dafür nötigen Dateien und Schritte
stehen im [Ursprungsprojekt](https://github.com/FyrbyAdditive/ms-r1-npu-hack)
unter `npu-fix/ssdt/`. Dieses Projekt fasst den Boot-Pfad absichtlich nicht an.

---

## Ehrliche Einordnung

* Die Patches sind gegen Commit `31ee26f` erzeugt und ihre Anwendbarkeit wurde
  mit `git apply --check` gegen einen frischen Checkout geprüft.
* **Das Modul wurde nicht kompiliert und nicht auf Hardware getestet.** Dafür
  braucht es die Kernel-Header von `7.0.0-41-cix` auf aarch64, die nur auf
  deinem Gerät vorliegen. Der Bau muss auf dem MS-R1 stattfinden. Rechne damit,
  dass beim ersten Durchlauf noch etwas nachzuziehen ist —
  `scripts/diagnose.sh` liefert dann die nötigen Angaben.
* Ob die 32-Bit-Begrenzung auf Kernel 7.0 noch gebraucht wird, ist nicht
  bewiesen, sondern aus dem Quellcode abgeleitet. Deshalb der Modulparameter:
  mit `force_dma32=0` lässt sich das ohne Neubau gegenprüfen.
* Ubuntu selbst liefert **kein** NPU-Paket. Das
  [PPA „Ubuntu Concept – CIX“](https://launchpad.net/~ubuntu-concept/+archive/ubuntu/cix/+packages)
  enthält nur `cix-firmware`, `linux-cix`, `linux-meta-cix`, `livecd-rootfs` und
  `ubuntu-cix-settings`. Ein Eigenbau ist derzeit also unvermeidlich. Sollte
  dort später ein `cix-npu-driver-dkms` erscheinen, ist das der bessere Weg.

## Quellen

* CIX-NPU-Kerneltreiber: https://github.com/cixtech/cix_opensource__npu_driver
* Ursprungsprojekt: https://github.com/FyrbyAdditive/ms-r1-npu-hack
* Vorgebaute CIX-Userspace-Pakete: https://github.com/radxa-pkg/cix-prebuilt/releases
* CIX-Pakete für Ubuntu: https://github.com/cixtech/cix_p1_ubuntu_adaption_debs
* PPA „Ubuntu Concept – CIX“: https://launchpad.net/~ubuntu-concept/+archive/ubuntu/cix/+packages
* Ankündigung „Ubuntu Concept goes CIX P1“: https://discourse.ubuntu.com/t/ubuntu-concept-goes-cix-p1/82213
* python3.13 aus Ubuntu 26.04 entfernt: https://launchpad.net/ubuntu/+source/python3.13/+publishinghistory
* Eigenständige CPython-Builds: https://github.com/astral-sh/python-build-standalone/releases
* Modelle: https://www.modelscope.cn/cix/ai_model_hub_25_Q3.git
