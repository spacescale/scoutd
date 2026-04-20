#!/usr/bin/env bash
set -euo pipefail

# This script builds the minimal bootable ext4 rootfs artifact for scoutd.
#
# Why this exists outside build.zig
#
# Zig should keep owning the scoutd binary build itself.
# The ext4 image build is a Linux release concern, not a Zig compile concern.
# It depends on Linux filesystem tools and fakeroot.
# That makes it a better fit for a release script than for the Zig build graph.
#
# What this script produces
#
# A tiny ext4 image that contains scoutd as /sbin/init plus the minimal
# directory tree the guest needs before scoutd mounts the runtime filesystems.
#
# The kernel will mount this image as the guest root filesystem.
# Then the kernel will execute /sbin/init, which is scoutd.

# if less than 2 args fail fast
if [[ $# -ne 2 ]]; then
  printf 'usage: %s <version> <scoutd-binary-path>\n' "$0" >&2
  exit 1
fi


VERSION="$1"
SCOUTD_BINARY="$2"

# SETUP THE VARIABLES
# Thirty two megabytes is still tiny and gives safer headroom
IMAGE_SIZE_MB="${IMAGE_SIZE_MB:-32}"
ARTIFACT_DIR="dist"
ROOTFS_IMAGE="${ARTIFACT_DIR}/scoutd-rootfs-${VERSION}-x86_64-ext4"

# Check if the Zig binary actually exists before we start
if [[ ! -f "$SCOUTD_BINARY" ]]; then
  printf 'scoutd binary not found at %s\n' "$SCOUTD_BINARY" >&2
  exit 1
fi



# These are the only tools we rely on for the image build.
# fakeroot lets the final filesystem look root owned without requiring real root.
# mke2fs creates and populates the ext4 image.
# dumpe2fs and debugfs are used for sanity validation after creation.
for tool in fakeroot mke2fs dumpe2fs debugfs truncate install chmod; do
  if ! command -v "$tool" >/dev/null 2>&1; then
    printf 'missing required tool %s\n' "$tool" >&2
    exit 1
  fi
done

# Create the output folder (dist/) where the final image will live
mkdir -p "$ARTIFACT_DIR"

# ==============================================================================
# PHASE 1: THE PREP TABLE
# ==============================================================================


# mktemp -d creates a temporary, random folder on your actual Mac/Linux machine
# e.g., /tmp/tmp.1a2b3c. This is our prep table.
WORKDIR="$(mktemp -d)"
STAGING_DIR="${WORKDIR}/rootfs"

# This cleanup trap ensures that if the script crashes, the Prep Table is thrown
# in the trash so it doesn't clutter the host
cleanup() {
  rm -rf "$WORKDIR"
}
trap cleanup EXIT


# We are now building the folder structure ON THE PREP TABLE.
# 'install -d' is just a safer, fancier version of 'mkdir -p'.
# We are creating the empty skeleton that the Linux kernel expects to see.
install -d -m 0755 \
  "${STAGING_DIR}/bin" \
  "${STAGING_DIR}/dev" \
  "${STAGING_DIR}/dev/pts" \
  "${STAGING_DIR}/dev/shm" \
  "${STAGING_DIR}/etc" \
  "${STAGING_DIR}/proc" \
  "${STAGING_DIR}/run" \
  "${STAGING_DIR}/sbin" \
  "${STAGING_DIR}/sys" \
  "${STAGING_DIR}/tmp" \
  "${STAGING_DIR}/usr" \
  "${STAGING_DIR}/var"


# Change permissions on specific folders so the guest kernel can write to them.
chmod 1777 "${STAGING_DIR}/tmp"
chmod 1777 "${STAGING_DIR}/dev/shm"


# Create a text file on the prep table so if you ever log into this VM, you
# can type `cat /etc/os-release` and it tells you it's a SpaceScale machine.
cat > "${STAGING_DIR}/etc/os-release" <<EOF
NAME=scoutd
ID=scoutd
VERSION=${VERSION}
PRETTY_NAME=scoutd ${VERSION}
EOF

# The kernel looks for init in standard locations.
# Take the raw Zig binary from your host, and copy it onto the prep table
# into the 'sbin' folder, and rename it to 'init'.
install -m 0755 "$SCOUTD_BINARY" "${STAGING_DIR}/sbin/init"


# ==============================================================================
# PHASE 2: THE BLANK HARD DRIVE (TRUNCATE)
# ==============================================================================

# Delete any old image that might be sitting in the dist/ folder.
rm -f "$ROOTFS_IMAGE"


# 'truncate' creates the blank physical file.
# Right now, scoutd-rootfs.ext4 is just a 32MB file filled with zeros. It has
# no filesystem. It is essentially a piece of unformatted raw metal.
truncate -s "${IMAGE_SIZE_MB}M" "$ROOTFS_IMAGE"


# ==============================================================================
# PHASE 3: THE BAKE (MKE2FS)
# ==============================================================================


# If we just put these files in the hard drive normally, they would belong to
# YOU (the user running the script). But inside the VM, the kernel expects
# files to be owned by the root user (UID 0).
#
# 'fakeroot' tricks the terminal into thinking you are the root user.
fakeroot sh -c "
 # Pretend that everything on the Prep Table is owned by root (0:0)
chown -R 0:0 '${STAGING_DIR}'

 # Run mke2fs (Make Ext2/3/4 Filesystem)
  mke2fs \
    -q \
    -t ext4 \
    -F \
    -L scoutd-rootfs \
    -m 0 \
    -d '${STAGING_DIR}' \
    '${ROOTFS_IMAGE}'
"
# Let's explain that mke2fs command:
# -t ext4 : Format the blank file as an ext4 filesystem.
# -F      : Force it (don't ask for confirmation).
# -m 0    : Don't reserve 5% of the disk for the root user (save space).
# -d '${STAGING_DIR}' :  It says "Take everything on my Prep  Table, and inject it directly into the formatted file."

#==============================================================================
# PHASE 4: VALIDATION
# ==============================================================================
# Validate the artifact structurally.
#
# We are not doing deep cryptographic validation here.
# We are only proving that the output is really an ext4 image and that the
# kernel entrypoint file exists inside it.


# Check the file to make sure it is actually an ext4 image now.
file "$ROOTFS_IMAGE"

# Ensure the filesystem isn't corrupted.
dumpe2fs -h "$ROOTFS_IMAGE" >/dev/null 2>&1


# Look inside the newly built hard drive file to confirm /sbin/init is there.
debugfs -R "stat /sbin/init" "$ROOTFS_IMAGE" >/dev/null 2>&1


printf '=======================================\n'
printf 'built %s\n' "$ROOTFS_IMAGE"
printf '=======================================\n'

