import AppKit
import Foundation
import Network

/// Which app is hosting the bridge for this process.
///
/// The bridge itself is app-agnostic transport; everything that differs between
/// ScreenshotTray and TodoTray — the opt-in variable, where the port file lands,
/// the log prefix, the release-configuration gate — arrives through this value.
///
/// It exists because the two apps are two processes with two support trees. A
/// single hard-coded `SCREENSHOTTRAY_DEBUG_BRIDGE` + `debug-bridge.port` pair
/// cannot describe both, and a harness that guesses would happily read a stale
/// port file written by the *other* app and report every probe as unreachable —
/// which reads as a passing run rather than a failing one.
public struct DebugBridgeHost: Sendable {
    /// Used in log lines so two bridges are distinguishable in Console.
    public let label: String
    /// Environment variable that opts a DEBUG build in.
    public let environmentKey: String
    /// File name written inside `supportDirectory` once the listener is ready.
    public let portFileName: String
    /// The app's support directory — already honours that app's harness
    /// override, so the port file moves with the rest of the hermetic tree.
    public let supportDirectory: @MainActor @Sendable () -> URL
    /// True for a fully-authorised RELEASE performance-harness launch, which is
    /// the only way a shipping binary answers anything (read-only surface only).
    public let allowsReleaseReadOnlySurface: @MainActor @Sendable () -> Bool
    /// Called on the main actor once the listener is ready, before the port
    /// file is written. Launch instrumentation hooks in here.
    public let didBecomeReady: @MainActor @Sendable () -> Void

    public init(
        label: String,
        environmentKey: String,
        portFileName: String,
        supportDirectory: @escaping @MainActor @Sendable () -> URL,
        allowsReleaseReadOnlySurface: @escaping @MainActor @Sendable () -> Bool = { false },
        didBecomeReady: @escaping @MainActor @Sendable () -> Void = {}
    ) {
        self.label = label
        self.environmentKey = environmentKey
        self.portFileName = portFileName
        self.supportDirectory = supportDirectory
        self.allowsReleaseReadOnlySurface = allowsReleaseReadOnlySurface
        self.didBecomeReady = didBecomeReady
    }

    /// A host that can never be enabled. The default, so a process that forgets
    /// to configure one exposes nothing rather than defaulting to another app's
    /// variable.
    public static let inert = DebugBridgeHost(
        label: "unconfigured",
        environmentKey: "",
        portFileName: "unconfigured-debug-bridge.port",
        supportDirectory: { URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true) }
    )
}

/// Loopback HTTP introspection bridge for end-to-end testing.
///
/// Why this exists: the app's unit / ViewInspector / pixel tests check code in
/// isolation. They keep passing while the *running* app misbehaves — a real
/// file gets the wrong extension on ingest, the wrong preferences row reads as
/// selected, etc. (B239, B244 and friends all shipped green.) The bridge lets
/// an external test harness ask the *live* process what its real runtime state
/// is, then assert on that instead of re-deriving the answer in a unit test.
///
/// It is **off by default** and only ever starts when the host's environment
/// variable is set, and only in DEBUG builds. It binds to `127.0.0.1` (loopback
/// only — never reachable off-machine) on an OS-assigned port, and writes that
/// port to the host's port file inside its support directory so the test
/// harness can find it without guessing.
///
/// It is a package of its own, depending on nothing beyond AppKit, Foundation
/// and Network, because the guarantees below — not the socket — are the
/// interesting part, and an app that had to reimplement them would get them
/// wrong. Every app that links it shares this one copy; a second copy would be
/// free to disagree with it.
///
/// Probes are registered by subsystems via `register(_:_:)` and return a plain
/// JSON-serialisable dictionary. Each probe runs on the main actor so it can
/// read view-model / AppKit state safely.
///
/// Companion: `todotray-ui-driver`, which ships inside TodoTray and drives the
/// same running app through the Accessibility API. Its `doctor` verb asks this
/// bridge for the probes `TodoTrayTestBridgeContract` requires.
@MainActor
public final class DebugBridge {
    public static let shared = DebugBridge()

    /// The route every probe answers on: `GET /probe/<name>`. Public so a
    /// client can read it instead of restating it.
    public nonisolated static let probeRoutePrefix = "/probe/"

    /// A probe maps decoded query parameters to a JSON-serialisable result.
    ///
    /// `async` so a probe may await the same durable barriers the MCP tools
    /// await (TODOTRAY-4V). A synchronous closure literal still satisfies this
    /// type, so every existing probe registration is unchanged.
    public typealias Probe = (_ query: [String: String]) async -> [String: Any]

    // MARK: - Read-only vs mutating probe surfaces

    //
    // 6a Phase 0 / plan §5 needs RELEASE-configuration timings, which means a
    // shipping binary has to answer the milestone and trace-counter probes. A
    // shipping binary must NOT be able to mutate anything through the bridge.
    //
    // The two surfaces are therefore distinct NOMINAL TYPES, not a naming
    // convention: `registerReadOnlySurface` accepts only `[ReadOnlyProbe]`, so
    // handing it a `MutatingProbe` is a compile error at the registration site.
    // That makes "is this probe allowed in Release?" a property the compiler
    // checks. The remaining gap — a probe wrongly DECLARED read-only — is the
    // app's to close, with a test that invokes every read-only probe against
    // seeded state and asserts the files on disk and the in-memory model come
    // back byte-identical.

    /// A probe that cannot change user data, app state, or on-screen UI.
    /// Answering it twice must leave the process indistinguishable from
    /// answering it zero times.
    public struct ReadOnlyProbe {
        public let name: String
        public let run: Probe

        public init(_ name: String, _ run: @escaping Probe) {
            self.name = name
            self.run = run
        }
    }

    /// A probe that changes something — user data, app state, window state, or
    /// diagnostic counters. DEBUG builds only, always.
    public struct MutatingProbe {
        public let name: String
        public let run: Probe

        public init(_ name: String, _ run: @escaping Probe) {
            self.name = name
            self.run = run
        }
    }

    private var probes: [String: Probe] = [:]
    public private(set) var readOnlyProbeNames: Set<String> = []
    public private(set) var mutatingProbeNames: Set<String> = []
    private var listener: NWListener?
    private let queue = DispatchQueue(label: "com.trulyuseful.TodoTrayTestBridge.debugBridge")

    private init() {}

    // MARK: - Host

    /// The app hosting this process's bridge. Set once, as early in launch as
    /// possible — `isEnabled` is read from view bodies, so a late configure
    /// would report "off" to something that runs before it.
    public private(set) static var host: DebugBridgeHost = .inert

    public static func configure(host: DebugBridgeHost) {
        self.host = host
    }

    /// Test seam: put the host back to its unconfigured state.
    public static func resetHostForTesting() {
        host = .inert
    }

    /// Whether the bridge should run for this launch.
    ///
    /// DEBUG: opt in with the host's environment variable.
    ///
    /// RELEASE: only for a fully-authorised performance-harness launch — see
    /// `DebugBridgeHost.allowsReleaseReadOnlySurface`, which requires the
    /// launch argument AND the harness token AND a support-directory redirect
    /// that was actually accepted (so the process is already reading a fixture
    /// and not the user's queue). Plan §5 requires Release builds for timings,
    /// and a DEBUG Swift build's performance is not a proxy for the shipped
    /// product — but only the READ-ONLY surface is registered there (see
    /// `startIfEnabled`), so a shipping binary cannot be driven, only read.
    ///
    /// No single mis-set variable reaches this: all three signals are needed,
    /// and a real user launching from Finder/Dock/login item supplies none.
    public static var isEnabled: Bool {
        #if DEBUG
            let key = host.environmentKey
            if !key.isEmpty, ProcessInfo.processInfo.environment[key] == "1" { return true }
            return host.allowsReleaseReadOnlySurface()
        #else
            return host.allowsReleaseReadOnlySurface()
        #endif
    }

    /// True when this process may register the mutating probe surface.
    /// A shipping binary never can, under any environment.
    public static var allowsMutatingProbes: Bool {
        #if DEBUG
            return true
        #else
            return false
        #endif
    }

    // MARK: - Registration

    /// Register a probe under `name`, reachable at `GET /probe/<name>`.
    /// Re-registering the same name replaces the previous probe.
    ///
    /// DEBUG-era convenience that keeps every existing probe registration
    /// compiling unchanged. It records the probe as MUTATING, because "unknown"
    /// must default to the restrictive side — an unclassified probe can never
    /// leak into the Release surface by omission.
    public func register(_ name: String, _ probe: @escaping Probe) {
        // Structural backstop, not an audit. Any call site that has not been
        // classified is refused in Release rather than trusted — otherwise a
        // single `register(...)` elsewhere in the app (AppDelegate registers
        // `agentBridge` this way) silently widens the shipping surface, which
        // is exactly what happened the first time this was tested live.
        guard Self.allowsMutatingProbes else {
            NSLog("%@ DebugBridge: refused unclassified probe '%@' in a release build", Self.host.label, name)
            return
        }
        probes[name] = probe
        mutatingProbeNames.insert(name)
        readOnlyProbeNames.remove(name)
    }

    /// The ONLY surface a shipping binary may expose. Takes `ReadOnlyProbe`
    /// values, so a `MutatingProbe` fails to compile here.
    public func registerReadOnlySurface(_ surface: [ReadOnlyProbe]) {
        for probe in surface {
            probes[probe.name] = probe.run
            readOnlyProbeNames.insert(probe.name)
            mutatingProbeNames.remove(probe.name)
        }
    }

    /// DEBUG-only surface.
    public func registerMutatingSurface(_ surface: [MutatingProbe]) {
        for probe in surface {
            probes[probe.name] = probe.run
            mutatingProbeNames.insert(probe.name)
            readOnlyProbeNames.remove(probe.name)
        }
    }

    /// Drop every registration. Test seam — the registry is a singleton and a
    /// surface test must be able to start from empty.
    public func resetRegistryForTesting() {
        probes.removeAll()
        readOnlyProbeNames.removeAll()
        mutatingProbeNames.removeAll()
    }

    /// Run a registered probe directly, bypassing HTTP. Test seam for the
    /// registry-enumeration test.
    public func runProbeForTesting(_ name: String, query: [String: String] = [:]) async -> [String: Any]? {
        guard let probe = probes[name] else { return nil }
        return await probe(query)
    }

    // MARK: - Lifecycle

    /// Start listening on loopback. Safe to call once from
    /// `applicationDidFinishLaunching`; a no-op when disabled or already
    /// running. `registerSurfaces` is invoked only when the bridge really
    /// starts, and is handed `allowsMutating` so the caller registers the
    /// read-only surface alone in a Release perf-harness launch.
    public func startIfEnabled(registerSurfaces: (_ allowsMutating: Bool) -> Void) {
        guard Self.isEnabled, listener == nil else { return }
        // Drop any port file left by a previous run BEFORE binding. A stale one
        // is worse than none: the harness reads it, curls a dead port, and every
        // probe reports "bridge unreachable" — which reads as a passing run
        // rather than a failing one. Removing it first makes the file's presence
        // mean exactly one thing: *this* process is listening on *that* port.
        // The file is only rewritten once the listener reports .ready, so the
        // harness can poll for it as a readiness signal (app launch can take
        // ~100s, well past any fixed sleep).
        try? FileManager.default.removeItem(at: Self.portFileURL)
        registerSurfaces(Self.allowsMutatingProbes)
        do {
            let params = NWParameters.tcp
            // Loopback-only: bind explicitly to 127.0.0.1 so the socket is never
            // exposed on any external interface.
            params.requiredLocalEndpoint = NWEndpoint.hostPort(host: "127.0.0.1", port: .any)
            let listener = try NWListener(using: params)
            self.listener = listener
            listener.stateUpdateHandler = { [weak self] state in
                if case .ready = state, let port = listener.port {
                    let portValue = port.rawValue
                    Task { @MainActor [weak self] in
                        Self.host.didBecomeReady()
                        self?.writePortFile(portValue)
                        NSLog("%@ DebugBridge: listening on 127.0.0.1:%d", Self.host.label, portValue)
                    }
                }
            }
            listener.newConnectionHandler = { [weak self] connection in
                Task { @MainActor [weak self] in
                    self?.handle(connection)
                }
            }
            listener.start(queue: queue)
        } catch {
            NSLog("%@ DebugBridge: failed to start: %@", Self.host.label, error.localizedDescription)
        }
    }

    // MARK: - Connection handling

    private func handle(_ connection: NWConnection) {
        connection.start(queue: queue)
        connection.receive(minimumIncompleteLength: 1, maximumLength: 16 * 1024) { [weak self] data, _, _, error in
            guard let data, !data.isEmpty, error == nil else {
                connection.cancel()
                return
            }
            // T-1648: a probe is somebody driving this app. Recorded before the
            // request is even parsed, so a malformed one still counts.
            HermeticIdleWatchdog.shared.noteActivity()
            let request = String(decoding: data, as: UTF8.self)
            // First line is "GET /path?query HTTP/1.1"
            let firstLine = request.split(separator: "\r\n", maxSplits: 1).first.map(String.init) ?? ""
            let parts = firstLine.split(separator: " ")
            // Probe execution touches main-actor state — hop to the main actor,
            // build the JSON, then reply.
            Task { @MainActor [weak self] in
                guard let self else { connection.cancel(); return }
                guard parts.count >= 2 else {
                    respond(connection, status: "400 Bad Request", json: ["ok": false, "error": "bad request"])
                    return
                }
                let target = String(parts[1])
                let result = await route(target)
                respond(connection, status: "200 OK", json: result)
            }
        }
    }

    /// Resolve `GET /probe/<name>?k=v` against the registry.
    private func route(_ target: String) async -> [String: Any] {
        guard let comps = URLComponents(string: "http://127.0.0.1\(target)") else {
            return ["ok": false, "error": "bad target"]
        }
        let path = comps.path
        if path == "/probe" || path == "/probes" {
            return ["ok": true, "probes": probes.keys.sorted()]
        }
        guard path.hasPrefix(Self.probeRoutePrefix) else {
            return ["ok": false, "error": "unknown path", "path": path]
        }
        let name = String(path.dropFirst(Self.probeRoutePrefix.count))
        guard let probe = probes[name] else {
            return ["ok": false, "error": "no probe named \(name)", "available": probes.keys.sorted()]
        }
        var query: [String: String] = [:]
        for item in comps.queryItems ?? [] {
            query[item.name] = item.value ?? ""
        }
        var result = await probe(query)
        if result["ok"] == nil { result["ok"] = true }
        // T-1596, Codex P1 on PR #222: every answer says WHICH process gave it.
        // A caller aiming `--pid` at one app and `--probe-base` at another would
        // otherwise take app A's accessibility tree together with app B's
        // "yes, I am hermetic" — and be told the pair is drivable.
        result["bridgePID"] = Int(getpid())
        return result
    }

    private func respond(_ connection: NWConnection, status: String, json: [String: Any]) {
        let body = (try? JSONSerialization.data(withJSONObject: json, options: [.prettyPrinted, .sortedKeys]))
            ?? Data("{\"ok\":false}".utf8)
        var head = "HTTP/1.1 \(status)\r\n"
        head += "Content-Type: application/json\r\n"
        head += "Content-Length: \(body.count)\r\n"
        head += "Connection: close\r\n\r\n"
        var payload = Data(head.utf8)
        payload.append(body)
        connection.send(content: payload, completion: .contentProcessed { _ in
            connection.cancel()
        })
    }

    // MARK: - Port discovery file

    /// Where this process advertises its port. Routed through the host's
    /// support directory so a hermetic harness override moves the port file
    /// together with the rest of the tree (identical path in normal runs).
    public static var portFileURL: URL {
        host.supportDirectory()
            .appendingPathComponent(host.portFileName, isDirectory: false)
    }

    private func writePortFile(_ port: UInt16) {
        let url = Self.portFileURL
        try? FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true
        )
        try? Data("\(port)".utf8).write(to: url)
    }
}
