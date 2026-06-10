// UserProfileApp.swift
// A realistic example showing:
//   - Dependency chain: URLSession → Repository → AsyncProvider<User>
//   - AsyncState<T> (.loading / .data / .error) in SwiftUI
//   - keepAlive for infrastructure providers
//   - onDispose cleanup
//   - container.invalidate() to trigger a refresh
//   - ProviderObserver for debug logging
//
// To run: create a new SwiftUI iOS 17 app and paste this file in.
// The example uses JSONPlaceholder (https://jsonplaceholder.typicode.com) — no auth needed.

import SwiftUI
import SwiftRiver

// MARK: - Models

struct User: Decodable, Equatable {
    let id: Int
    let name: String
    let username: String
    let email: String
    let phone: String
    let website: String
}

// MARK: - Repository

final class UserRepository {
    private let session: URLSession

    init(session: URLSession) {
        self.session = session
    }

    func fetchUser(id: Int) async throws -> User {
        let url = URL(string: "https://jsonplaceholder.typicode.com/users/\(id)")!
        let (data, response) = try await session.data(from: url)

        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
            throw URLError(.badServerResponse)
        }

        return try JSONDecoder().decode(User.self, from: data)
    }
}

// MARK: - Providers

/// Shared URLSession — keepAlive so it is never torn down between requests.
let sessionProvider = Provider<URLSession>("URLSession", keepAlive: true) { _ in
    let config = URLSessionConfiguration.default
    config.timeoutIntervalForRequest = 10
    return URLSession(configuration: config)
}

/// UserRepository depends on sessionProvider via ref.watch().
/// Demonstrates synchronous dependency composition inside a factory.
let repositoryProvider = Provider<UserRepository>("UserRepository") { ref in
    let session = ref.watch(sessionProvider)
    ref.onDispose { print("[River] UserRepository torn down") }
    return UserRepository(session: session)
}

/// The currently selected user ID — mutable state that drives the async fetch.
let selectedUserIDProvider = Provider<StateHolder<Int>>.state("selectedUserID", initial: 1)

/// Fetches the user for the currently selected ID.
/// Re-invalidate this provider to trigger a fresh fetch.
let currentUserProvider = AsyncProvider<User>("currentUser") { ref in
    let repo = ref.watch(repositoryProvider)
    let idHolder = ref.watch(selectedUserIDProvider)
    return try await repo.fetchUser(id: idHolder.state)
}

// MARK: - App Entry Point

@main
struct UserProfileApp: App {
    var body: some Scene {
        WindowGroup {
            ProviderScope(observers: [DebugObserver()]) {
                UserProfileView()
            }
        }
    }
}

// MARK: - Views

struct UserProfileView: View {
    @Environment(\.providerContainer) private var container

    @State private var userHolder: StateHolder<AsyncState<User>>?
    @State private var selectedIDHolder: StateHolder<Int>?
    @State private var isRefreshing = false

    var body: some View {
        NavigationStack {
            Group {
                switch userHolder?.state {
                case .loading, nil:
                    loadingView
                case .data(let user):
                    userCard(user)
                case .error(let error):
                    errorView(error)
                }
            }
            .navigationTitle("User Profile")
            .toolbar {
                ToolbarItem(placement: .primaryAction) {
                    Button {
                        Task { await refresh() }
                    } label: {
                        if isRefreshing {
                            ProgressView().controlSize(.small)
                        } else {
                            Label("Refresh", systemImage: "arrow.clockwise")
                        }
                    }
                    .disabled(isRefreshing)
                }
            }
        }
        .task {
            selectedIDHolder = await container.read(selectedUserIDProvider)
            userHolder = await container.watch(currentUserProvider)
        }
    }

    // MARK: Subviews

    private var loadingView: some View {
        VStack(spacing: 12) {
            ProgressView()
            Text("Loading user…")
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func userCard(_ user: User) -> some View {
        List {
            Section {
                VStack(alignment: .leading, spacing: 4) {
                    Text(user.name)
                        .font(.title2.bold())
                    Text("@\(user.username)")
                        .foregroundStyle(.secondary)
                }
                .padding(.vertical, 4)
            }

            Section("Contact") {
                LabeledContent("Email", value: user.email)
                LabeledContent("Phone", value: user.phone)
                LabeledContent("Website", value: user.website)
            }

            Section("Load a different user") {
                userIDPicker
            }
        }
        .animation(.default, value: user.id)
    }

    private func errorView(_ error: Error) -> some View {
        VStack(spacing: 16) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 48))
                .foregroundStyle(.orange)
            Text("Failed to load user")
                .font(.headline)
            Text(error.localizedDescription)
                .font(.caption)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            Button("Try Again") {
                Task { await refresh() }
            }
            .buttonStyle(.bordered)
        }
        .padding()
    }

    private var userIDPicker: some View {
        HStack {
            Text("User ID")
            Spacer()
            Picker("User ID", selection: Binding(
                get: { selectedIDHolder?.state ?? 1 },
                set: { newID in
                    selectedIDHolder?.state = newID
                    Task { await refresh() }
                }
            )) {
                ForEach(1...10, id: \.self) { id in
                    Text("\(id)").tag(id)
                }
            }
            .pickerStyle(.menu)
        }
    }

    // MARK: Actions

    /// Invalidates the currentUserProvider and re-watches it, triggering a fresh fetch.
    private func refresh() async {
        isRefreshing = true
        await container.invalidate(currentUserProvider)
        userHolder = await container.watch(currentUserProvider)

        // Wait for resolution
        while true {
            guard let state = userHolder?.state else { break }
            if case .loading = state {
                try? await Task.sleep(nanoseconds: 50_000_000)
            } else {
                break
            }
        }
        isRefreshing = false
    }
}

// MARK: - Observer

struct DebugObserver: ProviderObserver {
    func didAddProvider(_ key: ProviderKey, value: Any) {
        print("[River] ✅ Added:   \(key)")
    }
    func didDisposeProvider(_ key: ProviderKey) {
        print("[River] 🗑️ Disposed: \(key)")
    }
}
