# CIX NPU on Ubuntu 26.04 (Minisforum MS-R1)

Current CIX NPU driver (version 6.2.0) packaged with DKMS for Ubuntu 26.04 on
the Minisforum MS-R1 (CIX P1 / Sky1, ZHOUYI V3).

This is a rework of
[FyrbyAdditive/ms-r1-npu-hack](https://github.com/FyrbyAdditive/ms-r1-npu-hack),
adapted to the latest driver release and to Ubuntu 26.04 with kernel 7.0.

(Eine deutsche Fassung dieser Datei liegt unter `README.md`.)

---

## What changed compared to the original project

The original project targeted Armbian 26.2 with kernel 6.18 and shipped a
prebuilt `.deb` of driver **6.1.1** plus four separate fixes. On Ubuntu 26.04.1
with kernel `7.0.0-41-cix`, three of those four fixes are no longer needed — the
current CIX driver and the Ubuntu kernel already handle them.

| Fix in the original project | Status here |
|---|---|
| ACPI/SSDT override so the three NPU cores get a `_HID` | **Not needed.** The kernel already reports `CIXH4010:00`, `:01` and `:02` on its own. |
| Write `MODULE_IMPORT_NS(DMA_BUF)` as a string on kernel ≥ 6.13 | **Not needed.** Driver 6.2.0 contains that conditional in `aipu_dma_buf.c` itself. |
| Work around `CONFIG_ARCH_CIX` checks that fail on non-CIX kernels | **Not needed.** Driver 6.2.0 has no `CONFIG_ARCH_CIX` check left. |
| Constrain the IOVA window to 32 bits | **Still needed** — see below. Implemented as a module parameter instead of being hardcoded. |

Also new:

* **Correct source.** The upstream URL referenced by the original project
  (`cixtech/cix_opensource__release__npu_driver`) no longer exists. The current
  one is
  [cixtech/cix_opensource__npu_driver](https://github.com/cixtech/cix_opensource__npu_driver).
* **Correct branch.** The build uses `cix_mainline_dev`, commit `31ee26f`
  ("DPTSW-23705: update to new version 6.2.0-1", 2026-07-09). That is the
  kernel 7.0 line. The chronologically newer branch `cix_k6.6.89_2026q3` is
  **unsuitable** here: its `dkms.conf` carries a `BUILD_EXCLUSIVE_KERNEL` that
  greps for `CONFIG_ARCH_CIX=[ym]` and otherwise makes DKMS skip the build
  silently.
* **No binary blob.** Instead of shipping a `.deb`, the module is built from the
  official sources using the Debian packaging present in the upstream repo
  (`dh-dkms`). DKMS rebuilds it automatically on every kernel update.
* **No changes to the boot path, the initrd, or ACPI tables.**

---

## The remaining patch: 32-bit IOVA window

The CIX P1 NPU block only drives 32 bits on its address bus. In
`aipu_mm_add_iova_region()` the driver first requests a 35-bit window
(`bus_dma_limit = 0x800000000`, `dma_mask = 35`). The IOMMU then hands out IOVAs
starting at `0x700000000`. The NPU truncates those addresses, and every access
ends in an SMMU fault.

Driver 6.2.0 does fall back to 32 bits — but only if creating the 35-bit window
*fails*. On the MS-R1 it succeeds, and the problem only surfaces later as a
truncated access. So the constraint is still required.

`patches/0001-msr1-constrain-v3-iova-to-32-bit.patch` implements this as a
module parameter rather than hardcoding it:

```
force_dma32 = -1   auto: constrain on ZHOUYI V3 only (default)
force_dma32 =  0   never constrain (unmodified upstream behaviour)
force_dma32 =  1   always constrain
```

Toggle at runtime without rebuilding:

```bash
echo "options aipu force_dma32=0" | sudo tee /etc/modprobe.d/aipu.conf
sudo modprobe -r aipu && sudo modprobe aipu
```

That makes it easy to measure directly whether the constraint is actually needed
on a given device.

---

## Installation

```bash
cd ms-r1-npu-ubuntu2604
chmod +x install.sh uninstall.sh scripts/*.sh
sudo ./install.sh
```

The script checks architecture, kernel headers and ACPI devices, installs the
build dependencies, fetches the driver sources at the verified commit, applies
the patch, builds `cix-npu-driver-dkms` and installs it.

Useful options:

| Option | Effect |
|---|---|
| `--build-only` | Only build the `.deb`, do not install it |
| `--skip-deps` | Do not install dependencies via apt |
| `--legacy-umd` | Additionally apply the ABI patch for old userspace drivers (see below) |
| `--latest` | Use the branch tip instead of the verified commit (patches may then fail) |

### Verify the result

```bash
sudo ./scripts/verify.sh
```

Expected:

* `aipu` present in `lsmod`
* `/dev/aipu` present
* all three `CIXH4010:*` detected
* a `dmesg` line containing `NPU core num is 3`

If something is off, `sudo ./scripts/diagnose.sh` produces a complete,
shareable state report.

### Removal

```bash
sudo ./uninstall.sh
```

---

## Userspace driver

The kernel driver alone computes nothing. Inference needs the userspace driver
(UMD, `libnoe`) and optionally the ONNX Runtime.

Currently available publicly via
[radxa-pkg/cix-prebuilt](https://github.com/radxa-pkg/cix-prebuilt/releases),
release `26Q2-2607` (2026-07-08) — the same generation as driver 6.2.0 and
therefore the right match:

* `cix-noe-umd_3.1.2_arm64.deb`
* `cix-npu-onnxruntime_1.2.0_arm64.deb`

```bash
B=https://github.com/radxa-pkg/cix-prebuilt/releases/download/26Q2-2607
wget "$B/cix-noe-umd_3.1.2_arm64.deb" "$B/cix-npu-onnxruntime_1.2.0_arm64.deb"
sudo apt install ./cix-noe-umd_3.1.2_arm64.deb ./cix-npu-onnxruntime_1.2.0_arm64.deb

# Fix two CIX packaging bugs (see below):
sudo ./install-umd.sh
```

The `cix-npu-driver_3.0.3_arm64.deb` found in the same release is a **kernel
driver package for CIX's own kernel line** and is deliberately **not** installed
here — the self-built DKMS package takes its place.

### Why `install-umd.sh` is needed

The CIX packages fail during configuration on Ubuntu 26.04:

```
Detected Ubuntu (resolute), no option needed
error: externally-managed-environment
dpkg: error processing package cix-noe-umd (--configure)
```

Two independent causes:

1. **The obvious bug.** The `postinst` of `cix-noe-umd` contains a hardcoded
   list of codenames (`noble`, `oracular`, `plucky`) and only passes
   `--break-system-packages` for those. `resolute` is missing, so it calls
   `pip3` without the option — and PEP 668 blocks the system-wide install.
   (`cix-npu-onnxruntime` passes the option unconditionally, which is why
   `ZhouyiOperators` got through.)

2. **The actual bug.** `--break-system-packages` would not help at all here. The
   `libnoe-3.1.2` wheel declares `Requires-Python >=3.10, <3.14` and contains
   binary modules for CPython 3.10 through 3.13 only:

   ```
   libnoe/libnoe.cpython-310-aarch64-linux-gnu.so
   libnoe/libnoe.cpython-311-aarch64-linux-gnu.so
   libnoe/libnoe.cpython-312-aarch64-linux-gnu.so
   libnoe/libnoe.cpython-313-aarch64-linux-gnu.so
   ```

   Ubuntu 26.04 uses Python 3.14. There is no module for it — a forced install
   would go through, but `import libnoe` would fail.

### Where Python 3.13 comes from

**Ubuntu 26.04 has no `python3.13` package.** It was in the archive for a while
but was deleted from `resolute` on 2026-03-29 — visible in the
[python3.13 publishing history](https://launchpad.net/ubuntu/+source/python3.13/+publishinghistory)
(status `Deleted` for `release` and `proposed`). So `apt install python3.13`
fails with "unable to locate package". 3.13 is currently only maintained in
Plucky and Questing.

`install-umd.sh` therefore downloads a standalone CPython 3.13 build from
[astral-sh/python-build-standalone](https://github.com/astral-sh/python-build-standalone/releases)
into `/opt/cix-python3.13`:

* `cpython-3.13.15+20260901-aarch64-unknown-linux-gnu-install_only.tar.gz`
* SHA256 `76ed18125286d7dc96ce24023d1e319dbd55a89a767102411b1ea23846113f69`
  (verified before extraction; the script aborts on a mismatch)

These are prebuilt, glibc-linked CPython builds — the same source `uv` uses for
its Python versions. The system Python 3.14 is left untouched. If a Python 3.13
is already present (via pyenv, for example), it is used instead; you can point
at a specific one with `PY=/path/to/python3.13 sudo ./install-umd.sh`.

### What the script does — and in what order

The order matters. While `cix-noe-umd` is half-configured, **every** apt call
fails, because apt re-runs the broken `postinst` as part of it. A script that
installs packages first therefore dies from the very error it is meant to fix.
Hence:

1. Write the installation helper to `/usr/local/sbin/cix-noe-venv-install`
   (no apt, no network). It deliberately exits 0 when the environment does not
   exist yet — otherwise dpkg could not complete.
2. Replace `postinst` with a corrected version (the original is kept as
   `.cix-orig`) and run `dpkg --configure -a`. **From here on the package state
   is clean and apt is usable again.**
3. Provide Python 3.13 (use an existing one or fetch the standalone build).
4. Create the virtual environment at `/opt/cix-npu`; an existing one with the
   wrong Python version is recreated.
5. Install `libnoe` and `ZhouyiOperators` there, plus `numpy`/`pillow`.
6. Register `/usr/share/cix/lib` via `ld.so.conf.d`, since the libraries live
   outside the default search path.
7. Check the package state and `import libnoe`.

### If it still gets stuck

The two decisive steps can also be done by hand:

```bash
# 1. Neutralise the broken postinst and clean up the package state
sudo cp -a /var/lib/dpkg/info/cix-noe-umd.postinst \
           /var/lib/dpkg/info/cix-noe-umd.postinst.cix-orig
sudo tee /var/lib/dpkg/info/cix-noe-umd.postinst >/dev/null <<'EOF'
#!/bin/sh
exit 0
EOF
sudo chmod 755 /var/lib/dpkg/info/cix-noe-umd.postinst
sudo dpkg --configure -a

# 2. Then run the script
sudo ./install-umd.sh
```

Usage afterwards:

```bash
/opt/cix-npu/bin/python inference/infer_minimal.py
# or
source /opt/cix-npu/bin/activate
```

After an update of `cix-noe-umd`, dpkg overwrites the `postinst` with the broken
version again — just run `sudo ./install-umd.sh` once more.

### ONNX Runtime: a limitation

The **Python bindings** of the CIX ONNX Runtime cannot be used on Ubuntu 26.04.
The wheel `onnxruntime_zhouyi-1.22.0-cp311-cp311-linux_aarch64.whl` is pinned to
CPython 3.11, and Ubuntu 26.04 carries no `python3.11` in its archive (only 3.13
and 3.14). In practice:

* **Usable:** `libnoe` through the 3.13 environment, the C/C++ libraries under
  `/usr/share/cix/lib/`, and the bundled binaries
  `/usr/share/cix/bin/onnxruntime/onnx_test_runner` and `onnxruntime_perf_test`.
  `inference/infer_minimal.py` only needs `libnoe`, `numpy` and `pillow`, so
  that path works.
* **Not usable:** `import onnxruntime` with NPU acceleration. If you need that,
  there is no way around a container with Ubuntu 24.04 (Python 3.11 from its
  archive). A standalone 3.11 build would be possible in theory, but the ONNX
  Runtime pulls in extensive C++ dependencies, which makes the container the
  more reliable route.

### If only an old UMD is available

Older UMDs (`cix-noe-umd 2.0.2`, release `rc3.3-2601`) were built against the
kernel 6.6 struct layouts. Because the ioctl number encodes the struct size,
they no longer address driver 6.2.0 correctly. For that case
`patches/0002-legacy-umd-abi-compat.patch` is included
(`sudo ./install.sh --legacy-umd`): it accepts the old ioctl numbers as separate
cases and translates the structs.

**Mutually exclusive:** this patch widens `struct aipu_cap`, which changes the
number of `AIPU_IOCTL_QUERY_CAP`. A current UMD 3.1.2 will then no longer work.
Only take this patch if you are locked to 2.0.2 — otherwise the current UMD is
the better path.

---

## Inference test

`inference/infer_minimal.py` (taken from the original project) runs a minimal
inference. Matching model:

```bash
sudo apt install git-lfs && git lfs install
git clone https://www.modelscope.cn/cix/ai_model_hub_25_Q3.git
# model under models/ComputeVision/Image_Classification/onnx_mobilenet_v2
```

`smoketest/npu_smoketest.c` merely opens `/dev/aipu` and queries capabilities —
useful for testing the kernel driver without a UMD.

As a rough reference, the original project reports roughly 640 inferences/s and
about 1.5 ms per run for MobileNet v2 — measured on Armbian 26.2 with kernel
6.18.25, so not directly transferable to this setup.

---

## If the NPU cores are missing

On this MS-R1 (BIOS 1.0) all three cores already enumerate correctly. If
`verify.sh` finds fewer than three `CIXH4010:*` on a different device or after a
BIOS update, the `_HID` assignment is missing from the ACPI table. An SSDT
override is then needed as well; the required files and steps are in the
[original project](https://github.com/FyrbyAdditive/ms-r1-npu-hack) under
`npu-fix/ssdt/`. This project deliberately does not touch the boot path.

---

## Honest assessment

* The patches were generated against commit `31ee26f`, and their applicability
  was verified with `git apply --check` against a fresh checkout.
* **The module has not been compiled and has not been tested on hardware.** That
  requires the kernel headers of `7.0.0-41-cix` on aarch64, which only exist on
  the target device. The build has to happen on the MS-R1. Expect some
  follow-up work on the first run — `scripts/diagnose.sh` provides the necessary
  details.
* Whether the 32-bit constraint is still required on kernel 7.0 is not proven,
  only inferred from the source. Hence the module parameter: `force_dma32=0`
  lets you check that without rebuilding.
* Ubuntu itself ships **no** NPU package. The
  ["Ubuntu Concept – CIX" PPA](https://launchpad.net/~ubuntu-concept/+archive/ubuntu/cix/+packages)
  only contains `cix-firmware`, `linux-cix`, `linux-meta-cix`, `livecd-rootfs`
  and `ubuntu-cix-settings`. Building it yourself is therefore currently
  unavoidable. Should a `cix-npu-driver-dkms` appear there later, that is the
  better route.

## Sources

* CIX NPU kernel driver: https://github.com/cixtech/cix_opensource__npu_driver
* Original project: https://github.com/FyrbyAdditive/ms-r1-npu-hack
* Prebuilt CIX userspace packages: https://github.com/radxa-pkg/cix-prebuilt/releases
* CIX packages for Ubuntu: https://github.com/cixtech/cix_p1_ubuntu_adaption_debs
* "Ubuntu Concept – CIX" PPA: https://launchpad.net/~ubuntu-concept/+archive/ubuntu/cix/+packages
* "Ubuntu Concept goes CIX P1" announcement: https://discourse.ubuntu.com/t/ubuntu-concept-goes-cix-p1/82213
* python3.13 removed from Ubuntu 26.04: https://launchpad.net/ubuntu/+source/python3.13/+publishinghistory
* Standalone CPython builds: https://github.com/astral-sh/python-build-standalone/releases
* Models: https://www.modelscope.cn/cix/ai_model_hub_25_Q3.git
