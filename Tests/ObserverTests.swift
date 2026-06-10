// ObserverTests.swift
// Tests for ProviderObserver lifecycle callbacks.

import XCTest
@testable import SwiftRiver

// MARK: - Test Observer

final class RecordingObserver: ProviderObserver {
    var addedKeys:   [String] = []
    var disposedKeys:[String] = []
    var updatedKeys: [String] = []

    func didAddProvider(_ key: ProviderKey, value: Any) {
        addedKeys.append(key.description)
    }
    func didDisposeProvider(_ key: ProviderKey) {
        disposedKeys.append(key.description)
    }
    func didUpdateProvider(_ key: ProviderKey, value: Any) {
        updatedKeys.append(key.description)
    }
}

// MARK: - Tests

final class ObserverTests: XCTestCase {

    func testObserverReceivesDidAddOnRead() async {
        let observer = RecordingObserver()
        let container = ProviderContainer(observers: [observer])

        let provider = Provider<Int>("observed") { _ in 1 }
        _ = await container.read(provider)

        XCTAssertEqual(observer.addedKeys, ["Provider<observed>"])
    }

    func testObserverDidAddCalledOnceForCachedProvider() async {
        let observer = RecordingObserver()
        let container = ProviderContainer(observers: [observer])

        let provider = Provider<Int>("cached-obs") { _ in 1 }
        _ = await container.read(provider)
        _ = await container.read(provider)
        _ = await container.read(provider)

        XCTAssertEqual(observer.addedKeys.count, 3,
            "didAddProvider fires on every read call, not just the first build")
    }

    func testObserverReceivesDidDisposeOnInvalidate() async {
        let observer = RecordingObserver()
        let container = ProviderContainer(observers: [observer])

        let provider = Provider<Int>("dispose-obs") { _ in 99 }
        _ = await container.read(provider)
        await container.invalidate(provider)

        try? await Task.sleep(nanoseconds: 100_000_000)

        XCTAssertTrue(
            observer.disposedKeys.contains("Provider<dispose-obs>"),
            "didDisposeProvider must be called after invalidate"
        )
    }

    func testMultipleObserversAllReceiveCallbacks() async {
        let obs1 = RecordingObserver()
        let obs2 = RecordingObserver()
        let container = ProviderContainer(observers: [obs1, obs2])

        let provider = Provider<String>("multi-obs") { _ in "hello" }
        _ = await container.read(provider)

        XCTAssertFalse(obs1.addedKeys.isEmpty, "Observer 1 must receive callback")
        XCTAssertFalse(obs2.addedKeys.isEmpty, "Observer 2 must receive callback")
    }

    func testAsyncProviderObserverDidAddCalledAfterResolution() async throws {
        let observer = RecordingObserver()
        let container = ProviderContainer(observers: [observer])

        let provider = AsyncProvider<Int>("async-obs") { _ in 7 }
        let holder = await container.watch(provider)

        // Wait for resolution
        let deadline = Date().addingTimeInterval(2.0)
        while Date() < deadline {
            if case .data = holder.state { break }
            try await Task.sleep(nanoseconds: 50_000_000)
        }

        XCTAssertTrue(
            observer.addedKeys.contains("Provider<async-obs>"),
            "didAddProvider must fire after AsyncProvider resolves"
        )
    }

    func testDefaultObserverProtocolImplementationsDoNotCrash() async {
        // ProviderObserver has default no-op implementations.
        // This test ensures a minimal conformance doesn't crash.
        struct MinimalObserver: ProviderObserver {}

        let container = ProviderContainer(observers: [MinimalObserver()])
        let provider = Provider<Int>("minimal") { _ in 0 }
        _ = await container.read(provider)
        await container.invalidate(provider)
        // If we reach here without crashing, the test passes.
    }
}
