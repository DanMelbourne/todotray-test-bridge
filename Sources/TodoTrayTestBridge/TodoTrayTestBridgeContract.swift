import Foundation

/// What an app must answer before todotray-ui-driver's harness will drive it.
///
/// The two probe names below are a HARD requirement of the harness, and an
/// adopting app has no way to discover them: the harness refuses to send a
/// single synthetic event without the first, and calls the second from its
/// teardown trap so a run cannot leave a sheet or a QuickLook panel over
/// somebody's screen. Shipping them beside the bridge, with a check the adopter
/// can run, is what makes "is my app ready?" answerable before the first
/// confusing failure rather than after it.
public enum TodoTrayTestBridgeContract {
    /// Answered as `{"enabled": true}` when the process was launched under the
    /// hermetic contract — isolated support directory, isolated defaults domain,
    /// suppressed first-run onboarding.
    ///
    /// The harness refuses to drive input without it, because a bare launch puts
    /// first-run onboarding on screen and every click then lands on that window,
    /// which reads as a dead control rather than a wrong launch.
    public static let hermeticLaunchProbeName = "debug-automation-launch"

    /// Returns the app to a neutral surface: close sheets, modal sessions and
    /// preview panels. Called from the teardown trap, including on failure.
    public static let resetProbeName = "ui-reset"

    /// The contract number `GET /probe` reports as `contractVersion`. An integer,
    /// raised only when a bridge that followed the previous contract would now
    /// fail (a new required probe, a changed answer); an optional probe never
    /// raises it. todotray-ui-driver accepts this number and the one before it.
    /// 0.1.x predates the field and counts as 1, so the first release to send it still says 1.
    public static let contractVersion = 1

    /// T-2746. `debug` or `release`, from how this package was compiled: a release build that still
    /// answers `GET /probe` ships a test hook, and `todotray-ui-driver doctor` warns about it.
    /// Reported as `buildKind`; additive, so the contract number does not change.
    public static let buildKind: String = {
        #if DEBUG
            "debug"
        #else
            "release"
        #endif
    }()

    /// Every probe an adopting app must answer.
    public static let requiredProbeNames = [hermeticLaunchProbeName, resetProbeName]

    /// One requirement and whether this process satisfies it.
    public struct Requirement: Equatable, Sendable {
        public let name: String
        public let isSatisfied: Bool
        /// What to do about it, in the adopter's terms. Empty when satisfied.
        public let remedy: String

        public init(name: String, isSatisfied: Bool, remedy: String) {
            self.name = name
            self.isSatisfied = isSatisfied
            self.remedy = remedy
        }
    }

    /// Checks a set of registered probe names against the contract.
    ///
    /// The question is asked from two sides. From INSIDE the app, this function
    /// — through `DebugBridge.harnessConformance` — reads the registry itself.
    /// From OUTSIDE, `todotray-ui-driver doctor --probe-base <url>` asks the
    /// running bridge for the same probes over HTTP and says what to fix. The
    /// two cannot share code — the driver does not depend on this package — so
    /// the driver's own tests pin its probe names to `requiredProbeNames`, and
    /// a probe added here cannot go unasked there. It reports EVERY requirement rather than
    /// the first failure: an adopter fixing one probe at a time, learning of
    /// the next only after another round trip, is the experience this exists
    /// to replace.
    public static func conformance(registeredProbeNames: Set<String>) -> [Requirement] {
        requiredProbeNames.map { name in
            Requirement(
                name: name,
                isSatisfied: registeredProbeNames.contains(name),
                remedy: registeredProbeNames.contains(name) ? "" : remedy(for: name)
            )
        }
    }

    /// Whether every requirement is met.
    public static func conforms(registeredProbeNames: Set<String>) -> Bool {
        conformance(registeredProbeNames: registeredProbeNames).allSatisfy(\.isSatisfied)
    }

    private static func remedy(for name: String) -> String {
        switch name {
        case hermeticLaunchProbeName:
            "Register a read-only probe named \"\(hermeticLaunchProbeName)\" returning "
                + "[\"enabled\": true] when the process was launched under your hermetic "
                + "mode. Without it the harness will not send input at all, because a bare "
                + "launch puts first-run onboarding over the window it is meant to drive."
        case resetProbeName:
            "Register a probe named \"\(resetProbeName)\" that closes sheets, modal "
                + "sessions and preview panels. Teardown calls it from an EXIT trap, so "
                + "without it an interrupted run leaves its last dialog on screen."
        default:
            "Register a probe named \"\(name)\"."
        }
    }
}

public extension DebugBridge {
    /// This process's conformance with the harness contract.
    ///
    /// Reads the registry rather than a declaration, so a probe that was
    /// declared and never registered — the way a contract usually rots — reads
    /// as missing.
    var harnessConformance: [TodoTrayTestBridgeContract.Requirement] {
        TodoTrayTestBridgeContract.conformance(
            registeredProbeNames: readOnlyProbeNames.union(mutatingProbeNames)
        )
    }
}
