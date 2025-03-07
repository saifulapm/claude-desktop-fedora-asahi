#!/bin/bash
set -e

# Download URLs for different architectures
# Update these URLs when new versions of Claude Desktop are released
CLAUDE_DOWNLOAD_URL_X86_64="https://storage.googleapis.com/osprey-downloads-c02f6a0d-347c-492b-a752-3e0651722e97/nest-win-x64/Claude-Setup-x64.exe"
CLAUDE_DOWNLOAD_URL_AARCH64="$CLAUDE_DOWNLOAD_URL_X86_64" # Currently same as x86_64, update when aarch64 build is available

# Detect architecture
ARCH=$(uname -m)
case "$ARCH" in
    x86_64)
        CLAUDE_DOWNLOAD_URL="$CLAUDE_DOWNLOAD_URL_X86_64"
        ARCHITECTURE="x86_64"
        ;;
    aarch64|arm64)
        CLAUDE_DOWNLOAD_URL="$CLAUDE_DOWNLOAD_URL_AARCH64"
        ARCHITECTURE="aarch64"
        ;;
    *)
        echo "❌ Unsupported architecture: $ARCH"
        echo "This script currently supports x86_64 and aarch64 only"
        exit 1
        ;;
esac

echo "🖥️ Detected architecture: $ARCHITECTURE"

# Check for Fedora-based system or Asahi Linux
IS_FEDORA=false
IS_ASAHI=false

if [ -f "/etc/fedora-release" ]; then
    IS_FEDORA=true
    echo "✓ Fedora-based system detected"
elif grep -q "Asahi Linux" /etc/os-release 2>/dev/null; then
    IS_ASAHI=true
    echo "✓ Asahi Linux detected"
else
    echo "❌ This script requires a Fedora-based Linux distribution or Asahi Linux"
    exit 1
fi

# Check for root/sudo
if [ "$EUID" -ne 0 ]; then
    echo "Please run with sudo to install dependencies"
    exit 1
fi

# Print system information
echo "System Information:"
echo "Distribution: $(cat /etc/os-release | grep "PRETTY_NAME" | cut -d'"' -f2)"
if $IS_FEDORA; then
    echo "Fedora version: $(cat /etc/fedora-release)"
fi
echo "Architecture: $ARCHITECTURE"

# Function to check if a command exists
check_command() {
    if ! command -v "$1" &> /dev/null; then
        echo "❌ $1 not found"
        return 1
    else
        echo "✓ $1 found"
        return 0
    fi
}

# Check and install dependencies
echo "Checking dependencies..."
DEPS_TO_INSTALL=""

# Check system package dependencies
for cmd in 7z wget wrestool icotool convert npx rpm rpmbuild; do
    if ! check_command "$cmd"; then
        case "$cmd" in
            "7z")
                DEPS_TO_INSTALL="$DEPS_TO_INSTALL p7zip-plugins"
                ;;
            "wget")
                DEPS_TO_INSTALL="$DEPS_TO_INSTALL wget"
                ;;
            "wrestool"|"icotool")
                DEPS_TO_INSTALL="$DEPS_TO_INSTALL icoutils"
                ;;
            "convert")
                DEPS_TO_INSTALL="$DEPS_TO_INSTALL ImageMagick"
                ;;
            "npx")
                DEPS_TO_INSTALL="$DEPS_TO_INSTALL nodejs npm"
                ;;
            "rpm")
                DEPS_TO_INSTALL="$DEPS_TO_INSTALL rpm"
                ;;
            "rpmbuild")
                DEPS_TO_INSTALL="$DEPS_TO_INSTALL rpmbuild"
                ;;
            "curl")
                DEPS_TO_INSTALL="$DEPS_TO_INSTALL curl"
        esac
    fi
done

# Install system dependencies if any
if [ ! -z "$DEPS_TO_INSTALL" ]; then
    echo "Installing system dependencies: $DEPS_TO_INSTALL"
    if $IS_FEDORA; then
        dnf install -y $DEPS_TO_INSTALL
    elif $IS_ASAHI; then
        # Assuming Asahi Linux uses pacman (Arch-based)
        pacman -S --needed $DEPS_TO_INSTALL
    fi
    echo "System dependencies installed successfully"
fi

# Install electron globally via npm if not present
if ! check_command "electron"; then
    echo "Installing electron via npm..."
    npm install -g electron
    if ! check_command "electron"; then
        echo "Failed to install electron. Please install it manually:"
        echo "sudo npm install -g electron"
        exit 1
    fi
    echo "Electron installed successfully"
fi

# Extract version from the installer filename
VERSION=$(basename "$CLAUDE_DOWNLOAD_URL" | grep -oP 'Claude-Setup-x64\.exe' | sed 's/Claude-Setup-x64\.exe/0.8.0/')
PACKAGE_NAME="claude-desktop"
MAINTAINER="Claude Desktop Linux Maintainers"
DESCRIPTION="Claude Desktop for Linux"

# Create working directories
WORK_DIR="$(pwd)/build"
FEDORA_ROOT="$WORK_DIR/package-root"
INSTALL_DIR="$FEDORA_ROOT/usr"

# Clean previous build
rm -rf "$WORK_DIR"
mkdir -p "$WORK_DIR"
mkdir -p "$FEDORA_ROOT/FEDORA"
mkdir -p "$INSTALL_DIR/lib/$PACKAGE_NAME"
mkdir -p "$INSTALL_DIR/share/applications"
mkdir -p "$INSTALL_DIR/share/icons"
mkdir -p "$INSTALL_DIR/bin"

# Install asar if needed
if ! command -v asar > /dev/null 2>&1; then
    echo "Installing asar package globally..."
    npm install -g asar
fi

# Download Claude Windows installer
echo "📥 Downloading Claude Desktop installer for $ARCHITECTURE..."
CLAUDE_EXE="$WORK_DIR/Claude-Setup-x64.exe"
if ! curl -o "$CLAUDE_EXE" "$CLAUDE_DOWNLOAD_URL"; then
    echo "❌ Failed to download Claude Desktop installer"
    exit 1
fi
echo "✓ Download complete"

# Extract resources
echo "📦 Extracting resources..."
cd "$WORK_DIR"
if ! 7z x -y "$CLAUDE_EXE"; then
    echo "❌ Failed to extract installer"
    exit 1
fi

if ! 7z x -y "AnthropicClaude-$VERSION-full.nupkg"; then
    echo "❌ Failed to extract nupkg"
    exit 1
fi
echo "✓ Resources extracted"

# Extract and convert icons
echo "🎨 Processing icons..."
if ! wrestool -x -t 14 "lib/net45/claude.exe" -o claude.ico; then
    echo "❌ Failed to extract icons from exe"
    exit 1
fi

if ! icotool -x claude.ico; then
    echo "❌ Failed to convert icons"
    exit 1
fi
echo "✓ Icons processed"

# Map icon sizes to their corresponding extracted files
declare -A icon_files=(
    ["16"]="claude_13_16x16x32.png"
    ["24"]="claude_11_24x24x32.png"
    ["32"]="claude_10_32x32x32.png"
    ["48"]="claude_8_48x48x32.png"
    ["64"]="claude_7_64x64x32.png"
    ["256"]="claude_6_256x256x32.png"
)

# Install icons
for size in 16 24 32 48 64 256; do
    icon_dir="$INSTALL_DIR/share/icons/hicolor/${size}x${size}/apps"
    mkdir -p "$icon_dir"
    if [ -f "${icon_files[$size]}" ]; then
        echo "Installing ${size}x${size} icon..."
        install -Dm 644 "${icon_files[$size]}" "$icon_dir/claude-desktop.png"
    else
        echo "Warning: Missing ${size}x${size} icon"
    fi
done

# Process app.asar
mkdir -p electron-app
cp "lib/net45/resources/app.asar" electron-app/
cp -r "lib/net45/resources/app.asar.unpacked" electron-app/

cd electron-app
npx asar extract app.asar app.asar.contents

# Replace native module with stub implementation
echo "Creating stub native module..."
cat > app.asar.contents/node_modules/claude-native/index.js << EOF
// Stub implementation of claude-native using KeyboardKey enum values
const KeyboardKey = {
  Backspace: 43,
  Tab: 280,
  Enter: 261,
  Shift: 272,
  Control: 61,
  Alt: 40,
  CapsLock: 56,
  Escape: 85,
  Space: 276,
  PageUp: 251,
  PageDown: 250,
  End: 83,
  Home: 154,
  LeftArrow: 175,
  UpArrow: 282,
  RightArrow: 262,
  DownArrow: 81,
  Delete: 79,
  Meta: 187
};

Object.freeze(KeyboardKey);

module.exports = {
  getWindowsVersion: () => "10.0.0",
  setWindowEffect: () => {},
  removeWindowEffect: () => {},
  getIsMaximized: () => false,
  flashFrame: () => {},
  clearFlashFrame: () => {},
  showNotification: () => {},
  setProgressBar: () => {},
  clearProgressBar: () => {},
  setOverlayIcon: () => {},
  clearOverlayIcon: () => {},
  KeyboardKey
};
EOF

# Copy Tray icons
mkdir -p app.asar.contents/resources
cp ../lib/net45/resources/Tray* app.asar.contents/resources/

# Repackage app.asar
mkdir -p app.asar.contents/resources/i18n/
cp ../lib/net45/resources/*.json app.asar.contents/resources/i18n/

npx asar pack app.asar.contents app.asar

# Create native module with keyboard constants
mkdir -p "$INSTALL_DIR/lib/$PACKAGE_NAME/app.asar.unpacked/node_modules/claude-native"
cat > "$INSTALL_DIR/lib/$PACKAGE_NAME/app.asar.unpacked/node_modules/claude-native/index.js" << EOF
// Stub implementation of claude-native using KeyboardKey enum values
const KeyboardKey = {
  Backspace: 43,
  Tab: 280,
  Enter: 261,
  Shift: 272,
  Control: 61,
  Alt: 40,
  CapsLock: 56,
  Escape: 85,
  Space: 276,
  PageUp: 251,
  PageDown: 250,
  End: 83,
  Home: 154,
  LeftArrow: 175,
  UpArrow: 282,
  RightArrow: 262,
  DownArrow: 81,
  Delete: 79,
  Meta: 187
};

Object.freeze(KeyboardKey);

module.exports = {
  getWindowsVersion: () => "10.0.0",
  setWindowEffect: () => {},
  removeWindowEffect: () => {},
  getIsMaximized: () => false,
  flashFrame: () => {},
  clearFlashFrame: () => {},
  showNotification: () => {},
  setProgressBar: () => {},
  clearProgressBar: () => {},
  setOverlayIcon: () => {},
  clearOverlayIcon: () => {},
  KeyboardKey
};
EOF

# Copy app files
cp app.asar "$INSTALL_DIR/lib/$PACKAGE_NAME/"
cp -r app.asar.unpacked "$INSTALL_DIR/lib/$PACKAGE_NAME/"

# Create desktop entry
cat > "$INSTALL_DIR/share/applications/claude-desktop.desktop" << EOF
[Desktop Entry]
Name=Claude
Exec=claude-desktop %u
Icon=claude-desktop
Type=Application
Terminal=false
Categories=Office;Utility;
MimeType=x-scheme-handler/claude;
StartupWMClass=claude
EOF

# Determine lib directory based on architecture
if [ "$ARCHITECTURE" = "x86_64" ]; then
    LIB_DIR="lib64"
else
    LIB_DIR="lib"
fi

# Create launcher script
cat > "$INSTALL_DIR/bin/claude-desktop" << EOF
#!/bin/bash
electron /usr/${LIB_DIR}/claude-desktop/app.asar "\$@"
EOF
chmod +x "$INSTALL_DIR/bin/claude-desktop"

# Create RPM spec file with architecture support
cat > "$WORK_DIR/claude-desktop.spec" << EOF
Name:           claude-desktop
Version:        ${VERSION}
Release:        1%{?dist}
Summary:        Claude Desktop for Linux
License:        Proprietary
URL:            https://www.anthropic.com
BuildArch:      ${ARCHITECTURE}
Requires:       nodejs >= 12.0.0, npm, p7zip

%description
Claude is an AI assistant from Anthropic.
This package provides the desktop interface for Claude.

%install
%ifarch x86_64
mkdir -p %{buildroot}/usr/lib64/%{name}
%else
mkdir -p %{buildroot}/usr/lib/%{name}
%endif
mkdir -p %{buildroot}/usr/bin
mkdir -p %{buildroot}/usr/share/applications
mkdir -p %{buildroot}/usr/share/icons

# Copy files from the INSTALL_DIR based on architecture
%ifarch x86_64
cp -r ${INSTALL_DIR}/lib/%{name}/* %{buildroot}/usr/lib64/%{name}/
%else
cp -r ${INSTALL_DIR}/lib/%{name}/* %{buildroot}/usr/lib/%{name}/
%endif
cp -r ${INSTALL_DIR}/bin/* %{buildroot}/usr/bin/
cp -r ${INSTALL_DIR}/share/applications/* %{buildroot}/usr/share/applications/
cp -r ${INSTALL_DIR}/share/icons/* %{buildroot}/usr/share/icons/

%files
%{_bindir}/claude-desktop
%ifarch x86_64
%{_libdir}/%{name}
%else
/usr/lib/%{name}
%endif
%{_datadir}/applications/claude-desktop.desktop
%{_datadir}/icons/hicolor/*/apps/claude-desktop.png

%post
# Update icon caches
gtk-update-icon-cache -f -t %{_datadir}/icons/hicolor || :
# Force icon theme cache rebuild
touch -h %{_datadir}/icons/hicolor >/dev/null 2>&1 || :
update-desktop-database %{_datadir}/applications || :

%changelog
* $(date '+%a %b %d %Y') ${MAINTAINER} ${VERSION}-1
- Initial package
EOF

# Build RPM package or PKGBUILD for Asahi
if $IS_FEDORA; then
    echo "📦 Building RPM package for $ARCHITECTURE..."
    mkdir -p "${WORK_DIR}"/{BUILD,RPMS,SOURCES,SPECS,SRPMS}
    
    RPM_FILE="$(pwd)/claude-desktop-${VERSION}-1.${ARCHITECTURE}.rpm"
    if ! rpmbuild -bb \
        --define "_topdir ${WORK_DIR}" \
        --define "_rpmdir $(pwd)" \
        "${WORK_DIR}/claude-desktop.spec"; then
        echo "❌ Failed to build RPM package"
        exit 1
    fi
elif $IS_ASAHI; then
    echo "📦 Preparing package for Asahi Linux..."
    
    # Create a PKGBUILD file for Arch/Asahi Linux
    mkdir -p "$WORK_DIR/asahi-pkg"
    cd "$WORK_DIR/asahi-pkg"
    
    cat > PKGBUILD << EOF
# Maintainer: ${MAINTAINER}
pkgname=claude-desktop
pkgver=${VERSION}
pkgrel=1
pkgdesc="Claude Desktop for Linux"
arch=('aarch64')
url="https://www.anthropic.com"
license=('custom:proprietary')
depends=('nodejs' 'npm' 'electron' 'p7zip')
options=(!strip)

package() {
    cd "\$srcdir"
    
    # Create directories
    install -dm755 "\$pkgdir/usr/${LIB_DIR}/${pkgname}"
    install -dm755 "\$pkgdir/usr/bin"
    install -dm755 "\$pkgdir/usr/share/applications"
    
    # Copy files from the build directory
    cp -r "${INSTALL_DIR}/lib/${pkgname}"/* "\$pkgdir/usr/${LIB_DIR}/${pkgname}/"
    install -Dm755 "${INSTALL_DIR}/bin/claude-desktop" "\$pkgdir/usr/bin/claude-desktop"
    install -Dm644 "${INSTALL_DIR}/share/applications/claude-desktop.desktop" "\$pkgdir/usr/share/applications/claude-desktop.desktop"
    
    # Copy icons
    for size in 16 24 32 48 64 256; do
        install -dm755 "\$pkgdir/usr/share/icons/hicolor/\${size}x\${size}/apps"
        install -Dm644 "${INSTALL_DIR}/share/icons/hicolor/\${size}x\${size}/apps/claude-desktop.png" "\$pkgdir/usr/share/icons/hicolor/\${size}x\${size}/apps/claude-desktop.png"
    done
}
EOF
    
    echo "✓ PKGBUILD created for Asahi Linux"
    echo "To build the package, run: cd $WORK_DIR/asahi-pkg && makepkg -si"
fi

echo "✅ Build process completed successfully for $ARCHITECTURE architecture!"
if $IS_FEDORA; then
    echo "🎯 You can install the package using: sudo dnf install ./claude-desktop-${VERSION}-1.${ARCHITECTURE}.rpm"
elif $IS_ASAHI; then
    echo "🎯 Navigate to $WORK_DIR/asahi-pkg and run 'makepkg -si' to build and install the package"
fi


