# CADQuickLook

A native macOS viewer for STEP, IGES, BREP, and STL files, with Finder thumbnails and interactive Quick Look previews.

## Features

- Perspective and orthographic views
- Onshape-style navigation and standard view snaps
- Automatic edge, diameter, face-area, and point-to-point measurements
- STEP assembly placement through Open CASCADE
- The same viewer and controls in the app and Quick Look

## Install

Download the latest build from [GitHub Releases](https://github.com/lflanagan/CADQuickLook/releases/latest), unzip it, and move `CADQuickLook.app` to Applications.

## Build

Requires an Apple silicon Mac, macOS 26, Xcode 26, Homebrew, and XcodeGen.

```sh
brew bundle
xcodegen generate
DEVELOPMENT_TEAM=YOUR_TEAM_ID ./script/build_and_run.sh --verify
./script/install.sh
```

Development builds link against Homebrew's Open CASCADE libraries. Release archives bundle them.

Maintainers can create a signed archive with:

```sh
SIGNING_IDENTITY="Developer ID Application: …" ./script/package_release.sh
```

Parasolid and other proprietary CAD formats require a licensed translator.

## License

MIT. Open CASCADE and bundled libraries retain their respective licenses; see [third-party notices](THIRD_PARTY_NOTICES.md).
