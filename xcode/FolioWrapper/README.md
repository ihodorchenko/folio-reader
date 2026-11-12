# FolioWrapper — Xcode wrapper for managed Developer ID signing

This is **not** the app build. It is a tiny Xcode target whose only job is to let Xcode's
*Distribute App → Developer ID* flow sign and notarize the real `dist/Folio.app` produced by
`scripts/build-app.sh`.

Why it exists: with Xcode-managed certificates (`Developer ID Application Managed`) the private key
lives inside Xcode and is not visible to `codesign`/`notarytool` from the command line. The wrapper
target assembles `dist/Folio.app` in its product bundle (see `Scripts/embed-folio.sh`), so Xcode can
re-sign the whole bundle with the managed Developer ID and notarize it.

The project uses the Xcode 27 JSON format (`project.xcproj`, no `project.pbxproj`) — see
[`docs/xcode-27-project-format.md`](../../docs/xcode-27-project-format.md).

## Usage

```bash
./scripts/build-app.sh                     # build the real bundle first
open xcode/FolioWrapper/FolioWrapper.xcodeproj
```

Then in Xcode: scheme **Folio** → *Product → Archive* → Organizer → *Distribute App → Developer ID →
Upload* → export the notarized `Folio.app`.

The wrapper hard-codes `DEVELOPMENT_TEAM = 8885WMRK5B`; change it in
`FolioWrapper.xcodeproj/project.xcproj` (and `Scripts/embed-folio.sh` stays identity-agnostic) if you
use another team. Keep `MARKETING_VERSION` / `CURRENT_PROJECT_VERSION` in sync with
`app/Bundle/Info.plist` when bumping the version.
