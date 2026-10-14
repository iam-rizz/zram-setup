#!/usr/bin/env bash
# =============================================================================
#  zram-auto.sh — Automatic ZRAM swap: hardware-aware & persistent (systemd)
#
#  Repo: https://github.com/iam-rizz/zram-setup
#
#  One-line install:
#    curl -fsSL https://raw.githubusercontent.com/iam-rizz/zram-setup/main/zram-auto.sh | sudo bash
#
#  Usage (local file):
#    sudo bash zram-auto.sh              install / update (default)
#    sudo bash zram-auto.sh status       show zram status & tuning
#    sudo bash zram-auto.sh uninstall    remove & restore the previous setup
#
#  What it does:
#    - Sizes zram from total RAM, recalculated on every boot
#      (upgrade your RAM and the size follows automatically)
#    - Picks the compression algorithm based on the CPU (zstd / lz4)
#      with automatic fallback
#    - Applies zram-specific sysctl tuning (swappiness, page-cluster, watermarks)
#    - Disables zswap (double compression when combined with zram)
#    - Disables conflicting zram setups (zram-tools, zram-config,
#      zram-generator, zramd)
#    - Existing disk swap is NOT removed; it stays as a lower-priority fallback
# =============================================================================
set -euo pipefail

VERSION=1.0.1
NAME=zram-auto
RAW_URL=https://raw.githubusercontent.com/iam-rizz/zram-setup/main/zram-auto.sh
BIN=/usr/local/sbin/$NAME
CONF=/etc/default/$NAME
UNIT=/etc/systemd/system/$NAME.service
STATE=/var/lib/$NAME
CONFLICT_UNITS=(zramswap.service zram-config.service zram-swap.service zramd.service)
CONF_KEYS=(ZRAM_SIZE ZRAM_ALGO ZRAM_PRIORITY ZRAM_MEM_LIMIT TUNE_SYSCTL DISABLE_ZSWAP)

if [[ -t 1 ]]; then G=$'\e[32m' Y=$'\e[33m' R=$'\e[31m' N=$'\e[0m'; else G='' Y='' R='' N=''; fi
info() { echo "${G}[+]${N} $*"; }
warn() { echo "${Y}[!]${N} $*"; }
die()  { echo "${R}[x]${N} $*" >&2; exit 1; }

usage() {
  cat <<EOF
$NAME $VERSION — automatic, hardware-aware ZRAM swap

Usage:
  sudo bash zram-auto.sh [command]
  curl -fsSL $RAW_URL | sudo bash -s -- [command]

Commands:
  install     Install / update zram (default)
  status      Show zram status, compression ratio and tuning
  uninstall   Remove zram-auto and restore the previous setup
  version     Show version

Set config values at install time (optional):
  curl -fsSL $RAW_URL | sudo env ZRAM_SIZE=50% ZRAM_ALGO=lz4 bash

Variables: ${CONF_KEYS[*]}
Config file after install: $CONF
EOF
}

# When run from a file without root, re-exec itself with sudo.
# When piped (curl | bash) it can't re-exec, so ask the user to use sudo.
need_root() {
  [[ $EUID -eq 0 ]] && return 0
  local src=${BASH_SOURCE[0]:-} k envs=()
  if [[ -n $src && -f $src ]] && command -v sudo >/dev/null; then
    for k in "${CONF_KEYS[@]}"; do [[ -n ${!k-} ]] && envs+=("$k=${!k}"); done
    info "Root access required, re-running with sudo..."
    exec sudo env "${envs[@]}" bash "$src" "$@"
  fi
  die "Root access required. Use: curl -fsSL $RAW_URL | sudo bash"
}

# Validate config overrides passed through the environment (ZRAM_SIZE=50% etc.)
validate_env() {
  [[ -z ${ZRAM_SIZE-} || ${ZRAM_SIZE,,} =~ ^(auto|[0-9]+%|[0-9]+[kmg]?)$ ]] \
    || die "Invalid ZRAM_SIZE: '$ZRAM_SIZE' (e.g. auto, 50%, 4G, 2048M)"
  [[ -z ${ZRAM_ALGO-} || $ZRAM_ALGO =~ ^(auto|zstd|lz4|lz4hc|lzo-rle|lzo|842|deflate)$ ]] \
    || die "Invalid ZRAM_ALGO: '$ZRAM_ALGO' (auto, zstd, lz4, lzo-rle, lzo)"
  [[ -z ${ZRAM_PRIORITY-} || ( $ZRAM_PRIORITY =~ ^[0-9]+$ && $ZRAM_PRIORITY -le 32767 ) ]] \
    || die "Invalid ZRAM_PRIORITY: '$ZRAM_PRIORITY' (0 - 32767)"
  [[ -z ${ZRAM_MEM_LIMIT-} || ${ZRAM_MEM_LIMIT,,} =~ ^[0-9]+[kmg]?$ ]] \
    || die "Invalid ZRAM_MEM_LIMIT: '$ZRAM_MEM_LIMIT' (e.g. 0, 2G)"
  [[ -z ${TUNE_SYSCTL-} || $TUNE_SYSCTL =~ ^(yes|no)$ ]] \
    || die "TUNE_SYSCTL must be yes / no"
  [[ -z ${DISABLE_ZSWAP-} || $DISABLE_ZSWAP =~ ^(yes|no)$ ]] \
    || die "DISABLE_ZSWAP must be yes / no"
  return 0
}

# -----------------------------------------------------------------------------
preflight() {
  [[ $EUID -eq 0 ]] || die "Please run as root / with sudo."
  [[ -d /run/systemd/system ]] || die "systemd is required (other init systems are not supported yet)."
  local c
  for c in modprobe mkswap swapon swapoff sysctl awk nproc; do
    command -v "$c" >/dev/null || die "Required command '$c' not found."
  done
  if command -v systemd-detect-virt >/dev/null && systemd-detect-virt -cq; then
    die "Running inside a container. zram must be configured on the host."
  fi
  modprobe zram 2>/dev/null || true
  [[ -e /sys/class/zram-control || -e /sys/block/zram0 ]] \
    || die "This kernel does not support zram (zram module not found)."
}

disable_conflicts() {
  mkdir -p "$STATE"
  local u

  # zram services from other packages
  for u in "${CONFLICT_UNITS[@]}"; do
    systemctl list-unit-files --no-legend "$u" 2>/dev/null | grep -q . || continue
    if systemctl is-enabled -q "$u" 2>/dev/null || systemctl is-active -q "$u" 2>/dev/null; then
      warn "Disabling $u (conflicts with $NAME)"
      systemctl disable --now "$u" >/dev/null 2>&1 || true
      grep -qx "$u" "$STATE/disabled-units" 2>/dev/null || echo "$u" >> "$STATE/disabled-units"
    fi
  done

  # zram-generator (default on Fedora, Arch, etc.)
  if [[ -x /usr/lib/systemd/system-generators/zram-generator || -x /lib/systemd/system-generators/zram-generator ]]; then
    local gconf=/etc/systemd/zram-generator.conf
    if [[ ! -f $STATE/zram-generator.done ]]; then
      [[ -f $gconf ]] && cp -a "$gconf" "$STATE/zram-generator.conf.bak"
      printf '# Emptied by %s to avoid conflicts.\n# Run "zram-auto.sh uninstall" to restore.\n' "$NAME" > "$gconf"
      touch "$STATE/zram-generator.done"
      warn "zram-generator disabled via $gconf"
    fi
    [[ -d ${gconf}.d ]] && warn "Drop-ins found in ${gconf}.d/, check them manually to avoid conflicts."
    systemctl stop 'dev-zram*.swap' 'systemd-zram-setup@*.service' >/dev/null 2>&1 || true
  fi

  # Not disabled automatically, just warn
  [[ -f /etc/default/armbian-zram-config ]] \
    && warn "Armbian: set SWAP=false in /etc/default/armbian-zram-config to avoid a duplicate zram swap."
  systemctl is-enabled -q systemd-swap.service 2>/dev/null \
    && warn "systemd-swap is enabled: turn off its zram feature to avoid a duplicate zram swap."
  grep -qE '^[[:space:]]*/dev/zram' /etc/fstab 2>/dev/null \
    && warn "Found a /dev/zram entry in /etc/fstab, consider commenting it out to avoid conflicts."
  return 0
}

release_existing_zram() {
  local dev
  while read -r dev _; do
    [[ $dev == /dev/zram* ]] || continue
    warn "Turning off existing zram swap: $dev"
    swapoff "$dev" || die "Failed to swapoff $dev (not enough free RAM to hold its contents?)"
    { echo 1 > "/sys/block/${dev#/dev/}/reset"; } 2>/dev/null || true
  done < <(tail -n +2 /proc/swaps)
}

# -----------------------------------------------------------------------------
write_runtime() {
  cat > "$BIN" <<'__RUNTIME__'
#!/usr/bin/env bash
# zram-auto runtime — installed by zram-auto.sh, run by zram-auto.service.
# Do not edit this file; change settings in /etc/default/zram-auto instead.
set -uo pipefail

CONF=/etc/default/zram-auto
RUN=/run/zram-auto

ZRAM_SIZE=auto
ZRAM_ALGO=auto
ZRAM_PRIORITY=100
ZRAM_MEM_LIMIT=0
TUNE_SYSCTL=yes
DISABLE_ZSWAP=yes
# shellcheck disable=SC1090
[[ -r $CONF ]] && . "$CONF"

SYSCTL_KEYS=(vm.swappiness vm.page-cluster vm.watermark_boost_factor vm.watermark_scale_factor)

log() { echo "zram-auto: $*"; }
die() { echo "zram-auto: ERROR: $*" >&2; exit 1; }

cores_str() { local n; n=$(nproc); if (( n == 1 )); then echo "1 core"; else echo "$n cores"; fi; }
ram_mib() { awk '/^MemTotal:/ {printf "%d", $2 / 1024}' /proc/meminfo; }
max() { if (( $1 > $2 )); then echo "$1"; else echo "$2"; fi; }
min() { if (( $1 < $2 )); then echo "$1"; else echo "$2"; fi; }

kernel_ge() {  # kernel_ge 5 8  -> true if kernel >= 5.8
  local kmaj kmin
  IFS=. read -r kmaj kmin _ <<< "$(uname -r)"
  kmin=${kmin%%[!0-9]*}
  (( kmaj > $1 || (kmaj == $1 && kmin >= $2) ))
}

# zram size (uncompressed capacity) based on RAM; the curve never decreases
#   <= 2G : 150%            -> small-RAM devices benefit the most
#   <= 4G : 100%  (min 3G)
#   <= 8G :  75%  (min 4G)
#   <=16G :  50%  (min 6G)
#   > 16G :  25%  (8G - 16G)
auto_size_mib() {
  local r; r=$(ram_mib)
  if   (( r <= 2048 ));  then echo $(( r * 3 / 2 ))
  elif (( r <= 4096 ));  then max 3072 "$r"
  elif (( r <= 8192 ));  then max 4096 $(( r * 3 / 4 ))
  elif (( r <= 16384 )); then max 6144 $(( r / 2 ))
  else min 16384 "$(max 8192 $(( r / 4 )))"
  fi
}

resolve_size() {
  local s=${ZRAM_SIZE,,}
  case $s in
    auto|"") echo "$(auto_size_mib)M" ;;
    *%)
      s=${s%\%}
      [[ $s =~ ^[0-9]+$ ]] || die "invalid ZRAM_SIZE: $ZRAM_SIZE"
      echo "$(( $(ram_mib) * s / 100 ))M" ;;
    *)
      [[ $s =~ ^[0-9]+[kmg]?$ ]] || die "invalid ZRAM_SIZE: $ZRAM_SIZE"
      echo "${s^^}" ;;
  esac
}

find_free_dev() {
  local d i
  for d in /sys/block/zram*; do
    [[ -e $d/disksize ]] || continue
    if [[ $(<"$d/disksize") == 0 ]]; then echo "${d##*/}"; return 0; fi
  done
  if [[ -r /sys/class/zram-control/hot_add ]]; then
    i=$(</sys/class/zram-control/hot_add) && { echo "zram$i"; return 0; }
  fi
  return 1
}

# zstd = best compression ratio (CPU > 2 cores)
# lz4  = lightest & fastest (CPU <= 2 cores / low-end devices)
set_algo() {
  local dev=$1 list a
  if   [[ $ZRAM_ALGO != auto ]]; then list="$ZRAM_ALGO zstd lz4 lzo-rle lzo"
  elif (( $(nproc) <= 2 ));       then list="lz4 zstd lzo-rle lzo"
  else                                 list="zstd lz4 lzo-rle lzo"
  fi
  for a in $list; do
    modprobe -q "$a" 2>/dev/null || true
    if { echo "$a" > "/sys/block/$dev/comp_algorithm"; } 2>/dev/null; then
      echo "$a"; return 0
    fi
  done
  sed -n 's/.*\[\([^]]*\)\].*/\1/p' "/sys/block/$dev/comp_algorithm"
}

disable_zswap() {
  local p=/sys/module/zswap/parameters/enabled
  [[ $DISABLE_ZSWAP == yes && -w $p ]] || return 0
  if [[ $(<"$p") == Y ]]; then
    echo N > "$p" && log "zswap disabled (avoids double compression with zram)"
  fi
}

apply_sysctl() {
  [[ $TUNE_SYSCTL == yes ]] || return 0
  local k swp=100
  kernel_ge 5 8 && swp=180    # kernel >= 5.8 allows swappiness > 100
  if [[ ! -f $RUN/sysctl.orig ]]; then
    for k in "${SYSCTL_KEYS[@]}"; do
      sysctl -n "$k" >/dev/null 2>&1 && echo "$k=$(sysctl -n "$k")"
    done > "$RUN/sysctl.orig"
  fi
  local -A want=(
    [vm.swappiness]=$swp              # zram is far cheaper than disk -> swap more eagerly
    [vm.page-cluster]=0               # one page per swap-in (readahead is useless for RAM)
    [vm.watermark_boost_factor]=0
    [vm.watermark_scale_factor]=125   # kswapd wakes up earlier, less stutter
  )
  for k in "${SYSCTL_KEYS[@]}"; do
    sysctl -q -w "$k=${want[$k]}" 2>/dev/null || true
  done
  log "sysctl: swappiness=$swp page-cluster=0 watermark_boost_factor=0 watermark_scale_factor=125"
}

restore_sysctl() {
  [[ -f $RUN/sysctl.orig ]] || return 0
  local line
  while read -r line; do
    [[ -n $line ]] && { sysctl -q -w "$line" 2>/dev/null || true; }
  done < "$RUN/sysctl.orig"
  rm -f "$RUN/sysctl.orig"
}

do_start() {
  [[ $EUID -eq 0 ]] || die "must be run as root"
  [[ -f $RUN/device ]] && do_stop
  mkdir -p "$RUN"
  modprobe zram 2>/dev/null || true
  disable_zswap

  local dev algo size cores
  dev=$(find_free_dev) || die "no usable zram device available"
  for _ in {1..50}; do [[ -b /dev/$dev ]] && break; sleep 0.1; done
  [[ -b /dev/$dev ]] || die "/dev/$dev did not appear"

  cores=$(nproc)
  algo=$(set_algo "$dev")
  # Only matters on old kernels (< 4.7); newer kernels use per-CPU streams
  if [[ -w /sys/block/$dev/max_comp_streams ]]; then
    { echo "$cores" > "/sys/block/$dev/max_comp_streams"; } 2>/dev/null
  fi

  size=$(resolve_size) || exit 1
  echo "$size" > "/sys/block/$dev/disksize" || die "failed to set size $size on $dev"
  if [[ $ZRAM_MEM_LIMIT != 0 ]]; then
    { echo "${ZRAM_MEM_LIMIT^^}" > "/sys/block/$dev/mem_limit"; } 2>/dev/null \
      || log "warning: failed to set mem_limit=$ZRAM_MEM_LIMIT"
  fi

  mkswap -L zram-auto "/dev/$dev" >/dev/null || die "mkswap failed"
  swapon --discard -p "$ZRAM_PRIORITY" "/dev/$dev" 2>/dev/null \
    || swapon -p "$ZRAM_PRIORITY" "/dev/$dev" || die "swapon failed"
  echo "$dev" > "$RUN/device"

  apply_sysctl
  log "active: /dev/$dev size=$size algo=$algo prio=$ZRAM_PRIORITY (RAM $(ram_mib) MiB, $(cores_str), kernel $(uname -r))"
}

do_stop() {
  local dev
  if [[ -f $RUN/device ]]; then
    dev=$(<"$RUN/device")
    if grep -q "^/dev/${dev}[[:space:]]" /proc/swaps; then
      swapoff "/dev/$dev" || log "warning: swapoff /dev/$dev failed"
    fi
    { echo 1 > "/sys/block/$dev/reset"; } 2>/dev/null
    if [[ $dev != zram0 && -w /sys/class/zram-control/hot_remove ]]; then
      { echo "${dev#zram}" > /sys/class/zram-control/hot_remove; } 2>/dev/null
    fi
    rm -f "$RUN/device"
    log "stopped: /dev/$dev"
  fi
  restore_sysctl
}

do_status() {
  local dev k orig compr used
  printf 'RAM    : %s MiB\nCPU    : %s\nKernel : %s\n\n' "$(ram_mib)" "$(cores_str)" "$(uname -r)"
  echo "-- Active swap --"
  swapon --show 2>/dev/null || cat /proc/swaps
  echo
  if [[ -f $RUN/device ]]; then
    dev=$(<"$RUN/device")
    echo "-- ZRAM: /dev/$dev --"
    if command -v zramctl >/dev/null; then zramctl "/dev/$dev"; echo; fi
    if [[ -r /sys/block/$dev/mm_stat ]]; then
      read -r orig compr used _ < "/sys/block/$dev/mm_stat"
      awk -v o="$orig" -v c="$compr" -v u="$used" 'BEGIN {
        printf "Original data   : %.1f MiB\n", o / 1048576
        printf "Compressed      : %.1f MiB\n", c / 1048576
        printf "RAM used        : %.1f MiB\n", u / 1048576
        # below 1 MiB the allocator overhead dominates, so the ratio is meaningless
        if (o >= 1048576 && u > 0) printf "Effective ratio : %.2fx\n", o / u
        else                       print  "Effective ratio : - (not enough data swapped yet)"
      }'
    fi
  else
    echo "zram-auto is not active"
  fi
  echo
  echo "-- Tuning --"
  for k in "${SYSCTL_KEYS[@]}"; do
    printf '%-27s = %s\n' "$k" "$(sysctl -n "$k" 2>/dev/null || echo -)"
  done
  if [[ -r /sys/module/zswap/parameters/enabled ]]; then
    printf '%-27s = %s\n' "zswap" "$(</sys/module/zswap/parameters/enabled)"
  fi
  return 0
}

case ${1:-} in
  start)   do_start ;;
  stop)    do_stop ;;
  restart) do_stop; do_start ;;
  status)  do_status ;;
  *) echo "Usage: $0 {start|stop|restart|status}"; exit 1 ;;
esac
__RUNTIME__
  chmod 755 "$BIN"
}

write_config() {
  local k v
  if [[ -f $CONF ]]; then
    info "Keeping existing config: $CONF"
  else
    write_default_config
  fi
  # Overrides from the environment, e.g.: sudo env ZRAM_SIZE=50% bash zram-auto.sh
  for k in "${CONF_KEYS[@]}"; do
    v=${!k-}
    [[ -n $v ]] || continue
    if grep -q "^$k=" "$CONF"; then
      sed -i "s|^$k=.*|$k=$v|" "$CONF"
    else
      echo "$k=$v" >> "$CONF"
    fi
    info "Config: $k=$v"
  done
}

write_default_config() {
  cat > "$CONF" <<'__CONF__'
# zram-auto configuration
# After editing, apply with:  sudo systemctl restart zram-auto

# zram size (capacity for data BEFORE compression)
#   auto       = based on RAM, recalculated on every boot
#   50%        = percentage of RAM
#   4G / 2048M = fixed size
ZRAM_SIZE=auto

# Compression algorithm: auto | zstd | lz4 | lzo-rle | lzo
#   auto = zstd if the CPU has > 2 cores, lz4 if <= 2 cores
ZRAM_ALGO=auto

# Swap priority (higher = used first; disk swap is usually -2)
ZRAM_PRIORITY=100

# Max physical RAM zram may use after compression. 0 = no limit.
# Example: 2G
ZRAM_MEM_LIMIT=0

# Apply zram-specific sysctl tuning (swappiness, page-cluster, watermarks): yes | no
TUNE_SYSCTL=yes

# Disable zswap to avoid double compression: yes | no
DISABLE_ZSWAP=yes
__CONF__
}

write_unit() {
  cat > "$UNIT" <<EOF
[Unit]
Description=Automatic ZRAM swap (zram-auto)
Documentation=https://github.com/iam-rizz/zram-setup file:$CONF
After=local-fs.target systemd-modules-load.service

[Service]
Type=oneshot
RemainAfterExit=yes
ExecStart=$BIN start
ExecStop=$BIN stop

[Install]
WantedBy=multi-user.target
EOF
}

# -----------------------------------------------------------------------------
do_install() {
  validate_env
  preflight
  systemctl stop "$NAME.service" >/dev/null 2>&1 || true
  disable_conflicts
  release_existing_zram
  write_runtime
  write_config
  write_unit
  systemctl daemon-reload
  systemctl enable --now "$NAME.service" >/dev/null 2>&1 \
    || die "Service failed to start. Check the log: journalctl -u $NAME -b"
  info "Done! ZRAM is active and will start automatically on every boot."
  echo
  "$BIN" status
}

do_uninstall() {
  [[ $EUID -eq 0 ]] || die "Please run as root / with sudo."
  if [[ -f $UNIT ]]; then
    systemctl disable --now "$NAME.service" >/dev/null 2>&1 || true
  fi
  rm -f "$UNIT" "$BIN" "$CONF"
  systemctl daemon-reload

  if [[ -f $STATE/zram-generator.done ]]; then
    if [[ -f $STATE/zram-generator.conf.bak ]]; then
      cp -a "$STATE/zram-generator.conf.bak" /etc/systemd/zram-generator.conf
    else
      rm -f /etc/systemd/zram-generator.conf
    fi
    info "zram-generator config restored (active again after reboot)."
  fi
  if [[ -f $STATE/disabled-units ]]; then
    local u
    while read -r u; do
      [[ -n $u ]] || continue
      systemctl enable "$u" >/dev/null 2>&1 && info "Re-enabled $u (takes effect after reboot)."
    done < "$STATE/disabled-units"
  fi
  rm -rf "$STATE"
  info "Uninstall complete."
}

do_status() {
  [[ -x $BIN ]] || die "$NAME is not installed."
  exec "$BIN" status
}

# All logic lives in main() and is only called on the very last line,
# so nothing runs if a curl download is cut off halfway.
main() {
  local cmd=${1:-install}
  case $cmd in
    install|update)       need_root "$@"; do_install ;;
    uninstall|remove)     need_root "$@"; do_uninstall ;;
    status)               do_status ;;
    -v|--version|version) echo "$NAME $VERSION" ;;
    -h|--help|help)       usage ;;
    *) usage; exit 1 ;;
  esac
}

main "$@"
