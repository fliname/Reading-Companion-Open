import SwiftUI

@main
struct ReadingCompanionApp: App {
    @StateObject private var primaryModel = ReaderModel()
    @FocusedValue(\.readerModel) private var focusedModel

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(primaryModel)
                .focusedValue(\.readerModel, primaryModel)
                .frame(minWidth: 1_080, minHeight: 680)
        }
        .windowStyle(.titleBar)
        .commands { readerCommands }

        WindowGroup("阅读项目", for: String.self) { $documentPath in
            ReaderProjectWindow(documentPath: documentPath)
        }
        .windowStyle(.titleBar)

        Settings {
            SettingsView()
                .environmentObject(focusedModel ?? primaryModel)
                .frame(width: 680, height: 560)
        }
    }

    @CommandsBuilder
    private var readerCommands: some Commands {
            CommandGroup(replacing: .undoRedo) {
                Button("撤销划线修改") { focusedModel?.undoHighlightChange() }
                    .keyboardShortcut("z", modifiers: .command)
                    .disabled(focusedModel?.canUndoHighlight != true)
                Button("重做划线修改") { focusedModel?.redoHighlightChange() }
                    .keyboardShortcut("z", modifiers: [.command, .shift])
                    .disabled(focusedModel?.canRedoHighlight != true)
            }
            CommandGroup(replacing: .newItem) {
                Button("打开 PDF…") { focusedModel?.presentOpenPanel() }
                    .keyboardShortcut("o")
            }
            CommandMenu("阅读") {
                Button("上一页") { focusedModel?.changePage(by: -1) }
                    .keyboardShortcut(.upArrow, modifiers: [])
                Button("下一页") { focusedModel?.changePage(by: 1) }
                    .keyboardShortcut(.downArrow, modifiers: [])
                Divider()
                Button("切换当前页书签") { focusedModel?.toggleBookmark() }
                    .keyboardShortcut("d")
            }
    }
}

private struct ReaderProjectWindow: View {
    @StateObject private var model = ReaderModel()
    let documentPath: String?

    var body: some View {
        ContentView()
            .environmentObject(model)
            .focusedValue(\.readerModel, model)
            .frame(minWidth: 1_080, minHeight: 680)
            .task(id: documentPath) {
                guard let documentPath, model.documentURL?.standardizedFileURL.path != documentPath else { return }
                model.open(URL(fileURLWithPath: documentPath))
            }
    }
}

private struct ReaderModelFocusedKey: FocusedValueKey {
    typealias Value = ReaderModel
}

private extension FocusedValues {
    var readerModel: ReaderModel? {
        get { self[ReaderModelFocusedKey.self] }
        set { self[ReaderModelFocusedKey.self] = newValue }
    }
}
