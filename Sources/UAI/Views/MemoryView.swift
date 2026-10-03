import SwiftUI

/// Shared memory: what every AI should know about you, plus the chats from
/// all your AIs that UAI has stored on this Mac.
struct MemoryView: View {
    @EnvironmentObject private var memory: MemoryStore
    @EnvironmentObject private var index: ConversationIndex
    @AppStorage(SettingsKey.shareMemory) private var sharing = true
    @State private var draft = ""
    @State private var editing: MemoryNote.ID?
    @State private var editText = ""

    private var hasKey: Bool { AnthropicClient.apiKey != nil }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 22) {
                    explainer
                    addNote
                    notesList
                    chatsSummary
                }
                .padding(24)
                .frame(maxWidth: 760, alignment: .leading)
                .frame(maxWidth: .infinity)
            }
        }
        .background(Theme.contentBackground)
    }

    private var header: some View {
        HStack(spacing: 10) {
            Image(systemName: "brain.head.profile").font(.title3).foregroundStyle(Theme.violet)
            VStack(alignment: .leading, spacing: 0) {
                Text("Memory").font(.headline)
                Text("Shared by all your AIs · stored only on this Mac").font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            Toggle("Share memory with AIs", isOn: $sharing)
                .toggleStyle(.switch)
                .tint(Theme.pink)
        }
        .padding(.horizontal, 16)
        .frame(height: 48)
    }

    private var explainer: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("One memory for every AI").font(.title3.bold())
            Text("UAI keeps your chats from every AI on this Mac. When you send a message through Universal AI, or press **Memory** above any AI's chat, UAI adds what it knows about you, plus related bits of your chats with the other AIs. Each AI then knows what you told the others.")
                .foregroundStyle(.secondary)
        }
    }

    private var addNote: some View {
        HStack {
            TextField("Add something every AI should know, e.g. “I trade options and prefer short answers”",
                      text: $draft)
                .textFieldStyle(.roundedBorder)
                .onSubmit(add)
            Button("Remember", action: add)
                .buttonStyle(.borderedProminent)
                .tint(Theme.pink)
                .disabled(draft.trimmingCharacters(in: .whitespaces).isEmpty)
        }
    }

    private func add() {
        memory.add(draft)
        draft = ""
    }

    private var notesList: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("What your AIs know about you").font(.headline)
                Spacer()
                Button {
                    Task { await memory.learnFromChats() }
                } label: {
                    if memory.learning {
                        HStack(spacing: 6) { ProgressView().controlSize(.small); Text("Learning…") }
                    } else {
                        Label("Learn from my chats", systemImage: "sparkles")
                    }
                }
                .disabled(!hasKey || memory.learning)
                .help(hasKey
                      ? "Sends your 15 most recent captured chats to Claude to pick out lasting facts about you."
                      : "Add an Anthropic API key in Settings › Universal AI to use this.")
            }
            if let error = memory.lastError {
                Text(error).font(.caption).foregroundStyle(.secondary)
            }
            if memory.notes.isEmpty {
                Text("Nothing yet. Add notes above\(hasKey ? " or let Claude learn them from your chats" : "").")
                    .foregroundStyle(.secondary)
                    .padding(.vertical, 8)
            }
            ForEach(memory.notes) { note in
                HStack(alignment: .top, spacing: 10) {
                    Circle().fill(note.source == "You" ? Theme.pink : Theme.aqua).frame(width: 7, height: 7)
                        .padding(.top, 6)
                    if editing == note.id {
                        TextField("", text: $editText)
                            .textFieldStyle(.roundedBorder)
                            .onSubmit {
                                memory.update(note, text: editText)
                                editing = nil
                            }
                    } else {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(note.text).textSelection(.enabled)
                            Text("\(note.source) · \(note.date.formatted(date: .abbreviated, time: .omitted))")
                                .font(.caption).foregroundStyle(.tertiary)
                        }
                    }
                    Spacer()
                    Button {
                        editing = note.id
                        editText = note.text
                    } label: { Image(systemName: "pencil") }
                    Button { memory.delete(note) } label: { Image(systemName: "trash") }
                }
                .buttonStyle(.borderless)
                .padding(10)
                .background(Theme.card, in: RoundedRectangle(cornerRadius: 8))
            }
        }
    }

    private var chatsSummary: some View {
        let counts = Dictionary(grouping: index.items.values, by: \.provider).mapValues(\.count)
        return VStack(alignment: .leading, spacing: 8) {
            Text("Chats stored on this Mac").font(.headline)
            Text("\(index.items.count) chats from \(counts.count) AIs. UAI adds chats as you open each AI, and saves the full text of chats you open.")
                .font(.callout).foregroundStyle(.secondary)
            HStack(spacing: 14) {
                ForEach(Provider.all.filter { counts[$0.id] != nil }) { provider in
                    HStack(spacing: 5) {
                        ProviderIcon(provider: provider, size: 18)
                        Text("\(counts[provider.id] ?? 0)").font(.callout.monospacedDigit())
                    }
                }
            }
        }
    }
}
