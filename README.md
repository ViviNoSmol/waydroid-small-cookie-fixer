## A Small script for fixing certain Cookie-Related games on Waydroid
As the title and the readme says, its a small but powerful script that should fix these "Cookie" games that people tend to talk a lot *wink* *wink*
# As a little explanation into how this works;
Some Android games like Cookies won't run on Waydroid because they read the SELinux policy files and the build props, and see things like `lineage`, `su` and `test-keys`. 
I recreated a fix that the user [@TrixallTR](https://www.github.com/TrixallTR) did on this [issue comment](https://github.com/waydroid/waydroid/issues/2381#issuecomment-5932869653)
These are the things the script does:
- renaming `su` to `dn` and `lineage` to `android` across the SELinux policy files (`system_ext_sepolicy.cil`, `plat_sepolicy.cil`, `plat_pub_versioned.cil`, plus every other `.cil` and `*_contexts` file that mentions them, like `system_ext_service_contexts` and `vendor_hwservice_contexts`)
- putting the modified files into `overlay_rw`, so the original images stay untouched
- replacing `dev-keys`/`test-keys` with `release-keys`, `userdebug` with `user`, setting `ro.debuggable=0` and replacing `lineage_waydroid` with `aosp_waydroid` in the build props
The script does all of this on every start, also it fixes some problems that could happend along the way, like the overlay failing with a stale file handle error, `mount_overlays` turning itself off, and LXC refusing to start because of `lxc.apparmor.profile` on systems without AppArmor. (In my case im using Fedora)
## Usage

```bash
git clone https://github.com/ViviNoSmol/waydroid-small-cookie-fixer.git
chmod +x waydroid-stealth.sh && sudo ./waydroid-stealth.sh
waydroid session start
sudo ./waydroid-stealth.sh verify
```
`verify` only checks the current state (overlay mounted, props, leftover strings) and exits with 1 if something is missing.
Run it again after `waydroid upgrade`, after replacing the images, or if Waydroid stops starting.
Options/Test options:
- `--in-place` patches files already in `overlay_rw` instead of recopying them from the images
- `--no-backup` skips the `overlay_rw` backup
- `--whiteout-precompiled` hides `/vendor/etc/selinux/precompiled_sepolicy`
## Requirements

A working Waydroid install on a systemd distro. Everything else the script uses (`bash`, `sed`, `grep`, `find`, `xargs`, `awk`, `mount`, `lxc`, `systemctl`) ships with a normal install or comes with Pure Vanilla Waydroid (pun-inteded), except possibly `perl` and `setfattr` (the `attr` package, optional but recommended: it fixes the overlay stale file handle error).
```bash
# Arch / CachyOS / Manjaro
sudo pacman -S --needed perl attr

# Debian / Ubuntu
sudo apt install perl attr

# Fedora / Nobara
sudo dnf install perl attr

# openSUSE
sudo zypper install perl attr
```
On non-systemd distros you will need to restart `waydroid-container` yourself after running the script.

# IMPORTANT NOTES!
- Usually, Cookie's Devs don't care a lot about this unless you cheat on your games (please do not) and no one got banned for this, but still, I need to say, i'm NOT responsible for what happens to your account, or if you end up using this script for others games, I don't wanna explicitly mention the game due to obvious reason, but you can still share the script, huge thanks to [@TrixallTR](https://www.github.com/TrixallTR) for finding this! 
- `ro.lineage.*` props and the binary `precompiled_sepolicy` are left alone on purpose. The first are used by the LineageOS framework, and the second is not loaded when SELinux is disabled in the guest.
- Not every game checks the same things, so this is not guaranteed to work for everything. Brawl Stars will NOT work with this for example. And I didn't test with games with more agressive anti-cheat, Cookie's Devs just put mostly an anti-SU and anti-lineageos online check.
