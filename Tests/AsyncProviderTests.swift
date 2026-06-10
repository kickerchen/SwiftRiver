// AsyncProviderTests.swift
// Tests for AsyncProvider and AsyncState lifecycle.

import XCTest
@testable import SwiftRiver

final class AsyncProviderTests: XCTestCase {

    // MARK: - Initial state

    func testAsyncProviderStartsInLoadingState() async {
        let container = ProviderContainer()

        // Use a never-resolving provider to capture the .loading state
        let neverProvider = AsyncProvider<Int>("never") { _ in
            try await Task.sleep(nanoseconds: 60 * 1_000_000_000)
            return 0
        }

        let holder = await container.watch(neverProvider)
        if case .loading = holder.state {
            // pass
        } else {
            XCTFail("Expected .loading on first watch, got \(holder.state)")
        }
    }

    // MARK: - Successful resolution

    func testAsyncProviderResolvesToData() async throws {
        let container = ProviderContainer()

        let provider = AsyncProvider<String>("greeting") { _ in
            return "Hello, SwiftRiver"
        }

        let holder = await container.watch(provider)

        // Poll until resolved (actor scheduling may delay the Task)
        try await waitForState(holder) { state in
            if case .data = state { return true }
            return false
        }

        if case .data(let value) = holder.state {
            XCTAssertEqual(value, "Hello, SwiftRiver")
        } else {
            XCTFail("Expected .data, got \(holder.state)")
        }
    }

    // MARK: - Error handling

    func testAsyncProviderResolvesToError() async throws {
        struct FetchError: Error, Equatable {}
        let container = ProviderContainer()

        let provider = AsyncProvider<Int>("failing") { _ in
            throw FetchError()
        }

        let holder = await container.watch(provider)

        try await waitForState(holder) { state in
            if case .error = state { return true }
            return false
        }

        if case .error(let error) = holder.state {
            XCTAssertTrue(error is FetchError)
        } else {
            XCTFail("Expected .error, got \(holder.state)")
        }
    }

    // MARK: - Caching

    func testAsyncProviderIsCached() async throws {
        var callCount = 0
        let container = ProviderContainer()

        let provider = AsyncProvider<Int>("counted") { _ in
            callCount += 1
            return callCount
        }

        let holderA = await container.watch(provider)
        let holderB = await container.watch(provider)

        try await waitForState(holderA) { if case .data = $0 { return true }; return false }

        XCTAssertTrue(holderA === holderB, "Must return the same StateHolder")
        XCTAssertEqual(callCount, 1, "Factory must only run once")
    }

    // MARK: - Dependency via ref.watch inside async factory

    func testAsyncProviderCanWatchSyncProvider() async throws {
        let container = ProviderContainer()

        let baseURL = Provider<String>("baseURL") { _ in "https://api.example.com" }

        let provider = AsyncProvider<String>("endpoint") { ref in
            let base = ref.watch(baseURL)
            return "\(base)/users"
        }

        let holder = await container.watch(provider)
        try await waitForState(holder) { if case .data = $0 { return true }; return false }

        if case .data(let url) = holder.state {
            XCTAssertEqual(url, "https://api.example.com/users")
        } else {
            XCTFail("Expected .data")
        }
    }

    // MARK: - Helpers

    /// Polls `holder.state` until `condition` returns true or timeout expires.
    private func waitForState<T>(
        _ holder: StateHolder<AsyncState<T>>,
        timeout: TimeInterval = 2.0,
        condition: @escaping (AsyncState<T>) -> Bool
    ) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if condition(holder.state) { return }
            try await Task.sleep(nanoseconds: 50_000_000) // 50ms
        }
        XCTFail("Timed out waiting for expected AsyncState")
    }
}
