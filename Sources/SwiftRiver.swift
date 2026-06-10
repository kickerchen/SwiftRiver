// SwiftRiver.swift
// Riverpod-inspired DI for Swift
// @Observable · Swift Concurrency · actor-isolated graph · autoDispose
// Requires: Swift 5.9+, iOS 17+, macOS 14+

import Foundation
import Observation

// MARK: - ProviderKey

public struct ProviderKey: Hashable, CustomStringConvertible {
    private let id: ObjectIdentifier
    private let label: String

    init<T>(_ type: T.Type, label: String) {
        self.id = ObjectIdentifier(type as AnyObject.Type)
        self.label = label
    }

    // Stable key per instance — allows multiple providers of same type
    static func unique(label: String) -> ProviderKey {
        final class Token {}
        return ProviderKey(Token.self, label: label)
    }

    public var description: String { "Provider<\(label)>" }
}

// MARK: - ProviderNode

/// Node in the bidirectional dependency graph.
/// Lives entirely inside ProviderGraph (actor) — never escapes.
final class ProviderNode {
    let key: ProviderKey
    var dependents: Set<ProviderKey> = []
    var dependencies: Set<ProviderKey> = []
    var dispose: (() -> Void)?
    let keepAlive: Bool

    init(key: ProviderKey, keepAlive: Bool) {
        self.key = key
        self.keepAlive = keepAlive
    }
}

// MARK: - ProviderGraph (actor)

/// Actor-isolated store for the dependency graph and value cache.
/// All mutations are serialized — no locks needed.
actor ProviderGraph {

    private var cache: [ProviderKey: Any] = [:]
    private var nodes: [ProviderKey: ProviderNode] = [:]
    private var refs:  [ProviderKey: Ref] = [:]

    // MARK: Read / Build

    func read<T>(_ provider: Provider<T>) -> T {
        if let cached = cache[provider.key] as? T { return cached }
        return build(provider)
    }

    @discardableResult
    private func build<T>(_ provider: Provider<T>) -> T {
        let node = ProviderNode(key: provider.key, keepAlive: provider.keepAlive)
        nodes[provider.key] = node

        let ref = Ref(graph: self, nodeKey: provider.key)
        refs[provider.key] = ref

        // Factory runs synchronously; ref captures the graph actor reference
        let value = provider.factory(ref)
        cache[provider.key] = value

        node.dispose = { [weak self] in
            guard let self else { return }
            // Schedule actor-isolated cleanup
            Task { await self.runDispose(key: provider.key) }
        }

        return value
    }

    private func runDispose(key: ProviderKey) {
        refs[key]?.runDisposals()
        cache.removeValue(forKey: key)
        nodes.removeValue(forKey: key)
        refs.removeValue(forKey: key)
    }

    // MARK: Async Build

    /// Builds an AsyncProvider — returns a pre-allocated holder,
    /// fills it on a detached Task so callers aren't blocked.
    func buildAsync<T>(
        _ provider: AsyncProvider<T>,
        observers: [ProviderObserver]
    ) -> StateHolder<AsyncState<T>> {
        if let cached = cache[provider.key] as? StateHolder<AsyncState<T>> {
            return cached
        }

        let holder = StateHolder<AsyncState<T>>(.loading)
        cache[provider.key] = holder

        let node = ProviderNode(key: provider.key, keepAlive: provider.keepAlive)
        nodes[provider.key] = node

        let ref = Ref(graph: self, nodeKey: provider.key)
        refs[provider.key] = ref

        node.dispose = { [weak self] in
            Task { await self?.runDispose(key: provider.key) }
        }

        Task {
            do {
                let value = try await provider.factory(ref)
                await MainActor.run { holder.state = .data(value) }
                observers.forEach { $0.didAddProvider(provider.key, value: value) }
            } catch {
                await MainActor.run { holder.state = .error(error) }
            }
        }

        return holder
    }

    // MARK: Graph Edges

    func registerEdge(from child: ProviderKey, to parent: ProviderKey) {
        nodes[child]?.dependencies.insert(parent)
        nodes[parent]?.dependents.insert(child)
    }

    // MARK: Dispose

    func disposeNode(for key: ProviderKey, observers: [ProviderObserver]) {
        guard let node = nodes[key] else { return }
        observers.forEach { $0.didDisposeProvider(key) }

        // Unlink from upstream — may cascade disposal
        for depKey in node.dependencies {
            nodes[depKey]?.dependents.remove(key)
            if let upstream = nodes[depKey],
               upstream.dependents.isEmpty,
               !upstream.keepAlive {
                disposeNode(for: depKey, observers: observers)
            }
        }

        refs[key]?.runDisposals()
        cache.removeValue(forKey: key)
        nodes.removeValue(forKey: key)
        refs.removeValue(forKey: key)
    }

    func invalidate(key: ProviderKey, observers: [ProviderObserver]) {
        disposeNode(for: key, observers: observers)
    }
}

// MARK: - Ref

/// Scoped factory handle. Holds an unowned reference to the graph actor.
/// ref.watch() must be called from a synchronous context (inside a factory).
public final class Ref {
    private let graph: ProviderGraph
    fileprivate let nodeKey: ProviderKey
    private var disposals: [() -> Void] = []

    init(graph: ProviderGraph, nodeKey: ProviderKey) {
        self.graph = graph
        self.nodeKey = nodeKey
    }

    /// Synchronous read + edge registration.
    /// Safe because Provider factories are synchronous and called
    /// from within the actor's turn — no suspension, no re-entrancy.
    public func watch<T>(_ provider: Provider<T>) -> T {
        // actor.assumeIsolated: asserts we're already on the actor's executor.
        // This is true because build() calls factory(ref) while holding the actor.
        graph.assumeIsolated { graph in
            graph.registerEdge(from: nodeKey, to: provider.key)
            return graph.read(provider)
        }
    }

    public func onDispose(_ action: @escaping () -> Void) {
        disposals.append(action)
    }

    fileprivate func runDisposals() {
        disposals.forEach { $0() }
        disposals.removeAll()
    }
}

// MARK: - AsyncState

public enum AsyncState<T> {
    case loading
    case data(T)
    case error(Error)
}

// MARK: - StateHolder

@Observable
public final class StateHolder<T> {
    public var state: T
    public init(_ initial: T) { self.state = initial }
}

// MARK: - Provider

public final class Provider<T> {
    public let key: ProviderKey
    public let keepAlive: Bool
    fileprivate let factory: (Ref) -> T

    public init(
        _ label: String = "\(T.self)",
        keepAlive: Bool = false,
        _ factory: @escaping (Ref) -> T
    ) {
        self.key = .unique(label: label)
        self.keepAlive = keepAlive
        self.factory = factory
    }
}

public extension Provider {
    static func state<S>(
        _ label: String = "State<\(S.self)>",
        keepAlive: Bool = false,
        initial: S
    ) -> Provider<StateHolder<S>> {
        Provider<StateHolder<S>>(label, keepAlive: keepAlive) { _ in
            StateHolder(initial)
        }
    }
}

// MARK: - AsyncProvider

public final class AsyncProvider<T> {
    public let key: ProviderKey
    public let keepAlive: Bool
    fileprivate let factory: (Ref) async throws -> T

    public init(
        _ label: String = "Async<\(T.self)>",
        keepAlive: Bool = false,
        _ factory: @escaping (Ref) async throws -> T
    ) {
        self.key = .unique(label: label)
        self.keepAlive = keepAlive
        self.factory = factory
    }
}

// MARK: - ProviderContainer

/// Public interface — thin async wrapper around ProviderGraph.
/// @Observable so SwiftUI views re-render on any published change.
@Observable
public final class ProviderContainer {

    private let graph = ProviderGraph()
    private let observers: [ProviderObserver]

    public init(observers: [ProviderObserver] = []) {
        self.observers = observers
    }

    // MARK: Sync read (async dispatch to actor)

    /// Reads a provider, blocking the calling async context until resolved.
    public func read<T>(_ provider: Provider<T>) async -> T {
        let value = await graph.read(provider)
        observers.forEach { $0.didAddProvider(provider.key, value: value) }
        return value
    }

    /// Synchronous read for use inside already-actor-isolated contexts.
    /// Prefer this inside SwiftUI .task { } or other async contexts via await read().
    public func readSync<T>(_ provider: Provider<T>) -> T {
        graph.assumeIsolated { $0.read(provider) }
    }

    // MARK: Async provider

    public func watch<T>(_ provider: AsyncProvider<T>) async -> StateHolder<AsyncState<T>> {
        await graph.buildAsync(provider, observers: observers)
    }

    // MARK: Invalidate

    public func invalidate<T>(_ provider: Provider<T>) async {
        await graph.invalidate(key: provider.key, observers: observers)
    }

    public func invalidate<T>(_ provider: AsyncProvider<T>) async {
        await graph.invalidate(key: provider.key, observers: observers)
    }
}

// MARK: - ProviderObserver

public protocol ProviderObserver {
    func didAddProvider(_ key: ProviderKey, value: Any)
    func didDisposeProvider(_ key: ProviderKey)
    func didUpdateProvider(_ key: ProviderKey, value: Any)
}

public extension ProviderObserver {
    func didAddProvider(_ key: ProviderKey, value: Any) {}
    func didDisposeProvider(_ key: ProviderKey) {}
    func didUpdateProvider(_ key: ProviderKey, value: Any) {}
}

// MARK: - SwiftUI Integration

#if canImport(SwiftUI)
import SwiftUI

private struct ContainerKey: EnvironmentKey {
    static let defaultValue = ProviderContainer()
}

public extension EnvironmentValues {
    var providerContainer: ProviderContainer {
        get { self[ContainerKey.self] }
        set { self[ContainerKey.self] = newValue }
    }
}

public struct ProviderScope<Content: View>: View {
    private let container: ProviderContainer
    private let content: Content

    public init(
        observers: [ProviderObserver] = [],
        @ViewBuilder content: () -> Content
    ) {
        self.container = ProviderContainer(observers: observers)
        self.content = content()
    }

    public var body: some View {
        content.environment(\.providerContainer, container)
    }
}
#endif

// MARK: - Usage Example

/*

// 1. Define providers at module scope

let networkProvider = Provider<URLSession>("network", keepAlive: true) { _ in
    URLSession.shared
}

let userRepositoryProvider = Provider<UserRepository>("userRepo") { ref in
    let session = ref.watch(networkProvider)
    ref.onDispose { print("repo disposed") }
    return UserRepository(session: session)
}

let counterProvider = Provider<StateHolder<Int>>.state("counter", initial: 0)

let userProvider = AsyncProvider<User>("currentUser") { ref in
    let repo = ref.watch(userRepositoryProvider)
    return try await repo.fetchCurrentUser()
}

// 2. Consume in SwiftUI

struct UserView: View {
    @Environment(\.providerContainer) private var container
    @State private var userHolder: StateHolder<AsyncState<User>>?

    var body: some View {
        Group {
            switch userHolder?.state {
            case .loading, nil:   ProgressView()
            case .data(let u):    Text(u.name)
            case .error(let e):   Text(e.localizedDescription)
            }
        }
        .task {
            userHolder = await container.watch(userProvider)
        }
    }
}

// 3. Logger observer

struct LoggingObserver: ProviderObserver {
    func didAddProvider(_ key: ProviderKey, value: Any) {
        print("[River] ✅  \(key)")
    }
    func didDisposeProvider(_ key: ProviderKey) {
        print("[River] 🗑️  \(key)")
    }
}

*/
