@testable import TodoTrayTestBridge
import XCTest

/// T-1648. Four TodoTray `-DebugAutomation-` copies were left running from
/// 21:37 the previous evening until 07:10 the next morning, because every
/// cleanup mechanism lived outside the app: the launcher's EXIT trap does not
/// run under SIGKILL, and `ui_reap_stale_e2e_runs` only runs at the start of
/// the NEXT run — of which there was none.
///
/// The invariant these pin: a throwaway hermetic app that nothing is driving
/// terminates itself, and an installed app never does.
final class T1648HermeticIdleWatchdogTests: XCTestCase {
    // MARK: - The bundle gate, in both directions

    private let hermeticArguments = ["/path/TodoTray", "--debug-automation"]
    private let todoSupport = "/private/tmp/todotray-debug-automation.psLVKY"
    private let screenshotSupport = "/private/tmp/st-live"

    /// What a real hermetic launch has in its environment: the run's own
    /// support root (the throwaway bundle lives inside it) and its throwaway
    /// defaults domain.
    private func hermeticEnvironment(
        support: String,
        key: String = "TODOTRAY_SUPPORT_DIR",
        timeout: String? = nil
    ) -> [String: String] {
        var environment = [
            key: support,
            "TODOTRAY_DEBUG_DEFAULTS_DOMAIN": "com.trulyuseful.TodoTray.debugAutomation.dabc123",
        ]
        if let timeout {
            environment[HermeticIdleWatchdog.timeoutEnvironmentKey] = timeout
        }
        return environment
    }

    func test_isHermeticBundle_acceptsOnlyThrowawayCopies() {
        XCTAssertTrue(HermeticIdleWatchdog.isHermeticBundle(
            executablePath: "/private/tmp/todotray-debug-automation.psLVKY/TodoTray-DebugAutomation-739413150b82460b2c3a97db.app/Contents/MacOS/TodoTray",
            arguments: hermeticArguments,
            environment: hermeticEnvironment(support: todoSupport)
        ))
        XCTAssertTrue(HermeticIdleWatchdog.isHermeticBundle(
            executablePath: "/private/tmp/st-live/ScreenshotTray-DebugAutomation-48c92609.app/Contents/MacOS/ScreenshotTray",
            arguments: hermeticArguments,
            environment: [
                "SCREENSHOTTRAY_SUPPORT_DIR": screenshotSupport,
                "SCREENSHOTTRAY_DEBUG_DEFAULTS_DOMAIN":
                    "com.trulyuseful.ScreenshotTray.debugAutomation.d48c92609",
            ]
        ))
    }

    /// The half that matters: this type can end a process, so an installed app
    /// must be unreachable by it however it is called.
    func test_isHermeticBundle_refusesInstalledApps() {
        for path in [
            "/Applications/TodoTray.app/Contents/MacOS/TodoTray",
            "/Applications/ScreenshotTray.app/Contents/MacOS/ScreenshotTray",
            "/Users/someone/Code/ScreenshotTray/.build/debug/ScreenshotTray",
            "",
        ] {
            XCTAssertFalse(
                HermeticIdleWatchdog.isHermeticBundle(
                    executablePath: path,
                    arguments: hermeticArguments,
                    environment: hermeticEnvironment(support: todoSupport)
                ),
                "must never arm against \(path)"
            )
        }
    }

    /// Codex on PR #225. The first version asked only whether the path
    /// CONTAINED `-DebugAutomation-`, which a real installed app satisfies by
    /// being renamed, or by sitting under an unluckily named parent directory.
    /// This code runs in release builds and can end a process, so each of these
    /// must be refused.
    func test_isHermeticBundle_refusesLookalikePaths() {
        for path in [
            // A backup somebody renamed: no hex run id.
            "/Applications/TodoTray-DebugAutomation-backup.app/Contents/MacOS/TodoTray",
            // A real app under a directory that merely looks the part.
            "/Users/someone/TodoTray-DebugAutomation-abc123/TodoTray.app/Contents/MacOS/TodoTray",
            // The marker in the executable's own name rather than the bundle's.
            "/Applications/TodoTray.app/Contents/MacOS/TodoTray-DebugAutomation-a1b2c3",
            // Right bundle name, wrong layout — not an app bundle at all.
            "/private/tmp/TodoTray-DebugAutomation-a1b2c3.app/TodoTray",
            // Upper-case run id: the launchers mint lower-case hex only.
            "/private/tmp/x/TodoTray-DebugAutomation-A1B2C3.app/Contents/MacOS/TodoTray",
            // No run id at all.
            "/private/tmp/x/TodoTray-DebugAutomation-.app/Contents/MacOS/TodoTray",
        ] {
            XCTAssertFalse(
                HermeticIdleWatchdog.isHermeticBundle(
                    executablePath: path,
                    arguments: hermeticArguments,
                    environment: hermeticEnvironment(support: todoSupport)
                ),
                "a lookalike path must not arm the watchdog: \(path)"
            )
        }
    }

    /// Codex on PR #225, third round, and it named the hole in the previous
    /// two signals: `--debug-automation` is only ENFORCED in a DEBUG build.
    /// `TodoTrayDebugAutomationPolicy` is `#if DEBUG`, so in a release binary
    /// that argument is an unchecked string and the gate leans on the bundle's
    /// NAME — which anyone can produce by copying a release app and renaming
    /// it. Such a copy runs against ordinary user data, and arming there would
    /// force-quit the user's real app after the timeout.
    ///
    /// The launcher puts its throwaway bundle INSIDE the run's own support
    /// directory. A copy sitting anywhere else is not a hermetic run.
    func test_isHermeticBundle_refusesACopyOutsideTheRunsSupportRoot() {
        XCTAssertFalse(
            HermeticIdleWatchdog.isHermeticBundle(
                executablePath: "/Applications/TodoTray-DebugAutomation-deadbeef.app/Contents/MacOS/TodoTray",
                arguments: hermeticArguments,
                environment: hermeticEnvironment(support: todoSupport)
            ),
            """
            a correctly named copy that is NOT inside the support root this run \
            was given is somebody's renamed app, not a launcher-created \
            throwaway
            """
        )
    }

    /// And the second launcher-minted fact: the run's throwaway defaults
    /// domain. No shipping launch sets one at all.
    func test_isHermeticBundle_refusesARunWithNoThrowawayDefaultsDomain() {
        XCTAssertFalse(
            HermeticIdleWatchdog.isHermeticBundle(
                executablePath: hermeticPath,
                arguments: hermeticArguments,
                environment: ["TODOTRAY_SUPPORT_DIR": todoSupport]
            ),
            "a run with no throwaway defaults domain has not been through a launcher"
        )
        XCTAssertFalse(
            HermeticIdleWatchdog.isHermeticBundle(
                executablePath: hermeticPath,
                arguments: hermeticArguments,
                environment: [
                    "TODOTRAY_SUPPORT_DIR": todoSupport,
                    "TODOTRAY_DEBUG_DEFAULTS_DOMAIN": "com.trulyuseful.TodoTray",
                ]
            ),
            "the real shipping defaults domain is not a throwaway one"
        )
    }

    /// The second signal, and the one an installed app can never fake: both
    /// apps' automation policies refuse to start without this argument, and
    /// nothing launches a shipping app with it.
    func test_isHermeticBundle_requiresTheHermeticLaunchArgument() {
        XCTAssertFalse(
            HermeticIdleWatchdog.isHermeticBundle(
                executablePath: hermeticPath,
                arguments: ["/path/TodoTray"],
                environment: hermeticEnvironment(support: todoSupport)
            ),
            "a hermetic-looking bundle launched WITHOUT --debug-automation is not a hermetic run"
        )
    }

    // MARK: - Timeout resolution

    /// An ABSENT variable must yield the default. If it disabled the watchdog,
    /// a launcher that forgets to export it leaks exactly as before — which is
    /// the whole defect.
    func test_timeout_defaultsWhenUnset() {
        XCTAssertEqual(
            HermeticIdleWatchdog.timeoutSeconds(from: [:]),
            HermeticIdleWatchdog.defaultTimeoutSeconds
        )
        XCTAssertEqual(
            HermeticIdleWatchdog.timeoutSeconds(from: [
                HermeticIdleWatchdog.timeoutEnvironmentKey: "   ",
            ]),
            HermeticIdleWatchdog.defaultTimeoutSeconds
        )
    }

    func test_timeout_honoursExplicitValue() {
        XCTAssertEqual(
            HermeticIdleWatchdog.timeoutSeconds(from: [
                HermeticIdleWatchdog.timeoutEnvironmentKey: "600",
            ]),
            600
        )
    }

    func test_timeout_nonPositiveOrUnparsableDisables() {
        for raw in ["0", "-1", "not a number"] {
            XCTAssertNil(
                HermeticIdleWatchdog.timeoutSeconds(from: [
                    HermeticIdleWatchdog.timeoutEnvironmentKey: raw,
                ]),
                "\(raw) must disable the watchdog rather than pick a default"
            )
        }
    }

    // MARK: - The verdict itself

    func test_verdict_bothDirections() {
        XCTAssertEqual(HermeticIdleWatchdog.verdict(idleSeconds: 0, timeoutSeconds: 60), .keepRunning)
        XCTAssertEqual(HermeticIdleWatchdog.verdict(idleSeconds: 59.9, timeoutSeconds: 60), .keepRunning)
        XCTAssertEqual(HermeticIdleWatchdog.verdict(idleSeconds: 60, timeoutSeconds: 60), .terminate)
        XCTAssertEqual(HermeticIdleWatchdog.verdict(idleSeconds: 34200, timeoutSeconds: 1800), .terminate)
        XCTAssertEqual(HermeticIdleWatchdog.verdict(idleSeconds: 34200, timeoutSeconds: 0), .keepRunning)
    }

    /// A clock that goes backwards must read as "just active", never as a huge
    /// idle span that kills a live drive.
    func test_idleSeconds_neverNegative() {
        let watchdog = HermeticIdleWatchdog.shared
        let now = Date()
        watchdog.noteActivity(now: now)
        XCTAssertEqual(watchdog.idleSeconds(now: now.addingTimeInterval(-3600)), 0)
        XCTAssertEqual(watchdog.idleSeconds(now: now.addingTimeInterval(90)), 90, accuracy: 0.01)
    }

    // MARK: - The loop, driven end to end

    func test_startIfHermetic_refusesAnInstalledApp() {
        let watchdog = HermeticIdleWatchdog.shared
        defer { watchdog.stopForTesting() }
        let fired = expectation(description: "must not terminate")
        fired.isInverted = true
        let armed = watchdog.startIfHermetic(
            executablePath: "/Applications/TodoTray.app/Contents/MacOS/TodoTray",
            arguments: hermeticArguments,
            environment: hermeticEnvironment(support: todoSupport, timeout: "0.01"),
            pollInterval: 0.01,
            installsEventMonitor: false,
            terminate: { fired.fulfill() }
        )
        XCTAssertFalse(armed)
        wait(for: [fired], timeout: 0.5)
    }

    func test_startIfHermetic_isDisabledByAZeroTimeout() {
        let watchdog = HermeticIdleWatchdog.shared
        defer { watchdog.stopForTesting() }
        let fired = expectation(description: "must not terminate")
        fired.isInverted = true
        let armed = watchdog.startIfHermetic(
            executablePath: hermeticPath,
            arguments: hermeticArguments,
            environment: hermeticEnvironment(support: todoSupport, timeout: "0"),
            pollInterval: 0.01,
            installsEventMonitor: false,
            terminate: { fired.fulfill() }
        )
        XCTAssertFalse(armed)
        wait(for: [fired], timeout: 0.5)
    }

    /// The overnight case: nothing drives the app, so it quits — with no next
    /// run, no live owner, and no external sweep involved.
    func test_idleHermeticAppTerminatesItself() {
        let watchdog = HermeticIdleWatchdog.shared
        defer { watchdog.stopForTesting() }
        let fired = expectation(description: "terminated")
        let clock = ClockBox()
        XCTAssertTrue(watchdog.startIfHermetic(
            executablePath: hermeticPath,
            arguments: hermeticArguments,
            environment: hermeticEnvironment(support: todoSupport, timeout: "1800"),
            pollInterval: 0.01,
            installsEventMonitor: false,
            now: { clock.now },
            terminate: { fired.fulfill() }
        ))
        clock.advance(34200) // the real 9.5-hour leak
        wait(for: [fired], timeout: 5)
    }

    /// The half that protects a working session: an app that is being driven
    /// stays up however long the session runs.
    func test_activityKeepsADrivenAppAlive() {
        let watchdog = HermeticIdleWatchdog.shared
        defer { watchdog.stopForTesting() }
        let fired = expectation(description: "must not terminate")
        fired.isInverted = true
        let clock = ClockBox()
        XCTAssertTrue(watchdog.startIfHermetic(
            executablePath: hermeticPath,
            arguments: hermeticArguments,
            environment: hermeticEnvironment(support: todoSupport, timeout: "1800"),
            pollInterval: 0.01,
            installsEventMonitor: false,
            now: { clock.now },
            terminate: { fired.fulfill() }
        ))
        // Far past the timeout in total, but never idle for it: exactly the
        // shape of an agent driving the app across many tool calls.
        for _ in 0 ..< 20 {
            clock.advance(1200)
            watchdog.noteActivity(now: clock.now)
            usleep(20000)
        }
        wait(for: [fired], timeout: 0.5)
    }

    private let hermeticPath =
        "/private/tmp/todotray-debug-automation.psLVKY/TodoTray-DebugAutomation-739413150b82460b2c3a97db.app/Contents/MacOS/TodoTray"
}

/// A lock-guarded clock: the watchdog reads `now()` from its own timer queue
/// while the test advances it, and an unguarded `var` there is a data race the
/// thread sanitiser will fail on.
private final class ClockBox: @unchecked Sendable {
    private let lock = NSLock()
    private var value = Date()

    var now: Date {
        lock.lock()
        defer { lock.unlock() }
        return value
    }

    func advance(_ seconds: TimeInterval) {
        lock.lock()
        value = value.addingTimeInterval(seconds)
        lock.unlock()
    }
}

/// The watchdog being correct while nothing invokes it is the shape of a fix
/// that ships green and changes nothing on the machine. This reads the source.
/// (Each app that arms the watchdog pins its own launch wiring.)
final class T1648HermeticIdleWatchdogWiringTests: XCTestCase {
    private var repositoryRoot: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent() // TodoTrayTestBridgeTests
            .deletingLastPathComponent() // Tests
            .deletingLastPathComponent() // repo root
    }

    private func source(_ relativePath: String) throws -> String {
        try String(contentsOf: repositoryRoot.appendingPathComponent(relativePath), encoding: .utf8)
    }

    /// A `DebugBridge` probe is the main way a scenario says "I am still here".
    /// If the bridge stops renewing the lease, a long scenario that leans on
    /// probes rather than clicks gets killed mid-run.
    func test_debugBridgeRenewsTheLeaseOnEveryRequest() throws {
        let text = try source("Sources/TodoTrayTestBridge/DebugBridge.swift")
        XCTAssertTrue(
            text.contains("HermeticIdleWatchdog.shared.noteActivity()"),
            "DebugBridge must count an incoming request as activity"
        )
    }
}
