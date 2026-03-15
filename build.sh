#!/usr/bin/env bash
set -euo pipefail
alias wget='wget --https-only --secure-protocol=TLSv1_2'

###############################################
# Clear old resources
###############################################

APPDIR="$(pwd)/AppDir"
rm -rf "$APPDIR" KeePassX-* keepassx_*.deb libaudio2_*.deb libqtcore4_*.deb libqtgui4_*.deb .meta-* ubuntu-archive-key.gpg 

###############################################
# Fetch appimagetool
###############################################

APPIMAGETOOL="$HOME/Programs/appimagetool-x86_64.AppImage"

mkdir -p "$HOME/Programs"

if [ ! -f "$APPIMAGETOOL" ]; then
    echo "Downloading appimagetool..."
    wget -O "$APPIMAGETOOL" \
      "https://github.com/AppImage/appimagetool/releases/download/continuous/appimagetool-x86_64.AppImage"
    chmod +x "$APPIMAGETOOL"
fi

###############################################
# Download packages
###############################################

# Globals expected:
MIRROR="https://ubuntu.cs.utah.edu/ubuntu"
DIST="xenial"
ARCH="amd64"

UBUNTU_KEY="3B4FE6ACC0B21F32"
echo "Extracting Ubuntu archive signing key from system..."
gpg --no-default-keyring \
    --keyring /usr/share/keyrings/ubuntu-archive-keyring.gpg \
    --export $UBUNTU_KEY \
    > ubuntu-archive-key.gpg

echo "Importing Ubuntu signing key..."
gpg --keyserver hkps://keyserver.ubuntu.com --recv-keys $UBUNTU_KEY >/dev/null

verify_and_download() {
    local DEB_URL="$1"
    local COMP="$2"   # e.g. main, universe, restricted, multiverse

    local DEB_FILE PKG_NAME META_DIR
    DEB_FILE=$(basename "$DEB_URL")
    PKG_NAME=$(echo "$DEB_FILE" | cut -d_ -f1)
    META_DIR=".meta-${DIST}-${COMP}-${ARCH}"

    mkdir -p "$META_DIR"

    ########################################
    # 1. Fetch and verify Release
    ########################################
    if [ ! -f "$META_DIR/InRelease" ]; then
        echo "==> Fetching InRelease metadata for $DIST/$COMP ($ARCH)"

        wget -q "$MIRROR/dists/$DIST/InRelease" -O "$META_DIR/InRelease" || {
            echo "Failed to download InRelease"
            exit 1
        }

        echo "==> Verifying InRelease signature"

        VERIFY_OUTPUT=$(gpg --verify "$META_DIR/InRelease" 2>&1 || true)

        if echo "$VERIFY_OUTPUT" | grep -q "Good signature"; then
            echo "InRelease signature verified successfully"
        else
            echo "$VERIFY_OUTPUT"
            echo "InRelease signature verification failed"
            exit 1
        fi
    fi

    ########################################
    # 2. Find SHA256 + size for Packages.xz / Packages.gz
    ########################################
    local REL_FILE="$META_DIR/InRelease"
    local REL_PATH_XZ="$COMP/binary-$ARCH/Packages.xz"
    local REL_PATH_GZ="$COMP/binary-$ARCH/Packages.gz"

    local META_PATH META_URL EXPECTED_SHA EXPECTED_SIZE

    # Helper: extract SHA256 + size for a given path from InRelease
    _extract_sha_size() {
        local path="$1"
        awk -v p="$path" '
            $1 == "SHA256:" { in_sha=1; next }
            in_sha {
                # Look for a line ending with the exact path
                if ($0 ~ ("[[:space:]]" p "$")) {
                    print $1, $2
                    exit
                }
            }
        ' "$REL_FILE"
    }

    # Try Packages.xz first
    read -r EXPECTED_SHA EXPECTED_SIZE <<< "$(_extract_sha_size "$REL_PATH_XZ")"

    if [ -n "$EXPECTED_SHA" ] && [ -n "$EXPECTED_SIZE" ]; then
        META_PATH="$META_DIR/Packages.xz"
        META_URL="$MIRROR/dists/$DIST/$REL_PATH_XZ"
        echo "==> Using $REL_PATH_XZ (preferred)"
    else
        echo "Packages.xz not listed in InRelease, trying Packages.gz..."
        read -r EXPECTED_SHA EXPECTED_SIZE <<< "$(_extract_sha_size "$REL_PATH_GZ")"
        if [ -n "$EXPECTED_SHA" ] && [ -n "$EXPECTED_SIZE" ]; then
            META_PATH="$META_DIR/Packages.gz"
            META_URL="$MIRROR/dists/$DIST/$REL_PATH_GZ"
            echo "==> Using $REL_PATH_GZ (fallback)"
        else
            echo "No SHA256 entry for $REL_PATH_XZ or $REL_PATH_GZ in InRelease"
            exit 1
        fi
    fi

    ########################################
    # 3. Download and verify metadata file
    ########################################
    if [ ! -f "$META_PATH" ]; then
        echo "==> Downloading metadata: $META_URL"
        wget -q "$META_URL" -O "$META_PATH" || {
            echo "Failed to download metadata file"
            exit 1
        }
    fi

    echo "==> Verifying metadata size and SHA256"
    local ACT_SIZE ACT_SHA
    ACT_SIZE=$(stat -c%s "$META_PATH")
    ACT_SHA=$(sha256sum "$META_PATH" | awk '{print $1}')

    if [ "$ACT_SIZE" != "$EXPECTED_SIZE" ]; then
        echo "Size mismatch for metadata: expected $EXPECTED_SIZE, got $ACT_SIZE"
        exit 1
    fi

    if [ "$ACT_SHA" != "$EXPECTED_SHA" ]; then
        echo "SHA256 mismatch for metadata"
        echo "Expected: $EXPECTED_SHA"
        echo "Actual:   $ACT_SHA"
        exit 1
    fi

    echo "==> Metadata verified"

    ########################################
    # 4. Ensure we have uncompressed Packages
    ########################################
    local PKG_INDEX="$META_DIR/Packages"
    if [ ! -f "$PKG_INDEX" ]; then
        case "$META_PATH" in
            *.xz)
                xz -dc "$META_PATH" > "$PKG_INDEX" || {
                    echo "Failed to decompress Packages.xz"
                    exit 1
                }
                ;;
            *.gz)
                gunzip -c "$META_PATH" > "$PKG_INDEX" || {
                    echo "Failed to decompress Packages.gz"
                    exit 1
                }
                ;;
            *)
                echo "Unknown metadata format: $META_PATH"
                exit 1
                ;;
        esac
    fi

    ########################################
    # 5. Find filename + SHA256 for this package
    ########################################
    echo "==> Looking up $DEB_FILE in metadata"

    local META_FILENAME META_SHA
    
    # We require both Package: and matching Filename: and SHA256:
    read -r META_FILENAME META_SHA < <(
        awk -v target="$DEB_FILE" '
            /^Package:/ { in_pkg=1; fname=""; sha="" }
            in_pkg && /^Filename:/ {
                # Extract only the basename
                split($2, a, "/")
                if (a[length(a)] == target) fname=$2
            }
            in_pkg && /^SHA256:/ { sha=$2 }
            in_pkg && fname && sha {
                print fname, sha
                exit
            }
        ' "$PKG_INDEX"
    )

    if [ -z "$META_FILENAME" ] || [ -z "$META_SHA" ]; then
        echo "Package $DEB_FILE not found with Filename+SHA256 in metadata"
        return 1
    fi

    echo "==> Metadata filename: $META_FILENAME"
    echo "==> Metadata SHA256:   $META_SHA"

    # Check that the basename matches the .deb we intend to download
    local META_BASENAME
    META_BASENAME=$(basename "$META_FILENAME")
    if [ "$META_BASENAME" != "$DEB_FILE" ]; then
        echo "Filename mismatch:"
        echo "  Metadata expects: $META_BASENAME"
        echo "  URL provides:     $DEB_FILE"
        exit 1
    fi

    ########################################
    # 6. Download and verify the .deb
    ########################################
    echo "==> Downloading $DEB_FILE"
    wget -q "$DEB_URL" -O "$DEB_FILE" || {
        echo "Failed to download $DEB_FILE"
        exit 1
    }

    echo "==> Verifying .deb SHA256"
    local DEB_SHA
    DEB_SHA=$(sha256sum "$DEB_FILE" | awk '{print $1}')

    if [ "$DEB_SHA" != "$META_SHA" ]; then
        echo "SHA256 mismatch for $DEB_FILE"
        echo "Expected: $META_SHA"
        echo "Actual:   $DEB_SHA"
        exit 1
    fi

    echo "==> Verification successful for $DEB_FILE"
}

# Download keepassx
verify_and_download \
    "https://ubuntu.cs.utah.edu/ubuntu/pool/universe/k/keepassx/keepassx_2.0.2-1_amd64.deb" \
    "universe"

# Download libaudio2
verify_and_download \
    "https://ubuntu.cs.utah.edu/ubuntu/pool/main/n/nas/libaudio2_1.9.4-4_amd64.deb" \
    "main"

# Download libqtcore4
verify_and_download \
    "https://ubuntu.cs.utah.edu/ubuntu/pool/main/q/qt4-x11/libqtcore4_4.8.7+dfsg-5ubuntu2_amd64.deb" \
    "main"

# Download libqtgui4
verify_and_download \
    "https://ubuntu.cs.utah.edu/ubuntu/pool/main/q/qt4-x11/libqtgui4_4.8.7+dfsg-5ubuntu2_amd64.deb" \
    "main"

# Download libpng12-0
verify_and_download \
    "https://ubuntu.cs.utah.edu/ubuntu/pool/main/libp/libpng/libpng12-0_1.2.54-1ubuntu1_amd64.deb" \
    "main"

# Remove metadata and the key
rm -rf .meta-*
rm -f ubuntu-archive-key.gpg

###############################################
# Prepare sources
###############################################

mkdir -p $APPDIR

extract_deb() {
    local deb="$1"
    shift
    local patterns=("$@")

    echo "Extracting from $deb ..."

    # Resolve absolute path
    local deb_abs
    deb_abs="$(readlink -f "$deb")"

    # Create a unique temp directory
    local TMPDIR
    TMPDIR=$(mktemp -d)

    # Extract .deb contents into the temp dir
    ( cd "$TMPDIR" && ar x "$deb_abs" )

    # Find the data archive
    local DATA_TAR
    DATA_TAR=$(find "$TMPDIR" -maxdepth 1 -type f -name "data.tar.*")

    # Extract only the needed files
    tar --wildcards -xf "$DATA_TAR" -C "$APPDIR" "${patterns[@]}"

    # Cleanup
    rm -rf "$TMPDIR"
}

LIBS="usr/lib/x86_64-linux-gnu"
ICONS="usr/share/icons/hicolor/scalable/apps"

# keepassx
extract_deb keepassx_*.deb \
    "./usr/bin" \
    "./usr/share/keepassx" \
    "./usr/share/applications" \
    "./$ICONS/keepassx.svgz"


# libaudio2
extract_deb libaudio2_*.deb \
    "./$LIBS/libaudio.so.2*" \
    "./usr/share/libaudio2"

# libqtcore4
extract_deb libqtcore4_*.deb \
    "./$LIBS/libQtCore.so.4*"

# libqtgui4
extract_deb libqtgui4_*.deb \
    "./$LIBS/libQtGui.so.4*"

# libpng12-0
extract_deb libpng12-0_*.deb \
    "./lib/x86_64-linux-gnu/libpng12.so.0*"

# Force‑decompress real .svgz files
gzip -dc "$APPDIR/$ICONS/keepassx.svgz" \
    > "$APPDIR/$ICONS/keepassx.svg"
rm "$APPDIR/$ICONS/keepassx.svgz"

cp "$APPDIR/$ICONS/keepassx.svg" $APPDIR
sed -i 's/Exec=.*/Exec=\/AppRun/' "$APPDIR/usr/share/applications/keepassx.desktop"
cp "$APPDIR/usr/share/applications/keepassx.desktop" $APPDIR

###############################################
# Registration script
###############################################

cat > "$APPDIR/usr/bin/registration" << 'EOF'
#!/bin/bash
set -euo pipefail

ACTION="${1:-}"
APPDIR="${2:-}"

ICON_SRC="$APPDIR/keepassx.svg"
DESKTOP_SRC="$APPDIR/keepassx.desktop"

ICON_TARGET1="$HOME/.local/share/icons/hicolor/scalable/apps"
ICON_TARGET2="$HOME/.icons/hicolor/scalable/apps"
DESKTOP_TARGET="$HOME/.local/share/applications"

register() {
    echo "Where to place the KeePassX icon?"
    echo "(1) ~/.local/share/icons"
    echo "(2) ~/.icons"
    echo "Any other key to cancel"
    read -r choice

    case "$choice" in
        1) ICON_DEST="$ICON_TARGET1" ;;
        2) ICON_DEST="$ICON_TARGET2" ;;
        *) echo "Canceled"; exit 0 ;;
    esac

    mkdir -p "$ICON_DEST"
    cp "$ICON_SRC" "$ICON_DEST"

    mkdir -p "$DESKTOP_TARGET"
    cp "$DESKTOP_SRC" "$DESKTOP_TARGET"

    # Fix Exec to point to the AppImage
    sed -i "s|^Exec=.*|Exec=$APPIMAGE %f|" "$DESKTOP_TARGET/keepassx.desktop"

    echo "KeePassX registered"
}

unregister() {
    rm -f "$ICON_TARGET1/keepassx.svg"
    rm -f "$ICON_TARGET2/keepassx.svg"
    rm -f "$DESKTOP_TARGET/keepassx.desktop"

    echo "KeePassX unregistered"
}

case "$ACTION" in
    --register) register ;;
    --unregister) unregister ;;
    *) echo "Unknown action"; exit 1 ;;
esac
EOF

chmod +x "$APPDIR/usr/bin/registration"

###############################################
# Simple AppRun
###############################################

cat > "$APPDIR/AppRun" << 'EOF'
#!/bin/bash
set -euo pipefail
HERE="$(dirname "$(readlink -f "$0")")"

case "${1:-}" in
    --reg|-r) exec "$HERE/usr/bin/registration" --register "$HERE" ;;
    --unreg|-u) exec "$HERE/usr/bin/registration" --unregister "$HERE" ;;
esac

export LD_LIBRARY_PATH="$HERE/usr/lib/x86_64-linux-gnu:${LD_LIBRARY_PATH:-}"
exec "$HERE/usr/bin/keepassx" "$@"
EOF

chmod +x "$APPDIR/AppRun"

###############################################
# Build AppImage
###############################################

ARCH=x86_64 "$APPIMAGETOOL" --appimage-extract-and-run "$APPDIR"

###############################################
# Cleanup
###############################################

shopt -s extglob
rm -rf "$APPDIR" keepassx_*.deb libaudio2_*.deb libqtcore4_*.deb libqtgui4_*.deb

echo "Done"
