# BC-250 40 CU Unlock

Re-enable all 40 CUs on the AMD BC-250 (gfx1013 / Cyan Skillfish / salvaged PS5 APU).

The BC-250 ships with 24 of 40 RDNA2 CUs active. This patch unlocks all 40 by writing two hardware registers during amdgpu driver init. No firmware mods, no permanent changes — just a kernel module parameter.

## Results

**pp512 (Vulkan LLM inference, Qwen3.5-9B Q4_K_XL):**

| Config | pp512 tok/s | Power | Temp | SCLK |
|--------|------------|-------|------|------|
| Stock 24 CU | 230 | 95W | 79C | 1500MHz |
| **40 CU unlocked** | **372** | **125W** | **83C** | **1500MHz** |
| **Ratio** | **1.61x** | +30W | +4C | same |

At 2 GHz (governor default): 302 → 466 tok/s = 1.54x, but hits 96C. 1500 MHz / 900 mV is the recommended sweet spot.

## How It Works

Two registers control CU availability — both must be modified:

| Register | What it does | Stock | Unlocked |
|----------|-------------|-------|----------|
| `CC_GC_SHADER_ARRAY_CONFIG` | Enumeration mask (tells driver how many CUs) | `0xfff80000` (24 CU) | `0xffe00000` (40 CU) |
| `SPI_PG_ENABLE_STATIC_WGP_MASK` | Dispatch gate (tells SPI where to send waves) | `0x7` (WGP 0-2) | `0x1F` (WGP 0-4) |

**Neither alone is sufficient.** CC alone changes what the driver reports but SPI still dispatches to 24 CUs. SPI alone enables hardware dispatch but the driver only generates work for 24 CUs.

The patch writes both during `gfx_v10_0_get_cu_info()`, guarded by `device == 0x13FE` (BC-250 only) and `bc250_cc_write_mode=3` (off by default).

## Quick Start

> **Immutable / atomic distros (Bazzite, Silverblue, SteamOS):** the kernel-module
> rebuild in Options 1-3 cannot take effect. `/usr` and `/lib/modules` are read-only
> and the initramfs is image-managed, so `dracut` regeneration fails. Use Option 4
> (runtime register writes via UMR) instead.

### Option 1: Build Script (any distro)

```bash
git clone https://github.com/duggasco/bc250-40cu-unlock.git
cd bc250-40cu-unlock
sudo ./scripts/bc250-enable-40cu.sh build
sudo ./scripts/bc250-enable-40cu.sh enable   # reboots
```

Requirements: `gcc`, `make`, `zstd`, kernel headers (`linux-headers-$(uname -r)`)

### Option 2: Apply Patch Manually

```bash
# Get your kernel source
cd /path/to/linux-source/drivers/gpu/drm/amd/amdgpu/

# Apply
patch -p5 < /path/to/bc250-40cu-unlock/patch/bc250-40cu-amdgpu.patch

# Build just amdgpu
make -C /lib/modules/$(uname -r)/build M=$(pwd) -j$(nproc) modules

# Install
sudo cp amdgpu.ko.zst /lib/modules/$(uname -r)/kernel/drivers/gpu/drm/amd/amdgpu/
sudo depmod -a

# Enable
echo 'options amdgpu bc250_cc_write_mode=3' | sudo tee /etc/modprobe.d/bc250-40cu.conf
sudo reboot
```

### Option 3: CachyOS / Arch

Apply `patch/bc250-40cu-amdgpu.patch` to your kernel PKGBUILD patch set, rebuild, add the modprobe config.

### Option 4: Bazzite / atomic (rpm-ostree), runtime UMR (no kernel patch)

On atomic distros the module patch cannot persist, so write the CC and SPI registers at
runtime via UMR instead. `bc250-cu-live-manager.sh` does this and can install a boot
service to re-apply on every boot. Nothing is permanent: a reboot without the service
returns to stock 24 CU.

```bash
# umr must be present. On Bazzite:
#   rpm-ostree install umr        # then reboot to finalize (see note below)
sudo ./bc250-cu-live-manager.sh status            # current routed CU table
sudo ./bc250-cu-live-manager.sh enable all        # route all 40 CUs (live, volatile)
sudo ./bc250-cu-live-manager.sh write-service-table
sudo ./bc250-cu-live-manager.sh install-service   # persist across reboots
```

Caution: if your board has any defective unlocked WGPs, `enable all` can instantly
hard-lock the GPU (black screen). Find a stable subset first with the bisector in
"Selective CU Masking" below, then enable only the good pairs.

Bazzite / rpm-ostree notes:

- Layer packages with `rpm-ostree install <pkg>`, not `dnf`. The compute verifier needs
  `glslang`, `vulkan-headers`, and `vulkan-loader-devel`; `umr` is also a layered package.
- A layer installed with `--apply-live` is only finalized into the deployment on a *clean*
  shutdown. A hard power-cycle (for example recovering from a GPU hang) discards the staged
  deployment and the packages vanish on next boot. Install without `--apply-live` and do one
  clean `systemctl reboot` to finalize before any GPU poking, then confirm the packages
  appear in `rpm-ostree status` under LayeredPackages.

## Verification

After reboot:

```bash
# Check CU count
dmesg | grep active_cu_number
# Expected: active_cu_number 40

# Check register writes
dmesg | grep bc250-40cu
# Expected: bc250-40cu-enable: mode=3 se=0 sh=0 CC=0xfff80000->0xffe00000 SPI=0x00000007->0x0000001f

# Check RADV
RADV_DEBUG=info vulkaninfo --summary 2>&1 | grep num_cu
# Expected: num_cu = 40
```

If you used Option 4 (runtime UMR), `active_cu_number`, `num_cu`, and `cu_map.sh` keep
reporting 24: the firmware CC harvest layer is left at stock and work is routed through the
SPI dispatch mask. Use the live manager dashboard and the compute verifier for the real count:

```bash
sudo ./bc250-cu-live-manager.sh status | grep 'active & routed'   # e.g. 36/40 or 40/40
sudo ./scripts/bc250-compute-verify.sh                            # errors=0 confirms correctness
```

## CU Harvest Map

Check your board's stock CU layout (run without the patch):

```bash
./scripts/cu_map.sh
```

Our boards show contiguous harvesting:
```
SE0 SH0: ■■■■■■□□□□
SE0 SH1: ■■■■■■□□□□
SE1 SH0: ■■■■■■□□□□
SE1 SH1: ■■■■■■□□□□
24/40 CUs active, 16 harvested
```

We're collecting maps from across the fleet to find out if all BC-250s share this pattern.

## Governor / Thermal

40 CU at 2 GHz draws ~181W and hits 96C. Recommended: cap at 1500 MHz / 900 mV via the
governor. The currently maintained package is filippor's `cyan-skillfish-governor-smu`
(install and enable with `systemctl enable --now cyan-skillfish-governor-smu`):

```toml
# /etc/cyan-skillfish-governor-smu/config.toml
[[safe-points]]
frequency = 350
voltage = 700

[[safe-points]]
frequency = 1500
voltage = 900
```

## Selective CU Masking

Not all unlocked CUs are healthy. Boards with scattered harvest patterns (`■■□□■■□□■■`) are
obvious candidates for defective silicon, but a contiguous harvest pattern does **not**
guarantee the fused-off CUs are good. See the field counterexample below: one board with the
standard contiguous `■■■■■■□□□□` layout still had two genuinely defective unlocked WGPs (one
hard-locked the GPU on enable, the other miscomputed about 5% of results), giving a maximum
stable config of 36/40. Test before trusting all 40.

You can enable all 40 CUs and selectively exclude bad ones. On patched-module distros this is
done via `amdgpu.disable_cu` in the modprobe config. On atomic distros (Option 4) you simply
do not route the bad WGPs: enable only the good pairs with
`bc250-cu-live-manager.sh enable-wgp <SE.SH.WGP ...>`.

### Field counterexample (contiguous harvest, still defective)

The README and whitepaper note that on the original research boards the fused-off CUs were
disabled by firmware policy rather than silicon defect. That is not universal. A board running
this tooling under Bazzite, with the standard contiguous harvest, bisected to:

```
WGP 0.0.3 (SE0 SH0, CU 6-7): BAD  - routing it instantly hard-locks the GPU
WGP 0.0.4 (SE0 SH0, CU 8-9): BAD  - routes but returns ~5% wrong compute results
all other 6 unlocked pairs:  PASS - stable, error-free
=> max stable 36/40, both defects localized to shader array SE0.SH0
```

Treat the unlock as "all 40 are candidates, verify each" rather than "all 40 are guaranteed
good."

### WGP / CU Mapping (per shader array)

```
WGP 0 = CU 0,1    (stock active)
WGP 1 = CU 2,3    (stock active)
WGP 2 = CU 4,5    (stock active)
WGP 3 = CU 6,7    (unlocked — test these)
WGP 4 = CU 8,9    (unlocked — test these)

WGP CU Map Preview Example:
0 1 2 3 4 
■■■■■■□□□□
```

Disabling works at **WGP granularity** — disabling CU 6 also disables CU 7 (same WGP).

Format: `amdgpu.disable_cu=SE.SH.WGP` (comma-separated, added to modprobe config)

### Examples

```bash
# Enable all 40, but mask WGP 3 in SE1/SH0 (CUs 6-7) — gives 38 CUs
options amdgpu bc250_cc_write_mode=3 disable_cu=1.0.3

# Mask WGP 4 across all shader arrays — gives 32 CUs
options amdgpu bc250_cc_write_mode=3 disable_cu=0.0.4,0.1.4,1.0.4,1.1.4
```

### Automated Health Testing

Two approaches depending on your distro.

**Atomic distros (Bazzite etc.), recommended: runtime bisection (no reboots between tests).**
`bc250-wgp-bisect.sh` enables one factory-disabled WGP pair at a time via the live manager,
runs the compute verifier, then disables it. It writes a synced on-disk marker before each
register write, so if a defective WGP hard-locks the machine, re-running `start` after the
power-cycle records that pair as defective and continues instead of looping on it forever.

```bash
sudo ./bc250-wgp-bisect.sh start     # bisect all 8 upper pairs; resume after any hard-lock
sudo ./bc250-wgp-bisect.sh status    # verdict + the exact enable-wgp/persist commands
```

**Patched-module distros: per-WGP isolation across reboots.**

```bash
# Run per-WGP isolation test (20 reboots, tests each WGP individually).
# NOTE: relies on modprobe.d + initramfs regeneration, which does NOT work on
# atomic distros (dracut cannot rewrite the image-managed initramfs); use the
# bisector above there instead.
sudo ./scripts/bc250-cu-health-test.sh start

# Quick correctness test on current config (no reboot)
./scripts/bc250-compute-verify.sh

# Generate disable_cu config from health results
./scripts/bc250-cu-mask.sh --results /var/lib/bc250-cu-health-test/results.tsv

# Install the mask (adds to modprobe config)
sudo ./scripts/bc250-cu-mask.sh --results /var/lib/bc250-cu-health-test/results.tsv --install

# View harvest map with health overlay
./scripts/cu_map.sh --health /var/lib/bc250-cu-health-test/results.tsv
```

The verifier and health test distinguish "could not run" from "bad hardware":
`bc250-compute-verify.sh --check-deps` reports whether the build tools are present, the
verifier exits 3 (not a generic failure) when a dependency is missing, and the health test
records such a run as `SKIP` rather than a false `FAIL`. A WGP that hard-locks the machine is
recorded `FAIL` on the recovery boot instead of being retested indefinitely.

## Disabling

```bash
sudo ./scripts/bc250-enable-40cu.sh disable   # removes config, reboots to 24 CU
sudo ./scripts/bc250-enable-40cu.sh restore   # restores original amdgpu module
```

## Whitepaper

The full academic writeup is available as a PDF:

**[Re-enabling Fused-Off Compute Units on the AMD BC-250 APU via Register-Level Modification](docs/whitepaper-cu-unlock.pdf)** (8 pages)

Covers the complete methodology, 4-state controlled experiment, community harvest map survey (n=58), performance characterization, and dual-register gating architecture analysis. LaTeX source included at [docs/whitepaper-cu-unlock.tex](docs/whitepaper-cu-unlock.tex).

## Technical Details

See [docs/technical-report.md](docs/technical-report.md) for additional technical notes including:
- Register map (UMR dumps)
- Architecture analysis (CC vs SPI vs RLC vs SMU)
- Why `ignore_cu_harvest` doesn't work
- Power/thermal characterization

## Safety

- Default off (`bc250_cc_write_mode=0`) — does nothing unless explicitly enabled
- Guarded by PCI device ID `0x13FE` — only fires on BC-250
- No permanent hardware changes — reboot without the config returns to stock 24 CU
- On the original research boards the harvested CUs had power, clocks, and matching CGTS config (RLC_PG_CNTL = 0, no power gating active), indicating they were disabled by firmware policy rather than silicon defect. This is not universal: at least one in-the-wild board with a contiguous harvest pattern had genuinely defective unlocked WGPs (see "Selective CU Masking"). Verify each unlocked WGP with the bisector or compute verifier before relying on all 40.

## Credits

- **duggasco** — research, testing, documentation
- **filippor** — independent testing, `ignore_cu_harvest` kernel patch, cyan-skillfish-governor
- **Claude** — analysis, tooling, SPI register discovery
- **Codex** — identified SPI_PG_ENABLE_STATIC_WGP_MASK architecture
- **BC-250 Discord** — thermal/voltage guidance, fleet testing

## License

GPL-2.0 (same as the Linux kernel)
