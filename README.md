# SwiftRiver 🌊

A lightweight, Riverpod-inspired dependency injection and state management framework for Swift — built on **`actor`-isolated graph**, **`@Observable`**, and **Swift Concurrency** from the ground up.

> ⚠️ **Current Status**: Core architecture is implemented and functional. Not yet recommended for production use. Feedback and contributions welcome.

**Requires**: Swift 5.9+, iOS 17+, macOS 14+

---

## Why I Built This

Most state management solutions for Swift either:

- Wrap `@Published` / `ObservableObject` with thin abstractions — inheriting all of Combine's thread-safety ambiguities, or
- Port patterns from other ecosystems without embracing what Swift's actor model actually offers

I wanted to explore what dependency injection looks like when you treat **the actor as the unit of isolation** — not a lock, not a queue, but a first-class Swift concurrency primitive.

The specific question I kept asking: *what does Riverpod's provider graph look like if the graph itself is an `actor`, and synchronous dependency reads inside factories use `assumeIsolated` to assert — rather than hope — that isolation is already held?*

SwiftRiver is my answer to that question.

---

## Core Concepts

### `Provider<T>`

The fundamental unit. A `Provider` declares *how* to create a value — lazily, with automatic dependency tracking via `Ref`.

```swift
let networkProvider = Provider<URLSession>("network", keepAlive: true) { _ in
    URLSession.shared
}

let repositoryProvider = Provider<UserRepository>("userRepo") { ref in
    let session = ref.watch(networkProvider)  // tracked dependency
    ref.onDispose { print("repo disposed") }
    return UserRepository(session: session)
}
```

### `Provider.state()` — Mutable State

A convenience factory that wraps an initial value in a `StateHolder<T>` — an `@Observable` class that drives SwiftUI re-renders automatically.

```swift
let counterProvider = Provider<StateHolder<Int>>.state("counter", initial: 0)
```

### `AsyncProvider<T>`

For values that require async work to produce (network calls, disk reads). Returns a `StateHolder<AsyncState<T>>` immediately in `.loading`, then transitions to `.data` or `.error`.

```swift
let userProvider = AsyncProvider<User>("currentUser") { ref in
    let repo = ref.watch(userRepositoryProvider)
    return try await repo.fetchCurrentUser()
}
```

### `ProviderContainer`

The public interface. A thin `@Observable` wrapper around the actor-isolated `ProviderGraph`.

```swift
let container = ProviderContainer()

// Async read (preferred)
let session = await container.read(networkProvider)

// Watch an async provider — returns immediately with .loading state
let userHolder = await container.watch(userProvider)
```

### `ProviderScope` — SwiftUI Integration

Injects a `ProviderContainer` into the SwiftUI environment for the entire view subtree.

```swift
@main
struct MyApp: App {
    var body: some Scene {
        WindowGroup {
            ProviderScope(observers: [LoggingObserver()]) {
                ContentView()
            }
        }
    }
}
```

Consume in any view via `@Environment`:

```swift
struct UserView: View {
    @Environment(\.providerContainer) private var container
    @State private var userHolder: StateHolder<AsyncState<User>>?

    var body: some View {
        Group {
            switch userHolder?.state {
            case .loading, nil:  ProgressView()
            case .data(let u):   Text(u.name)
            case .error(let e):  Text(e.localizedDescription)
            }
        }
        .task {
            userHolder = await container.watch(userProvider)
        }
    }
}
```

---

## Design Decisions & Tradeoffs

### The graph is an `actor`

`ProviderGraph` is a Swift `actor`. All cache reads, writes, and graph edge registrations are serialized by the actor's executor — no locks, no queues, no `DispatchQueue.main.async` boilerplate.

### `assumeIsolated` inside `Ref.watch()`

When a provider factory calls `ref.watch(anotherProvider)`, it needs to read and register a graph edge synchronously — without `await`. This is safe because `build()` calls `factory(ref)` *while already holding the actor's turn*. There is no suspension between entering the actor and calling the factory, so no other task can interleave.

`assumeIsolated` asserts this guarantee at runtime:

```swift
public func watch<T>(_ provider: Provider<T>) -> T {
    graph.assumeIsolated { graph in
        graph.registerEdge(from: nodeKey, to: provider.key)
        return graph.read(provider)
    }
}
```

If the assertion is ever violated, the program crashes immediately — a loud failure rather than a silent data race.

### `@Observable` over `ObservableObject`

`StateHolder<T>` and `ProviderContainer` use Swift 5.9's `@Observable` macro. This gives fine-grained property-level tracking — SwiftUI views only re-render when the specific property they read changes, not on any mutation to the object.

### autoDispose with cascade

When a provider with no `keepAlive` loses all its dependents, it is automatically disposed. Disposal cascades upstream: if a now-unused provider was the last dependent of its own dependency, that dependency is disposed too — preventing memory leaks in long-running apps.

---

## Current Status

| Feature | Status |
|---|---|
| `actor`-isolated `ProviderGraph` | ✅ Implemented |
| `Provider<T>` with lazy init | ✅ Implemented |
| `Provider.state()` for mutable state | ✅ Implemented |
| `AsyncProvider<T>` with `AsyncState` | ✅ Implemented |
| Bidirectional dependency graph | ✅ Implemented |
| autoDispose with cascade | ✅ Implemented |
| `ref.watch()` + `ref.onDispose()` | ✅ Implemented |
| `ProviderObserver` protocol | ✅ Implemented |
| SwiftUI `ProviderScope` + Environment | ✅ Implemented |
| `ProviderContainer.invalidate()` | ✅ Implemented |
| Scoped child containers | 📋 Planned |
| Stream-based reactive providers | 📋 Planned |
| Swift macro ergonomics (`@River`) | 📋 Planned |
| Comprehensive test suite | 📋 Planned |

---

## Observability — `ProviderObserver`

Plug in observers to monitor the lifecycle of every provider — useful for logging, analytics, or debugging:

```swift
struct LoggingObserver: ProviderObserver {
    func didAddProvider(_ key: ProviderKey, value: Any) {
        print("[River] ✅  \(key)")
    }
    func didDisposeProvider(_ key: ProviderKey) {
        print("[River] 🗑️  \(key)")
    }
}

ProviderScope(observers: [LoggingObserver()]) { ... }
```

---

## Comparison

| | SwiftRiver | TCA | Riverpod (Flutter) |
|---|---|---|---|
| Language | Swift | Swift | Dart |
| Graph isolation | `actor` | Swift Concurrency | Dart isolates |
| UI reactivity | `@Observable` | `@ObservableState` | `ref.watch()` |
| Async state | `AsyncState<T>` enum | `Effect` | `AsyncNotifier` |
| autoDispose | ✅ | ❌ | ✅ |
| Learning curve | Low–Medium | High | Medium |
| Production ready | ❌ Not yet | ✅ Yes | ✅ Yes |

> TCA is battle-tested and excellent. SwiftRiver explores a smaller, more direct surface area — fewer concepts, same concurrency guarantees.

---

## Roadmap

- [ ] Scoped `ProviderContainer` (child containers for feature modules)
- [ ] Stream / `AsyncSequence`-based providers
- [ ] `@River` macro to reduce declaration boilerplate
- [ ] Full test suite
- [ ] Documentation site

---

## Motivation & Background

I've been building mobile apps professionally across Flutter and native Swift/iOS. After working extensively with Riverpod on the Flutter side, I became curious whether its core idea — providers as lazy, composable, auto-disposable dependency declarations — could be expressed idiomatically in Swift using actors rather than Dart's zone system.

This project is as much an exploration of **Swift Concurrency correctness** as it is a usable framework. If the design thinking interests you, open a Discussion.

---

## Contributing

The best way to contribute right now:

1. Open an issue with your use case or questions about the API design
2. Try wiring it up in a small app and report what breaks
3. Review the `ARCHITECTURE.md` for the internal design and share feedback

---

## License

MIT
