import SwiftUI

/// The second screen: who and what the app remembers, where each thing was last seen, and the recent
/// questions and answers. Everything here is also reachable by voice ("Who do you know?", "Forget
/// Sarah"); this is for looking it over and for a sighted helper.
struct MemoryView: View {
    @ObservedObject var model: AppModel
    @Environment(\.dismiss) private var dismiss
    @State private var confirmingForgetAll = false
    @State private var confirmingForget = false
    /// Who or what the "Forget" confirmation is asking about.
    @State private var forgetName = ""
    @Environment(\.dynamicTypeSize) private var typeSize
    /// Thumbnails grow with the text beside them.
    @ScaledMetric(relativeTo: .headline) private var thumbnailSize: CGFloat = 56

    var body: some View {
        NavigationStack {
            List {
                Section {
                    NavigationLink {
                        VoiceSettingsPage(settings: .shared)
                    } label: {
                        Label("Settings", systemImage: "gearshape.fill")
                    }
                }
                Section("People") {
                    if model.memoryPeople.isEmpty {
                        Text("No one yet. Point at someone and say “This is Sarah”.")
                            .foregroundStyle(.secondary)
                    }
                    ForEach(model.memoryPeople, id: \.name) { person in
                        row(thumbnail: person.thumbnail, symbol: "person.fill", title: person.name,
                            detail: "\(person.samples.count) face sample\(person.samples.count == 1 ? "" : "s")")
                            .forgettable { forget(person.name) }
                    }
                }
                Section("Things") {
                    if model.memoryBelongings.isEmpty {
                        Text("Nothing yet. Point at something and say “Remember this as my keys”.")
                            .foregroundStyle(.secondary)
                    }
                    ForEach(model.memoryBelongings, id: \.name) { thing in
                        row(thumbnail: thing.thumbnail, symbol: "shippingbox.fill", title: thing.name.capitalized,
                            detail: lastSeen(thing))
                            .forgettable { forget(thing.name) }
                    }
                }
                Section("Recent") {
                    if model.history.isEmpty {
                        Text("Questions and answers from this session appear here.")
                            .foregroundStyle(.secondary)
                    }
                    ForEach(model.history) { exchange in
                        VStack(alignment: .leading, spacing: 4) {
                            Text(exchange.question).font(.subheadline).foregroundStyle(.secondary)
                            Text(exchange.answer).font(.body)
                        }
                        // Which line was the question is otherwise told only by its size and color.
                        .accessibilityElement(children: .ignore)
                        .accessibilityLabel("You asked: \(exchange.question) Answer: \(exchange.answer)")
                    }
                }
                Section {
                    Button("Forget everything", role: .destructive) { confirmingForgetAll = true }
                        .disabled(model.memoryPeople.isEmpty && model.memoryBelongings.isEmpty)
                } footer: {
                    Text("Faces and things are stored only on this phone.")
                }
            }
            .navigationTitle("Memories")
            .toolbar {
                ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } }
            }
            .confirmationDialog("Forget every person and thing?", isPresented: $confirmingForgetAll, titleVisibility: .visible) {
                Button("Forget everything", role: .destructive) { model.forgetEverything() }
            }
        }
        .onAppear { model.refreshMemory() }
        // A face or a thing that is forgotten cannot be brought back, so one swipe is not enough.
        .confirmationDialog("Forget \(forgetName)?", isPresented: $confirmingForget, titleVisibility: .visible) {
            Button("Forget", role: .destructive) { model.forget(forgetName) }
        }
    }

    private func row(thumbnail: Data?, symbol: String, title: String, detail: String) -> some View {
        // Side by side, large text is squeezed into a few characters a line; stacked, it has the width.
        let layout = typeSize.isAccessibilitySize
            ? AnyLayout(VStackLayout(alignment: .leading, spacing: 8)) : AnyLayout(HStackLayout(spacing: 12))
        return layout {
            Group {
                if let thumbnail, let image = UIImage(data: thumbnail) {
                    Image(uiImage: image).resizable().scaledToFill()
                } else {
                    Image(systemName: symbol).font(.title2).foregroundStyle(.secondary)
                }
            }
            .frame(width: thumbnailSize, height: thumbnailSize)
            .background(Color(.secondarySystemBackground))
            .clipShape(RoundedRectangle(cornerRadius: 10))
            .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.headline)
                Text(detail).font(.subheadline).foregroundStyle(.secondary)
            }
        }
        .accessibilityElement(children: .combine)
    }

    private func forget(_ name: String) {
        forgetName = name
        confirmingForget = true
    }

    private func lastSeen(_ thing: Belonging) -> String {
        guard let seen = thing.lastSeen else { return "Not seen since it was learned" }
        var text = "Seen \(MemoryReplies.ago(seen.date))"
        if let surface = seen.near.first(where: { $0.hasPrefix("on:") }) { text += ", on the \(surface.dropFirst(3))" }
        if let beside = seen.near.first(where: { !$0.hasPrefix("on:") }) { text += ", near \(beside)" }
        return text
    }
}

private extension View {
    /// "Forget" on a swipe, and in a long-press menu for anyone who cannot swipe.
    func forgettable(_ forget: @escaping () -> Void) -> some View {
        swipeActions {
            // Darker than the system's destructive red, whose white label is only 3.4:1.
            Button("Forget", action: forget).tint(Color(red: 0.78, green: 0.12, blue: 0.12))
        }
        .contextMenu { Button("Forget", role: .destructive, action: forget) }
    }
}
