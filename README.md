<p align="center">
  <picture>
    <source media="(prefers-color-scheme: dark)" srcset="assets/sala_full_dark.png">
    <img src="assets/sala_full_light.png" width="200" alt="Sala">
  </picture>
</p>

<p align="center">An unofficial iOS app for <a href="https://www.aula.dk">Aula</a>, the Danish school and daycare platform.</p>

> [!WARNING]
> Sala is a work in progress and very much vibe coded. It comes with no guarantees of any kind: use it at your own risk.
>
> Sala may not be sold, rented or used commercially. See [License](#license).
>
> Sala is an independent hobby project. It is in no way associated with, affiliated with, endorsed by or supported by Aula, KOMBIT, Netcompany, the municipalities, schools or daycares that use Aula, or anyone else.

## What it does

- **Today**: each child's status (present, sick, gone home, ...), pickup time and who picks up, closing time, holiday requests and messages that need an answer, upcoming events and posts.
- **Pickup and sick**: set the pickup time, report a child sick.
- **Holidays**: answer the institution's holiday requests.
- **Calendar**: Aula's calendar, optionally synced to the iOS Calendar.
- **Messages**: threads, replies (to everyone or only the sender), and your own folders.
- **Gallery**: albums and photos.
- **Widget**: status, pickup time and closing time on the Home Screen.

Sala has no server. The app talks to Aula directly from the phone, and you log in with MitID inside the app. Your Aula session stays in the device's Keychain.

The Aula calls began as a Swift port of a small Python server built on [`aula`](https://github.com/nickknissen/aula) (`nickknissen/aula`), a Python API wrapper for Aula. Thanks to its authors for working out how Aula's API behaves.

## Building

Requires Xcode with the iOS 26 SDK and [XcodeGen](https://github.com/yonaskolb/XcodeGen).

1. Copy `ios/Config/Local.example.xcconfig` to `ios/Config/Local.xcconfig` (gitignored) and set your `DEVELOPMENT_TEAM` and a `SALA_BUNDLE_ID` your team can register. A free personal team works: the app and widget share data through a keychain access group, not an app group. Simulator builds need this too, since an unsigned build has no Keychain access.
2. Open `ios/Sala.xcodeproj` and run, or install on a connected phone with `ios/scripts/install-device.sh "<device name>"`.

`ios/project.yml` is the source of truth for the Xcode project. `ios/Sala.xcodeproj` is generated from it and committed, so run `xcodegen generate` in `ios/` after changing the spec.

## Tests

```sh
cd ios && xcodebuild test -project Sala.xcodeproj -scheme Sala -destination 'platform=iOS Simulator,name=<an iPhone simulator>'
```

## Docs

- [`API.md`](API.md): the in-app routes between the views and Aula.
- [`docs/aula-shapes/`](docs/aula-shapes/): where fields sit in Aula's responses, captured from real Aula and anonymised.

## License

[PolyForm Noncommercial 1.0.0](LICENSE). You may use, change and share Sala for noncommercial purposes only. You may not sell it, rent it, charge for access to it, or use it in any other commercial way. Commercial rights are reserved to the copyright holder.
