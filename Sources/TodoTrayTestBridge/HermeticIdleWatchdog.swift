import AppKit
import Foundation

/// Terminates a hermetic DEBUG-automation app that nothing is driving any more.
///
/// T-1648. Every hermetic run copies the app into a throwaway
/// `<App>-DebugAutomation-<suffix>.app` bundle under `/private/tmp` and
/// launches it detached, so the copy survives its launcher. Tidying it up was
/// entirely EXTERNAL work, and both external mechanisms have the same hole:
///
///   * the launcher's EXIT trap does not run when the owning shell is
///     SIGKILLed, which on this project is the ordinary way a run ends (the
///     Stop button, an app restart, a stray Esc from the harness); and
///   * `ui_reap_stale_e2e_runs` in `scripts/lib/e2e_ui_guard.sh` was written to
///     cover exactly that, but it runs at the START OF THE NEXT RUN — so if
///     there is no next run, nothing ever reaps.
///
/// On 2026-09-07 four TodoTray copies launched between 21:37 and 21:52 were
/// still running at 07:10 the next morning, each with a valid owner stamp
/// naming a long-dead shell. They were perfectly reapable; nobody ran a sweep.
/// The leak window was not "until the next run" — it was unbounded.
///
/// So the app owns its own lifetime. Nothing external is required, and it
/// works under SIGKILL of every process that launched it.
///
/// "Being driven" is deliberately defined by OBSERVED INPUT rather than by a
/// live owner pid. The documented agent workflow launches the app in one tool
/// call and drives it from later ones, so the launching shell is routinely dead
/// while the app is very much in use; keying on the owner would kill exactly
/// the sessions that are working. Activity is therefore any `DebugBridge`
/// request (probes, checkpoints, health) or any key/mouse event the app
/// receives — which covers `todotray-ui-driver`, since it sends real CGEvents that arrive
/// as ordinary `NSEvent`s.
public final class HermeticIdleWatchdog: @unchecked Sendable {
    public static let shared = HermeticIdleWatchdog()

    /// Seconds of inactivity before a hermetic app terminates itself.
    /// `0` (or any non-positive value) disables the watchdog for that run.
    public static let timeoutEnvironmentKey = "E2E_HERMETIC_IDLE_TIMEOUT_SECONDS"

    /// 30 minutes. Long enough that an agent reading source between two drives
    /// is never interrupted, short enough that "left running overnight" cannot
    /// happen. Relaunching costs about a minute; the leak cost 9.5 hours.
    public static let defaultTimeoutSeconds: TimeInterval = 1800

    /// How long the watchdog waits for a polite `terminate(_:)` before ending
    /// the process outright. A hermetic copy has no user data to lose — its
    /// whole support tree is a throwaway — so a hung teardown must not be able
    /// to reinstate the very leak this exists to stop.
    public static let terminationGraceSeconds: TimeInterval = 15

    /// The launch argument every hermetic run carries. Both apps' automation
    /// policies refuse to start without it, and no installed app is ever
    /// launched with it.
    public static let hermeticLaunchArgument = "--debug-automation"

    public enum Verdict: Equatable, Sendable {
        case keepRunning
        case terminate
    }

    private let lock = NSLock()
    private var lastActivity = Date()
    private var timer: DispatchSourceTimer?
    private var eventMonitor: Any?
    private var isRunning = false

    private init() {}

    // MARK: - Pure decisions (unit-pinned)

    /// `nil` means "no watchdog for this run" — an explicit non-positive value,
    /// or a value that is not a number at all. An ABSENT variable is the
    /// ordinary case and yields the default: the protection has to be on by
    /// default, or a launcher that forgets to export it leaks exactly as before.
    public static func timeoutSeconds(from environment: [String: String]) -> TimeInterval? {
        guard let raw = environment[timeoutEnvironmentKey]?
            .trimmingCharacters(in: .whitespacesAndNewlines),
            !raw.isEmpty
        else {
            return defaultTimeoutSeconds
        }
        guard let value = TimeInterval(raw) else { return nil }
        return value > 0 ? value : nil
    }

    /// The whole termination decision, with no clock and no process state, so
    /// both directions can be pinned.
    public static func verdict(idleSeconds: TimeInterval, timeoutSeconds: TimeInterval) -> Verdict {
        guard timeoutSeconds > 0 else { return .keepRunning }
        return idleSeconds >= timeoutSeconds ? .terminate : .keepRunning
    }

    /// Whether this process really is one of the launchers' throwaway copies.
    ///
    /// Codex on PR #225, and it was right: the first version asked whether the
    /// executable path CONTAINED `-DebugAutomation-`, which an installed app
    /// satisfies by sitting anywhere under a directory somebody named that way,
    /// or by being renamed `TodoTray-DebugAutomation-backup.app`. This code
    /// compiles into release builds and can end a process, so "probably
    /// hermetic" is not good enough.
    ///
    /// Three independent signals now, all of them minted by the launchers and
    /// none reachable by an ordinary installed app:
    ///
    ///  1. the executable sits at `<something>.app/Contents/MacOS/<name>`;
    ///  2. that `.app` component is named exactly the way the launchers name
    ///     it — `<App>-DebugAutomation-<hex>.app`, the hex being the run's own
    ///     domain suffix (`scripts/launch_*_debug_automation.sh`), which is
    ///     also the shape `ui_reap_stale_e2e_runs` matches;
    ///  3. the process carries `--debug-automation`, without which both apps'
    ///     automation policies refuse to start at all.
    ///
    /// A renamed backup fails 2 (no hex run id) and 3. A real app under an
    /// unluckily named parent directory fails 2 and 3.
    public static func isHermeticBundle(
        executablePath: String,
        arguments: [String] = CommandLine.arguments,
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> Bool {
        guard arguments.contains(hermeticLaunchArgument) else { return false }
        // Absolute only. Everything below reasons about path components, and a
        // relative path cannot be compared with the support root, so it fails
        // closed rather than being resolved against an unknown directory.
        guard executablePath.hasPrefix("/") else { return false }
        let components = executablePath.split(separator: "/", omittingEmptySubsequences: true)
        // …/<bundle>.app/Contents/MacOS/<executable>
        guard components.count >= 4 else { return false }
        guard components[components.count - 2] == "MacOS",
              components[components.count - 3] == "Contents"
        else { return false }
        guard isHermeticBundleName(String(components[components.count - 4])) else { return false }

        // Codex on PR #225, third round, and the reason the earlier signals were
        // not enough: `--debug-automation` is only ENFORCED in a DEBUG build.
        // `TodoTrayDebugAutomationPolicy` is `#if DEBUG`, so in a release binary
        // that argument is an unchecked string and the gate leans almost
        // entirely on the bundle's name — which somebody can produce by copying
        // a release app and renaming it.
        //
        // These two are minted by the launcher for the run and cannot be
        // satisfied by an ordinary launch of an installed app: the throwaway
        // bundle is created INSIDE the run's own support directory, and the run
        // is given a defaults domain in the DEBUG-only namespace.
        let parent = components[..<(components.count - 3)].dropLast()
        let bundleParent = "/" + parent.joined(separator: "/")
        guard supportDirectoryEnvironmentKeys.contains(where: { key in
            guard let raw = environment[key]?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !raw.isEmpty
            else { return false }
            return canonicalPath(raw) == canonicalPath(bundleParent)
        }) else { return false }

        return defaultsDomainEnvironmentKeys.contains { key in
            environment[key]?.contains(hermeticDefaultsDomainMarker) == true
        }
    }

    /// Where each launcher puts the run's throwaway bundle. The copy lives
    /// directly inside this directory (`scripts/launch_*_debug_automation.sh`),
    /// so "the bundle's parent is the support root this process was given" is a
    /// fact only the launcher can arrange.
    public static let supportDirectoryEnvironmentKeys = [
        "TODOTRAY_SUPPORT_DIR",
        "SCREENSHOTTRAY_SUPPORT_DIR",
    ]

    /// The per-run throwaway defaults domain, e.g.
    /// `com.trulyuseful.TodoTray.debugAutomation.d<hex>`. Both apps' automation
    /// policies refuse a domain outside this namespace, and no shipping launch
    /// sets one at all.
    public static let defaultsDomainEnvironmentKeys = [
        "TODOTRAY_DEBUG_DEFAULTS_DOMAIN",
        "SCREENSHOTTRAY_DEBUG_DEFAULTS_DOMAIN",
    ]

    static let hermeticDefaultsDomainMarker = ".debugAutomation."

    private static func canonicalPath(_ path: String) -> String {
        URL(fileURLWithPath: path).standardizedFileURL.resolvingSymlinksInPath().path
    }

    /// Where this process is really running from.
    ///
    /// `Bundle.main.executableURL` rather than `argv[0]`: the gate now checks
    /// the exact `.app/Contents/MacOS/…` tail, and argv[0] is whatever the
    /// launcher chose to pass — a relative path or a symlink would read as "not
    /// hermetic" and silently disarm the watchdog, which is the leak coming
    /// back. Symlinks are resolved for the same reason.
    public static func currentExecutablePath() -> String {
        if let url = Bundle.main.executableURL {
            return url.resolvingSymlinksInPath().path
        }
        return ProcessInfo.processInfo.arguments.first ?? ""
    }

    /// `<App>-DebugAutomation-<hex>.app`, written out rather than regex'd so
    /// the rule reads the same as the shell glob it mirrors.
    static func isHermeticBundleName(_ name: String) -> Bool {
        guard name.hasSuffix(".app") else { return false }
        let stem = name.dropLast(".app".count)
        guard let markerRange = stem.range(of: "-DebugAutomation-") else { return false }
        let app = stem[stem.startIndex ..< markerRange.lowerBound]
        let runIdentifier = stem[markerRange.upperBound...]
        guard !app.isEmpty, app.allSatisfy({ $0.isLetter || $0.isNumber }) else { return false }
        guard !runIdentifier.isEmpty,
              runIdentifier.allSatisfy({ $0.isHexDigit && !$0.isUppercase })
        else { return false }
        return true
    }

    // MARK: - Activity

    /// Record that something is driving this app. Cheap, lock-guarded, and safe
    /// from any thread — the bridge calls it from its own network queue and the
    /// event monitor calls it from the main thread.
    public func noteActivity(now: Date = Date()) {
        lock.lock()
        lastActivity = now
        lock.unlock()
    }

    public func idleSeconds(now: Date = Date()) -> TimeInterval {
        lock.lock()
        let last = lastActivity
        lock.unlock()
        // A backwards clock reads as "just active", never as a huge idle span.
        return max(0, now.timeIntervalSince(last))
    }

    // MARK: - Lifecycle

    /// Arm the watchdog if this really is a hermetic run. A no-op otherwise, and
    /// a no-op on a second call.
    ///
    /// `terminate` is injectable so the tests can drive the whole loop without
    /// ending the test process.
    @discardableResult
    public func startIfHermetic(
        executablePath: String = HermeticIdleWatchdog.currentExecutablePath(),
        arguments: [String] = CommandLine.arguments,
        environment: [String: String] = ProcessInfo.processInfo.environment,
        pollInterval: TimeInterval = 30,
        installsEventMonitor: Bool = true,
        now: @escaping @Sendable () -> Date = Date.init,
        terminate: (@Sendable () -> Void)? = nil
    ) -> Bool {
        guard Self.isHermeticBundle(
            executablePath: executablePath,
            arguments: arguments,
            environment: environment
        ) else {
            return false
        }
        guard let timeout = Self.timeoutSeconds(from: environment) else { return false }

        lock.lock()
        if isRunning {
            lock.unlock()
            return false
        }
        isRunning = true
        lastActivity = now()
        lock.unlock()

        let fire = terminate ?? { Self.terminateCurrentProcess() }
        let timer = DispatchSource.makeTimerSource(
            queue: DispatchQueue(label: "com.trulyuseful.hermetic-idle-watchdog")
        )
        timer.schedule(deadline: .now() + pollInterval, repeating: pollInterval)
        timer.setEventHandler { [weak self] in
            guard let self else { return }
            let idle = idleSeconds(now: now())
            guard Self.verdict(idleSeconds: idle, timeoutSeconds: timeout) == .terminate else {
                return
            }
            self.timer?.cancel()
            self.timer = nil
            NSLog(
                "HermeticIdleWatchdog: no activity for %.0fs (limit %.0fs) — terminating this throwaway automation app",
                idle,
                timeout
            )
            fire()
        }
        timer.resume()
        self.timer = timer

        if installsEventMonitor {
            installEventMonitor()
        }
        return true
    }

    /// Real key/mouse input arriving at this app counts as being driven — this
    /// is what makes an `todotray-ui-driver` run, which never touches the bridge, keep the
    /// app alive.
    private func installEventMonitor() {
        let mask: NSEvent.EventTypeMask = [
            .keyDown, .flagsChanged,
            .leftMouseDown, .leftMouseUp, .rightMouseDown, .rightMouseUp,
            .otherMouseDown, .otherMouseUp,
            .leftMouseDragged, .rightMouseDragged, .otherMouseDragged,
            .mouseMoved, .scrollWheel,
        ]
        let monitor = NSEvent.addLocalMonitorForEvents(matching: mask) { [weak self] event in
            self?.noteActivity()
            return event
        }
        lock.lock()
        eventMonitor = monitor
        lock.unlock()
    }

    /// Ask AppKit to shut down cleanly, then insist. `applicationWillTerminate`
    /// is where both apps flush their state, so the polite path is tried first;
    /// but a hermetic copy that refuses to quit is the leak, so the grace timer
    /// is unconditional.
    private static func terminateCurrentProcess() {
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + terminationGraceSeconds) {
            NSLog("HermeticIdleWatchdog: graceful termination did not finish — exiting")
            exit(0)
        }
        DispatchQueue.main.async {
            NSApplication.shared.terminate(nil)
        }
    }

    // MARK: - Testing

    public func stopForTesting() {
        lock.lock()
        timer?.cancel()
        timer = nil
        isRunning = false
        let monitor = eventMonitor
        eventMonitor = nil
        lock.unlock()
        if let monitor {
            NSEvent.removeMonitor(monitor)
        }
    }
}
