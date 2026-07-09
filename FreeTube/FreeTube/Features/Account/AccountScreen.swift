import SwiftUI
import Kingfisher

@available(iOS 17.0, *)
struct AccountScreen: View {
    @State private var model = AccountViewModel()
    @State private var showingLogin = false

    var body: some View {
        NavigationStack {
            List {
                if let info = model.info {
                    Section {
                        HStack(spacing: 12) {
                            KFImage(info.avatarURL)
                                .thumbnail(size: CGSize(width: 64, height: 64)) {
                                    Circle().fill(.gray.opacity(0.2))
                                }
                                .resizable()
                                .scaledToFill()
                                .frame(width: 64, height: 64)
                                .clipShape(Circle())

                            VStack(alignment: .leading) {
                                Text(info.displayName).font(.headline)
                                if let handle = info.handle {
                                    Text(handle).font(.caption).foregroundStyle(.secondary)
                                }
                            }
                        }
                    }
                    Section {
                        Button(role: .destructive) {
                            Task { await model.signOut() }
                        } label: {
                            Label("Sign out", systemImage: "rectangle.portrait.and.arrow.right")
                        }
                    }
                } else {
                    Section {
                        Button {
                            showingLogin = true
                        } label: {
                            Label("Sign in to YouTube", systemImage: "person.crop.circle.badge.plus")
                        }
                    } footer: {
                        Text("FreeTube uses a `WKWebView` to capture cookies. They are stored only in the Keychain.")
                    }
                }

                Section {
                    Button(role: .destructive) {
                        Task { await SessionManager.shared.handleExpiredSession() }
                    } label: {
                        Label("Reset session", systemImage: "arrow.counterclockwise")
                    }
                } footer: {
                    Text("If videos stop loading, tap this to wipe stored cookies and the visitor token. The next playback attempt will run anonymously.")
                }

                Section {
                    NavigationLink {
                        SettingsScreen()
                    } label: {
                        Label("Settings", systemImage: "gear")
                    }
                }
            }
            .navigationTitle("Account")
            .task { await model.load() }
            .sheet(isPresented: $showingLogin) {
                LoginScreen()
                    .onDisappear { Task { await model.load() } }
            }
            .errorToast(Bindable(model).errorState)
        }
    }
}
