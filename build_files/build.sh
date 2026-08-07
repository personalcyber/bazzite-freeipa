#!/bin/bash

set -ouex pipefail

### Install packages

# freeipa-client pulls in sssd, krb5-workstation, certmonger, and other
# required dependencies automatically.
dnf5 install -y \
    freeipa-client \
    oddjob \
    oddjob-mkhomedir

### Preserve FreeIPA join state across bootc updates
#
# bootc performs a three-way /etc merge on update: it diffs old-image /etc
# vs new-image /etc and applies that delta to local /etc. Files that
# ipa-client-install creates and that are NOT shipped in this image are
# treated as local additions and are never touched by updates.
#
# Strategy: create the directory skeleton here so the paths exist at first
# boot, but deliberately ship NO config file content. ipa-client-install
# then owns those files entirely, and bootc will never overwrite them.

install -d -m 0755 /etc/ipa
install -d -m 0750 /etc/sssd/conf.d

# Ensure sssd runtime and cache directories survive across updates.
# These already live under /var which is mutable and preserved by bootc.
install -d -m 0711 /var/lib/sss/db
install -d -m 0755 /var/lib/sss/pipes/private
install -d -m 0755 /var/log/sssd

### Install Fleet agent (fleetd/orbit)
#
# fleetd is Fleet's cross-platform osquery agent (orbit + osqueryd):
# https://fleetdm.com/docs/using-fleet/orbit
# https://fleetdm.com/docs/configuration/agent-configuration
#
# There is no public dnf/yum repo for it. The only supported way to obtain
# an installable package is `fleetctl package`, which fetches the orbit and
# osqueryd binaries from Fleet's TUF update server (tuf.fleetctl.com) and
# wraps them into an rpm using fpm. Install fpm's build dependencies, grab
# the latest fleetctl release, and build the rpm WITHOUT --fleet-url or
# --enroll-secret so no server address or secret is baked into the image.

dnf5 install -y ruby ruby-devel rubygems rpm-build gcc make redhat-rpm-config

# Fedora's rubygems defaults to a per-user install (under $HOME) even when
# run as root, which would land the gem cache under /root. /root, /usr/local,
# /opt, etc. are all symlinked into /var on this ostree-based image (see the
# /opt note in the Containerfile) and /var isn't populated during this RUN
# step, so nothing can be created under any of them. Pin GEM_HOME under
# /tmp (tmpfs-mounted for this RUN step, see Containerfile) to sidestep
# that, with its bin/ on PATH so `fleetctl package` can find the fpm
# executable it shells out to.
export GEM_HOME=/tmp/fleet-fpm-gems
export PATH="${GEM_HOME}/bin:${PATH}"
mkdir -p "${GEM_HOME}"
gem install --no-document fpm

# fleetctl separately writes a query-history file straight to /root/.goquery
# regardless of $HOME (it resolves the home directory via the OS user
# database, not the environment), so the HOME trick above wouldn't have
# covered it anyway. Fix it at the source instead: create the real backing
# directory for the /root -> /var/roothome symlink.
mkdir -p /var/roothome

_fleet_version="$(curl -fsSL https://api.github.com/repos/fleetdm/fleet/releases/latest |
    jq -r '.tag_name' | sed 's/^fleet-v//')"
_fleet_workdir="$(mktemp -d)"
curl -fsSL \
    "https://github.com/fleetdm/fleet/releases/download/fleet-v${_fleet_version}/fleetctl_v${_fleet_version}_linux_amd64.tar.gz" \
    -o "${_fleet_workdir}/fleetctl.tar.gz"
tar -xzf "${_fleet_workdir}/fleetctl.tar.gz" -C "${_fleet_workdir}"
_fleetctl="${_fleet_workdir}/fleetctl_v${_fleet_version}_linux_amd64/fleetctl"
chmod 0755 "${_fleetctl}"

# fleetctl is invoked directly from ${_fleet_workdir} rather than installed
# to /usr/local/bin: /usr/local is symlinked into /var on this ostree-based
# image (see the GEM_HOME note above) and isn't writable during this RUN
# step.
(cd "${_fleet_workdir}" && "${_fleetctl}" package --type rpm)

# fleet-osquery writes orbit's TUF-managed binary tree under /opt/orbit AND
# a launcher under /usr/local/bin. Both /opt and /usr/local are symlinked
# into /var in this image (see the [IM]MUTABLE /opt note in the
# Containerfile), and /var isn't populated during this RUN step, so
# pre-create both real backing directories just so dnf5 has somewhere to
# write through the symlinks.
mkdir -p /var/opt /var/usrlocal

# fpm-generated postinstall scriptlets (%post/%posttrans) call systemctl in
# ways that fail hard in this scriptless buildah container (no systemd
# PID 1), unlike the tolerant %systemd_post macros freeipa's packages use
# above. Skip scriptlets entirely — we enable orbit.service ourselves
# below regardless of whatever the package's postinstall would have done.
dnf5 install -y --setopt=tsflags=noscripts "${_fleet_workdir}"/fleet-osquery*.rpm

### Seed orbit's /opt and /usr/local files onto real (non-fresh-install) systems
#
# bootc/ostree do NOT carry arbitrary /var content from the container image
# into a deployed system beyond a genuinely first-ever install, and recent
# ostree versions dropped even that: /var is machine-local state, meant to
# be populated via systemd-tmpfiles, not shipped with the image. Since
# /opt and /usr/local both resolve through /var here, the files fleet-
# osquery just installed above only exist in this ephemeral build layer --
# on `bootc switch` (the documented, common path onto this image), rpm's
# database ends up listing /opt/orbit/... and /usr/local/bin/orbit as
# installed while the paths themselves are completely empty.
#
# Work around this by stashing what was just installed under a plain /usr
# path (which IS committed normally -- orbit.service loading correctly
# from /usr/lib/systemd/system proves that), then shipping a tmpfiles.d
# snippet that copies it into place through the symlinks on first boot.
# The 'C' tmpfiles directive only acts if its destination doesn't already
# exist, so this never clobbers orbit's own self-updated binaries later.
mkdir -p /usr/lib/fleetd-seed
cp -a /opt/orbit /usr/lib/fleetd-seed/opt-orbit
cp -a /usr/local/bin/orbit /usr/lib/fleetd-seed/usrlocal-bin-orbit

install -d -m 0755 /usr/lib/tmpfiles.d
cat > /usr/lib/tmpfiles.d/fleetd-seed.conf << 'EOF'
# Populate /opt/orbit and /usr/local/bin/orbit (both resolving into /var)
# from the image-committed seed the first time they're missing. See the
# Fleet agent section of build.sh for why this exists.
C /opt/orbit - - - - /usr/lib/fleetd-seed/opt-orbit
C /usr/local/bin/orbit - - - - /usr/lib/fleetd-seed/usrlocal-bin-orbit
EOF

# Make sure orbit.service doesn't race the tmpfiles seeding above. This is
# almost certainly already guaranteed by systemd's default ordering (both
# sysinit.target, which pulls in systemd-tmpfiles-setup.service, and
# orbit.service's own multi-user.target dependency chain go through
# basic.target), but it's cheap to make explicit.
install -d -m 0755 /usr/lib/systemd/system/orbit.service.d
cat > /usr/lib/systemd/system/orbit.service.d/10-wait-for-seed.conf << 'EOF'
[Unit]
After=systemd-tmpfiles-setup.service
EOF

### Preserve Fleet enrollment state across bootc updates
#
# Same three-way /etc merge concern as FreeIPA above: orbit's runtime
# configuration (Fleet server URL, enrollment secret path, TLS settings)
# lives in /etc/default/orbit, which is read via orbit.service's
# EnvironmentFile directive. Because the package was built without
# --fleet-url/--enroll-secret, that file should already be free of server
# details, but strip it unconditionally so this image never ships any
# content there. An operator enrolls the host later (populating
# /etc/default/orbit and enabling the service); bootc will treat that as a
# local addition and never touch it on subsequent updates.

rm -f /etc/default/orbit

# fleetctl and fpm itself are only needed to produce the package and don't
# need to ship in the final image.
rm -rf "${GEM_HOME}"
rm -rf "${_fleet_workdir}"
# Drop the query-history file fleetctl wrote to /root/.goquery; /var/roothome
# itself stays, since it's the image's real backing directory for the
# pre-existing /root symlink, not something this build step introduced.
rm -rf /var/roothome/.goquery
unset _fleet_version _fleet_workdir _fleetctl GEM_HOME

# ruby/ruby-devel/rubygems/rpm-build are also removed: nothing else in this
# image legitimately needs a system Ruby, and leaving one in place makes
# the Homebrew installer below pick it up instead of its own vendored Ruby
# -- Fedora splits the 'json' stdlib gem out of the base ruby package, so
# Homebrew's install script fails with a LoadError as soon as it tries to
# use the system interpreter. gcc/make/redhat-rpm-config are left alone:
# unlike ruby, they may already be relied on by the base Bazzite image for
# akmods/DKMS builds, and `dnf5 remove` can't tell "installed only for this
# step" apart from "already required by the base image".
dnf5 remove -y ruby ruby-devel rubygems rpm-build || true

### Enable required system units

systemctl enable sssd
systemctl enable oddjobd
systemctl enable podman.socket
# orbit will log connection errors until an operator populates
# /etc/default/orbit with a Fleet server URL and enrollment secret, but
# enabling it now means it starts enforcing agent configuration as soon as
# that file is in place, with no extra step required after enrollment.
systemctl enable orbit || true

### Fix bootc-image-builder ISO manifest generation compatibility
#
# Repos inherited from the Bazzite base image (e.g. terra-mesa) reference
# GPG keys via local file:// paths in /etc/pki/rpm-gpg/. BIB's anaconda-iso
# manifest generation extracts repo configs from the container image and runs
# dnf dependency resolution inside its own container, which has no access to
# those key files. Patching gpgcheck=0 alone is insufficient — dnf also
# enforces repo_gpgcheck (repomd.xml signature verification) and fails with
# "Signing key not found" when the gpgkey reference is absent.
#
# In a bootc image, packages are never updated via dnf; bootc upgrade pulls
# cosign-verified OCI images instead. These repos serve no purpose in the
# deployed system. Truncate any repo file that carries a local file:// gpgkey
# reference so BIB's manifest generation can proceed without error.
#
# Each directory is searched separately so find exits 0 when the directory
# exists, avoiding a pipefail abort if one of the directories is absent.
for _repo_dir in /etc/yum.repos.d /usr/lib/yum.repos.d; do
    [[ -d "$_repo_dir" ]] || continue
    find "$_repo_dir" -name '*.repo' | while IFS= read -r _repo_file; do
        grep -ql 'gpgkey=file://' "$_repo_file" 2>/dev/null || continue
        # Remove local file:// gpgkey lines and disable signature checking.
        # BIB's depsolve runs inside its own container and cannot access
        # file:// paths from the target image. In a bootc image, packages
        # are never updated via dnf; security comes from cosign-verified
        # OCI image pulls, so disabling repo GPG checks is safe here.
        sed -i \
            -e '/^gpgkey=file:/d' \
            -e 's/^gpgcheck=.*/gpgcheck=0/' \
            -e 's/^repo_gpgcheck=.*/repo_gpgcheck=0/' \
            "$_repo_file"
        grep -q '^repo_gpgcheck=' "$_repo_file" || \
            sed -i '/^\[/a repo_gpgcheck=0' "$_repo_file"
        grep -q '^gpgcheck=' "$_repo_file" || \
            sed -i '/^\[/a gpgcheck=0' "$_repo_file"
    done
done
unset _repo_dir _repo_file

### Install Homebrew for all users (including FreeIPA domain users)
#
# Homebrew is installed to /home/linuxbrew/.linuxbrew (the standard Linux
# prefix). In a bootc deployment, /home is a symlink to /var/home. The /var
# tree is seeded from the OCI image on first install and preserved across
# bootc upgrades, so the brew installation is present from first boot and
# survives image updates independently.
#
# The 'brew' group grants write access to the installation. Local users and
# FreeIPA domain users added to this group can run 'brew install'. Users not
# in the group can still run any package that is already installed.

useradd -r -M -d /home/linuxbrew -s /bin/bash linuxbrew
groupadd -r brew
usermod -aG brew linuxbrew

# /home is a symlink to /var/home in Bazzite; create the real directory
# since the symlink target does not exist during the container build.
mkdir -p /var/home/linuxbrew
chown linuxbrew:linuxbrew /var/home/linuxbrew
chmod 0755 /var/home/linuxbrew

curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh \
    -o /tmp/brew-install.sh
# runuser/su both invoke PAM which fails in a container build environment.
# setpriv drops to the target UID/GID without PAM and is safe in containers.
setpriv --reuid=linuxbrew --regid=linuxbrew --init-groups \
    env HOME=/home/linuxbrew USER=linuxbrew NONINTERACTIVE=1 \
    bash /tmp/brew-install.sh

chgrp -R brew /home/linuxbrew/.linuxbrew
chmod -R g+rwX /home/linuxbrew/.linuxbrew
find /home/linuxbrew/.linuxbrew -type d -exec chmod g+s {} +

cat > /etc/profile.d/brew.sh << 'BREWEOF'
if [[ -x /home/linuxbrew/.linuxbrew/bin/brew ]]; then
    eval "$(/home/linuxbrew/.linuxbrew/bin/brew shellenv)"
fi
BREWEOF
chmod 644 /etc/profile.d/brew.sh

### Configure container image signature verification
#
# Ship the Cosign public key and a container policy so that deployed systems
# can verify this image's signature on every bootc upgrade. Without these
# files the client pulls with ostree-unverified-registry: and skips checking.
#
# After this image is deployed, switch to the signed scheme once with:
#   sudo bootc switch ostree-image-signed:docker://ghcr.io/personalcyber/bazzite-freeipa:latest
# Subsequent upgrades will then enforce signature verification automatically.

install -d -m 0755 /etc/pki/containers
install -m 0644 /ctx/cosign.pub \
    /etc/pki/containers/ghcr.io-personalcyber-bazzite-freeipa.pub

install -d -m 0755 /etc/containers/registries.d
cat > /etc/containers/registries.d/ghcr.io-personalcyber-bazzite-freeipa.yaml << 'EOF'
docker:
  ghcr.io/personalcyber/bazzite-freeipa:
    use-sigstore-attachments: true
EOF

# Patch the existing policy.json (inherited from the base image) rather than
# replacing it, to preserve verification rules for the base image itself.
jq '.transports.docker["ghcr.io/personalcyber/bazzite-freeipa"] = [
  {
    "type": "sigstoreSigned",
    "keyPath": "/etc/pki/containers/ghcr.io-personalcyber-bazzite-freeipa.pub",
    "signedIdentity": {"type": "matchRepository"}
  }
]' /etc/containers/policy.json > /tmp/policy.json.new
install -m 0644 /tmp/policy.json.new /etc/containers/policy.json
