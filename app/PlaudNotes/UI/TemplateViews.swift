import SwiftUI

struct TemplateListView: View {
    @Environment(TemplateStore.self) private var store
    @State private var editing: NoteTemplate?

    var body: some View {
        List {
            Section("內建（不可修改，可複製後編輯）") {
                ForEach(NoteTemplate.builtIns) { t in
                    HStack {
                        Text(t.name)
                        Spacer()
                        Button("複製") { editing = store.duplicate(t) }.buttonStyle(.borderless)
                    }
                }
            }
            Section("自訂") {
                if store.custom.isEmpty { Text("尚無自訂範本").foregroundStyle(.secondary) }
                ForEach(store.custom) { t in
                    Button(t.name) { editing = t }
                }
                .onDelete { idx in idx.map { store.custom[$0] }.forEach(store.delete) }
            }
        }
        .navigationTitle("筆記範本")
        .toolbar {
            Button("新增", systemImage: "plus") {
                let t = NoteTemplate.newCustom()
                store.upsert(t)
                editing = t
            }
        }
        .sheet(item: $editing) { t in TemplateEditor(template: t) }
    }
}

struct TemplateEditor: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(TemplateStore.self) private var store
    @State var template: NoteTemplate

    var body: some View {
        NavigationStack {
            Form {
                TextField("名稱", text: $template.name)
                Section {
                    TextEditor(text: $template.prompt)
                        .frame(minHeight: 280)
                        .font(.body.monospaced())
                } header: { Text("指示（Prompt）") } footer: {
                    Text("可用變數：" + NoteTemplate.variables.joined(separator: " ") + "\n逐字稿會自動附在指示後面，不需要自己加。")
                }
            }
            .navigationTitle("編輯範本")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("取消") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("儲存") { store.upsert(template); dismiss() }
                        .disabled(template.name.trimmingCharacters(in: .whitespaces).isEmpty)
                }
            }
        }
    }
}
