# Parallels Linux Agent VM

This runbook creates the Ubuntu desktop VM used for Linux development, computer-use automation, and Linux-only
conformance checks. It is written for another agent to execute on a new Apple Silicon Mac without relying on the
state of the current machine.

The tested baseline is:

| Setting | Verified baseline (2026-08-12) |
|---|---|
| Host | Apple Silicon, macOS 26.6, Parallels Desktop Pro 26.4.1 (57516) |
| Guest | Ubuntu Desktop 24.04.4 LTS ARM64, Ubuntu generic kernel 6.8.0-137 |
| Desktop | GNOME on Wayland with automatic login; Parallels 3D acceleration disabled |
| VM resources | 4 vCPU, 8 GB RAM, 64 GB expanding disk |
| Guest access | Parallels Tools 26.4.1 (57516) plus key-only SSH as the desktop user |
| Computer use | Cua Driver 0.19.3 plus its WinRects GNOME helper as a desktop-user systemd service |
| Linux conformance | Docker Engine 29.7.2 ARM64; `dartclaw-test` UID 1201; Dart SDK at `/opt/dart-sdk`; `claude` + `codex` CLIs in `/usr/local/bin` |
| Host integration | Shared folders, profile, clipboard, cloud, SmartMount, camera, and location disabled |

This is a disposable development VM, not a production security boundary. Automatic login deliberately trades local
login security for unattended desktop availability. Do not store long-lived production credentials in the VM or its
snapshots.

Treat a newer Parallels major version, Ubuntu release, Cua Driver version, or Docker Engine version as an upgrade.
Re-run every acceptance check before updating this matrix or the final snapshot.

Do not move this VM to Ubuntu's HWE kernel track without first checking Parallels' published kernel support. Desktop
26 currently supports Linux guest kernels 5.10 through 6.13; Ubuntu 24.04.4's HWE kernel 7.0 caused broken dynamic
resolution, partial frames, and persistent black frames in this baseline. GNOME on Xorg reproduced the resize failure
with 3D both enabled and disabled. Wayland with 3D enabled still lost most of Parallels' framebuffer even though Cua's
compositor capture was complete; Wayland with 3D disabled produced stable complete frames. Keep the generic 6.8
kernel, Wayland, and 3D-off combination unless a complete cold-boot graphics and computer-use validation proves a
replacement.

## 1. Choose Local Values

Install Parallels Desktop Pro or Business and Homebrew first. Then open a dedicated Bash shell, change the checkout
path and local values, and keep that shell open for the remaining host commands:

```bash
set -euo pipefail

PROJECT_ROOT='/absolute/path/to/dartclaw-public'
cd "$(git -C "$PROJECT_ROOT" rev-parse --show-toplevel)"
mkdir -p .agent_temp

for required_command in prlctl jq rg ssh scp git; do
  command -v "$required_command" >/dev/null || {
    printf 'Missing host command: %s\n' "$required_command" >&2
    exit 1
  }
done
prlctl --version | rg -q '^prlctl version 26\.'

VM_NAME='Ubuntu 24'
GUEST_USER='parallels'
CPU_COUNT=4
MEMORY_MB=8192
```

Install missing `jq` or `rg` commands with `brew install jq ripgrep`. `prlctl` comes from Parallels Desktop; macOS
provides SSH and SCP. The version assertion deliberately stops on an unverified Parallels major version.

Do not copy a password into a script, shell history, repository file, or snapshot description. The password is needed
only for interactive guest recovery; normal agent access uses Parallels Tools or SSH keys.

## 2. Install Ubuntu and Create a Recovery Point

In Parallels, create an Ubuntu 24.04 ARM64 desktop VM, complete the installer, log in once, finish GNOME's first-run
flow, and leave the desktop session running. Use the username chosen above.

Verify the VM name and record its initial state:

```bash
set -euo pipefail
prlctl list -a
prlctl status "$VM_NAME"
prlctl snapshot "$VM_NAME" --name "before-agent-setup-$(date +%Y%m%d-%H%M%S)"
```

The snapshot records the VM's current power state; it does not need a guest-readiness probe.

## 3. Install Parallels Tools

The VM must be running:

```bash
set -euo pipefail
prlctl installtools "$VM_NAME"
```

This initiates or mounts the Parallels Tools installer. Complete any installer shown inside Ubuntu and reboot if
requested. Do not use `apt install parallels-tools` on a stock Ubuntu guest – that package is not in Ubuntu's default
repository.

Verify both the Tools state and credential-free root execution:

```bash
set -euo pipefail
prlctl list -i "$VM_NAME" | rg -q '^GuestTools: state=installed '
prlctl exec "$VM_NAME" /usr/bin/id | rg -q '^uid=0\(root\)'
```

Both assertions must pass. Stop here if either does not.

Record the resolved VM identity and verify the guest and disk before any system mutation:

```bash
set -euo pipefail
VM_UUID="$(prlctl list -f --json "$VM_NAME" | jq -er '.[0].uuid')"
printf 'VM UUID: %s\n' "$VM_UUID"
prlctl list -i "$VM_NAME" | rg -q "hdd0 .*type='expanded' 65536Mb"
prlctl exec "$VM_NAME" /bin/bash -s <<'GUEST'
set -euo pipefail
. /etc/os-release
test "$ID" = ubuntu
test "$VERSION_ID" = 24.04
test "$(dpkg --print-architecture)" = arm64
test -f /etc/gdm3/custom.conf
GUEST
```

## 4. Allocate Resources and Limit Host Exposure

Stop the VM before changing CPU or memory:

```bash
set -euo pipefail
prlctl stop "$VM_NAME"
prlctl set "$VM_NAME" --cpus "$CPU_COUNT" --memsize "$MEMORY_MB"
prlctl set "$VM_NAME" --3d-accelerate off
```

Disable ambient host integrations. These settings prevent an unattended guest from automatically reading the Mac's
home directory, clipboard, cloud folders, removable drives, camera, or location:

```bash
set -euo pipefail
prlctl set "$VM_NAME" --shf-host-defined off --shf-host-automount off
prlctl set "$VM_NAME" --shared-profile off
prlctl set "$VM_NAME" \
  --sh-app-host-to-guest off \
  --sh-app-guest-to-host off \
  --show-guest-notifications off
prlctl set "$VM_NAME" --shared-clipboard off --shared-cloud off
prlctl set "$VM_NAME" --smart-mount off \
  --smart-mount-removable-drives off \
  --smart-mount-dvd-drives off \
  --smart-mount-network-shares off
prlctl set "$VM_NAME" --auto-share-camera off --auto-share-smart-card off
prlctl set "$VM_NAME" --share-host-location off --sync-vm-hostname off
prlctl set "$VM_NAME" --autostart off --autostop shutdown --on-window-close keep-running
prlctl start "$VM_NAME"

VM_INTEGRATION_INFO="$(prlctl list -i "$VM_NAME")"
printf '%s\n' "$VM_INTEGRATION_INFO" | grep -Eq '^  video .*3d-acceleration=off '
for expected_line in \
  '  Automatic sharing cameras: off' \
  '  Automatic sharing smart cards: off' \
  'Host Shared Folders: (-)' \
  'Host defined sharing: Off' \
  'Shared Profile: (-)' \
  '  Host-to-guest apps sharing: off' \
  '  Guest-to-host apps sharing: off' \
  'SmartMount: (-)' \
  '  Shared clipboard mode: off' \
  '  Shared cloud: off' \
  '  VM hostname synchronization: off' \
  '  Share host location: off'; do
  printf '%s\n' "$VM_INTEGRATION_INFO" | grep -Fxq "$expected_line"
done
```

`keep-running` lets agents continue when the Parallels window closes. `autostop shutdown` asks the guest to shut down
when the host stops Parallels.

## 5. Configure Ubuntu

Create `.agent_temp/configure-parallels-linux-guest.sh` on the host with the following content. The script is specific
to Ubuntu Desktop 24.04 and requires the desktop user to be logged in so its GNOME settings bus exists.

```bash
#!/usr/bin/env bash

set -euo pipefail

guest_user="${1:?guest username required}"
guest_home="$(getent passwd "$guest_user" | cut -d: -f6)"
guest_uid="$(id -u "$guest_user")"
guest_runtime="/run/user/$guest_uid"
guest_bus="$guest_runtime/bus"

if [[ -z "$guest_home" || ! -d "$guest_home" ]]; then
  printf 'Guest user not found: %s\n' "$guest_user" >&2
  exit 1
fi
if [[ ! -S "$guest_bus" ]]; then
  printf 'No desktop session bus for %s; log in to GNOME and retry\n' "$guest_user" >&2
  exit 1
fi

export DEBIAN_FRONTEND=noninteractive

apt-get update
apt-get install -y --no-install-recommends \
  at-spi2-core \
  build-essential \
  ca-certificates \
  curl \
  dbus-x11 \
  git \
  jq \
  libxi6 \
  openssh-server \
  pipx \
  python3-pip \
  python3-venv \
  ripgrep \
  rsync \
  xdotool
apt-get full-upgrade -y

# Ubuntu 24.04.4 may select an HWE kernel newer than Parallels supports. Move
# to the continuously supported Ubuntu 24.04 generic (6.8) track instead.
apt-get install -y linux-generic
mapfile -t hwe_meta_packages < <(
  dpkg-query -W -f='${binary:Package}\t${db:Status-Abbrev}\n' 'linux-*' 2>/dev/null |
    awk '$2 == "ii" && $1 ~ /^linux-.*-hwe-24\.04(:[^[:space:]]+)?$/ {print $1}'
)
if (( ${#hwe_meta_packages[@]} > 0 )); then
  printf 'Purging HWE kernel-track packages:\n'
  printf '  %s\n' "${hwe_meta_packages[@]}"
  apt-get purge -y "${hwe_meta_packages[@]}"
fi
generic_kernel="$(
  find /boot -maxdepth 1 -type f -name 'vmlinuz-6.8.0-*-generic' -printf '%f\n' |
    sed 's/^vmlinuz-//' |
    sort -V |
    tail -n 1
)"
test -n "$generic_kernel"
install -d -m 0755 /etc/default/grub.d
printf 'GRUB_DEFAULT="Advanced options for Ubuntu>Ubuntu, with Linux %s"\n' \
  "$generic_kernel" > /etc/default/grub.d/99-parallels-supported-kernel.cfg
update-grub

gdm_config=/etc/gdm3/custom.conf
if [[ ! -e "${gdm_config}.before-agent-setup" ]]; then
  cp -a "$gdm_config" "${gdm_config}.before-agent-setup"
fi
sed -i -E \
  -e 's/^[#[:space:]]*WaylandEnable=.*/WaylandEnable=true/' \
  -e 's/^[#[:space:]]*AutomaticLoginEnable[[:space:]]*=.*/AutomaticLoginEnable=true/' \
  -e "s/^[#[:space:]]*AutomaticLogin[[:space:]]*=.*/AutomaticLogin=${guest_user}/" \
  "$gdm_config"
grep -Fxq 'WaylandEnable=true' "$gdm_config"
grep -Fxq 'AutomaticLoginEnable=true' "$gdm_config"
grep -Fxq "AutomaticLogin=${guest_user}" "$gdm_config"

install -d -m 0755 /etc/ssh/sshd_config.d
cat > /etc/ssh/sshd_config.d/00-agent-vm.conf <<EOF
PermitRootLogin no
PubkeyAuthentication yes
PasswordAuthentication no
KbdInteractiveAuthentication no
AllowUsers ${guest_user}
EOF
chmod 0600 /etc/ssh/sshd_config.d/00-agent-vm.conf

install -d -o "$guest_user" -g "$guest_user" -m 0700 "$guest_home/.ssh"
touch "$guest_home/.ssh/authorized_keys"
chown "$guest_user:$guest_user" "$guest_home/.ssh/authorized_keys"
chmod 0600 "$guest_home/.ssh/authorized_keys"

/usr/sbin/sshd -t
systemctl enable --now ssh.service
systemctl mask sleep.target suspend.target hibernate.target hybrid-sleep.target

user_env=(
  env
  HOME="$guest_home"
  XDG_RUNTIME_DIR="$guest_runtime"
  DBUS_SESSION_BUS_ADDRESS="unix:path=$guest_bus"
)
runuser -u "$guest_user" -- "${user_env[@]}" \
  gsettings set org.gnome.desktop.interface toolkit-accessibility true
runuser -u "$guest_user" -- "${user_env[@]}" \
  gsettings set org.gnome.desktop.session idle-delay 'uint32 0'
runuser -u "$guest_user" -- "${user_env[@]}" \
  gsettings set org.gnome.desktop.screensaver lock-enabled false
runuser -u "$guest_user" -- "${user_env[@]}" \
  gsettings set org.gnome.desktop.lockdown disable-lock-screen true
runuser -u "$guest_user" -- "${user_env[@]}" \
  gsettings set org.gnome.settings-daemon.plugins.power sleep-inactive-ac-type 'nothing'
runuser -u "$guest_user" -- "${user_env[@]}" \
  gsettings set org.gnome.settings-daemon.plugins.power sleep-inactive-battery-type 'nothing'

printf 'Guest baseline configured for %s\n' "$guest_user"
```

Transfer it through a direct `tee` process, not a nested `prlctl exec ... sh -c ...` command. Parallels flattens
complex guest shell arguments, which can corrupt quoting, JSON, and exit status.

```bash
set -euo pipefail
prlctl exec "$VM_NAME" /usr/bin/install -d -m 0700 /root/agent-vm-setup
prlctl exec "$VM_NAME" /usr/bin/tee /root/agent-vm-setup/configure.sh \
  < .agent_temp/configure-parallels-linux-guest.sh >/dev/null
prlctl exec "$VM_NAME" /bin/chmod 0700 /root/agent-vm-setup/configure.sh
prlctl exec "$VM_NAME" /bin/bash /root/agent-vm-setup/configure.sh "$GUEST_USER"
prlctl exec "$VM_NAME" /bin/rm -f /root/agent-vm-setup/configure.sh
prlctl exec "$VM_NAME" /bin/rmdir /root/agent-vm-setup
```

## 6. Enable Key-Only SSH

Parallels can synchronize the Mac user's public SSH keys into the guest. It does not copy private keys. Preserve an
existing private key when its public half is missing:

```bash
set -euo pipefail
SSH_PRIVATE_KEY="$HOME/.ssh/id_ed25519"
SSH_PUBLIC_KEY="${SSH_PRIVATE_KEY}.pub"
if [[ -f "$SSH_PRIVATE_KEY" && ! -f "$SSH_PUBLIC_KEY" ]]; then
  ssh-keygen -y -f "$SSH_PRIVATE_KEY" > "$SSH_PUBLIC_KEY"
  chmod 0644 "$SSH_PUBLIC_KEY"
elif [[ ! -f "$SSH_PRIVATE_KEY" && -f "$SSH_PUBLIC_KEY" ]]; then
  printf 'Public key exists without its private key: %s\n' "$SSH_PUBLIC_KEY" >&2
  exit 1
elif [[ ! -f "$SSH_PRIVATE_KEY" ]]; then
  ssh-keygen -t ed25519 -f "$SSH_PRIVATE_KEY"
fi
prlctl set "$VM_NAME" --sync-ssh-ids on
```

Resolve the current shared-network IP rather than storing it in a script:

```bash
set -euo pipefail
GUEST_IP="$(prlctl list -f --json "$VM_NAME" | jq -r '.[0].ip_configured')"
test -n "$GUEST_IP" && test "$GUEST_IP" != '-'
GUEST_TARGET="$GUEST_USER@$GUEST_IP"
printf 'Guest target: %s\n' "$GUEST_TARGET"
test "$(ssh -o BatchMode=yes -o StrictHostKeyChecking=accept-new "$GUEST_TARGET" id -un)" = "$GUEST_USER"
```

The SSH test must report the selected desktop username. Verify that password and root SSH are disabled:

```bash
set -euo pipefail
SSHD_EFFECTIVE="$(prlctl exec "$VM_NAME" /usr/sbin/sshd -T)"
for expected_line in \
  'permitrootlogin no' \
  'pubkeyauthentication yes' \
  'passwordauthentication no' \
  'kbdinteractiveauthentication no' \
  "allowusers $GUEST_USER"; do
  printf '%s\n' "$SSHD_EFFECTIVE" | grep -Fxq "$expected_line"
done
```

Expected values are `permitrootlogin no`, `pubkeyauthentication yes`, `passwordauthentication no`,
`kbdinteractiveauthentication no`, and the selected `allowusers` value.

For a shared Mac or tighter key management, leave `--sync-ssh-ids off` and install one purpose-specific public key in
`authorized_keys` instead.

## 7. Install Cua Driver

Install the tested Cua Driver release as the desktop user, never root. This block uses the release's immutable ARM64
archive and its published SHA-256 instead of executing a mutable remote installer:

```bash
set -euo pipefail
ssh "$GUEST_TARGET" /bin/bash -s <<'GUEST'
set -euo pipefail

cua_version='0.19.3'
cua_target='aarch64-unknown-linux-gnu'
cua_archive="cua-driver-rs-${cua_version}-linux-arm64-binary.tar.gz"
cua_sha256='68c4bc4455250384b6e0fc6ab99ed2be5de8944de4ecea00fc3f4a88d8f4d460'
cua_url="https://github.com/trycua/cua/releases/download/cua-driver-rs-v${cua_version}/${cua_archive}"
temporary_directory="$(mktemp -d)"
trap 'rm -rf "$temporary_directory"' EXIT

curl -fsSL "$cua_url" -o "$temporary_directory/$cua_archive"
printf '%s  %s\n' "$cua_sha256" "$temporary_directory/$cua_archive" | sha256sum -c -

release_name="${cua_version}-${cua_target}"
release_directory="$HOME/.cua-driver/packages/releases/$release_name"
install -d -m 0755 "$release_directory" "$HOME/.local/bin"
tar -xzf "$temporary_directory/$cua_archive" -C "$release_directory"
test -x "$release_directory/cua-driver"

ln -sfn "releases/$release_name" "$HOME/.cua-driver/packages/current.next"
mv -Tf "$HOME/.cua-driver/packages/current.next" "$HOME/.cua-driver/packages/current"
ln -sfn "$HOME/.cua-driver/packages/current/cua-driver" "$HOME/.local/bin/cua-driver"

CUA_DRIVER_RS_TELEMETRY_ENABLED=0 "$HOME/.local/bin/cua-driver" telemetry disable
test "$("$HOME/.local/bin/cua-driver" --version)" = 'cua-driver 0.19.3'
"$HOME/.local/bin/cua-driver" telemetry status | grep -q '^Telemetry: disabled'
GUEST
```

Telemetry disablement persists across upgrades. It retains the local pseudonymous installation ID; run
`cua-driver telemetry reset-id` inside the guest only if that ID should also be removed.

Create `.agent_temp/cua-driver.service` on the host:

```ini
[Unit]
Description=Cua Driver desktop automation daemon
After=graphical-session.target
PartOf=graphical-session.target

[Service]
Type=simple
Environment=CUA_DRIVER_RS_ENABLE_WAYLAND=1
ExecStart=%h/.local/bin/cua-driver serve
Restart=on-failure
RestartSec=2

[Install]
WantedBy=graphical-session.target
```

Install and start the user service:

```bash
set -euo pipefail
ssh "$GUEST_TARGET" 'mkdir -p ~/.config/systemd/user'
scp .agent_temp/cua-driver.service "$GUEST_TARGET:.config/systemd/user/cua-driver.service"
ssh "$GUEST_TARGET" \
  'systemctl --user daemon-reload && systemctl --user enable --now cua-driver.service'
ssh "$GUEST_TARGET" 'systemctl --user status cua-driver.service --no-pager'
test "$(ssh "$GUEST_TARGET" 'systemctl --user is-active cua-driver.service')" = active
```

Install Cua's bundled GNOME Wayland helper before rebooting. It supplies reliable window bounds, capture, cursor,
and activation metadata to Cua:

```bash
set -euo pipefail
ssh "$GUEST_TARGET" '~/.cua-driver/packages/current/wayland-helper/install.sh'
ssh "$GUEST_TARGET" 'gnome-extensions info winrects@cua | grep -Fxq "  Enabled: Yes"'
```

The service is tied to the graphical session because computer use needs its display, user D-Bus, and AT-SPI bus.
Do not replace it with a root service. Login lingering is unnecessary with automatic login and does not create a
usable desktop by itself.

Cua's hosted install page may still describe Linux as x86_64-only, but release 0.19.3 publishes the verified Linux
ARM64 archive used above. To upgrade, update the version and checksum from the official release, rebuild the baseline,
and rerun this guide's complete verification before changing the tested matrix.

References: [Cua installation](https://cua.ai/docs/how-to-guides/driver/install),
[keep-running guide](https://cua.ai/docs/how-to-guides/driver/keep-running), and
[platform support](https://cua.ai/docs/reference/cua-driver/platform-support).

## 8. Reboot and Verify the Complete Path

Restart the VM so the generic kernel, GDM Wayland selection, automatic login, GNOME helper, and user service all take
effect:

```bash
set -euo pipefail
prlctl stop "$VM_NAME"
prlctl start "$VM_NAME"
guest_ready=false
for _ in {1..90}; do
  GUEST_IP="$(prlctl list -f --json "$VM_NAME" | jq -r '.[0].ip_configured')"
  if [[ -n "$GUEST_IP" && "$GUEST_IP" != '-' ]]; then
    GUEST_TARGET="$GUEST_USER@$GUEST_IP"
    if ssh -o BatchMode=yes -o ConnectTimeout=2 "$GUEST_TARGET" true 2>/dev/null; then
      guest_ready=true
      break
    fi
  fi
  sleep 2
done
if [[ "$guest_ready" != true ]]; then
  prlctl status "$VM_NAME" >&2
  prlctl list -f --json "$VM_NAME" >&2
  printf 'Guest SSH did not become ready after 90 attempts\n' >&2
  exit 1
fi

desktop_ready=false
for _ in {1..60}; do
  if CUA_HEALTH="$(
    ssh "$GUEST_TARGET" '~/.local/bin/cua-driver call health_report "{}"' 2>/dev/null
  )" && printf '%s\n' "$CUA_HEALTH" | jq -e '.overall == "ok"' >/dev/null; then
    desktop_ready=true
    break
  fi
  sleep 2
done
if [[ "$desktop_ready" != true ]]; then
  ssh "$GUEST_TARGET" 'systemctl --user status cua-driver.service --no-pager' >&2 || true
  ssh "$GUEST_TARGET" 'systemctl --user show-environment' >&2 || true
  printf 'Desktop and Cua Driver did not become ready after 60 attempts\n' >&2
  exit 1
fi
```

Verify the operating system and desktop session:

```bash
set -euo pipefail
GUEST_SESSION_ENV="$(ssh "$GUEST_TARGET" 'systemctl --user show-environment')"
printf '%s\n' "$GUEST_SESSION_ENV" | grep -Eq '^DISPLAY=.+'
printf '%s\n' "$GUEST_SESSION_ENV" | grep -Eq '^WAYLAND_DISPLAY=.+'
printf '%s\n' "$GUEST_SESSION_ENV" | grep -Fxq 'XDG_SESSION_TYPE=wayland'
ssh "$GUEST_TARGET" /bin/bash -s <<'GUEST'
set -euo pipefail
. /etc/os-release
test "$ID" = ubuntu
test "$VERSION_ID" = 24.04
test "$(dpkg --print-architecture)" = arm64
[[ "$(uname -r)" == 6.8.0-*-generic ]]
GUEST
```

After proving that 6.8 booted, remove the old HWE kernel packages and the one-boot GRUB pin. The script derives and
prints an ABI-bounded package set before purging it; it never matches the running 6.8 ABI:

```bash
set -euo pipefail
prlctl exec "$VM_NAME" /bin/bash -s <<'GUEST'
set -euo pipefail
[[ "$(uname -r)" == 6.8.0-*-generic ]]

mapfile -t old_kernel_versions < <(
  find /boot -maxdepth 1 -type f -name 'vmlinuz-*-generic' -printf '%f\n' |
    sed 's/^vmlinuz-//' |
    grep -v '^6\.8\.0-' || true
)
mapfile -t installed_packages < <(
  dpkg-query -W -f='${binary:Package}\t${db:Status-Abbrev}\n' 'linux-*' 2>/dev/null |
    awk '$2 == "ii" {print $1}'
)
old_kernel_packages=()
for kernel_version in "${old_kernel_versions[@]}"; do
  kernel_abi="${kernel_version%-generic}"
  for package in "${installed_packages[@]}"; do
    case "$package" in
      linux-*"$kernel_abi"*)
        old_kernel_packages+=("$package")
        ;;
    esac
  done
done
if (( ${#old_kernel_packages[@]} > 0 )); then
  mapfile -t old_kernel_packages < <(printf '%s\n' "${old_kernel_packages[@]}" | sort -u)
  printf 'Purging old kernel packages:\n'
  printf '  %s\n' "${old_kernel_packages[@]}"
  apt-get purge -y "${old_kernel_packages[@]}"
fi
rm -f /etc/default/grub.d/99-parallels-supported-kernel.cfg
update-grub
if find /boot -maxdepth 1 -type f -name 'vmlinuz-*-generic' -printf '%f\n' | grep -Ev '^vmlinuz-6\.8\.0-'; then
  printf 'A non-6.8 kernel remains in /boot\n' >&2
  exit 1
fi
test -e /boot/vmlinuz-"$(uname -r)"
GUEST
```

`XDG_SESSION_TYPE` must be `wayland`; both `WAYLAND_DISPLAY` and compatibility `DISPLAY` must be set. Then verify Cua
end to end:

```bash
set -euo pipefail
test "$(ssh "$GUEST_TARGET" '~/.local/bin/cua-driver --version')" = 'cua-driver 0.19.3'
ssh "$GUEST_TARGET" '~/.local/bin/cua-driver doctor'
ssh "$GUEST_TARGET" 'gnome-extensions info winrects@cua' | grep -Fxq '  State: ACTIVE'
ssh "$GUEST_TARGET" '~/.local/bin/cua-driver call health_report "{}"' | jq -e '
  .overall == "ok" and
  .driver_version == "0.19.3" and
  ([.checks[] | select(
    .name == "ax_capability" or
    .name == "screen_capture_capability" or
    .name == "wayland_backend"
  )] as $required |
    ($required | length) == 3 and
    ([$required[].name] | unique | length) == 3 and
    all($required[]; .status == "pass"))
'
ssh "$GUEST_TARGET" '~/.local/bin/cua-driver call list_windows "{}"' | \
  jq -e '.windows | type == "array"'
```

`health_report` must return `"overall": "ok"` with passing accessibility and screen-capture checks. Validate the
visible desktop independently from the host:

```bash
set -euo pipefail
prlctl capture "$VM_NAME" --file .agent_temp/parallels-linux-final.png
test -s .agent_temp/parallels-linux-final.png
```

Open the PNG and confirm it shows the logged-in Ubuntu desktop, not GDM, a blank frame, or a lock screen. A setup is
not complete until the resize regression below and a semantic Cua action test have both passed.

With the Parallels VM window visible, resize it repeatedly through at least four materially different shapes: small
landscape, tall portrait, large landscape, then the intended steady-state size. Wait two seconds after each resize,
save a fresh `prlctl capture`, and visually confirm that every frame is complete. This directly covers the resize path
that previously produced partial and persistent black frames; a single static capture does not.

Then use an AT-SPI element token for text entry on Wayland. Do not make raw portal-mediated pointer or key injection
part of unattended acceptance:

```bash
set -euo pipefail
ssh "$GUEST_TARGET" /bin/bash -s <<'GUEST'
set -euo pipefail
CUA="$HOME/.local/bin/cua-driver"
"$CUA" call launch_app '{"name":"gnome-text-editor"}' >/dev/null

editor_window=''
for _ in {1..30}; do
  editor_window="$(
    "$CUA" call list_windows '{}' |
      jq -c '[.windows[] | select(.app_name | ascii_downcase | contains("text editor"))] | last // empty'
  )"
  [[ -n "$editor_window" ]] && break
  sleep 1
done
test -n "$editor_window"

pid="$(printf '%s\n' "$editor_window" | jq -er '.pid')"
window_id="$(printf '%s\n' "$editor_window" | jq -er '.window_id')"
state_payload="$(jq -nc --argjson pid "$pid" --argjson window_id "$window_id" \
  '{pid:$pid, window_id:$window_id}')"
editor_state="$("$CUA" call get_window_state "$state_payload")"
element_token="$(
  printf '%s\n' "$editor_state" |
    jq -er '[.elements[] | select(.role == "text box")] | first | .element_token'
)"
snapshot_id="$(printf '%s\n' "$editor_state" | jq -er '.snapshot_id')"
type_payload="$(jq -nc \
  --argjson pid "$pid" \
  --argjson window_id "$window_id" \
  --arg snapshot_id "$snapshot_id" \
  --arg element_token "$element_token" \
  '{pid:$pid, window_id:$window_id, snapshot_id:$snapshot_id,
    element_token:$element_token, delivery_mode:"foreground", text:"CUA_DRIVER_READY"}')"

"$CUA" call type_text "$type_payload" >/dev/null
for _ in {1..10}; do
  editor_state="$("$CUA" call get_window_state "$state_payload")"
  printf '%s\n' "$editor_state" | jq -e \
    '.tree_markdown | contains("CUA_DRIVER_READY")' >/dev/null && break
  sleep 1
done
printf '%s\n' "$editor_state" | jq -e \
  '.tree_markdown | contains("CUA_DRIVER_READY")' >/dev/null
printf '%s\n' "$editor_state" | jq -er '.screenshot_png_b64' | base64 -d > "$HOME/.cache/cua-driver-ready.png"
test -s "$HOME/.cache/cua-driver-ready.png"
GUEST
scp "$GUEST_TARGET:.cache/cua-driver-ready.png" .agent_temp/cua-driver-ready.png
test -s .agent_temp/cua-driver-ready.png
```

Open `.agent_temp/cua-driver-ready.png` and verify Text Editor visibly contains `CUA_DRIVER_READY`. The structured
action responses alone cannot prove that input reached the window. Close Text Editor and discard the test draft after
the check.

Confirm there are no pending Ubuntu updates and that Parallels Tools survived the kernel update:

```bash
set -euo pipefail
PENDING_UPDATES="$(ssh "$GUEST_TARGET" 'apt list --upgradable 2>/dev/null' | tail -n +2)"
test -z "$PENDING_UPDATES"
VM_INFO="$(prlctl list -i "$VM_NAME")"
printf '%s\n' "$VM_INFO" | rg -q '^State: running$'
printf '%s\n' "$VM_INFO" | rg -q '^GuestTools: state=installed '
printf '%s\n' "$VM_INFO" | rg -q "cpu cpus=${CPU_COUNT} "
printf '%s\n' "$VM_INFO" | rg -q "memory size=${MEMORY_MB}Mb "
printf '%s\n' "$VM_INFO" | rg -q '^  video .*3d-acceleration=off '
printf '%s\n' "$VM_INFO" | rg -q "hdd0 .*type='expanded' 65536Mb"
prlctl exec "$VM_NAME" /bin/systemctl is-active prltoolsd.service
```

## 9. Optional Docker Conformance Profile

Skip this section when the VM is only for desktop/browser work. For DartClaw's real Linux isolation checks, install
Docker Engine from Docker's official Ubuntu repository inside the guest. Ubuntu 24.04 `noble` on ARM64 is supported.

Run these commands in a guest terminal or SSH session:

```bash
set -euo pipefail
. /etc/os-release
test "$VERSION_CODENAME" = noble
test "$(dpkg --print-architecture)" = arm64

sudo apt remove -y \
  docker.io docker-compose docker-compose-v2 docker-doc docker-buildx \
  podman-docker containerd runc
sudo apt update
sudo apt install -y ca-certificates curl
sudo install -m 0755 -d /etc/apt/keyrings
sudo curl -fsSL https://download.docker.com/linux/ubuntu/gpg \
  -o /etc/apt/keyrings/docker.asc
sudo chmod a+r /etc/apt/keyrings/docker.asc

sudo tee /etc/apt/sources.list.d/docker.sources >/dev/null <<EOF
Types: deb
URIs: https://download.docker.com/linux/ubuntu
Suites: noble
Components: stable
Architectures: arm64
Signed-By: /etc/apt/keyrings/docker.asc
EOF

sudo apt update
sudo apt install -y \
  docker-ce docker-ce-cli containerd.io \
  docker-buildx-plugin docker-compose-plugin
sudo usermod -aG docker "$USER"
```

Reboot or log out and back in, then verify:

```bash
set -euo pipefail
docker version
docker run --rm hello-world
```

Membership in the `docker` group grants root-equivalent control of the guest. Use Docker rootless mode instead when
that trust level is inappropriate. See Docker's official
[Ubuntu installation](https://docs.docker.com/engine/install/ubuntu/) and
[Linux post-installation](https://docs.docker.com/engine/install/linux-postinstall/) guides.

Docker Desktop on macOS can hide native Linux UID behavior. To exercise bind mounts as a host UID other than the
container image's typical UID 1000, create a dedicated guest conformance user with an unused non-1000 UID:

```bash
set -euo pipefail
CONFORMANCE_USER='dartclaw-test'
CONFORMANCE_UID=1201
if getent passwd "$CONFORMANCE_UID"; then
  printf 'UID already used\n' >&2
  exit 1
fi
sudo useradd --create-home --uid "$CONFORMANCE_UID" --shell /bin/bash "$CONFORMANCE_USER"
sudo usermod -aG docker "$CONFORMANCE_USER"
```

Clone or copy the test checkout into that user's home, start a login shell with `sudo -iu "$CONFORMANCE_USER"`, and
confirm both conditions before running the Linux conformance suite:

```bash
set -euo pipefail
test "$(id -u)" -ne 1000
docker run --rm hello-world
```

Do not run the conformance checkout from a Parallels shared folder; that reintroduces host filesystem translation and
weakens the proof.

For provider-harness conformance, install the provider CLIs system-wide so both root and the conformance user resolve
them (`prlctl exec` runs with `HOME=/`, so per-user installers land in `/.local` — copy the binary out instead):

```bash
# claude: native installer, then promote the versioned binary
curl -fsSL https://claude.ai/install.sh | bash
sudo install -m 755 "$(readlink -f ~/.local/bin/claude)" /usr/local/bin/claude

# codex: musl release binary from GitHub
arch=aarch64-unknown-linux-musl
url=$(curl -fsSL https://api.github.com/repos/openai/codex/releases/latest \
  | grep -o "https://[^\"]*codex-${arch}.tar.gz" | head -1)
curl -fsSL "$url" | tar -xz -C /tmp && sudo install -m 755 "/tmp/codex-${arch}" /usr/local/bin/codex
```

Note: Docker Engine inside the Linux guest needs no nested virtualization — containers share the guest kernel. Only
Docker Desktop (which boots its own VM) would; do not install it in the guest.

After syncing a checkout onto the VM, open its permissions before running bridge-using suites: a `0700` checkout (the
default for a home-dir rsync) blocks the container's uid-1000 user from traversing to the bind-mounted bridge binary,
failing every gateway/mediated fixture with permission errors that look like bridge defects. On the checkout root run
`chmod 755` on each path component and `chmod -R a+rX build` so the bridge binary and its parents are world-traversable.
Order matters: run the `build` chmod **after** any `build_bridge.sh` invocation — a root-built bridge under `prlctl`
comes out `0700`, and a chmod that ran before the rebuild silently reintroduces the same mass failure.

## 10. Create the Reusable Baseline

Close test applications and remove test screenshots from the guest. Create the final snapshot while the VM is stopped
so the checkpoint is a clean powered-off baseline:

```bash
set -euo pipefail
prlctl stop "$VM_NAME"
prlctl snapshot "$VM_NAME" --name "agent-dev-ready-$(date +%Y%m%d-%H%M%S)"
prlctl snapshot-list "$VM_NAME" --tree
```

Keep the golden VM stopped for cloning. Keep the original pre-setup snapshot until the final baseline has passed at
least one cold-boot test.

## 11. Per-Agent Use

Treat one VM as single-caller. For parallel agents, stop the golden VM and create a separate clone per agent:

```bash
set -euo pipefail
GOLDEN_VM="$VM_NAME"
AGENT_VM='Ubuntu 24 - agent 01'
test "$(prlctl status "$GOLDEN_VM" | awk '{print $NF}')" = stopped
prlctl clone "$GOLDEN_VM" --name "$AGENT_VM"
prlctl start "$AGENT_VM"
```

Resolve each clone's IP dynamically. Full clones copy the guest SSH host keys; local disposable clones therefore share
an identity unless clone provisioning regenerates those keys. Never use that model for mutually untrusted workloads.
If an IP is reused, remove only that stale host entry with `ssh-keygen -R <ip>` after verifying the clone target.

Resetting a snapshot or deleting a clone is destructive. Resolve the exact VM and snapshot IDs with `prlctl list -a`
and `prlctl snapshot-list <vm> --json` before using `snapshot-switch` or `delete`. Do not automate either operation with
an unvalidated name, glob, or broad path.

## Customization

### Resources

- 4 vCPU and 8 GB RAM are a comfortable GNOME/browser baseline on a 48 GB host.
- Use 2 vCPU and 4 GB only for light shell work.
- Increase memory before CPU for browser-heavy agents.
- Leave enough host memory for macOS and every concurrently running clone.

### Repository access

Prefer a guest-native Git clone. It gives Linux-native ownership, paths, and filesystem behavior, which is important
for conformance tests. If a host share is unavoidable, expose one narrow directory and prefer read-only mode:

```bash
set -euo pipefail
REPO_ROOT="$(pwd -P)"
prlctl set "$VM_NAME" --shf-host on
prlctl set "$VM_NAME" --shf-host-add dartclaw-source --path "$REPO_ROOT" --mode ro
```

Do not share the entire Mac home directory with an unattended VM. Remove the share when the task completes:

```bash
set -euo pipefail
prlctl set "$VM_NAME" --shf-host-del dartclaw-source
prlctl set "$VM_NAME" --shf-host off
```

### Rosetta

Keep Rosetta for Linux disabled for ARM64 conformance. Enable `--rosetta-linux on` only for a task that explicitly
requires an x86_64 Linux binary; doing so can hide architecture portability problems.

### Automatic login and desktop locking

Automatic login, disabled locking, and masked sleep are required for unattended screenshot/input loops. For a VM used
only through SSH, keep normal login security instead and omit Cua Driver. Do not mix the two threat models silently.

### Cua permissions and policies

The baseline uses Cua's standard permission mode. Use a reviewed bounded policy when the VM contains data beyond a
disposable workspace. Do not enable unrestricted mode by default.

## Troubleshooting

### `prlctl exec --current-user` fails

Confirm the desktop user is logged in and Parallels Tools are healthy. After a Tools or kernel upgrade, reboot and
verify `prltoolsd.service`. Key-only SSH remains the preferred user-command path because it preserves ordinary shell
semantics.

### Cua reports no display or windows

Check all three conditions:

```bash
set -euo pipefail
ssh "$GUEST_TARGET" 'systemctl --user show-environment' | rg 'DISPLAY|XDG_SESSION_TYPE'
ssh "$GUEST_TARGET" 'systemctl --user status cua-driver.service --no-pager'
ssh "$GUEST_TARGET" 'gnome-extensions info winrects@cua' | rg 'Enabled|State'
ssh "$GUEST_TARGET" '~/.local/bin/cua-driver doctor'
```

The session must be Wayland, WinRects must be active, the service must run as the desktop user, and the user's
D-Bus/AT-SPI bus must be reachable. Cua's raw pointer and key path uses GNOME's Remote Desktop portal and may prompt or
fail without an attended portal session. The unattended baseline therefore accepts semantic AT-SPI actions and browser
automation, not arbitrary coordinate input.

### Desktop is partial, flickers, or turns black

Check the kernel and session before changing graphics acceleration:

```bash
set -euo pipefail
ssh "$GUEST_TARGET" 'uname -r; systemctl --user show-environment | grep "^XDG_SESSION_TYPE="'
prlctl capture "$VM_NAME" --file .agent_temp/parallels-linux-graphics-check.png
```

This baseline requires the Ubuntu generic 6.8 kernel, GNOME Wayland, and Parallels 3D acceleration disabled. Do not
switch back to Xorg: it produced a persistent black-frame failure during repeated Parallels window resizing with both
3D enabled and disabled. Wayland plus VirGL still emitted partial or black Parallels frames while Cua saw a complete
desktop; disabling 3D made repeated Parallels captures complete. Parallels documents Linux kernels 5.10 through 6.13
as supported, warns that newer kernels can cause display and performance problems, and recommends disabling 3D for
Linux GUI problems. Change one variable at a time and cold-boot before comparing the same reproduction.

References: [supported Linux kernels](https://kb.parallels.com/en/129963),
[VirGL on Apple silicon](https://kb.parallels.com/en/128518), and
[Parallels 26 graphics settings](https://docs.parallels.com/landing/pdfm-ug/v26-es-es/guida-utente-di-parallels-desktop-per-mac-26/preferencias-de-parallels-desktop-y-configuracion-de-maquina-virtual/configuracion-de-hardware/configuracion-grafica).

### Screen size changes after reboot

Parallels may select a different valid resolution when its window size changes. Agents must query Cua's current screen
size before coordinate actions rather than caching dimensions from a previous boot.

### SSH host-key warning after cloning

Resolve the clone name and current IP first. Remove only the stale entry for that verified IP, then reconnect with
`StrictHostKeyChecking=accept-new`. A production-quality cloning pipeline should regenerate guest SSH host keys.

## What the Runtime Helper Owns

`dev/tools/parallels_linux.sh` is the runtime lifecycle helper, not the provisioning source of truth. Keep this runbook
authoritative for machine setup and customization. The helper must preserve command arguments and exit status, use a
secure unique guest staging path, avoid changing VM state for host-only capture/snapshot operations, and carry portable
tests before agents depend on it.

Parallels CLI reference: [Parallels Desktop Developer's Guide – command-line utility](https://docs.parallels.com/landing/parallels-desktop-developers-guide/command-line-interface-utility).
Treat the installed Parallels 26 command help (`prlctl help` and `prlctl <action> --help`) as authoritative for local
option semantics.
