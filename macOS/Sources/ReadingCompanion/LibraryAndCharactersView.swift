import SwiftUI

struct ImportCategorySheet: View {
    @EnvironmentObject private var model: ReaderModel
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            VStack(alignment: .leading, spacing: 6) {
                Text("选择书籍类型")
                    .font(.title2.bold())
                Text(model.pendingImportURL?.deletingPathExtension().lastPathComponent ?? "待导入书籍")
                    .font(.headline)
                    .lineLimit(2)
                Text("类型会决定 AI 伴读方式和导航功能，也可稍后在书架的批量管理中修改。")
                    .foregroundStyle(.secondary)
            }

            categoryButton(.nonfiction, symbol: "text.book.closed")
            categoryButton(.fiction, symbol: "theatermasks")

            HStack {
                Spacer()
                Button("取消") {
                    model.cancelPendingImport()
                    dismiss()
                }
                .keyboardShortcut(.cancelAction)
            }
        }
        .padding(24)
        .frame(width: 500)
    }

    private func categoryButton(_ category: BookCategory, symbol: String) -> some View {
        Button {
            model.confirmPendingImport(as: category)
            dismiss()
        } label: {
            HStack(spacing: 15) {
                Image(systemName: symbol)
                    .font(.system(size: 28))
                    .foregroundStyle(Color(nsColor: category.markerColor))
                    .frame(width: 42)
                VStack(alignment: .leading, spacing: 5) {
                    Text(category.rawValue).font(.headline)
                    Text(category.detail)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.leading)
                }
                Spacer()
                Image(systemName: "chevron.right").foregroundStyle(.tertiary)
            }
            .padding(15)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .background(Color(nsColor: category.markerColor).opacity(0.08), in: RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).stroke(Color(nsColor: category.markerColor).opacity(0.25)))
    }
}

struct CharacterSidebarContent: View {
    @EnvironmentObject private var model: ReaderModel
    @State private var expandedIDs: Set<UUID> = []

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("人物索引").font(.headline)
                Spacer()
                Text("\(model.characters.count) 人")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Button {
                    model.assistantVisible = true
                    model.characterManagementVisible = true
                } label: {
                    Label("管理", systemImage: "slider.horizontal.3")
                }
                .buttonStyle(.borderless)
                .help("在右侧打开人物管理")
                .disabled(model.zoomLocked && !model.assistantVisible)
            }
            .padding(10)
            Divider()

            if model.characters.isEmpty {
                VStack(spacing: 10) {
                    Image(systemName: "person.2")
                        .font(.system(size: 28))
                        .foregroundStyle(.secondary)
                    Text("还没有人物").font(.headline)
                    Text("点击右上角“管理”，可批量识别或逐个添加人物。")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                        .frame(maxWidth: 220)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                List {
                    ForEach(model.characters) { character in
                        characterRow(character)
                    }
                    .onMove { offsets, destination in
                        model.moveCharacters(fromOffsets: offsets, toOffset: destination)
                    }
                }
            }
        }
    }

    private func characterRow(_ character: BookCharacter) -> some View {
        DisclosureGroup(isExpanded: Binding(
            get: { expandedIDs.contains(character.id) },
            set: { expanded in
                if expanded { expandedIDs.insert(character.id) }
                else { expandedIDs.remove(character.id) }
            }
        )) {
            if expandedIDs.contains(character.id) {
                let occurrences = model.characterOccurrences(for: character)
                let occurrenceWindow = model.characterOccurrenceWindow(
                    for: character,
                    occurrences: occurrences
                )
                VStack(alignment: .leading, spacing: 9) {
                    if character.allNames.count > 1 {
                        Text("姓名：\(character.allNames.joined(separator: "、"))")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    HStack(spacing: 8) {
                        Label("全文 \(occurrences.count) 处", systemImage: "magnifyingglass")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Spacer()
                        Button("上一次") { model.navigateCharacter(character, direction: -1) }
                        Button("下一次") { model.navigateCharacter(character, direction: 1) }
                    }
                    .buttonStyle(.borderless)
                    .disabled(occurrences.isEmpty)

                    ForEach(Array(occurrenceWindow), id: \.self) { index in
                        let occurrence = occurrences[index]
                        Button { model.goToCharacterOccurrence(occurrence, character: character, index: index) } label: {
                            HStack(alignment: .firstTextBaseline, spacing: 6) {
                                Text("\(index + 1) · P\(occurrence.pageIndex + 1)")
                                    .font(.caption2.monospacedDigit())
                                    .foregroundStyle(.secondary)
                                Text(occurrence.text)
                                    .font(.caption)
                                    .lineLimit(2)
                            }
                        }
                        .buttonStyle(.plain)
                    }
                    if occurrences.count > occurrenceWindow.count,
                       let first = occurrenceWindow.first,
                       let last = occurrenceWindow.last {
                        Text("当前显示第 \(first + 1)–\(last + 1) 处，可用上一次/下一次依次查看")
                            .font(.caption2)
                            .foregroundStyle(.tertiary)
                    }
                }
                .padding(.top, 7)
            }
        } label: {
            HStack(spacing: 8) {
                Circle()
                    .fill(Color(nsColor: character.color))
                    .frame(width: 9, height: 9)
                VStack(alignment: .leading, spacing: 2) {
                    Text(character.name)
                        .fontWeight(.semibold)
                        .foregroundStyle(Color(nsColor: character.color))
                        .lineLimit(1)
                        .truncationMode(.tail)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(Color(nsColor: character.color).opacity(0.14), in: Capsule())
                    let details = character.information
                    if !details.isEmpty {
                        Text(details)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .truncationMode(.tail)
                    }
                }
                Spacer(minLength: 0)
            }
            .font(.system(size: 13))
        }
    }
}

struct CharacterManagementPanel: View {
    @EnvironmentObject private var model: ReaderModel
    @State private var batchSource = ""
    @State private var newName = ""
    @State private var newDetails = ""
    @State private var isSelecting = false
    @State private var selectedCharacterIDs: Set<UUID> = []
    /// 面板内的本地工作副本：所有修改先落到副本，点“保存”才写回并持久化
    @State private var workingCharacters: [BookCharacter] = []

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Label("人物管理", systemImage: "person.2.fill")
                    .font(.headline)
                Spacer()
                Toggle("文中高亮", isOn: Binding(
                    get: { model.characterHighlightsEnabled },
                    set: { enabled in model.setCharacterHighlightsEnabled(enabled) }
                ))
                .toggleStyle(.switch)
                .controlSize(.small)
                Button("保存") {
                    model.replaceCharacters(workingCharacters)
                    model.characterManagementVisible = false
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
                .keyboardShortcut(.return, modifiers: .command)
            }
            .padding(12)
            Divider()

            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    GroupBox("批量识别") {
                        VStack(alignment: .leading, spacing: 10) {
                            Text("每行一位人物：人物名字/别名：信息。多个别名用斜杠隔开，也可省略别名。")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                            ZStack(alignment: .topLeading) {
                                if batchSource.isEmpty {
                                    Text("阿辽沙/阿廖沙：卡拉马佐夫家的幼子，德米特里的弟弟\n伊万：知识分子，阿辽沙的兄长")
                                        .font(.system(size: 13))
                                        .foregroundStyle(Color(.placeholderTextColor))
                                        .padding(.horizontal, 12)
                                        .padding(.vertical, 15)
                                        .allowsHitTesting(false)
                                }
                                TextEditor(text: $batchSource)
                                    .font(.system(size: 13))
                                    .frame(minHeight: 150)
                                    .scrollContentBackground(.hidden)
                                    .padding(6)
                                    .background(Color(nsColor: .textBackgroundColor), in: RoundedRectangle(cornerRadius: 7))
                                    .overlay(RoundedRectangle(cornerRadius: 7).stroke(Color.secondary.opacity(0.25)))
                            }
                            HStack {
                                Spacer()
                                Button("批量识别") {
                                    if mergeBatch(batchSource) > 0 { batchSource = "" }
                                }
                                .buttonStyle(.borderedProminent)
                                .disabled(batchSource.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                            }
                        }
                        .padding(.top, 5)
                    }

                    GroupBox("逐个添加") {
                        VStack(spacing: 9) {
                            TextField("人物名字", text: $newName)
                            TextField("身份，关系等信息", text: $newDetails)
                            HStack {
                                Text("添加后会自动分配未使用的独立颜色。")
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)
                                Spacer()
                                Button("添加人物", action: addSingleCharacter)
                                    .disabled(newName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                            }
                        }
                        .textFieldStyle(.roundedBorder)
                        .padding(.top, 5)
                    }

                    VStack(alignment: .leading, spacing: 10) {
                        HStack(spacing: 12) {
                            Text("已添加人物").font(.headline)
                            Spacer()
                            if isSelecting {
                                Button(selectedCharacterIDs.count == workingCharacters.count ? "取消全选" : "全选") {
                                    if selectedCharacterIDs.count == workingCharacters.count {
                                        selectedCharacterIDs.removeAll()
                                    } else {
                                        selectedCharacterIDs = Set(workingCharacters.map(\.id))
                                    }
                                }
                                .buttonStyle(.borderless)
                                Button("删除(\(selectedCharacterIDs.count))", role: .destructive) {
                                    workingCharacters.removeAll { selectedCharacterIDs.contains($0.id) }
                                    selectedCharacterIDs.removeAll()
                                    isSelecting = false
                                }
                                .buttonStyle(.borderless)
                                .disabled(selectedCharacterIDs.isEmpty)
                                Button("完成") {
                                    isSelecting = false
                                    selectedCharacterIDs.removeAll()
                                }
                                .buttonStyle(.borderless)
                            } else {
                                Text("\(workingCharacters.count) 人")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                Button("选择") { isSelecting = true }
                                    .buttonStyle(.borderless)
                                    .disabled(workingCharacters.isEmpty)
                            }
                        }
                        if workingCharacters.isEmpty {
                            Text("识别或添加后，可在这里逐个修改。")
                                .font(.callout)
                                .foregroundStyle(.secondary)
                                .frame(maxWidth: .infinity, alignment: .center)
                                .padding(.vertical, 22)
                        } else {
                            LazyVStack(spacing: 9) {
                                ForEach($workingCharacters) { $character in
                                    CharacterManagementRow(
                                        character: $character,
                                        isSelecting: isSelecting,
                                        isSelected: selectedCharacterIDs.contains(character.id),
                                        onToggleSelection: { toggleSelection(character.id) }
                                    )
                                        .dropDestination(for: String.self) { items, _ in
                                            guard !isSelecting,
                                                  let payload = items.first,
                                                  let fromID = UUID(uuidString: payload) else { return false }
                                            moveWorkingCharacter(id: fromID, before: character.id)
                                            return true
                                        }
                                }
                                // 拖到列表底部时把人物移到最后
                                Color.clear
                                    .frame(height: 14)
                                    .contentShape(Rectangle())
                                    .dropDestination(for: String.self) { items, _ in
                                        guard !isSelecting,
                                              let payload = items.first,
                                              let fromID = UUID(uuidString: payload) else { return false }
                                        moveWorkingCharacter(id: fromID, before: nil)
                                        return true
                                    }
                            }
                        }
                    }
                }
                .padding(14)
            }
        }
        .background(.regularMaterial)
        .onAppear { workingCharacters = model.characters }
    }

    /// 解析批量文本并合并进本地工作副本（同名更新、新名追加），返回识别条数
    private func mergeBatch(_ source: String) -> Int {
        var recognized = 0
        for rawLine in source.components(separatedBy: .newlines) {
            guard let parsed = ReaderModel.parseCharacterBatchLine(rawLine) else { continue }
            var character = workingCharacters.first {
                $0.name.localizedCaseInsensitiveCompare(parsed.name) == .orderedSame
            } ?? BookCharacter(name: parsed.name)
            character.name = parsed.name
            character.aliases = parsed.aliases
            character.identity = parsed.identity
            character.relationship = parsed.relationship
            if let index = workingCharacters.firstIndex(where: { $0.id == character.id }) {
                workingCharacters[index] = character
            } else {
                workingCharacters.append(character)
            }
            recognized += 1
        }
        return recognized
    }

    private func moveWorkingCharacter(id: UUID, before targetID: UUID?) {
        guard let from = workingCharacters.firstIndex(where: { $0.id == id }) else { return }
        let item = workingCharacters.remove(at: from)
        if let targetID, let target = workingCharacters.firstIndex(where: { $0.id == targetID }) {
            workingCharacters.insert(item, at: target)
        } else {
            workingCharacters.append(item)
        }
    }

    private func toggleSelection(_ id: UUID) {
        if selectedCharacterIDs.contains(id) {
            selectedCharacterIDs.remove(id)
        } else {
            selectedCharacterIDs.insert(id)
        }
    }

    private func addSingleCharacter() {
        let line = "\(newName)：\(newDetails)"
        guard mergeBatch(line) > 0 else { return }
        newName = ""
        newDetails = ""
    }
}

private struct CharacterManagementRow: View {
    @Binding var character: BookCharacter
    var isSelecting = false
    var isSelected = false
    var onToggleSelection: () -> Void = {}

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            if isSelecting {
                Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                    .font(.system(size: 18))
                    .foregroundStyle(isSelected ? Color.accentColor : Color.secondary)
                    .padding(.top, 1)
            }
            VStack(alignment: .leading, spacing: 9) {
                HStack(spacing: 8) {
                    if !isSelecting {
                        Image(systemName: "line.3.horizontal")
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundStyle(.tertiary)
                            .padding(.vertical, 4)
                            .contentShape(Rectangle())
                            .draggable(character.id.uuidString)
                            .help("拖动调整人物顺序")
                    }
                    Circle().fill(Color(nsColor: character.color)).frame(width: 11, height: 11)
                    TextField("人物名字", text: $character.name)
                        .textFieldStyle(.plain)
                        .fontWeight(.semibold)
                        .foregroundStyle(Color(nsColor: character.color))
                        .lineLimit(1)
                        .padding(.horizontal, 7)
                        .padding(.vertical, 3)
                        .background(Color(nsColor: character.color).opacity(0.14), in: Capsule())
                    Spacer()
                }
                TextField("其他名字（顿号或逗号分隔）", text: aliasesBinding)
                    .textFieldStyle(.roundedBorder)
                TextField("身份、关系等信息", text: informationBinding)
                    .textFieldStyle(.roundedBorder)
            }
        }
        .padding(11)
        .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 9))
        .overlay(RoundedRectangle(cornerRadius: 9).stroke(isSelecting && isSelected ? Color.accentColor.opacity(0.55) : Color.secondary.opacity(0.14)))
        .contentShape(Rectangle())
        .onTapGesture {
            if isSelecting { onToggleSelection() }
        }
    }

    private var aliasesBinding: Binding<String> {
        Binding(
            get: { character.aliases.joined(separator: "、") },
            set: { character.aliases = [$0] }
        )
    }

    private var informationBinding: Binding<String> {
        Binding(
            get: { character.information },
            set: {
                character.identity = $0
                character.relationship = ""
            }
        )
    }
}
