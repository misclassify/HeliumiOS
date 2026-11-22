# Helium for iOS (personal port)

A native SwiftUI + WKWebView browser carrying Helium's look and privacy defaults.
Chromium/Blink can't run on iOS (Apple only allows WebKit), so this is a port of Helium's
*features*, not of the Chromium engine. Based on Helium 0.22.2 branding (GPL-3.0, imputnet/helium).

## Features
- Tabs, tab switcher with previews, private tabs (isolated, wiped when the last one closes)
- Ad/tracker blocking via WebKit content rules: built-in list + uBlock Origin filters, EasyPrivacy,
EasyList, Peter Lowe (domain rules converted on-device, refreshed weekly)
- Third-party cookie blocking, HTTPS upgrade (with fallback), tracking-parameter stripping
- Fingerprint-surface reduction + Global Privacy Control
- Local !bangs (!g !yt !w !gh !r ...), search engine choice, no search suggestions (no keystroke leaks)
- Find on page, desktop-site toggle, downloads (share sheet / Save to Files), JS dialogs, camera/mic prompts

## Build the IPA (no Mac needed)
1. Create a private GitHub repo and push this folder to `main`.
2. Open **Actions → Build IPA → Run workflow** (it also runs on every push).
3. Download the `Helium-ipa` artifact → unzip → `Helium.ipa` (unsigned).

## Install
Sign + install with SideStore, AltStore or Sideloadly using your Apple ID.
(Free accounts: re-sign every 7 days.)

## Local build (on a Mac)
```
brew install xcodegen && xcodegen generate && open Helium.xcodeproj
```

## Not possible on iOS
Chrome extensions, Helium's Chromium patches/settings pages, setting it as the system default browser
(needs Apple's entitlement).
