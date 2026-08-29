# Contributing

Thanks for helping out. A few things that are specific to this project:

- `project.yml` is the source of truth. `CADQuickLook.xcodeproj` is generated
  and git-ignored: run `xcodegen generate` after editing `project.yml`, and
  never commit the project file.
- Build and run with `./script/build_and_run.sh`, install the app and its Quick
  Look extensions into `~/Applications` with `./script/install.sh`. See the
  README for the Homebrew prerequisites and the `DEVELOPMENT_TEAM` note.
- The C++ bridge in `CADQuickLook/Bridge` is the only place Open CASCADE is
  used. Keep the Swift side free of OCCT types.
- Everything under `Shared/` is compiled into the app and both extensions, so
  it must stay sandbox-safe and must not depend on AppKit windows.
- Swift 6 strict concurrency is on; the build must have no warnings in files
  you touch.
- Keep pull requests focused. Describe what you tested (which sample files,
  app vs. Quick Look) in the description.

Bug reports with a sample file that reproduces the problem are the most
useful kind.
