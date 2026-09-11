import Foundation
@testable import TodoTrayTestBridge
import XCTest

/// The port file is the harness's readiness signal, so whatever the host wants
/// done at readiness — launch instrumentation in particular — must run BEFORE
/// it is written. Otherwise a harness that sees the file and starts timing is
/// measuring a launch that has not finished.
final class DebugBridgeReadinessTests: XCTestCase {
    private func bridgeSource() throws -> String {
        try String(
            contentsOf: URL(fileURLWithPath: #filePath)
                .deletingLastPathComponent()
                .deletingLastPathComponent()
                .deletingLastPathComponent()
                .appendingPathComponent("Sources/TodoTrayTestBridge/DebugBridge.swift"),
            encoding: .utf8
        )
    }

    func test_theHostHearsOfReadinessBeforeThePortFileIsPublished() throws {
        let bridge = try bridgeSource()
        let readyHandler = try XCTUnwrap(bridge.range(of: "if case .ready = state"))
        let readySource = String(bridge[readyHandler.lowerBound...])
        let hostHook = try XCTUnwrap(readySource.range(of: "Self.host.didBecomeReady()")?.lowerBound)
        let portPublication = try XCTUnwrap(readySource.range(of: "self?.writePortFile(portValue)")?.lowerBound)
        XCTAssertLessThan(hostHook, portPublication)
    }

    /// Clients and documentation quote this route. It is a public constant so
    /// they can read it instead of restating it, and the router must use it.
    func test_theRouterAnswersOnThePublishedRoute() throws {
        XCTAssertEqual(DebugBridge.probeRoutePrefix, "/probe/")
        XCTAssertTrue(
            try bridgeSource().contains("path.hasPrefix(Self.probeRoutePrefix)"),
            "The router stopped using the published route constant."
        )
    }
}
