import SwiftUI

@available(iOS 17.0, *)
struct SaveToPlaylistSheet: View {
    @State private var model: SaveToPlaylistViewModel
    @Environment(\.dismiss) private var dismiss
    @State private var showingCreate = false
    @State private var newTitle = ""
    @State private var newIsPrivate = false

    init(videoID: String) {
        _model = State(wrappedValue: SaveToPlaylistViewModel(videoID: videoID))
    }

    var body: some View {
        NavigationStack {
            List {
                Section {
                    ForEach(model.available) { playlist in
                        Button {
                            Task { await model.toggle(playlist) }
                        } label: {
                            HStack {
                                Text(playlist.title)
                                Spacer()
                                if playlist.containsVideo {
                                    Image(systemName: "checkmark")
                                }
                            }
                        }
                    }
                }

                Section {
                    Button {
                        showingCreate = true
                    } label: {
                        Label("New playlist…", systemImage: "plus")
                    }
                }
            }
            .navigationTitle("Save")
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
            .task { await model.load() }
            .errorToast(Bindable(model).errorState)
            .sheet(isPresented: $showingCreate) { createSheet }
        }
    }

    @ViewBuilder
    private var createSheet: some View {
        NavigationStack {
            Form {
                TextField("Title", text: $newTitle)
                Toggle("Private", isOn: $newIsPrivate)
            }
            .navigationTitle("New playlist")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { showingCreate = false }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Create") {
                        Task {
                            await model.createNew(title: newTitle, isPrivate: newIsPrivate)
                            showingCreate = false
                            newTitle = ""
                        }
                    }
                    .disabled(newTitle.isEmpty)
                }
            }
        }
        .presentationDetents([.medium])
    }
}
