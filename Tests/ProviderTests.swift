// ProviderTests.swift
// Tests for Provider, ProviderGraph, and ProviderContainer core behaviour.

import XCTest
@testable import SwiftRiver

final class ProviderTests: XCTestCase {

    // MARK: - Basic read

    func testSyncProviderReturnsValue() async {
        let container = ProviderContainer()
        let provider = Provider<Int>("test") { _ in 42 }

        let value = await container.read(provider)
        XCTAssertEqual(value, 42)
    }

    func testProviderIsLazilyInitialized() async {
        var factoryCallCount = 0
        let container = ProviderContainer()
        let provider = Provider<Int>("lazy") { _ in
            factoryCallCount += 1
            return 1
        }

        XCTAssertEqual(factoryCallCount, 0, "Factory must not run before first read")
        _ = await container.read(provider)
        XCTAssertEqual(factoryCallCount, 1)
    }

    func testProviderIsCached() async {
        var factoryCallCount = 0
        let container = ProviderContainer()
        let provider = Provider<Int>("cached") { _ in
            factoryCallCount += 1
            return 99
        }

        _ = await container.read(provider)
        _ = await container.read(provider)
        _ = await container.read(provider)

        XCTAssertEqual(factoryCallCount, 1, "Factory must run exactly once — result is cached")
    }

    // MARK: - StateHolder (mutable state)

    func testStateProviderInitialValue() async {
        let container = ProviderContainer()
        let counter = Provider<StateHolder<Int>>.state("counter", initial: 0)

        let holder = await container.read(counter)
        XCTAssertEqual(holder.state, 0)
    }

    func testStateProviderMutation() async {
        let container = ProviderContainer()
        let counter = Provider<StateHolder<Int>>.state("counter", initial: 0)

        let holder = await container.read(counter)
        holder.state = 5
        XCTAssertEqual(holder.state, 5)
    }

    func testStateProviderSameHolderReturnedOnSubsequentReads() async {
        let container = ProviderContainer()
        let counter = Provider<StateHolder<Int>>.state("counter", initial: 0)

        let holderA = await container.read(counter)
        holderA.state = 10
        let holderB = await container.read(counter)

        XCTAssertEqual(holderB.state, 10, "Must return the same StateHolder instance")
        XCTAssertTrue(holderA === holderB)
    }

    // MARK: - Dependency graph (ref.watch)

    func testRefWatchResolvesTransitiveDependency() async {
        let container = ProviderContainer()

        let baseProvider = Provider<Int>("base") { _ in 10 }
        let derivedProvider = Provider<Int>("derived") { ref in
            ref.watch(baseProvider) * 2
        }

        let value = await container.read(derivedProvider)
        XCTAssertEqual(value, 20)
    }

    func testDeepDependencyChain() async {
        let container = ProviderContainer()

        let a = Provider<Int>("a") { _ in 1 }
        let b = Provider<Int>("b") { ref in ref.watch(a) + 1 }
        let c = Provider<Int>("c") { ref in ref.watch(b) + 1 }
        let d = Provider<Int>("d") { ref in ref.watch(c) + 1 }

        let value = await container.read(d)
        XCTAssertEqual(value, 4)
    }

    // MARK: - Independent containers

    func testEachContainerHasIsolatedState() async {
        let containerA = ProviderContainer()
        let containerB = ProviderContainer()

        let counter = Provider<StateHolder<Int>>.state("counter", initial: 0)

        let holderA = await containerA.read(counter)
        holderA.state = 99

        let holderB = await containerB.read(counter)
        XCTAssertEqual(holderB.state, 0, "Containers must not share state")
    }

    // MARK: - Multiple providers of same type

    func testTwoProvidersOfSameTypAreIndependent() async {
        let container = ProviderContainer()

        let counterA = Provider<StateHolder<Int>>.state("counterA", initial: 0)
        let counterB = Provider<StateHolder<Int>>.state("counterB", initial: 0)

        let holderA = await container.read(counterA)
        holderA.state = 7

        let holderB = await container.read(counterB)
        XCTAssertEqual(holderB.state, 0, "Different providers must not share holders")
    }
}
