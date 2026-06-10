// CounterApp.swift
// The simplest possible SwiftRiver example.
// Shows: Provider.state(), StateHolder mutation, ProviderScope, @Environment.
//
// To run: create a new SwiftUI iOS 17 app and paste this file in.

import SwiftUI
import SwiftRiver

// MARK: - Providers (defined at module scope)

/// A single integer counter, starting at 0.
let counterProvider = Provider<StateHolder<Int>>.state("counter", initial: 0)

/// A derived, read-only provider — doubles the counter value.
/// Demonstrates synchronous dependency composition via ref.watch().
let doubledProvider = Provider<Int>("doubled") { ref in
    ref.watch(counterProvider).state * 2
}

// MARK: - App Entry Point

@main
struct CounterApp: App {
    var body: some Scene {
        WindowGroup {
            // ProviderScope creates the ProviderContainer and injects it
            // into the SwiftUI environment for the entire subtree.
            ProviderScope(observers: [LoggingObserver()]) {
                CounterView()
            }
        }
    }
}

// MARK: - Views

struct CounterView: View {
    @Environment(\.providerContainer) private var container

    // StateHolder is @Observable — SwiftUI re-renders when .state changes.
    @State private var counter: StateHolder<Int>?
    @State private var doubled: Int = 0

    var body: some View {
        VStack(spacing: 24) {
            Text("SwiftRiver Counter")
                .font(.headline)
                .foregroundStyle(.secondary)

            Text("\(counter?.state ?? 0)")
                .font(.system(size: 80, weight: .bold, design: .rounded))
                .contentTransition(.numericText())
                .animation(.spring(duration: 0.3), value: counter?.state)

            Text("Doubled: \(doubled)")
                .font(.subheadline)
                .foregroundStyle(.secondary)

            HStack(spacing: 20) {
                Button {
                    withAnimation { counter?.state -= 1 }
                    Task { doubled = await container.read(doubledProvider) }
                } label: {
                    Image(systemName: "minus.circle.fill")
                        .font(.system(size: 44))
                        .tint(.red)
                }

                Button {
                    withAnimation { counter?.state += 1 }
                    Task { doubled = await container.read(doubledProvider) }
                } label: {
                    Image(systemName: "plus.circle.fill")
                        .font(.system(size: 44))
                        .tint(.green)
                }
            }

            Button("Reset") {
                withAnimation { counter?.state = 0 }
                Task { doubled = await container.read(doubledProvider) }
            }
            .buttonStyle(.bordered)
            .tint(.secondary)
        }
        .padding()
        .task {
            // Read providers once — StateHolder is cached, so subsequent
            // reads return the same instance.
            counter = await container.read(counterProvider)
            doubled = await container.read(doubledProvider)
        }
    }
}

// MARK: - Observer

struct LoggingObserver: ProviderObserver {
    func didAddProvider(_ key: ProviderKey, value: Any) {
        print("[River] ✅ \(key)")
    }
    func didDisposeProvider(_ key: ProviderKey) {
        print("[River] 🗑️ \(key)")
    }
}
