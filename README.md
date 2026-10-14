# zram-setup

![Bash](https://img.shields.io/badge/bash-4%2B-4EAA25?logo=gnubash&logoColor=white)
![Init](https://img.shields.io/badge/init-systemd-30D475)
![License](https://img.shields.io/badge/license-MIT-blue)

A bash script that sets up **ZRAM swap** automatically, tunes it to your hardware, and keeps it active across reboots.

ZRAM creates a compressed swap device inside RAM. In practice this gives you 2–4x more effective memory without touching slow disk storage. It makes the biggest difference on low-RAM laptops, VPSes, and single-board computers like the Raspberry Pi.

## Features

- **Automatic sizing.** zram size is derived from total RAM and recalculated on every boot, so it adapts if you upgrade your RAM.
- **Automatic algorithm.** Uses `zstd` on capable CPUs and `lz4` on weak ones, with fallback if the kernel lacks support.
- **Kernel tuning.** Sets `swappiness`, `page-cluster`, and watermark values tailored for zram.
- **Persistent.** Installed as a systemd service, so it comes up on every boot.
- **Conflict-free.** Disables zswap and other zram setups (zram-tools, zram-config, zram-generator, zramd).
- **Keeps your disk swap.** Existing disk swap is left in place as a lower-priority fallback.
- **Fully reversible.** `uninstall` removes everything and re-enables your previous setup.

## Quick install

```bash
curl -fsSL https://raw.githubusercontent.com/iam-rizz/zram-setup/main/zram-auto.sh | sudo bash
```

Or with `wget`:

```bash
wget -qO- https://raw.githubusercontent.com/iam-rizz/zram-setup/main/zram-auto.sh | sudo bash
```

That's it. ZRAM is active immediately and the status is printed at the end.

> **Security tip:** before running a script from the internet as root, it's good practice to read it first:
> ```bash
> curl -fsSL https://raw.githubusercontent.com/iam-rizz/zram-setup/main/zram-auto.sh -o zram-auto.sh
> less zram-auto.sh
> sudo bash zram-auto.sh
> ```

## Commands

| Action | One-line | Local file |
|---|---|---|
| Install / update | `curl -fsSL <URL> \| sudo bash` | `sudo bash zram-auto.sh` |
| Show status | `sudo zram-auto status` | `bash zram-auto.sh status` |
| Uninstall | `curl -fsSL <URL> \| sudo bash -s -- uninstall` | `sudo bash zram-auto.sh uninstall` |
| Version | `curl -fsSL <URL> \| bash -s -- version` | `bash zram-auto.sh version` |
| Help | `curl -fsSL <URL> \| bash -s -- help` | `bash zram-auto.sh help` |

`<URL>` = `https://raw.githubusercontent.com/iam-rizz/zram-setup/main/zram-auto.sh`

Once installed, the `zram-auto` command is available system-wide (`/usr/local/sbin/zram-auto`) with the subcommands `start`, `stop`, `restart`, and `status`.

## Manual install

```bash
git clone https://github.com/iam-rizz/zram-setup.git
cd zram-setup
sudo bash zram-auto.sh
```

If you run it without `sudo`, the script will ask for root access automatically.

## How it works

### zram size

The sizes below are the capacity for data **before** compression. The RAM actually consumed is usually about a third of that (`zstd` typically compresses 3–4x).

| Total RAM | Formula | Example |
|---|---|---|
| ≤ 2 GB | 150% of RAM | 1 GB → 1.5 GB, 2 GB → 3 GB |
| 2–4 GB | 100% of RAM (min. 3 GB) | 4 GB → 4 GB |
| 4–8 GB | 75% of RAM (min. 4 GB) | 8 GB → 6 GB |
| 8–16 GB | 50% of RAM (min. 6 GB) | 16 GB → 8 GB |
| > 16 GB | 25% of RAM (8–16 GB) | 32 GB → 8 GB, 64 GB → 16 GB |

The less RAM you have, the larger the percentage, because low-memory devices benefit the most from "extra" RAM. The curve never decreases, so there are no odd jumps between tiers.

### Compression algorithm

| Condition | Algorithm | Why |
|---|---|---|
| CPU with > 2 cores | `zstd` | Best compression ratio |
| CPU with ≤ 2 cores | `lz4` | Lightest and fastest |
| Not supported by the kernel | `lzo-rle` → `lzo` | Automatic fallback |

### Kernel tuning

| Parameter | Value | Purpose |
|---|---|---|
| `vm.swappiness` | `180` (kernel ≥ 5.8), `100` (older kernels) | Swapping to zram is far cheaper than disk, so the kernel can swap more eagerly |
| `vm.page-cluster` | `0` | Read one page per swap-in; readahead is pointless for RAM-backed swap |
| `vm.watermark_boost_factor` | `0` | Prevents excessive reclaim after fragmentation events |
| `vm.watermark_scale_factor` | `125` | Wakes kswapd earlier, reducing stutter under memory pressure |

These values follow what Pop!_OS and ChromeOS use for zram. The original values are saved and restored when the service is stopped or uninstalled.

### Swap priority

ZRAM is activated with priority `100`. Disk swap usually has a negative priority, so zram is always used first and disk swap only kicks in once zram is full.

## Configuration

After installing, the configuration lives in `/etc/default/zram-auto`:

```bash
ZRAM_SIZE=auto        # auto | 50% | 4G | 2048M
ZRAM_ALGO=auto        # auto | zstd | lz4 | lzo-rle | lzo
ZRAM_PRIORITY=100     # 0 - 32767, higher = used first
ZRAM_MEM_LIMIT=0      # max physical RAM for zram, 0 = no limit (e.g. 2G)
TUNE_SYSCTL=yes       # yes | no
DISABLE_ZSWAP=yes     # yes | no
```

After editing, apply the changes with:

```bash
sudo systemctl restart zram-auto
```

### Set config at install time

Any of the variables above can be passed directly in the one-line command:

```bash
# zram at 50% of RAM using lz4
curl -fsSL https://raw.githubusercontent.com/iam-rizz/zram-setup/main/zram-auto.sh | sudo env ZRAM_SIZE=50% ZRAM_ALGO=lz4 bash

# fixed 4 GB, no sysctl tuning
curl -fsSL https://raw.githubusercontent.com/iam-rizz/zram-setup/main/zram-auto.sh | sudo env ZRAM_SIZE=4G TUNE_SYSCTL=no bash
```

Values are validated before anything is changed. Re-running the installer without variables keeps your existing config.

## Example status output

```
$ sudo zram-auto status
RAM    : 7842 MiB
CPU    : 8 cores
Kernel : 6.8.0-45-generic

-- Active swap --
NAME       TYPE      SIZE USED PRIO
/swap.img  file        2G   0B   -2
/dev/zram0 partition 5.7G 1.2G  100

-- ZRAM: /dev/zram0 --
NAME       ALGORITHM DISKSIZE  DATA  COMPR  TOTAL STREAMS MOUNTPOINT
/dev/zram0 zstd          5.7G  1.2G 301.5M 312.8M       8 [SWAP]

Original data   : 1228.8 MiB
Compressed      : 301.5 MiB
RAM used        : 312.8 MiB
Effective ratio : 3.93x

-- Tuning --
vm.swappiness               = 180
vm.page-cluster             = 0
vm.watermark_boost_factor   = 0
vm.watermark_scale_factor   = 125
zswap                       = N
```

*The numbers above are just an example; yours will differ.*

## Installed files

| Path | Purpose |
|---|---|
| `/usr/local/sbin/zram-auto` | Runtime script (start / stop / restart / status) |
| `/etc/default/zram-auto` | Configuration file |
| `/etc/systemd/system/zram-auto.service` | systemd service that runs on every boot |
| `/var/lib/zram-auto/` | Records of disabled setups, used by uninstall |
| `/run/zram-auto/` | Runtime state (cleared on reboot) |

## Requirements

- Linux with **systemd** (Ubuntu, Debian, Fedora, Arch, openSUSE, Linux Mint, Pop!_OS, Raspberry Pi OS, etc.)
- A kernel with the **zram** module (virtually every modern distro kernel has it)
- `bash` 4+ and `util-linux` (`mkswap`, `swapon`; `zramctl` is optional, used for status)
- Root access

It **cannot** run inside containers (Docker, LXC, or OpenVZ/LXC-based VPSes), because zram has to be configured by the host kernel. KVM-based VPSes work fine.

## Handling other zram setups

| Setup | Action |
|---|---|
| `zram-tools` (zramswap.service) | Disabled automatically |
| `zram-config` (Ubuntu) | Disabled automatically |
| `zram-generator` (Fedora, Arch) | Disabled via `/etc/systemd/zram-generator.conf` |
| `zramd`, `zram-swap` | Disabled automatically |
| Armbian `armbian-zram-config` | Warning only; set `SWAP=false` manually |
| `systemd-swap` | Warning only; turn off its zram feature manually |
| `/dev/zram` entry in `/etc/fstab` | Warning only; comment it out manually |

Everything that is disabled automatically gets re-enabled on `uninstall`.

## Troubleshooting

**The service fails to start.** Check its log:

```bash
journalctl -u zram-auto -b
```

**Using hibernation?** ZRAM can't be used for hibernation because its contents are lost on power-off. Keep a disk swap (partition or swapfile) large enough for hibernation.

**Uninstall fails at `swapoff`.** There isn't enough free RAM to hold the decompressed contents of zram. Close some applications and try again.

**Should I remove my disk swap?** No need. Disk swap is still useful as a fallback when zram fills up, and zram is always used first thanks to its higher priority.

**Want a bigger or smaller zram?** Change `ZRAM_SIZE` in `/etc/default/zram-auto`, then run `sudo systemctl restart zram-auto`.

## Uninstall

```bash
curl -fsSL https://raw.githubusercontent.com/iam-rizz/zram-setup/main/zram-auto.sh | sudo bash -s -- uninstall
```

This stops zram, restores the original sysctl values, removes all installed files, and re-enables any previous zram setup (takes effect after reboot).

## License

[MIT](LICENSE)
