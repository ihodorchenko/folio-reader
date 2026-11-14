# Releasing Folio (manual)

Notarization is possible **only from Xcode** here: the Developer ID identity and the notary
credentials live in the Xcode session, while the terminal has neither — `codesign` finds no
`Developer ID Application` certificate and `notarytool` answers «Must provide credentials». So a
release always has the same three steps:

1. version + commit + tag from the terminal;
2. archive and notarize in Xcode, export the app to `dist/Folio.app`;
3. package, verify and publish from the terminal.

`scripts/build-app.sh` is deliberately **not** part of this flow: it produces an ad-hoc bundle for
CI and smoke tests, Gatekeeper rejects it, and `scripts/package-release.sh` refuses to package it.
There is no tag-triggered workflow — pushing a tag publishes nothing.

## 1. Version, commit and tag

```bash
./scripts/set-version.sh 1.2.2     # MARKETING_VERSION / CURRENT_PROJECT_VERSION, project only
./scripts/check-version.sh         # the plist must still refer to the project, not carry a copy
git diff                           # only Folio.xcodeproj/project.xcproj should change
git add -A && git commit -m "Release 1.2.2" && git push
git tag -a v1.2.2 -m "Folio 1.2.2 — <theme>" && git push origin v1.2.2
```

The Xcode project is the **only** source of a version: `MARKETING_VERSION` →
`CFBundleShortVersionString`, `CURRENT_PROJECT_VERSION` → `CFBundleVersion`. `app/Bundle/Info.plist`
is a template with `$(MARKETING_VERSION)` / `$(CURRENT_PROJECT_VERSION)` placeholders, so Xcode — a
plain build and an archive alike — and `scripts/build-app.sh` stamp the same pair without a second
file to edit. `FOLIO_VERSION` / `FOLIO_BUILD` override the CLI build; CI uses that to put the
workflow run number into its ad-hoc artifacts. CI runs `check-version.sh` on every push.

## 2. Archive and notarize in Xcode

```bash
open Folio.xcodeproj
```

1. Scheme **Folio** → *Product → Archive*.
2. Organizer → *Distribute App → Developer ID → Upload* (wait for «Notarization succeeded»).
3. *Export* the notarized app into `dist/Folio.app`, replacing the previous bundle — the packaging
   step reads the app from there.

The archive embeds PDFium, the Rust core and `ru.lproj`, and signs everything with the team's
Developer ID and the hardened runtime, then staples the ticket. Only arm64 is built
(`EXCLUDED_ARCHS[sdk=macosx*] = x86_64`) because PDFium and the Rust core are arm64-only.

## 3. Package and verify from the terminal

```bash
./scripts/package-release.sh 1.2.2
```

The script fails instead of producing a bad asset when:

- the bundle is not signed with a **Developer ID Application** certificate (an ad-hoc
  `build-app.sh` export, or a development-signed Xcode build);
- Gatekeeper does not accept it as `source=Notarized Developer ID`;
- the version or build number of the app differs from the project (a stale export);
- the stapled ticket does not survive the zip.

It writes `dist/Folio.app.zip` and `dist/Folio.app.zip.sha256`, and re-checks the unpacked archive
(version, `spctl`, `stapler validate`) — i.e. exactly what a user downloads.

## 4. Publish

Copy [`.github/release-notes.md`](../.github/release-notes.md), replace `{{VERSION}}`, `{{SHA256}}`
and `{{COMMIT}}`, add the «What's new» section, then:

```bash
gh release create v1.2.2 --title "Folio 1.2.2 — <theme>" --notes-file /tmp/release-notes-1.2.2.md \
    dist/Folio.app.zip dist/Folio.app.zip.sha256
# or create the release in the GitHub web UI and attach both files
```

Check the published release: the asset is the notarized zip, the SHA-256 in the notes matches
`dist/Folio.app.zip.sha256`, and `v1.2.2` is marked as the latest release.

## Notes

- Keep the app version and the tag equal: `v1.2.2` ↔ `1.2.2`; `check-version.sh 1.2.2` verifies it.
- The release asset is always the Xcode archive, repacked from `dist/Folio.app`. The CI artifact
  (`Folio-app-<run>`) and any `build-app.sh` bundle are ad-hoc signed and are **not** release assets.
- No secrets or certificates live in the repository; the Developer ID identity stays in the local
  keychain and is used only by Xcode during *Distribute App*. If a Developer ID and `notarytool`
  credentials ever become available to the terminal, `scripts/build-app.sh` can sign, notarize and
  staple on its own (`FOLIO_SIGN_IDENTITY`, `FOLIO_NOTARIZE=1`, `FOLIO_NOTARY_PROFILE`) — that would
  replace steps 2–3, but it is not the case today.
