# TodoTrayTestBridge

A small loopback HTTP server that lets an end-to-end test ask a running macOS app what it thinks. For example: which row is selected, whether the document is saved, or whether the app was launched in test mode. The answers come back as JSON.

Screenshots and the accessibility tree show what is on screen. They can't show what the app has concluded internally, and recomputing that inside a test only proves the test agrees with itself. A probe asks the process that is actually running.

It is the app-side half of `todotray-ui-driver`, the UI driver that ships inside TodoTray at `TodoTray.app/Contents/Helpers/todotray-ui-driver`. The bridge doesn't depend on the driver, and works with any client that can make an HTTP request.

## Add it

In `Package.swift`:

```swift
dependencies: [
    .package(url: "https://github.com/danmelbourne/todotray-test-bridge", from: "0.1.0"),
],
```

Then, in your app target's dependencies:

```swift
.product(name: "TodoTrayTestBridge", package: "todotray-test-bridge"),
```

In Xcode, choose **File › Add Package Dependencies…** and paste the same URL.

macOS 13 or later. It depends on nothing beyond AppKit, Foundation and Network.

## Wire it up

```swift
import AppKit
import TodoTrayTestBridge

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        DebugBridge.configure(host: DebugBridgeHost(
            label: "MyApp",
            environmentKey: "MYAPP_DEBUG_BRIDGE",
            portFileName: "debug-bridge.port",
            // Your app's support folder — the one your test mode redirects.
            supportDirectory: { MyAppPaths.supportDirectory }
        ))

        DebugBridge.shared.startIfEnabled { allowsMutating in
            DebugBridge.shared.registerReadOnlySurface([
                DebugBridge.ReadOnlyProbe(TodoTrayTestBridgeContract.hermeticLaunchProbeName) { _ in
                    ["enabled": MyAppPaths.isTestLaunch]
                },
                DebugBridge.ReadOnlyProbe("selection") { _ in
                    ["id": selectedItemID() ?? ""]
                },
            ])
            guard allowsMutating else { return }
            DebugBridge.shared.registerMutatingSurface([
                DebugBridge.MutatingProbe(TodoTrayTestBridgeContract.resetProbeName) { _ in
                    closeSheetsModalsAndPanels()
                    return [:]
                },
            ])
        }
    }
}
```

Launch a debug build with the variable set, then read the port and ask a question:

```bash
MYAPP_DEBUG_BRIDGE=1 ./MyApp.app/Contents/MacOS/MyApp &
PORT="$(cat "$SUPPORT_DIR/debug-bridge.port")"
curl -s "http://127.0.0.1:$PORT/probe/debug-automation-launch"
# {"bridgePID": 51234, "enabled": true, "ok": true}
```

## Routes

```
GET /probe            →  {"ok": true, "probes": ["debug-automation-launch", …]}
GET /probe/<name>     →  that probe's answer as JSON; query items are its arguments
```

Every answer carries `ok` and `bridgePID`, the process id of the process that answered. A client can then refuse an answer from a different process, such as a second copy of the app or a stale one. The route prefix is `DebugBridge.probeRoutePrefix`.

## What it guarantees

- **Loopback only.** It binds `127.0.0.1` on a port the OS chooses, so it can't be reached from another machine, and two copies never fight over a port.
- **Off unless asked.** A debug build answers only when the host's environment variable is `"1"`. A release build answers only when `allowsReleaseReadOnlySurface` says so, and then only to read-only probes.
- **The port file means one thing.** It is deleted at start and written only once the listener is accepting connections. If the file exists, this process is listening on that port.
- **Read-only and mutating are different types.** `registerReadOnlySurface` accepts only `ReadOnlyProbe` values, so a mutating probe in the release surface is a compile error. A probe added through the untyped `register(_:_:)` counts as mutating.

## The two probes a harness requires

| Probe | Answers | Why |
| --- | --- | --- |
| `debug-automation-launch` | `{"enabled": true}` when the app was launched in its test mode | Ask it before sending any input, so a run never drives an app that is showing somebody's real data |
| `ui-reset` | closes sheets, modals and preview panels | Call it during teardown, including when a run fails, so no dialog is left over somebody's screen |

From inside the app, `DebugBridge.shared.harnessConformance` reads what is actually registered and lists every missing probe with what to do about it. From outside, `todotray-ui-driver doctor --probe-base http://127.0.0.1:$PORT` asks the running bridge for the same probes.

## The idle watchdog

`HermeticIdleWatchdog.shared.startIfHermetic()` makes a throwaway test copy of an app quit itself after 30 minutes with nothing driving it. It follows TodoTray's own launcher conventions: a `<App>-DebugAutomation-<hex>.app` copy inside the run's support folder, launched with `--debug-automation`. In any other app it stays disarmed, and calling it does nothing.

## Versions

Tagged with semantic versions. Until `1.0.0`, a minor version may change the API.

## Licence

MIT. See [LICENSE](LICENSE).
