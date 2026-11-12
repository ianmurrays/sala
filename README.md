<picture><source media="(prefers-color-scheme: dark)" srcset="assets/sala_full_dark.png"><img src="assets/sala_full_light.png" width="200" alt="Sala"></picture>

# sala

Created in [T3 Code](https://t3.codes).

## iOS app

`ios/project.yml` is the source of truth for the Xcode project; `ios/Sala.xcodeproj` is committed and generated from it, so run `xcodegen generate` in `ios/` after changing the spec.

To build for a device, copy `ios/Config/Local.example.xcconfig` to `ios/Config/Local.xcconfig` (gitignored) and set your `DEVELOPMENT_TEAM` and a `SALA_BUNDLE_ID` your team can register. A free personal team works: the app and widget share data through a keychain access group, not an app group. Simulator builds need no setup.

## License

[PolyForm Noncommercial 1.0.0](LICENSE)
