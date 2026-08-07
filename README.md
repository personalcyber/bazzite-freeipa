# bazzite-freeipa

A custom [bootc](https://github.com/bootc-dev/bootc) image layered on [Bazzite](https://github.com/ublue-os/bazzite) (Universal Blue) that ships `freeipa-client` and the [Fleet](https://fleetdm.com/) osquery agent (`fleetd`/`orbit`) pre-installed. The image is built and published automatically to GHCR via GitHub Actions and is designed to preserve an existing FreeIPA domain join and Fleet enrollment across `bootc` updates.

Published image: `ghcr.io/personalcyber/bazzite-freeipa:latest`

---

# Switching to This Image

## From an Existing Bazzite or Universal Blue System

If you are already running a bootc-based system (Bazzite, Bluefin, Aurora, etc.), switching requires a single command and a reboot. No reinstall is needed.

```bash
sudo bootc switch ghcr.io/personalcyber/bazzite-freeipa:latest
```

`bootc switch` stages the new image. The switch takes effect on the next reboot.

```bash
systemctl reboot
```

After rebooting, confirm you are on the new image:

```bash
sudo bootc status
```

> [!NOTE]
> If your current system is already joined to a FreeIPA domain, the join state is preserved. See [FreeIPA Join Persistence](#freeipa-join-persistence) below for details on how this works.

## From a Non-bootc Fedora or RPM-based System

A fresh install using an ISO is the recommended path. Download or build an ISO from this repository (see [Building Disk Images](#building-disk-images)) and boot from it. The installer's post-install script automatically switches the new system to `ghcr.io/personalcyber/bazzite-freeipa:latest`.

---

# Setting Up FreeIPA Client

The `freeipa-client`, `sssd`, `oddjob`, and `oddjob-mkhomedir` packages are pre-installed in this image. After switching or installing, join the machine to your FreeIPA domain using `ipa-client-install`.

## Prerequisites

- Network access to your FreeIPA server (DNS must be resolvable)
- A one-time password or admin credentials for enrollment

## Joining the Domain

```bash
sudo ipa-client-install \
    --domain=your.domain.example \
    --server=ipa.your.domain.example \
    --realm=YOUR.DOMAIN.EXAMPLE \
    --mkhomedir \
    --no-ntp
```

Key flags:
- `--mkhomedir` — creates home directories on first login via `oddjob-mkhomedir`, which is enabled in this image
- `--no-ntp` — recommended if NTP is already managed by another service (e.g., `systemd-timesyncd` or Chrony on your network)
- `--unattended` — add this flag for scripted/automated enrollment together with `--password`

`ipa-client-install` will write and own `/etc/ipa/default.conf`, `/etc/sssd/sssd.conf`, `/etc/krb5.conf`, and related files. These are treated as local files by bootc and will not be overwritten by image updates.

After the join completes, verify that `sssd` is running:

```bash
systemctl status sssd
```

And test that a domain user can be resolved:

```bash
id <domain-username>
```

## Leaving the Domain

To remove the machine from FreeIPA cleanly:

```bash
sudo ipa-client-install --uninstall
```

---

# Setting Up the Fleet Agent

The Fleet osquery agent (`fleetd`, i.e. `orbit` + `osqueryd`) is pre-installed but ships **unconfigured** — the image is built without a Fleet server URL or enrollment secret baked in, so it never phones home until you point it at your own Fleet instance. See Fleet's [agent configuration docs](https://fleetdm.com/docs/configuration/agent-configuration) for the full set of options.

## Enrolling the Host

Create `/etc/default/orbit` with your Fleet server details:

```bash
sudo tee /etc/default/orbit > /dev/null <<'EOF'
ORBIT_FLEET_URL=https://fleet.your.domain.example
ORBIT_ENROLL_SECRET=your-enroll-secret
# Or, to keep the secret out of this file, reference a separate file instead:
# ORBIT_ENROLL_SECRET_PATH=/etc/default/orbit-secret
EOF
sudo chmod 0600 /etc/default/orbit
sudo systemctl restart orbit
```

`orbit` is already enabled, so it starts enforcing the new configuration as soon as the service restarts (or at next boot).

Verify enrollment:

```bash
systemctl status orbit
```

The host should then appear in your Fleet server's UI within a few minutes.

## Leaving Fleet

```bash
sudo systemctl stop orbit
sudo rm -f /etc/default/orbit
```

---

# FreeIPA Join Persistence

This image is specifically designed so that an existing domain join survives `bootc` updates. Here is how it works.

When `bootc` applies an update it performs a **three-way merge** of `/etc`:

1. It diffs the old image's `/etc` against the new image's `/etc`.
2. It applies that delta to your local `/etc`.

Files that exist locally but are **not present in the image** are treated as local additions and are never touched. This image deliberately ships the directory skeletons `/etc/ipa/` and `/etc/sssd/conf.d/` but ships **no config file content** inside them. Every file that `ipa-client-install` writes — `sssd.conf`, `default.conf`, `krb5.conf`, etc. — is therefore a local addition that bootc will never overwrite.

Runtime state (`/var/lib/sss/`, `/var/log/sssd/`) lives under `/var`, which bootc never modifies.

**In practice:** after a `bootc update` and reboot, `sssd` comes back up reading the same config it had before the update, and domain authentication continues without any intervention.

### What Could Break a Join

- Manually editing a file that a future image version also ships (currently none, by design)
- Running `ipa-client-install --uninstall` before updating, then expecting the join to survive

---

# Fleet Enrollment Persistence

The same three-way `/etc` merge logic protects Fleet enrollment. `orbit.service` reads its configuration (Fleet server URL, enrollment secret, TLS settings) from `/etc/default/orbit` via an `EnvironmentFile` directive. This image never ships content in that file — the build strips it unconditionally after installing the `fleet-osquery` package — so once you create it locally (see [Setting Up the Fleet Agent](#setting-up-the-fleet-agent)), bootc treats it purely as a local addition and never overwrites it.

**In practice:** after a `bootc update` and reboot, `orbit` comes back up reading the same `/etc/default/orbit` it had before the update, and the host stays enrolled without any intervention.

---

# Changes to the Base Bazzite Image

This image is built on top of `ghcr.io/ublue-os/bazzite-gnome:stable` and makes the following deliberate modifications to support FreeIPA client functionality and ensure join state survives `bootc` updates.

## Packages Added

| Package | Purpose |
|---|---|
| `freeipa-client` | Core FreeIPA client tooling (`ipa-client-install`, `ipa` CLI). Also pulls in `sssd`, `krb5-workstation`, `certmonger`, and other required dependencies. |
| `oddjob` | D-Bus service that allows `sssd` to perform privileged operations (e.g. creating home directories) on behalf of unprivileged processes. |
| `oddjob-mkhomedir` | PAM module and helper that automatically creates a home directory on first login for domain users. |
| `fleet-osquery` (`orbit`) | Fleet's osquery agent manager. Built at image-build time via `fleetctl package` (no public dnf/yum repo exists for it) and installed without a Fleet server URL or enrollment secret baked in. |

## Systemd Units Enabled

| Unit | Purpose |
|---|---|
| `sssd` | System Security Services Daemon — handles Kerberos authentication, LDAP user/group lookups, and caching for the FreeIPA domain. |
| `oddjobd` | D-Bus daemon for `oddjob`. Must be running for `pam_oddjob_mkhomedir` to create home directories at login. |
| `podman.socket` | Inherited from the Bazzite base; retained for rootless container support. |
| `orbit` | Fleet's agent manager. Enabled unconfigured; it logs connection errors until `/etc/default/orbit` is populated (see [Setting Up the Fleet Agent](#setting-up-the-fleet-agent)), after which it starts enforcing agent configuration with no extra step required. |

## Homebrew

[Homebrew](https://brew.sh) is installed system-wide at `/home/linuxbrew/.linuxbrew` and is available to every user — including FreeIPA domain users — without any per-user setup.

The brew environment is sourced automatically for all login and interactive shells via `/etc/profile.d/brew.sh`. No manual PATH configuration is required.

### How it persists across bootc updates

In a bootc deployment `/home` is a symlink to `/var/home`. The `/var` tree is seeded from the OCI image on first install and preserved across `bootc upgrade` runs. This means the Homebrew installation is present from the very first boot and survives image updates independently. Packages you install via `brew` after deployment are not affected by image updates.

### Running installed packages

All users can run any package already installed in the shared prefix without any additional configuration. The `brew` command itself is in PATH for every user.

### Installing new packages (write access)

Package installation requires write access to the shared prefix. Access is controlled by the `brew` group.

**For local users:**

```bash
sudo usermod -aG brew <username>
```

The user must log out and back in for the group change to take effect.

**For FreeIPA domain users:**

Add the user to the local `brew` group on each host where they need install access:

```bash
sudo usermod -aG brew <domain-username>
```

Or manage it centrally via an IPA sudo rule or HBAC rule that grants `usermod` privileges to a designated admin group.

> [!NOTE]
> Users not in the `brew` group can still run any package that is already installed. Only writing new packages to the shared prefix requires group membership.

## /etc Directory Skeleton

`ipa-client-install` writes its configuration into `/etc/ipa/`, `/etc/sssd/`, and `/etc/krb5.conf`. For bootc's three-way `/etc` merge to treat those files as local additions (and therefore never overwrite them on update), the directories must exist in the image but must contain no config file content.

This image creates the following empty directory skeletons at build time:

| Path | Permissions | Purpose |
|---|---|---|
| `/etc/ipa/` | `0755` | Root directory for IPA client config. `ipa-client-install` writes `default.conf` here. |
| `/etc/sssd/conf.d/` | `0750` | Drop-in directory for SSSD config fragments. `ipa-client-install` writes `sssd.conf` one level up. |

No config files are shipped inside these directories. Every file written by `ipa-client-install` is a local addition from bootc's perspective and will never be touched by an image update.

## Fleet Agent Packaging

Fleet's `fleetctl package` command (the only supported way to produce an installable `fleetd` package, since there is no public dnf/yum repo) is used at image-build time to build a `fleet-osquery` rpm. This requires `fpm` and its build dependencies (`ruby`, `ruby-devel`, `rubygems`, `rpm-build`, `gcc`, `make`, `redhat-rpm-config`). `fleetctl`, the `fpm` gem, and the `ruby`/`ruby-devel`/`rubygems`/`rpm-build` packages are all removed once the rpm is built and installed — a leftover system Ruby causes the Homebrew install step further down to use it instead of its own vendored Ruby, and Fedora's base `ruby` package is missing the `json` stdlib gem Homebrew needs. `gcc` and `make` are left in place, since unlike Ruby they may already be relied on elsewhere in the base Bazzite image (e.g. akmods/DKMS builds) and blindly removing them is riskier than the modest space they cost.

The package is built without `--fleet-url`/`--enroll-secret`, and `/etc/default/orbit` — the file `orbit.service` reads its configuration from — is deleted unconditionally after installation so this image never ships enrollment details. See [Fleet Enrollment Persistence](#fleet-enrollment-persistence) for why this matters across updates.

## /var Runtime Directories

SSSD's cache and runtime socket directories live under `/var`, which bootc never modifies. They are pre-created at build time to avoid race conditions on first boot before `sssd` has initialised them:

| Path | Permissions |
|---|---|
| `/var/lib/sss/db` | `0711` |
| `/var/lib/sss/pipes/private` | `0755` |
| `/var/log/sssd` | `0755` |

## Hostname Preservation

The upstream Bazzite image ships `/etc/hostname` containing the default value `bazzite`. If bootc's three-way merge applies a new image that still contains that default, and the local hostname has never been changed from the default, the hostname can be reset — breaking Kerberos, which ties tickets to the machine's FQDN.

This image ships `/etc/hostname` as an **empty file**, written via a `COPY` instruction in the Containerfile (not a `RUN` step — the OCI build runtime bind-mounts `/etc/hostname` into every `RUN` container, making `rm` fail with *Device or resource busy*). With an empty file in the image, bootc has no meaningful upstream value to merge against, and the hostname set during installation or by `hostnamectl` is always preserved across updates.

> [!IMPORTANT]
> Set the correct FQDN hostname **before** running `ipa-client-install`. The hostname is baked into the Kerberos principal and LDAP host entry at join time.
>
> ```bash
> sudo hostnamectl set-hostname myhost.your.domain.example
> ```

---

# Keeping the Image Updated

`bootc` checks for and stages updates automatically if the `bootc-fetch-apply-updates.timer` systemd unit is enabled. To enable automatic updates:

```bash
sudo systemctl enable --now bootc-fetch-apply-updates.timer
```

Updates are staged in the background and applied on the next reboot. A reboot does **not** happen automatically unless you also configure a reboot schedule.

To trigger a manual update check:

```bash
sudo bootc upgrade
```

---

# Building the Image Locally

Requires [just](https://just.systems/) and [podman](https://podman.io/). Both are available by default on all Universal Blue images.

```bash
just build          # Build the container image
just lint           # Run shellcheck on all shell scripts
just format         # Run shfmt on all shell scripts
just check          # Validate Justfile syntax
just clean          # Remove local build artifacts
```

---

# Building Disk Images Locally

Disk images (QCOW2 and installer ISOs) are produced by [bootc-image-builder](https://github.com/osbuild/bootc-image-builder) running as a privileged Podman container. `just` and `podman` are required. Both are available by default on all Universal Blue images.

> [!IMPORTANT]
> ISO builds require the published OCI image to be accessible. The `build-iso-*` targets use the locally built container image (`localhost/bazzite-freeipa:latest`). The `rebuild-iso-*` targets rebuild the container image first.

## Build Sequence

Always follow this order when building locally:

1. **Build the container image** — this produces `localhost/bazzite-freeipa:latest` in your local Podman store:

   ```bash
   just build
   ```

2. **Build the disk image** — this invokes bootc-image-builder against the locally built image:

   ```bash
   just build-iso-gnome    # Anaconda installer ISO (GNOME desktop)
   just build-iso-kde      # Anaconda installer ISO (KDE desktop)
   just build-qcow2        # QCOW2 virtual machine image
   ```

   Output is written to `output/` in the repository root.

   If you want to rebuild the container image and the disk image in a single step, use the `rebuild-*` variants instead:

   ```bash
   just rebuild-iso-gnome
   just rebuild-iso-kde
   just rebuild-qcow2
   ```

> [!NOTE]
> `just build-iso-gnome` (and the other `build-*` targets) do **not** rebuild the container image. If you have made changes to `build_files/build.sh` or `Containerfile`, run `just build` first, or use `just rebuild-iso-gnome` to do both steps automatically.

## Running a Built Image in a VM

After a successful build you can boot the image locally in a browser-based VM:

```bash
just run-vm-qcow2       # Boot the QCOW2 image (opens browser at localhost:8006+)
just run-vm-iso-gnome   # Boot the GNOME ISO in a VM
just run-vm-iso-kde     # Boot the KDE ISO in a VM
```

The VM runner requires `podman` and KVM (`/dev/kvm`). A browser window opens automatically after ~30 seconds.

## Output Files

| Target | Output path |
|---|---|
| `build-qcow2` | `output/qcow2/disk.qcow2` |
| `build-iso-gnome` | `output/bootiso/install.iso` |
| `build-iso-kde` | `output/bootiso/install.iso` |

Run `just clean` to remove all build artifacts.

---

# Building Disk Images via GitHub Actions

The [build-disk.yml](./.github/workflows/build-disk.yml) workflow builds installable disk images (`qcow2`, `anaconda-iso-gnome`, and `anaconda-iso-kde`) from the **published** OCI image at `ghcr.io/personalcyber/bazzite-freeipa:latest`. Trigger it manually from the **Actions** tab, selecting `amd64` or `arm64`.

> [!NOTE]
> The GitHub Actions workflow uses the last image pushed to GHCR, not your local build. Push your changes and wait for the `build.yml` workflow to complete before triggering `build-disk.yml`.

The ISO kickstart is pre-configured to switch a newly installed system to `ghcr.io/personalcyber/bazzite-freeipa:latest` automatically.

To upload disk images to S3, add the following repository secrets under `Settings` → `Secrets and Variables` → `Actions`:

| Secret | Description |
|---|---|
| `S3_PROVIDER` | Provider name from the [rclone S3 list](https://rclone.org/s3/) |
| `S3_BUCKET_NAME` | Your bucket name |
| `S3_ACCESS_KEY_ID` | Access key for the bucket |
| `S3_SECRET_ACCESS_KEY` | Secret key for the bucket |
| `S3_REGION` | Bucket region (`auto` if unknown) |
| `S3_ENDPOINT` | Provider-specific endpoint URL |

---

# Image Signing

Images pushed to GHCR are signed with [Cosign](https://github.com/sigstore/cosign) using a key stored as the `SIGNING_SECRET` repository secret. The public key is at [`cosign.pub`](./cosign.pub).

To verify an image locally:

```bash
cosign verify --key cosign.pub ghcr.io/personalcyber/bazzite-freeipa:latest
```

> [!WARNING]
> Never commit `cosign.key` to the repository. Only `cosign.pub` is safe to commit.

---

# Community

- [Universal Blue Forums](https://universal-blue.discourse.group/)
- [Universal Blue Discord](https://discord.gg/WEu6BdFEtp)
- [bootc discussion forums](https://github.com/bootc-dev/bootc/discussions)
