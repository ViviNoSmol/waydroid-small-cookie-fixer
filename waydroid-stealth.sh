#!/usr/bin/env bash
set -euo pipefail

WD=/var/lib/waydroid
OV=$WD/overlay_rw
OVW=$WD/overlay_work
CFG=$WD/waydroid.cfg
STATE=$WD/.stealth-manifest

MODE=apply
INPLACE=0
BACKUP=1
WHITEOUT=0

usage() {
  cat <<'EOT'
Usage: sudo ./waydroid-stealth.sh [verify] [options]

  verify                   check the current state without changing anything
  --in-place               patch existing overlay_rw files instead of recopying them from the images
  --no-backup              skip the overlay_rw backup
  --whiteout-precompiled   hide /vendor/etc/selinux/precompiled_sepolicy
  -h, --help               show this help

Env: WD_IMAGES=/path forces the images directory
EOT
}

for a in "$@"; do
  case "$a" in
    verify) MODE=verify ;;
    --in-place) INPLACE=1 ;;
    --no-backup) BACKUP=0 ;;
    --whiteout-precompiled) WHITEOUT=1 ;;
    -h|--help) usage; exit 0 ;;
    *) echo "Unknown option: $a" >&2; usage >&2; exit 1 ;;
  esac
done

[ "$(id -u)" -eq 0 ] || exec sudo "$0" "$@"

ok()   { printf '  [ok]   %s\n' "$*"; }
bad()  { printf '  [FAIL] %s\n' "$*"; }
info() { printf '==> %s\n' "$*"; }

REAL_USER=${SUDO_USER:-}
run_as_user() {
  if [ -n "$REAL_USER" ] && [ "$REAL_USER" != root ]; then
    local uid; uid=$(id -u "$REAL_USER")
    sudo -u "$REAL_USER" env XDG_RUNTIME_DIR="/run/user/$uid" \
      DBUS_SESSION_BUS_ADDRESS="unix:path=/run/user/$uid/bus" "$@"
  else
    "$@"
  fi
}

verify() {
  local rc=0 tags type dbg leftover sel_l sel_s
  info "Verifying"

  if grep -q '^mount_overlays *= *True' "$CFG" 2>/dev/null; then
    ok "mount_overlays = True"
  else
    bad "mount_overlays is not True"; rc=1
  fi

  if lxc-info -P "$WD/lxc" -n waydroid -sH 2>&1 | grep -q 'Built without AppArmor'; then
    bad "LXC config has lxc.apparmor.profile but LXC has no AppArmor support (run the script)"; rc=1
  fi

  if mount | grep -q "overlay on $WD/rootfs "; then
    ok "overlay mounted on rootfs"
  else
    bad "no overlay mounted on rootfs (is the session running?)"; rc=1
  fi

  if waydroid status 2>/dev/null | grep -q 'Container:.*RUNNING'; then
    tags=$(waydroid shell -- sh -c 'getprop ro.build.tags' | tr -d '\r' || true)
    type=$(waydroid shell -- sh -c 'getprop ro.build.type' | tr -d '\r' || true)
    dbg=$(waydroid shell -- sh -c 'getprop ro.debuggable' | tr -d '\r' || true)
    [ "$tags" = release-keys ] && ok "ro.build.tags = release-keys" || { bad "ro.build.tags = '$tags'"; rc=1; }
    [ "$type" = user ]         && ok "ro.build.type = user"         || { bad "ro.build.type = '$type'"; rc=1; }
    [ "$dbg" = 0 ]             && ok "ro.debuggable = 0"            || { bad "ro.debuggable = '$dbg'"; rc=1; }

    leftover=$(waydroid shell -- sh -c "getprop | grep -iE 'dev-keys|test-keys|userdebug|lineage_waydroid'" | tr -d '\r' || true)
    if [ -z "$leftover" ]; then ok "no dev-keys/test-keys/userdebug/lineage_waydroid in getprop"
    else bad "props with leftovers:"; printf '%s\n' "$leftover" | sed 's/^/         /'; rc=1; fi

    sel_l=$(waydroid shell -- sh -c 'grep -rl lineage /system/etc/selinux /system_ext/etc/selinux /vendor/etc/selinux 2>/dev/null' \
              | tr -d '\r' | grep -v precompiled_sepolicy || true)
    sel_s=$(waydroid shell -- sh -c 'grep -rlw su /system/etc/selinux /system_ext/etc/selinux /vendor/etc/selinux 2>/dev/null' \
              | tr -d '\r' | grep -vE 'precompiled_sepolicy|plat_file_contexts' || true)
    if [ -z "$sel_l$sel_s" ]; then ok "SELinux: no 'lineage' or 'su' left (except the precompiled binary and the /system/xbin/su path)"
    else bad "SELinux leftovers:"; printf '%s\n%s\n' "$sel_l" "$sel_s" | sed '/^$/d; s/^/         /'; rc=1; fi
  else
    bad "container is not running, cannot check props (start it with: waydroid session start)"; rc=1
  fi

  [ "$rc" -eq 0 ] && info "All good" || info "Pending items, run the script without arguments"
  return "$rc"
}

if [ "$MODE" = verify ]; then
  verify && exit 0 || exit 1
fi

for c in perl sed mount find xargs; do
  command -v "$c" >/dev/null || { echo "Missing command: $c" >&2; exit 1; }
done
[ -f "$CFG" ] || { echo "$CFG not found" >&2; exit 1; }

IMG=$(awk -F' *= *' '/^images_path/ {print $2; exit}' "$CFG" || true)
IMG=${IMG:-$WD/images}
EXTRA=/etc/waydroid-extra/images

pick_img() {
  if [ -n "${WD_IMAGES:-}" ] && [ -f "$WD_IMAGES/$1" ]; then echo "$WD_IMAGES/$1"
  elif [ -f "$EXTRA/$1" ]; then echo "$EXTRA/$1"
  else echo "$IMG/$1"; fi
}
SYS_IMG=$(pick_img system.img)
VEN_IMG=$(pick_img vendor.img)
[ -f "$SYS_IMG" ] && [ -f "$VEN_IMG" ] || { echo "Cannot find system.img/vendor.img ($SYS_IMG / $VEN_IMG)" >&2; exit 1; }
info "Images: $SYS_IMG | $VEN_IMG"

TMP=$(mktemp -d /tmp/wd-stealth.XXXXXX)
SYS=$TMP/sys
VEN=$TMP/ven
mkdir -p "$SYS" "$VEN"

cleanup() {
  mountpoint -q "$SYS" 2>/dev/null && umount "$SYS" 2>/dev/null || true
  mountpoint -q "$VEN" 2>/dev/null && umount "$VEN" 2>/dev/null || true
  rmdir "$SYS" "$VEN" "$TMP" 2>/dev/null || true
}
trap cleanup EXIT

info "Stopping Waydroid"
run_as_user waydroid session stop >/dev/null 2>&1 || true
waydroid container stop >/dev/null 2>&1 || true
for m in "$WD/rootfs/vendor/waydroid.prop" "$WD/rootfs/vendor" "$WD/rootfs"; do
  while mountpoint -q "$m" 2>/dev/null; do umount "$m" 2>/dev/null || break; done
done

if [ "$BACKUP" = 1 ] && [ -d "$OV" ]; then
  info "Backing up overlay_rw to overlay_rw.bak-stealth"
  rm -rf "$WD/overlay_rw.bak-stealth"
  cp -a "$OV" "$WD/overlay_rw.bak-stealth" 2>/dev/null || echo "  (warning: the backup reported warnings)"
fi

info "Mounting images read-only"
mount -o ro,loop "$SYS_IMG" "$SYS"
mount -o ro,loop "$VEN_IMG" "$VEN"

mkdir -p "$OV/system" "$OV/vendor"

if [ "$INPLACE" = 0 ] && [ -f "$STATE" ]; then
  while IFS= read -r p; do [ -n "$p" ] && rm -f -- "$p"; done < "$STATE"
fi
: > "$STATE"

STAGED=
stage() {
  local f=$1 root=$2 sub=$3 dst
  dst="$OV/$sub/${f#"$root"/}"
  mkdir -p "$(dirname "$dst")"
  if [ "$INPLACE" = 0 ] || [ ! -e "$dst" ]; then cp -p -- "$f" "$dst"; fi
  echo "$dst" >> "$STATE"
  STAGED=$dst
}

patch_selinux() {
  local f=$1 base; base=$(basename "$f")
  case "$base" in
    *.cil)
      perl -pi -e 's/\bsu\b/dn/g; s/\bsu_/dn_/g; s/lineage/android/g' "$f" ;;
    vendor_*_contexts|system_ext_*_contexts)
      perl -pi -e 's/lineage/android/g; s/(u:object_r:)su(_[^\s:]*)?:/$1dn$2:/; s/((?:domain|type)=)su\b/$1dn/' "$f" ;;
    plat_keystore2_key_contexts)
      perl -pi -e 's/\bsu_key\b/dn_key/g; s/\bsu domain\b/dn domain/g; 1 while s/(u:object_r:[^\s:]*)lineage/$1android/' "$f" ;;
    *)
      perl -pi -e '1 while s/(u:object_r:[^\s:]*)lineage/$1android/; s/(u:object_r:)su(_[^\s:]*)?:/$1dn$2:/; s/((?:domain|type)=)su\b/$1dn/' "$f" ;;
  esac
}

patch_props() {
  sed -i -E \
    -e 's/(dev|test)-keys/release-keys/g' \
    -e 's/\buserdebug\b/user/g' \
    -e 's/^(ro\.([a-z_]+\.)?build\.type)=.*/\1=user/' \
    -e 's/^(ro\.([a-z_]+\.)?build\.tags)=.*/\1=release-keys/' \
    -e 's/^ro\.debuggable=.*/ro.debuggable=0/' \
    -e 's/(=|\/|-)lineage_waydroid/\1aosp_waydroid/g' \
    "$1"
}

info "Patching SELinux files and props"
for pair in "$SYS:system" "$VEN:vendor"; do
  root=${pair%%:*}
  sub=${pair##*:}

  while IFS= read -r -d '' f; do
    stage "$f" "$root" "$sub"
    patch_selinux "$STAGED"
    echo "  selinux  ${STAGED#"$OV"/}"
  done < <(find "$root" \( -name '*.cil' -o -name '*_contexts' \) -type f -print0 \
             | xargs -0 -r grep -IlZE '\bsu\b|\bsu_|lineage' || true)

  while IFS= read -r -d '' f; do
    stage "$f" "$root" "$sub"
    patch_props "$STAGED"
    echo "  props    ${STAGED#"$OV"/}"
  done < <(grep -rIlZE 'dev-keys|test-keys|userdebug|ro\.debuggable=1|lineage_waydroid' --include='*.prop' "$root" || true)
done

if [ "$WHITEOUT" = 1 ]; then
  info "Hiding precompiled_sepolicy (whiteout)"
  p=$OV/vendor/etc/selinux/precompiled_sepolicy
  mkdir -p "$(dirname "$p")"
  rm -f -- "$p"
  mknod "$p" c 0 0
  echo "$p" >> "$STATE"
fi

info "Resetting overlay state (avoids ESTALE)"
rm -rf "$OVW"
mkdir -p "$OVW/system" "$OVW/vendor"
if command -v setfattr >/dev/null; then
  for d in system vendor; do
    setfattr -x trusted.overlay.origin "$OV/$d" 2>/dev/null || true
  done
else
  echo "  (warning: setfattr is missing, install the attr package if the overlay fails with a stale file handle error)"
fi

info "Enabling mount_overlays"
if grep -q '^mount_overlays' "$CFG"; then
  sed -i 's/^mount_overlays *=.*/mount_overlays = True/' "$CFG"
else
  sed -i '/^\[waydroid\]/a mount_overlays = True' "$CFG"
fi

LXC_CFG=$WD/lxc/waydroid/config
if [ -f "$LXC_CFG" ] && lxc-info -P "$WD/lxc" -n waydroid -sH 2>&1 | grep -q 'Built without AppArmor'; then
  info "LXC has no AppArmor support: removing lxc.apparmor.profile from the config"
  sed -i -E '/^lxc\.(apparmor\.profile|aa_profile)/d' "$LXC_CFG"
fi

cleanup
info "Restarting waydroid-container"
systemctl restart waydroid-container

cat <<EOT

Done. Next:
  waydroid session start
  sudo $0 verify
EOT
