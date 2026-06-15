# SwiftRiver Architecture

This document describes the internal design of SwiftRiver — the structure of each layer, the reasoning behind key decisions, and the tradeoffs made. It is intended for contributors and anyone who wants to understand the framework beyond its API surface.

---

## Overview

SwiftRiver is structured in five layers, each with a single responsibility:

```
┌──────────────────────────────────────────────┐
│              SwiftUI Layer                   │  ProviderScope, EnvironmentValues
├──────────────────────────────────────────────┤
│           ProviderContainer                  │  Public API — @Observable thin wrapper
├──────────────────────────────────────────────┤
│     Provider  /  AsyncProvider               │  Value declarations (factories)
├──────────────────────────────────────────────┤
│        Ref  /  StateHolder                   │  Factory handle + observable state box
├──────────────────────────────────────────────┤
│    ProviderGraph (actor)  /  ProviderNode    │  Isolated graph, cache, autoDispose
└──────────────────────────────────────────────┘
```

---

## Layer 1: `ProviderGraph` — the actor-isolated core

```swift
actor ProviderGraph {
    private var cache: [ProviderKey: Any]
    private var nodes: [ProviderKey: ProviderNode]
    private var refs:  [ProviderKey: Ref]
}
```

`ProviderGraph` is a Swift `actor`. This is the central architectural decision in SwiftRiver.

By making the graph an actor, all mutations to the cache and dependency graph are automatically serialized by Swift's cooperative thread pool — no `NSLock`, no `DispatchQueue`, no `@unchecked Sendable` workarounds. Concurrent reads from multiple tasks are queued and executed one at a time, in order.

### `ProviderNode` — the graph vertex

Each registered provider gets a `ProviderNode` inside the graph:

```swift
final class ProviderNode {
    let key: ProviderKey
    var dependents: Set<ProviderKey>    // who depends on me
    var dependencies: Set<ProviderKey>  // who I depend on
    var dispose: (() -> Void)?
    let keepAlive: Bool
}
```

`ProviderNode` is a plain `final class` — it lives entirely inside the actor and never escapes, so reference semantics are safe here without `Sendable` conformance.

### `ProviderKey` — stable identity

```swift
public struct ProviderKey: Hashable {
    let id: UUID
    private let label: String
}
```

Keys are created via `.unique(label:)`, which generates a fresh `UUID` per call-site. The UUID provides a stable, unique identity for the lifetime of the process — without requiring the user to manually assign string identifiers. Multiple providers of the same value type are distinguished by their key, not their generic parameter.

---

## Layer 2: `Ref` and `assumeIsolated`

`Ref` is the factory handle passed to every provider's factory closure. It serves two purposes:

1. **Dependency registration** — `ref.watch()` reads another provider and registers a graph edge
2. **Disposal hooks** — `ref.onDispose()` registers cleanup closures that run when the provider is disposed

```swift
public final class Ref {
    private let graph: ProviderGraph
    fileprivate let nodeKey: ProviderKey
    private var disposals: [() -> Void] = []
}
```

### The `assumeIsolated` contract in `ref.watch()`

This is the most subtle part of SwiftRiver's design:

```swift
public func watch<T>(_ provider: Provider<T>) -> T {
    graph.assumeIsolated { graph in
        graph.registerEdge(from: nodeKey, to: provider.key)
        return graph.read(provider)
    }
}
```

`actor.assumeIsolated` is a Swift standard library function that asserts — at runtime — that the current execution context is already on the actor's executor. If the assertion holds, it grants synchronous, non-`async` access to the actor's isolated state.

**Why is this safe here?**

The call chain is:

```
ProviderGraph.read(provider)          ← actor turn begins
  └─ ProviderGraph.build(provider)    ← still inside actor turn
       └─ provider.factory(ref)       ← factory runs synchronously
            └─ ref.watch(other)       ← assumeIsolated asserts actor is held
                 └─ graph.registerEdge / graph.read
```

Between `build()` entering and `factory(ref)` returning, there is **no `await`** — no suspension point where another task could preempt and acquire the actor. Swift's structured concurrency guarantees this: actor reentrancy only occurs at `await` boundaries, and there are none here.

`assumeIsolated` converts this runtime guarantee into a synchronous code path, avoiding the need to make every factory `async` just to read a dependency. If the guarantee is ever violated — if `ref.watch()` is called outside of a factory context — the program crashes immediately with a clear error, rather than producing a silent data race.

---

## Layer 3: `StateHolder<T>` and `AsyncState<T>`

### `StateHolder<T>`

```swift
@Observable
public final class StateHolder<T> {
    public var state: T
}
```

`StateHolder` is the observable box for mutable state. It uses Swift 5.9's `@Observable` macro, which generates fine-grained property-level tracking. SwiftUI views that read `holder.state` will only re-render when `state` changes — not on unrelated mutations to other `@Observable` objects.

This is intentionally minimal. `StateHolder` has no mutation API beyond direct property assignment — state mutation is the provider consumer's responsibility, keeping the framework's surface area small.

### `AsyncState<T>`

```swift
public enum AsyncState<T> {
    case loading
    case data(T)
    case error(Error)
}
```

`AsyncProvider` results are wrapped in `StateHolder<AsyncState<T>>`. The holder is created immediately (in `.loading`) and returned to the caller before the async work begins. The `Task` that runs the factory updates the holder on the `@MainActor` when it completes:

```swift
Task {
    do {
        let value = try await provider.factory(ref)
        await MainActor.run { holder.state = .data(value) }
    } catch {
        await MainActor.run { holder.state = .error(error) }
    }
}
```

Updating `holder.state` on `@MainActor` ensures that SwiftUI re-renders are always triggered from the main thread, matching UIKit/SwiftUI's threading requirements.

---

## Layer 4: `Provider` and `AsyncProvider`

Both types are plain `final class` values — not structs — because they carry a factory closure and are referenced by the graph's cache dictionary.

```swift
public final class Provider<T> {
    public let key: ProviderKey
    public let keepAlive: Bool
    fileprivate let factory: (Ref) -> T
}

public final class AsyncProvider<T> {
    public let key: ProviderKey
    public let keepAlive: Bool
    fileprivate let factory: (Ref) async throws -> T
}
```

Providers are typically declared as global `let` constants — one declaration per dependency, shared across the whole app. The `key` is stable for the lifetime of the process.

### `Provider.state()` convenience

```swift
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
```

This factory method eliminates the boilerplate of wrapping every mutable value in `StateHolder` manually. It is syntactic sugar — no special runtime behaviour.

---

## Layer 5: `ProviderContainer` and SwiftUI

### `ProviderContainer`

```swift
@Observable
public final class ProviderContainer {
    private let graph = ProviderGraph()
    private let observers: [ProviderObserver]
}
```

`ProviderContainer` is the public interface. It is `@Observable` so it can be injected into the SwiftUI environment and observed by views. Internally it is a thin `async` wrapper around `ProviderGraph`:

```swift
public func read<T>(_ provider: Provider<T>) async -> T {
    let value = await graph.read(provider)
    observers.forEach { $0.didAddProvider(provider.key, value: value) }
    return value
}
```

`readSync` is provided for contexts where the caller can assert actor isolation is already held — mirroring the same `assumeIsolated` pattern used in `Ref.watch()`:

```swift
public func readSync<T>(_ provider: Provider<T>) -> T {
    graph.assumeIsolated { $0.read(provider) }
}
```

### `ProviderScope`

```swift
public struct ProviderScope<Content: View>: View {
    private let container: ProviderContainer
    public var body: some View {
        content.environment(\.providerContainer, container)
    }
}
```

`ProviderScope` creates a `ProviderContainer` and injects it into the SwiftUI environment. Views anywhere in the subtree read it via `@Environment(\.providerContainer)`. There is no global singleton — the container's lifetime is tied to the scope view's lifetime.

---

## autoDispose — Cascade Disposal

When `disposeNode(for:)` is called, SwiftRiver walks the dependency graph upward:

```swift
for depKey in node.dependencies {
    nodes[depKey]?.dependents.remove(key)
    if let upstream = nodes[depKey],
       upstream.dependents.isEmpty,
       !upstream.keepAlive {
        disposeNode(for: depKey, observers: observers)  // recursive cascade
    }
}
```

If removing `key` from an upstream provider's `dependents` leaves it with zero dependents, and it is not `keepAlive`, it is disposed too. This cascades until a `keepAlive` provider or a provider with remaining dependents is reached.

Providers marked `keepAlive: true` are exempt from autoDispose — useful for shared infrastructure like `URLSession` or a database connection that should persist for the app's lifetime.

---

## What SwiftRiver Deliberately Does Not Do

**No Combine dependency.** Change propagation uses `@Observable` and closure-based disposal hooks. This keeps the dependency surface minimal and avoids Combine's threading ambiguities.

**No global mutable state.** There is no `ProviderContainer.shared`. The `EnvironmentKey` default value creates a container as a fallback, but all real usage goes through `ProviderScope`. Tests create fresh containers with no shared state.

**No reflection or `@dynamicMemberLookup`.** Every provider and its value type is known at compile time. The API is explicit and type-safe throughout.

**No `ObservableObject` / `objectWillChange`.** `StateHolder` and `ProviderContainer` use `@Observable`. This is not compatible with iOS 16 and earlier — a deliberate tradeoff for fine-grained reactivity and cleaner code.

---

## Open Questions

These design decisions are not yet settled:

1. **`ProviderKey` persistence** — Keys are UUID-based and stable for the lifetime of the process, but not across restarts. For most DI use cases this is fine, but serializing or persisting provider keys would require a different approach (e.g. stable string identifiers or a macro-generated constant).

2. **Scoped containers** — How should a child `ProviderContainer` interact with its parent's cache? Copy-on-write, delegation, and full isolation are all viable options with different tradeoffs.

3. **Stream-based providers** — `AsyncSequence` support for providers that emit multiple values over time (e.g. a Firestore listener). The challenge is integrating streams with the current disposal model cleanly.

4. **`@River` macro** — Once the API stabilizes, a macro could reduce provider declaration boilerplate significantly. The open question is whether hiding the factory closure obscures too much of the mental model for new users.

Feedback on any of these is welcome via GitHub Discussions.

---

## Further Reading

- [Swift Evolution SE-0306 — Actors](https://github.com/apple/swift-evolution/blob/main/proposals/0306-actors.md)
- [Swift Evolution SE-0316 — Global Actors](https://github.com/apple/swift-evolution/blob/main/proposals/0316-global-actors.md)
- [Swift Evolution SE-0395 — Observation (@Observable)](https://github.com/apple/swift-evolution/blob/main/proposals/0395-observability.md)
- [Riverpod documentation](https://riverpod.dev) — the conceptual inspiration
- [The Composable Architecture](https://github.com/pointfreeco/swift-composable-architecture) — a different set of tradeoffs worth understanding
