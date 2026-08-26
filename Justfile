# Build commands for the BoyaManager menu bar app

# Default recipe: build the app bundle
default: app

# Build BoyaManager.app bundle to ./build/
app:
    @mkdir -p build
    xcodebuild -project BoyaManager.xcodeproj -scheme BoyaManager -configuration Debug -destination 'platform=macOS,arch=arm64' -derivedDataPath .build/xcode -quiet
    @if [ -d build/BoyaManager.app ]; then trash build/BoyaManager.app; fi
    @cp -R .build/xcode/Build/Products/Debug/BoyaManager.app build/

# Build release app bundle. Apple silicon only, deliberately — there is no
# Intel Mac to test an x86_64 slice on, and shipping an untested one is worse
# than not shipping it.
app-release:
    @mkdir -p build
    xcodebuild -project BoyaManager.xcodeproj -scheme BoyaManager -configuration Release -destination 'platform=macOS,arch=arm64' -derivedDataPath .build/xcode -quiet
    @if [ -d build/BoyaManager.app ]; then trash build/BoyaManager.app; fi
    @cp -R .build/xcode/Build/Products/Release/BoyaManager.app build/
    @lipo -info build/BoyaManager.app/Contents/MacOS/BoyaManager

# Regenerate Xcode project from project.yml
gen:
    xcodegen generate

# Lint. Every rule SwiftLint has, minus the ones .swiftlint.yml argues with.
lint:
    swiftlint lint --strict

# The rules that need a compiler log, which means a clean build first.
lint-analyze:
    #!/usr/bin/env bash
    set -euo pipefail
    mkdir -p .build
    LOG=.build/swiftlint-build.log
    xcodebuild -project BoyaManager.xcodeproj -scheme BoyaManager -configuration Debug \
        -destination 'platform=macOS,arch=arm64' -derivedDataPath .build/xcode clean build > "$LOG"
    swiftlint analyze --strict --compiler-log-path "$LOG"

# Run the app
run: app
    open build/BoyaManager.app

# Render the menu bar icon in every state to /tmp/boyamanager-icons for inspection
icons:
    swift build
    .build/debug/BoyaManager --render-icons /tmp/boyamanager-icons
    open /tmp/boyamanager-icons

# Talk to the receiver from the terminal: handshake, dump every attribute, close
probe:
    swift build
    .build/debug/BoyaManager --probe

# Follow the app's log stream
log:
    /usr/bin/log stream --predicate 'subsystem=="com.bn-l.boya-manager"' --level debug

# Clean build artifacts
clean:
    @if [ -d build ]; then trash build; fi
    @if [ -d .build ]; then trash .build; fi

# Create DMG from release build
dmg: app-release
    #!/usr/bin/env bash
    set -euo pipefail
    VERSION=$(/usr/libexec/PlistBuddy -c "Print CFBundleShortVersionString" Info.plist)
    DMG="build/BoyaManager_${VERSION}.dmg"
    if [ -e "$DMG" ]; then trash "$DMG"; fi
    hdiutil create "$DMG" -volname "BoyaManager" -srcfolder build/BoyaManager.app -ov -format UDZO
    echo "$DMG"

# Create GitHub release with DMG
release: dmg
    #!/usr/bin/env bash
    set -euo pipefail
    VERSION=$(/usr/libexec/PlistBuddy -c "Print CFBundleShortVersionString" Info.plist)
    DMG="build/BoyaManager_${VERSION}.dmg"
    SHA=$(shasum -a 256 "$DMG" | cut -d' ' -f1)
    gh release create "v${VERSION}" "$DMG" --title "BoyaManager v${VERSION}" --notes "See assets to download and install."
    echo ""
    echo "SHA256: ${SHA}"

# Print version from Info.plist
version:
    @/usr/libexec/PlistBuddy -c "Print CFBundleShortVersionString" Info.plist
