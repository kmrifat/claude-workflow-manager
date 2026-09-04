#!/bin/bash
#
#  loopback.sh — run the phone client against the real Mac server, in one process.
#
#  `Tools/Loopback/main.swift` starts a real `BoardServer` with a real TLS-PSK
#  listener, a real `BoardService` over an in-memory SwiftData store, and a real
#  `zsh` on a real pty — then dials it with a client built from the same
#  `ClaudeWMWire` types the phone uses. Nothing is stubbed, which is the point:
#  `BoardTransport` duplicates `BoardServer`'s connection parameters on purpose
#  (`ClaudeWMWire` may not import Network), and only a real handshake catches
#  the two drifting apart.
#
#  It also covers the things a unit test cannot reach: that a phone's keystrokes
#  reach a shell, that a symlink pointing out of the repository is refused, and
#  that dropping the phone does not kill the dev server.
#
#  Needs a Debug build first, for SwiftTerm and ClaudeWMWire:
#
#    xcodebuild -project workflow-manager.xcodeproj -scheme workflow-manager \
#      -destination 'platform=macOS' -derivedDataPath .xcbuild build
#

set -euo pipefail

cd "$(dirname "$0")/.."

BUILT=".xcbuild/Build/Products/Debug"
OUT="${TMPDIR:-/tmp}/claude-wm-loopback"

if [ ! -f "$BUILT/SwiftTerm.o" ] || [ ! -f "$BUILT/ClaudeWMWire.o" ]; then
    echo "Build the app first — see the header of this script." >&2
    exit 1
fi

# Every app source except the @main entry point: the harness supplies its own.
#
# The unquoted expansion below is deliberate and only works because of the bash
# shebang. Run the same swiftc line by hand in zsh — the default shell here —
# and it does *not* word-split: the whole list arrives as a single filename,
# swiftc quietly compiles the harness alone, and every app type is reported as
# "cannot find in scope". That reads as a module problem and is not one; the fix
# in zsh is ${=SOURCES}.
SOURCES=$(find workflow-manager -name '*.swift' ! -name 'ClaudeWMApp.swift' | tr '\n' ' ')

mkdir -p "$OUT"
# shellcheck disable=SC2086
swiftc -o "$OUT/loopback" \
    Tools/Loopback/main.swift $SOURCES ClaudeWMMobile/BoardTransport.swift \
    -I "$BUILT" "$BUILT/SwiftTerm.o" "$BUILT/ClaudeWMWire.o" \
    -framework AppKit -framework SwiftData -framework Network -framework UserNotifications

exec "$OUT/loopback"
