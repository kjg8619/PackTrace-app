# Toolchain notes

PackTrace is developed with the **Command Line Tools only** (no Xcode):
Swift 6.4, macOS 27 SDK, target macOS 14. A few choices in the code follow from
that and are worth knowing before changing them.

| Choice | Why |
|---|---|
| SwiftPM package, no `.xcodeproj` | `xcodebuild` needs Xcode. `scripts/` (`build.sh`, `test.sh`, `verify.sh`) are the real build and test gates. |
| `ObservableObject` + `@StateObject` + `@Published`, no `@State` / `@Observable` | The SDK's SwiftUI expects the `SwiftUIMacros` plugin, which the Command Line Tools do not ship (they have `libSwiftMacros`, `libObservationMacros`, `libTestingMacros`). View-local state lives in small `ObservableObject` models instead. Behaviour is the same. |
| Explicit Swift Testing plugin path | `swift test` does not find the testing macros on its own; `scripts/test.sh` passes `-Xswiftc -plugin-path -Xswiftc <CLT>/usr/lib/swift/host/plugins/testing`. XCTest is not available. |
| App bundle assembled by a script | SwiftPM has no bundle step; `scripts/make-app-bundle.sh` builds `dist/PackTrace.app`. |

With Xcode installed, `@State` and `@Observable` would work, but the code keeps
to the subset that builds with the Command Line Tools so both setups stay green.
CI builds with Xcode 27 (GitHub's `xcode-27` runner image, macOS 27); there
`scripts/test.sh` leaves the plugin path to Xcode.
Older Swift 6 toolchains are untested.
