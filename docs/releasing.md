# Releasing Folio (manual)

Releases are built, notarized and published **locally**. CI only runs the tests and uploads an
ad-hoc build artifact for smoke tests; pushing a tag does not publish anything (there is no
tag-triggered workflow).

## 1. Bump and check the version

```bash
./scripts/set-version.sh 1.2.1     # MARKETING_VERSION / CURRENT_PROJECT_VERSION + Info.plist
./scripts/check-version.sh         # fails when the project and Info.plist diverge
git diff                           # only the two version values should change
git add -A && git commit -m "Release 1.2.1" && git push
```

The Xcode project is the source of truth: `MARKETING_VERSION` → `CFBundleShortVersionString`,
`CURRENT_PROJECT_VERSION` → `CFBundleVersion`. CI runs `check-version.sh` on every push.

## 2. Build, sign and notarize in Xcode

```bash
open Folio.xcodeproj
```

1. Scheme **Folio** → *Product → Archive*.
2. Organizer → *Distribute App → Developer ID → Upload* (wait for «Notarization succeeded»).
3. *Export* the notarized app to a folder, e.g. `~/Desktop/Folio-1.2.1`.

The archive build embeds PDFium, the Rust core and `ru.lproj`, and signs everything with the team's
Developer ID; no `dist/` copying is involved. Only arm64 is built
(`EXCLUDED_ARCHS[sdk=macosx*] = x86_64`) because PDFium and the Rust core are arm64-only.

## 3. Verify

```bash
cd ~/Desktop/Folio-1.2.1
codesign -dv --verbose=4 Folio.app | grep -E "Authority|TeamIdentifier"
spctl --assess --type execute --verbose=2 Folio.app    # accepted, source=Notarized Developer ID
xcrun stapler validate Folio.app
/usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" Folio.app/Contents/Info.plist
```

Open the app, open a PDF (Finder / *Open With* / drag & drop), check the toolbar, selection action bar
and dictionary once before publishing.

## 4. Package

```bash
ditto -c -k --keepParent Folio.app Folio.app.zip
shasum -a 256 Folio.app.zip > Folio.app.zip.sha256
cat Folio.app.zip.sha256
```

## 5. Publish

Copy [`.github/release-notes.md`](../.github/release-notes.md), replace `{{VERSION}}`, `{{SHA256}}`
and `{{COMMIT}}`, add the «What's new» section, then:

```bash
gh release create v1.2.1 --title "Folio 1.2.1" --notes-file /tmp/release-notes.md \
    Folio.app.zip Folio.app.zip.sha256
# or create the release in the GitHub web UI and attach both files
```

Check the published release: the asset is the notarized zip, the SHA-256 in the notes matches
`Folio.app.zip.sha256`, and `v1.2.1` is marked as the latest release.

## Notes

- Keep the app version and the tag equal: `v1.2.1` ↔ `1.2.1`. `check-version.sh 1.2.1` verifies it.
- The CI artifact (`Folio-app-<run>`) is ad-hoc signed and **not** a release asset.
- No secrets or certificates live in the repository; the Developer ID identity stays in the local
  keychain and is used only by Xcode during *Distribute App*.
