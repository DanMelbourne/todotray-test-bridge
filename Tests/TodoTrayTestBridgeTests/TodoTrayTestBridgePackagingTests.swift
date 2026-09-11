// T-1593. The state-probe bridge used to live inside TodoKit, a hundred-file
// library that pulls Sparkle, Sentry, MarkdownEngine and the whole Todo domain.
// A third-party app could not adopt the bridge without adopting all of that, so
// in practice it would reimplement it — and get the guarantees wrong, because
// the guarantees are the interesting part, not the socket.
//
// This test target depends on TodoTrayTestBridge and NOTHING else, which is the
// claim: if the extraction ever reaches back into TodoKit or ScreenshotTray,
// this target stops compiling.

import Foundation
@testable import TodoTrayTestBridge
import XCTest

final class TodoTrayTestBridgePackagingTests: XCTestCase {
    /// The package must not name either product anywhere in its source.
    ///
    /// A build-time dependency would already break this target, but a hardcoded
    /// path or environment key would not — and that is the shape the two
    /// products' own halves take, so it is the shape most likely to leak back.
    func test_theExtractedPackageNamesNeitherProduct() throws {
        let sources = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Sources/TodoTrayTestBridge")
        let files = try FileManager.default.contentsOfDirectory(at: sources, includingPropertiesForKeys: nil)
            .filter { $0.pathExtension == "swift" }
        XCTAssertFalse(files.isEmpty, "TodoTrayTestBridge has no sources; the path is wrong.")

        for file in files {
            let text = try String(contentsOf: file, encoding: .utf8)
            // Prose may explain where this came from; CODE may not depend on it.
            let code = text
                .split(separator: "\n", omittingEmptySubsequences: false)
                .filter { !$0.trimmingCharacters(in: .whitespaces).hasPrefix("//") }
                .joined(separator: "\n")
            for banned in ["import TodoKit", "import ScreenshotTray", "TodoTray.app", "ScreenshotTray.app"] {
                XCTAssertFalse(
                    code.contains(banned),
                    "\(file.lastPathComponent) reaches back into a product (\(banned))."
                )
            }
        }
    }

    /// A target is reachable only from inside its own package.
    ///
    /// Codex P1 on PR #220: the extraction is pointless without this line. An
    /// app adding this repository as a SwiftPM dependency can depend on nothing
    /// but the entries in `products`, so a bridge that is a target and not a
    /// library can only be adopted by copying its source.
    func test_theBridgeIsExportedAsALibraryProduct() throws {
        let manifest = try String(
            contentsOf: URL(fileURLWithPath: #filePath)
                .deletingLastPathComponent()
                .deletingLastPathComponent()
                .deletingLastPathComponent()
                .appendingPathComponent("Package.swift"),
            encoding: .utf8
        )
        XCTAssertTrue(
            manifest.contains(#".library(name: "TodoTrayTestBridge", targets: ["TodoTrayTestBridge"])"#),
            "TodoTrayTestBridge is not a product, so no external package can depend on it."
        )
    }

    /// The default host exposes nothing, so a process that forgets to configure
    /// one cannot accidentally answer another app's environment variable.
    func test_theDefaultHostIsInert() {
        let inert = DebugBridgeHost.inert
        XCTAssertEqual(inert.environmentKey, "", "An empty key can never be opted into.")
        XCTAssertEqual(inert.label, "unconfigured")
        XCTAssertNotEqual(inert.portFileName, "debug-bridge.port", "That is ScreenshotTray's file.")
    }
}

final class TodoTrayTestBridgeContractTests: XCTestCase {
    /// The two probes the harness genuinely requires, which an adopter has no
    /// way to discover from anywhere else.
    func test_bothRequiredProbesAreNamed() {
        XCTAssertEqual(
            TodoTrayTestBridgeContract.requiredProbeNames,
            ["debug-automation-launch", "ui-reset"]
        )
    }

    func test_conformanceReportsEveryRequirementNotJustTheFirst() {
        // An adopter fixing one probe at a time, learning of the next only
        // after another round trip, is the experience this replaces.
        let none = TodoTrayTestBridgeContract.conformance(registeredProbeNames: [])
        XCTAssertEqual(none.count, 2)
        XCTAssertTrue(none.allSatisfy { !$0.isSatisfied })
        for requirement in none {
            XCTAssertFalse(
                requirement.remedy.isEmpty,
                "\(requirement.name) says it is missing without saying what to do."
            )
            XCTAssertTrue(
                requirement.remedy.contains(requirement.name),
                "The remedy must name the probe it is about."
            )
        }
        XCTAssertFalse(TodoTrayTestBridgeContract.conforms(registeredProbeNames: []))
    }

    func test_halfAContractIsNotAContract() {
        let half = TodoTrayTestBridgeContract.conformance(
            registeredProbeNames: ["debug-automation-launch"]
        )
        XCTAssertEqual(half.filter(\.isSatisfied).map(\.name), ["debug-automation-launch"])
        XCTAssertEqual(half.filter { !$0.isSatisfied }.map(\.name), ["ui-reset"])
        XCTAssertFalse(TodoTrayTestBridgeContract.conforms(registeredProbeNames: ["debug-automation-launch"]))
    }

    func test_anAppAnsweringBothConforms() {
        XCTAssertTrue(
            TodoTrayTestBridgeContract.conforms(
                registeredProbeNames: ["debug-automation-launch", "ui-reset", "something-else"]
            )
        )
    }

    /// Read from the REGISTRY, not from a declaration: a probe that was declared
    /// and never registered is how a contract usually rots.
    @MainActor
    func test_conformanceReadsWhatIsActuallyRegistered() {
        let bridge = DebugBridge.shared
        bridge.resetRegistryForTesting()
        XCTAssertTrue(bridge.harnessConformance.allSatisfy { !$0.isSatisfied })

        bridge.registerReadOnlySurface([
            DebugBridge.ReadOnlyProbe("debug-automation-launch") { _ in ["enabled": true] },
        ])
        XCTAssertEqual(
            bridge.harnessConformance.filter(\.isSatisfied).map(\.name),
            ["debug-automation-launch"]
        )

        bridge.registerReadOnlySurface([
            DebugBridge.ReadOnlyProbe("ui-reset") { _ in ["ok": true] },
        ])
        XCTAssertTrue(bridge.harnessConformance.allSatisfy(\.isSatisfied))
        bridge.resetRegistryForTesting()
    }
}

final class TodoTrayTestBridgeSurfaceTests: XCTestCase {
    /// An unclassified `register(...)` records the probe as MUTATING, because
    /// "unknown" must default to the restrictive side — otherwise one such call
    /// elsewhere in an app silently widens what a shipping binary exposes.
    @MainActor
    func test_anUnclassifiedProbeIsMutatingNotReadOnly() {
        let bridge = DebugBridge.shared
        bridge.resetRegistryForTesting()
        bridge.register("unclassified") { _ in [:] }

        // In a DEBUG test build the registration is accepted, and the point is
        // WHICH surface it lands on: a shipping binary registers only the
        // read-only one, so being absent from it is what keeps it out.
        XCTAssertTrue(bridge.mutatingProbeNames.contains("unclassified"))
        XCTAssertFalse(
            bridge.readOnlyProbeNames.contains("unclassified"),
            "An unclassified probe must never reach the surface a release build exposes."
        )
        XCTAssertFalse(
            DebugBridge.allowsMutatingProbes && !bridge.mutatingProbeNames.isEmpty
                && bridge.readOnlyProbeNames.contains("unclassified")
        )
        bridge.resetRegistryForTesting()
    }

    /// Re-classifying moves a probe between surfaces rather than listing it on
    /// both, which would make "is this in the release surface?" ambiguous.
    @MainActor
    func test_reclassifyingMovesAProbeRatherThanDuplicatingIt() {
        let bridge = DebugBridge.shared
        bridge.resetRegistryForTesting()
        bridge.register("moving") { _ in [:] }
        XCTAssertTrue(bridge.mutatingProbeNames.contains("moving"))

        bridge.registerReadOnlySurface([DebugBridge.ReadOnlyProbe("moving") { _ in [:] }])
        XCTAssertTrue(bridge.readOnlyProbeNames.contains("moving"))
        XCTAssertFalse(bridge.mutatingProbeNames.contains("moving"))

        bridge.registerMutatingSurface([DebugBridge.MutatingProbe("moving") { _ in [:] }])
        XCTAssertTrue(bridge.mutatingProbeNames.contains("moving"))
        XCTAssertFalse(bridge.readOnlyProbeNames.contains("moving"))
        bridge.resetRegistryForTesting()
    }

    /// The release gate is a compile-time fact, not a runtime flag: a shipping
    /// binary can never register the mutating surface, under any environment.
    @MainActor
    func test_theReleaseGateIsAConfigurationFactNotAnEnvironmentOne() throws {
        let source = try String(
            contentsOf: URL(fileURLWithPath: #filePath)
                .deletingLastPathComponent()
                .deletingLastPathComponent()
                .deletingLastPathComponent()
                .appendingPathComponent("Sources/TodoTrayTestBridge/DebugBridge.swift"),
            encoding: .utf8
        )
        let gate = try XCTUnwrap(source.range(of: "public static var allowsMutatingProbes: Bool {"))
        let block = String(source[gate.lowerBound...].prefix(260))
        XCTAssertTrue(block.contains("#if DEBUG"), "The gate stopped being a build configuration.")
        XCTAssertFalse(
            block.contains("ProcessInfo"),
            "An environment variable must not be able to open the mutating surface."
        )
        #if DEBUG
            XCTAssertTrue(DebugBridge.allowsMutatingProbes)
        #else
            XCTAssertFalse(DebugBridge.allowsMutatingProbes)
        #endif
    }
}
