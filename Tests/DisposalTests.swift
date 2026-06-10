// DisposalTests.swift
// Tests for autoDispose, cascade disposal, keepAlive, onDispose hooks,
// and invalidate behaviour.

import XCTest
@testable import SwiftRiver

final class DisposalTests: XCTestCase {

    // MARK: - onDispose hook

    func testOnDisposeIsCalledOnInvalidate() async {
        let container = ProviderContainer()
        var disposed = false

        let provider = Provider<Int>("disposable") { ref in
            ref.onDispose { disposed = true }
            return 1
        }

        _ = await container.read(provider)
        XCTAssertFalse(disposed)

        await container.invalidate(provider)

        // Give the actor-scheduled Task a moment to execute
        try? await Task.sleep(nanoseconds: 100_000_000)
        XCTAssertTrue(disposed, "onDispose must be called after invalidate")
    }

    func testOnDisposeCanRegisterMultipleHooks() async {
        let container = ProviderContainer()
        var log: [String] = []

        let provider = Provider<Int>("multi-dispose") { ref in
            ref.onDispose { log.append("first") }
            ref.onDispose { log.append("second") }
            ref.onDispose { log.append("third") }
            return 0
        }

        _ = await container.read(provider)
        await container.invalidate(provider)
        try? await Task.sleep(nanoseconds: 100_000_000)

        XCTAssertEqual(log, ["first", "second", "third"])
    }

    // MARK: - Invalidate clears cache

    func testInvalidateClearsCache() async {
        var callCount = 0
        let container = ProviderContainer()

        let provider = Provider<Int>("rebuild") { _ in
            callCount += 1
            return callCount
        }

        let first = await container.read(provider)
        XCTAssertEqual(first, 1)

        await container.invalidate(provider)
        try? await Task.sleep(nanoseconds: 100_000_000)

        let second = await container.read(provider)
        XCTAssertEqual(second, 2, "After invalidation, factory must run again")
        XCTAssertEqual(callCount, 2)
    }

    // MARK: - keepAlive

    func testKeepAliveProviderIsNotDisposedWhenDependentIsGone() async {
        var keepAliveFactoryCount = 0
        let container = ProviderContainer()

        let keepAliveProvider = Provider<Int>("infrastructure", keepAlive: true) { _ in
            keepAliveFactoryCount += 1
            return 42
        }

        let dependentProvider = Provider<Int>("dependent") { ref in
            ref.watch(keepAliveProvider)
        }

        _ = await container.read(dependentProvider)
        XCTAssertEqual(keepAliveFactoryCount, 1)

        // Invalidate the dependent — keepAlive upstream must survive
        await container.invalidate(dependentProvider)
        try? await Task.sleep(nanoseconds: 100_000_000)

        // Read keepAlive again — factory must NOT run a second time
        let value = await container.read(keepAliveProvider)
        XCTAssertEqual(value, 42)
        XCTAssertEqual(keepAliveFactoryCount, 1, "keepAlive provider must not be re-created")
    }

    func testNonKeepAliveProviderIsDisposedWhenNoLongerNeeded() async {
        var disposed = false
        let container = ProviderContainer()

        let upstream = Provider<Int>("upstream") { ref in
            ref.onDispose { disposed = true }
            return 10
        }

        let downstream = Provider<Int>("downstream") { ref in
            ref.watch(upstream)
        }

        _ = await container.read(downstream)

        // Invalidate downstream — upstream has no keepAlive and no other dependents,
        // so it should cascade-dispose
        await container.invalidate(downstream)
        try? await Task.sleep(nanoseconds: 100_000_000)

        XCTAssertTrue(disposed, "Non-keepAlive upstream must be cascade-disposed")
    }

    // MARK: - AsyncProvider invalidate

    func testAsyncProviderInvalidateAllowsRebuild() async throws {
        var callCount = 0
        let container = ProviderContainer()

        let provider = AsyncProvider<Int>("async-rebuild") { _ in
            callCount += 1
            return callCount
        }

        let holderA = await container.watch(provider)
        try await waitForData(holderA)
        XCTAssertEqual(callCount, 1)

        await container.invalidate(provider)
        try? await Task.sleep(nanoseconds: 100_000_000)

        let holderB = await container.watch(provider)
        try await waitForData(holderB)
        XCTAssertEqual(callCount, 2, "After async invalidate, factory must run again")
    }

    // MARK: - Helpers

    private func waitForData<T>(
        _ holder: StateHolder<AsyncState<T>>,
        timeout: TimeInterval = 2.0
    ) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if case .data = holder.state { return }
            if case .error(let e) = holder.state { XCTFail("Unexpected error: \(e)"); return }
            try await Task.sleep(nanoseconds: 50_000_000)
        }
        XCTFail("Timed out waiting for .data state")
    }
}
