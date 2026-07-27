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

### Enable required system units

systemctl enable sssd
systemctl enable oddjobd
systemctl enable podman.socket

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
