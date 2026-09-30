import Foundation
import Observation

/// App 設定（UserDefaults）。API key 不在這裡，一律存 Keychain。
@MainActor
@Observable
final class AppSettings {
    private let defaults: UserDefaults

    var llm: LLMConfig {
        didSet { saveLLM() }
    }
    var chineseConversion: ChineseConversionSetting {
        didSet { defaults.set(chineseConversion.rawValue, forKey: ChineseConversionSetting.storageKey) }
    }
    var noteLanguage: NoteLanguage {
        didSet { defaults.set(noteLanguage.rawValue, forKey: "noteLanguage") }
    }
    var defaultTemplateID: UUID {
        didSet { defaults.set(defaultTemplateID.uuidString, forKey: "defaultTemplateID") }
    }

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        if let data = defaults.data(forKey: "llmConfig"),
           let c = try? JSONDecoder().decode(LLMConfig.self, from: data) {
            llm = c
        } else {
            llm = .default
        }
        chineseConversion = defaults.string(forKey: ChineseConversionSetting.storageKey)
            .flatMap(ChineseConversionSetting.init(rawValue:)) ?? .s2tw
        noteLanguage = defaults.string(forKey: "noteLanguage").flatMap(NoteLanguage.init(rawValue:)) ?? .zhTW
        defaultTemplateID = defaults.string(forKey: "defaultTemplateID").flatMap(UUID.init(uuidString:))
            ?? NoteTemplate.builtIns[0].id
    }

    func selectPreset(_ preset: LLMPreset) {
        llm = LLMConfig(preset: preset)
    }

    private func saveLLM() {
        if let data = try? JSONEncoder().encode(llm) { defaults.set(data, forKey: "llmConfig") }
    }
}
