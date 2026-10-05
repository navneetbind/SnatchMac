# SnatchMac

Menu bar OCR for macOS. Press **⌘⇧2**, drag over anything on screen, and the text is on your clipboard.
Everything runs on-device with Apple's Vision framework. Nothing is uploaded.

Requires macOS 14 Sonoma or later. Universal (Apple Silicon + Intel).

## Features

- **Capture text** with ⌘⇧2: drag over a video, PDF, screen share, screenshot… and paste. Focus returns to
  the app you were in, so ⌘V works straight away. Esc, right-click or a plain click cancels.
- **QR codes and barcodes**: the payload is copied (optionally opens http(s) links).
- **Links**: a capture that is a single URL shows "Link copied".
- **Maccy-style history popup** (click the menu bar icon): type to search, ↑↓ + ↩ or ⌘1–⌘9 to copy,
  ⌥P pin, ⌥⌫ delete, ⌥⌘⌫ clear, ⌘, settings.
- **Read Clipboard Image**: OCR an image you already copied.
- **Settings** (General · Recognition · History · Appearance · Extras · Advanced): shortcut recorder,
  launch at login, accurate/fast mode, language, line breaks, history size, popup position.
- **Extras** (all off by default): single-line capture shortcut, hold Space to move the selection,
  text clean-up (rejoin hyphenated words, merge wrapped lines), hold ⌥ on release to edit before copying,
  All/Text/Links/QR tabs in the popup, Open Image or PDF… (text-layer PDFs skip OCR), read aloud.
- **URL scheme**: `snatchmac://capture`, `clipboard`, `history`, `settings` (Raycast, Alfred, Shortcuts).

## Install

Open `SnatchMac-<version>.dmg` and drag SnatchMac onto Applications.

SnatchMac is not notarized, so on a Mac that downloaded it the first launch says it "can't be verified":
click Done, then System Settings → Privacy & Security → **Open Anyway** (once).

On the first ⌘⇧2, allow **Screen Recording** (System Settings → Privacy & Security →
Screen & System Audio Recording) and choose Quit & Reopen. macOS may re-confirm this occasionally;
that's normal for every screen-capture app.

## Build

Needs only the Command Line Tools (no Xcode).

```bash
./build.sh install   # build, copy to ~/Applications, relaunch
./build.sh dmg       # build/SnatchMac-<version>.dmg (drag-to-Applications, volume icon, signed)
```

`swift scripts/make_icon.swift` redraws `Resources/AppIcon.icns`.

### Code signing

macOS ties the Screen Recording permission to the code signature. Ad-hoc signing changes with every
build, so the permission would reset after each rebuild. `build.sh` signs with a self-signed
**`SnatchMac Dev`** code-signing identity when it exists (override with `SNATCHMAC_SIGN_ID`):

```bash
cat > cert.cnf <<'EOF'
[req]
distinguished_name = dn
x509_extensions = ext
prompt = no
[dn]
CN = SnatchMac Dev
[ext]
basicConstraints = critical, CA:false
keyUsage = critical, digitalSignature
extendedKeyUsage = critical, codeSigning
EOF
openssl req -x509 -newkey rsa:2048 -nodes -keyout key.pem -out cert.pem -days 3650 -config cert.cnf
openssl pkcs12 -export -legacy -inkey key.pem -in cert.pem -name "SnatchMac Dev" -out dev.p12 -passout pass:temp
security import dev.p12 -k ~/Library/Keychains/login.keychain-db -P temp -T /usr/bin/codesign
rm key.pem cert.pem dev.p12 cert.cnf
```

It shows as "not trusted" in Keychain Access; codesign uses it anyway.

## Troubleshooting

- Each capture step is logged to `~/Library/Logs/SnatchMac/snatchmac.log` (permission check, selection,
  screen grab, OCR, copy).
- UI snapshots without Screen Recording permission:
  `defaults write com.navneetbind.snatchmac debugSnapshots -bool YES`, then
  `open "snatchmac://snapshot?show=history&dir=/tmp"` (or `show=settings&tab=2`) writes PNGs of the
  app's own windows.

## Uninstall

Quit SnatchMac, move it to the Trash, remove it from Screen & System Audio Recording, then:

```bash
rm -rf ~/Library/Application\ Support/SnatchMac ~/Library/Caches/com.navneetbind.snatchmac ~/Library/Logs/SnatchMac
defaults delete com.navneetbind.snatchmac
```
