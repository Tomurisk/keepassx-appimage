#!/usr/bin/env bash
set -euo pipefail
alias wget='wget --https-only --secure-protocol=TLSv1_2'

###############################################
# Config
###############################################

APPDIR="$(pwd)/AppDir"
AIT_DIR="/tmp/appimagetool"
AIT_VER="1.9.1"

AIT_SHA256="ed4ce84f0d9caff66f50bcca6ff6f35aae54ce8135408b3fa33abfc3cb384eb0"

# Clear old resources
rm -rf "$APPDIR" "$AIT_DIR" KeePassX-* *.deb

###############################################
# Download packages
###############################################

sudo tee /etc/apt/sources.list.d/xenial.list >/dev/null <<EOF
deb [signed-by=/usr/share/keyrings/ubuntu-archive-keyring.gpg] https://ubuntu.cs.utah.edu/ubuntu xenial main universe
EOF

sudo apt update

apt-get download keepassx=2.0.2-1
apt-get download libaudio2=1.9.4-4
apt-get download libqtcore4=4:4.8.7+dfsg-5ubuntu2
apt-get download libqtgui4=4:4.8.7+dfsg-5ubuntu2
apt-get download libpng12-0=1.2.54-1ubuntu1
apt-get download libgcrypt20=1.6.5-2
apt-get download libgpg-error0=1.21-2ubuntu1

###############################################
# Fetch appimagetool
###############################################

APPIMAGETOOL="$AIT_DIR/appimagetool-x86_64.AppImage"
mkdir -p "$AIT_DIR"

if [ ! -f "$APPIMAGETOOL" ]; then
    echo "Downloading appimagetool..."
    wget -O "$APPIMAGETOOL" \
      "https://github.com/AppImage/appimagetool/releases/download/${AIT_VER}/appimagetool-x86_64.AppImage"

    if echo "$AIT_SHA256  $APPIMAGETOOL" | sha256sum -c -; then
        echo "appimagetool checksum OK"
        chmod +x "$APPIMAGETOOL"
    else
        echo "ERROR: Checksum mismatch!"
        exit 1
    fi
fi

###############################################
# Prepare source deb files and bundle libs
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

    # Extract only the needed files, replace ./lib to ./usr/lib for
    # some extractions to succeed
    tar --wildcards \
    --transform='s|^./lib/|./usr/lib/|' \
    -xf "$DATA_TAR" -C "$APPDIR" \
    "${patterns[@]}"

    # Cleanup
    rm -rf "$TMPDIR"
}

LIBS="usr/lib/x86_64-linux-gnu"
DOC="usr/share/doc"
ICONS="usr/share/icons/hicolor/scalable/apps"

# keepassx
extract_deb keepassx_*.deb \
    "./$DOC/keepassx/copyright" \
    "./usr/bin" \
    "./usr/share/keepassx" \
    "./usr/share/applications" \
    "./$ICONS/keepassx.svgz"

# libaudio2
extract_deb libaudio2_*.deb \
    "./$DOC/libaudio2/copyright" \
    "./$LIBS/libaudio.so.2*" \
    "./usr/share/libaudio2"

# libqtcore4
extract_deb libqtcore4_*.deb \
    "./$DOC/libqtcore4/copyright" \
    "./$LIBS/libQtCore.so.4*"

# libqtgui4
extract_deb libqtgui4_*.deb \
    "./$DOC/libqtgui4/copyright" \
    "./$LIBS/libQtGui.so.4*"

# libpng12-0
extract_deb libpng12-0_*.deb \
    "./$DOC/libpng12-0/copyright" \
    "./lib/x86_64-linux-gnu/libpng12.so.0*"

# libgcrypt20
extract_deb libgcrypt20_*.deb \
    "./$DOC/libgcrypt20/copyright" \
    "./lib/x86_64-linux-gnu/libgcrypt.so.20*"

# libgpg-error0
extract_deb libgpg-error0_*.deb \
    "./$DOC/libgpg-error0/copyright" \
    "./lib/x86_64-linux-gnu/libgpg-error.so.0*"

# Force‑decompress real .svgz files
gzip -dc "$APPDIR/$ICONS/keepassx.svgz" \
    > "$APPDIR/$ICONS/keepassx.svg"
rm "$APPDIR/$ICONS/keepassx.svgz"

cp "$APPDIR/$ICONS/keepassx.svg" $APPDIR
sed -i 's/Exec=.*/Exec=\/AppRun/' "$APPDIR/usr/share/applications/keepassx.desktop"
cp "$APPDIR/usr/share/applications/keepassx.desktop" $APPDIR

rm -rf *.deb

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

# Don't use system theme
export KDE_FULL_SESSION=false
export GTK2_RC_FILES=/dev/null

# Use only the AppImage's icon directories
export XDG_DATA_DIRS="$HERE/usr/share"

export LD_LIBRARY_PATH="$HERE/usr/lib/x86_64-linux-gnu:${LD_LIBRARY_PATH:-}"
exec "$HERE/usr/bin/keepassx" "$@"
EOF

chmod +x "$APPDIR/AppRun"

###############################################
# Build AppImage
###############################################

RUNTIME="runtime-x86_64"

gpg --import <<'EOF'
-----BEGIN PGP PUBLIC KEY BLOCK-----

mDMEZjaeexYJKwYBBAHaRw8BAQdAhvHdHoBweX0uVRgfcnlzexrSg+TAbK2mU1TA
gi0TMC20NEFwcEltYWdlIHR5cGUgMiBydW50aW1lIDx0eXBlMi1ydW50aW1lQGFw
cGltYWdlLm9yZz6IlgQTFggAPgIbAwULCQgHAgYVCgkICwIEFgIDAQIeAQIXgBYh
BFcMd6zqQMDxt1iQLL+WzKVkkPaVBQJmN7FgBQkSzRXlAAoJEL+WzKVkkPaVCXsA
/0JxQPlr2AlKalt9LAGCXU633gBoXh8/sQQngGGWjhT2APoCls0XWL2qhx1jAIdr
AqDmOi3bdzBOpWBBIsOexhbdBrg4BGY2nnsSCisGAQQBl1UBBQEBB0CRVIEEu+Ft
W68O33iZCVDMIYUWdD59iXfQ7rHf8HxAEgMBCAeIfgQYFggAJhYhBFcMd6zqQMDx
t1iQLL+WzKVkkPaVBQJmNp57AhsMBQkDwmcAAAoJEL+WzKVkkPaVY7oA/icTs/E6
47LTon7ua021HdjQlwkHZOpa/hqBWQEB3w6GAQCbaPRxKcNN9Yfwxc6cIvfUORKz
+4OQzyesHV5P4fYLDw==
=r/5H
-----END PGP PUBLIC KEY BLOCK-----
EOF

wget -O "$AIT_DIR/runtime-x86_64.sig" \
  "https://github.com/AppImage/type2-runtime/releases/download/continuous/$RUNTIME.sig"
wget -O "$AIT_DIR/runtime-x86_64" \
  "https://github.com/AppImage/type2-runtime/releases/download/continuous/$RUNTIME"

if gpg --verify "$AIT_DIR/$RUNTIME.sig" "$AIT_DIR/$RUNTIME" 2>/dev/null; then
    echo "Runtime signature OK"
    ARCH=x86_64 "$APPIMAGETOOL" --appimage-extract-and-run --no-appstream --runtime-file "$AIT_DIR/$RUNTIME" "$APPDIR"
else
    echo "ERROR: Signature verification failed!"
    exit 1
fi

###############################################
# Cleanup
###############################################

shopt -s extglob
rm -rf "$APPDIR" "$AIT_DIR"

echo "Done"
