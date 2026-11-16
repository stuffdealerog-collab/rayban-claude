import AssistantCore
import SwiftUI

/// Первый запуск: пользователь создаёт своего ассистента — имя, характер, манера, — подключает ключи и очки.
struct OnboardingView: View {
    @Environment(AppSettings.self) private var settings
    @Environment(GlassesManager.self) private var glasses
    @Environment(AssistantController.self) private var assistant

    private enum Step: Int, CaseIterable {
        case welcome, name, character, manner, about, keys, access
    }

    @State private var step: Step = OnboardingView.initialStep

    private static var initialStep: Step {
        #if DEBUG
        if let raw = DemoMode.onboardingStep, let step = Step(rawValue: raw) { return step }
        #endif
        return .welcome
    }
    @State private var forward = true
    @State private var aboutText = ""
    @State private var micGranted: Bool?

    var body: some View {
        VStack(spacing: 0) {
            if step != .welcome {
                progress
                    .padding(.horizontal, Theme.Space.xl)
                    .padding(.top, Theme.Space.m)
            }

            ZStack {
                content
                    .id(step)
                    .transition(.asymmetric(
                        insertion: .offset(x: forward ? 40 : -40).combined(with: .opacity),
                        removal: .offset(x: forward ? -40 : 40).combined(with: .opacity)
                    ))
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)

            footer
                .padding(.horizontal, Theme.Space.xl)
                .padding(.bottom, Theme.Space.l)
        }
        .background(Theme.background.ignoresSafeArea())
        .tint(tone.text)
    }

    private let tone = Theme.Tone.assistant

    // MARK: - Шаги

    @ViewBuilder
    private var content: some View {
        @Bindable var settings = settings
        switch step {
        case .welcome:
            VStack(alignment: .leading, spacing: Theme.Space.xl) {
                Spacer(minLength: Theme.Space.l)
                RouteMap(hub: settings.persona.displayName)
                    .frame(height: 300)
                VStack(alignment: .leading, spacing: Theme.Space.m) {
                    Text("Ассистент в ваших очках")
                        .font(.sign(.largeTitle))
                        .foregroundStyle(Theme.textPrimary)
                    Text("Слышит вас через очки Ray-Ban Meta и отвечает голосом. Видит их камерой, помнит вас, ведёт календарь и почту, переводит разговор. Сначала придумайте, каким он будет.")
                        .font(.body)
                        .foregroundStyle(Theme.textSecondary)
                }
                Spacer()
            }
            .padding(.horizontal, Theme.Space.xl)

        case .name:
            StepPage(title: "Как его зовут", subtitle: "По этому имени он будет откликаться в режиме «Без рук».") {
                TextField("Имя", text: $settings.persona.assistantName)
                    .font(.sign(.largeTitle))
                    .textInputAutocapitalization(.words)
                    .autocorrectionDisabled()
                    .padding(.vertical, Theme.Space.s)
                    .overlay(alignment: .bottom) { Capsule().fill(tone.color).frame(height: 6) }
                FlowChips(options: Persona.suggestedNames, selected: settings.persona.assistantName) {
                    settings.persona.assistantName = $0
                }
            }

        case .character:
            StepPage(title: "Какой у него характер", subtitle: "Это определяет, как \(settings.persona.displayName) говорит и шутит. Можно поменять в настройках.") {
                VStack(spacing: Theme.Space.s) {
                    ForEach(PersonaCharacter.allCases) { character in
                        ChoiceRow(title: character.title, detail: character.summary, isSelected: settings.persona.character == character) {
                            withAnimation(Theme.ease(0.2)) { settings.persona.character = character }
                        }
                    }
                    if settings.persona.character == .custom {
                        TextField("Например: спокойный, говорит как старый друг, немного философ", text: $settings.persona.customCharacter, axis: .vertical)
                            .lineLimit(3...5)
                            .padding(Theme.Space.m)
                            .background(Theme.surface, in: RoundedRectangle(cornerRadius: Theme.Radius.control + 2, style: .continuous))
                            .overlay(RoundedRectangle(cornerRadius: Theme.Radius.control + 2, style: .continuous).strokeBorder(Theme.hairline))
                    }
                }
            }

        case .manner:
            StepPage(title: "Как ему с вами говорить", subtitle: "Язык управления — на нём \(settings.persona.displayName) слушает. Заговорите на другом из трёх — ответит на нём.") {
                VStack(alignment: .leading, spacing: Theme.Space.xl) {
                    LabeledControl(title: "Язык") {
                        Picker("Язык", selection: $settings.language) {
                            ForEach(AssistantLanguage.allCases) { Text($0.title).tag($0) }
                        }
                        .pickerStyle(.segmented)
                    }
                    LabeledControl(title: "Обращение") {
                        Picker("Обращение", selection: $settings.persona.address) {
                            ForEach(AddressForm.allCases) { Text($0.title).tag($0) }
                        }
                        .pickerStyle(.segmented)
                    }
                    LabeledControl(title: "Ответы") {
                        Picker("Ответы", selection: $settings.persona.length) {
                            ForEach(AnswerLength.allCases) { Text($0.title).tag($0) }
                        }
                        .pickerStyle(.segmented)
                    }
                    LabeledControl(title: "Юмор") {
                        Slider(value: $settings.persona.humor, in: 0...1) {
                            Text("Юмор")
                        } minimumValueLabel: {
                            Text("Серьёзно").font(.caption).foregroundStyle(Theme.textMuted)
                        } maximumValueLabel: {
                            Text("Шутливо").font(.caption).foregroundStyle(Theme.textMuted)
                        }
                    }
                }
            }

        case .about:
            StepPage(title: "Расскажите о себе", subtitle: "\(settings.persona.displayName) запишет это в память и будет учитывать. Можно пропустить — он узнает вас в разговоре.") {
                VStack(spacing: Theme.Space.m) {
                    TextField("Ваше имя", text: $settings.persona.userName)
                        .textInputAutocapitalization(.words)
                        .padding(Theme.Space.m)
                        .background(Theme.surface, in: RoundedRectangle(cornerRadius: Theme.Radius.control + 2, style: .continuous))
                        .overlay(RoundedRectangle(cornerRadius: Theme.Radius.control + 2, style: .continuous).strokeBorder(Theme.hairline))
                    TextField("Чем занимаетесь, где живёте, что важно помнить: «Живу в Ташкенте, работаю дизайнером, не ем острое, у жены день рождения 3 мая»", text: $aboutText, axis: .vertical)
                        .lineLimit(5...10)
                        .padding(Theme.Space.m)
                        .background(Theme.surface, in: RoundedRectangle(cornerRadius: Theme.Radius.control + 2, style: .continuous))
                        .overlay(RoundedRectangle(cornerRadius: Theme.Radius.control + 2, style: .continuous).strokeBorder(Theme.hairline))
                }
            }

        case .keys:
            StepPage(title: "Ключи", subtitle: "Ключи хранятся только в Keychain этого iPhone.") {
                VStack(alignment: .leading, spacing: Theme.Space.xl) {
                    KeyField(
                        title: "Claude — обязательно",
                        detail: "platform.claude.com → API Keys. Это «мозг» ассистента; оплата — за использование.",
                        placeholder: "sk-ant-…",
                        text: $settings.apiKey
                    )
                    KeyField(
                        title: "ElevenLabs — живой голос",
                        detail: "elevenlabs.io → Developers → API Keys. Есть бесплатный тариф. Нужен для узбекского языка.",
                        placeholder: "Необязательно",
                        text: $settings.elevenLabsAPIKey
                    )
                }
            }

        case .access:
            StepPage(title: "Микрофон и очки", subtitle: "Календарь, контакты и геолокацию \(settings.persona.displayName) попросит, когда они впервые понадобятся.") {
                VStack(spacing: Theme.Space.s) {
                    AccessRow(
                        symbol: "mic",
                        title: "Микрофон и распознавание речи",
                        state: micGranted == true ? "Разрешено" : (micGranted == false ? "Запрещено в Настройках" : nil)
                    ) {
                        Task { micGranted = await SpeechListener.requestPermissions() }
                    }
                    AccessRow(
                        symbol: "eyeglasses",
                        title: "Очки Ray-Ban Meta",
                        state: glasses.isRegistered ? "Подключены" : nil
                    ) {
                        Task { await glasses.connect() }
                    }
                    Text("Для очков нужен Meta AI с режимом разработчика: Meta AI → Настройки → ваши очки → Developer Mode. Подключить можно и позже.")
                        .font(.footnote)
                        .foregroundStyle(Theme.textMuted)
                        .padding(.top, Theme.Space.s)
                }
            }
        }
    }

    /// Путь настройки — линия со станциями: пройденные залиты, текущая — кольцо.
    private var progress: some View {
        let steps = Step.allCases.dropFirst()
        return HStack(spacing: 0) {
            ForEach(Array(steps.enumerated()), id: \.element) { index, item in
                if index > 0 {
                    Rectangle()
                        .fill(item.rawValue <= step.rawValue ? tone.color : Theme.hairline)
                        .frame(height: 6)
                }
                Circle()
                    .fill(item.rawValue < step.rawValue ? tone.color : Theme.porcelain)
                    .overlay(
                        Circle().strokeBorder(item.rawValue <= step.rawValue ? tone.color : Theme.textMuted.opacity(0.5), lineWidth: 4)
                    )
                    .frame(width: item == step ? 20 : 14, height: item == step ? 20 : 14)
            }
        }
        .frame(height: 20)
        .animation(Theme.ease(0.4), value: step)
        .accessibilityElement()
        .accessibilityLabel("Шаг \(step.rawValue) из \(Step.allCases.count - 1)")
    }

    private var footer: some View {
        HStack(spacing: Theme.Space.m) {
            if step != .welcome {
                Button {
                    move(by: -1)
                } label: {
                    Image(systemName: "chevron.left")
                        .font(.body.weight(.semibold))
                        .frame(width: 56, height: 56)
                        .background(Theme.surface, in: Circle())
                        .overlay(Circle().strokeBorder(Theme.hairline))
                        .foregroundStyle(Theme.textPrimary)
                }
                .accessibilityLabel("Назад")
            }
            Button {
                if step == .access { finish() } else { move(by: 1) }
            } label: {
                HStack(spacing: Theme.Space.s) {
                    Text(primaryTitle).font(.sign(.title3))
                    Image(systemName: "arrow.right").font(.body.weight(.bold))
                }
                .frame(maxWidth: .infinity, minHeight: 56)
                .background(tone.color, in: RoundedRectangle(cornerRadius: Theme.Radius.card, style: .continuous))
                .foregroundStyle(.white)
            }
            .buttonStyle(PressScaleStyle())
            .disabled(!canContinue)
            .opacity(canContinue ? 1 : 0.5)
        }
        .sensoryFeedback(.selection, trigger: step)
    }

    private var primaryTitle: String {
        switch step {
        case .welcome: return "Создать ассистента"
        case .about: return aboutText.isEmpty && settings.persona.userName.isEmpty ? "Пропустить" : "Дальше"
        case .keys: return settings.trimmedAPIKey.isEmpty ? "Добавлю позже" : "Дальше"
        case .access: return "Готово"
        default: return "Дальше"
        }
    }

    private var canContinue: Bool {
        switch step {
        case .name: return !settings.persona.assistantName.trimmingCharacters(in: .whitespaces).isEmpty
        case .character: return settings.persona.character != .custom || !settings.persona.customCharacter.trimmingCharacters(in: .whitespaces).isEmpty
        default: return true
        }
    }

    private func move(by offset: Int) {
        guard let next = Step(rawValue: step.rawValue + offset) else { return }
        forward = offset > 0
        withAnimation(Theme.ease(0.4)) { step = next }
    }

    private func finish() {
        seedMemory()
        settings.onboardingCompleted = true
        if !settings.trimmedAPIKey.isEmpty || !settings.trimmedElevenLabsKey.isEmpty {
            let greeting = assistant.greeting
            Task {
                try? await Task.sleep(nanoseconds: 700_000_000)
                await assistant.say(greeting)
            }
        }
    }

    /// То, что пользователь рассказал о себе, — первая заметка памяти.
    private func seedMemory() {
        let name = settings.persona.userName.trimmingCharacters(in: .whitespacesAndNewlines)
        let about = aboutText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty || !about.isEmpty else { return }
        let memory = assistant.memory
        var lines: [String] = []
        if !name.isEmpty { lines.append("- Имя: \(name)") }
        if !about.isEmpty { lines.append("- \(about)") }
        if let existing = try? memory.read(MemoryStore.profileName), !existing.isEmpty {
            try? memory.write(MemoryStore.profileName, text: existing + "\n\n## Из первой настройки\n" + lines.joined(separator: "\n"))
        } else {
            try? memory.write(MemoryStore.profileName, text: "# Обо мне\n\n" + lines.joined(separator: "\n") + "\n")
        }
        NotificationCenter.default.post(name: .memoryDidChange, object: nil)
    }
}

// MARK: - Части шагов

private struct StepPage<Content: View>: View {
    let title: String
    let subtitle: String
    @ViewBuilder let content: Content

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Theme.Space.xl) {
                VStack(alignment: .leading, spacing: Theme.Space.s) {
                    Text(title)
                        .font(.sign(.largeTitle))
                        .foregroundStyle(Theme.textPrimary)
                    Text(subtitle)
                        .font(.callout)
                        .foregroundStyle(Theme.textSecondary)
                }
                content
            }
            .padding(.horizontal, Theme.Space.xl)
            .padding(.top, Theme.Space.xxl)
            .padding(.bottom, Theme.Space.xl)
        }
        .scrollDismissesKeyboard(.interactively)
    }
}

private struct ChoiceRow: View {
    let title: String
    let detail: String
    let isSelected: Bool
    let action: () -> Void

    private let tone = Theme.Tone.assistant

    var body: some View {
        Button(action: action) {
            HStack(alignment: .center, spacing: Theme.Space.m) {
                // Выбранный вариант — станция в кольце линии.
                Circle()
                    .fill(isSelected ? Theme.porcelain : Theme.background)
                    .overlay(Circle().strokeBorder(isSelected ? tone.color : Theme.textMuted.opacity(0.6), lineWidth: isSelected ? 6 : 3))
                    .frame(width: 24, height: 24)
                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                        .font(.sign(.title3))
                        .foregroundStyle(Theme.textPrimary)
                    Text(detail)
                        .font(.footnote)
                        .foregroundStyle(Theme.textSecondary)
                        .multilineTextAlignment(.leading)
                }
                Spacer(minLength: 0)
            }
            .padding(Theme.Space.m + 2)
            .background(Theme.surface, in: RoundedRectangle(cornerRadius: Theme.Radius.card, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: Theme.Radius.card, style: .continuous)
                    .strokeBorder(isSelected ? tone.color : Theme.hairline, lineWidth: isSelected ? 3 : 1)
            )
        }
        .buttonStyle(PressScaleStyle())
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }
}

private struct FlowChips: View {
    let options: [String]
    let selected: String
    let pick: (String) -> Void

    var body: some View {
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 96), spacing: Theme.Space.s)], alignment: .leading, spacing: Theme.Space.s) {
            ForEach(options, id: \.self) { option in
                Button {
                    pick(option)
                } label: {
                    Text(option)
                        .font(.sign(.body, weight: .semibold))
                        .frame(maxWidth: .infinity, minHeight: 44)
                        .background(option == selected ? Theme.accent : Theme.surface, in: Capsule())
                        .overlay(Capsule().strokeBorder(option == selected ? Color.clear : Theme.hairline))
                        .foregroundStyle(option == selected ? Color.white : Theme.textPrimary)
                }
                .buttonStyle(PressScaleStyle())
            }
        }
    }
}

private struct LabeledControl<Content: View>: View {
    let title: String
    @ViewBuilder let content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Space.s) {
            Text(title).plateStyle()
            content
        }
    }
}

private struct KeyField: View {
    let title: String
    let detail: String
    let placeholder: String
    @Binding var text: String

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Space.s) {
            Text(title)
                .font(.sign(.title3))
            SecureField(placeholder, text: $text)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .padding(Theme.Space.m)
                .background(Theme.surface, in: RoundedRectangle(cornerRadius: Theme.Radius.control + 2, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: Theme.Radius.control + 2, style: .continuous).strokeBorder(Theme.hairline))
            Text(detail)
                .font(.footnote)
                .foregroundStyle(Theme.textSecondary)
        }
    }
}

private struct AccessRow: View {
    let symbol: String
    let title: String
    let state: String?
    let action: () -> Void

    var body: some View {
        HStack(spacing: Theme.Space.m) {
            Image(systemName: symbol)
                .font(.body)
                .frame(width: 24)
                .foregroundStyle(Theme.textSecondary)
            Text(title)
                .font(.body)
                .foregroundStyle(Theme.textPrimary)
            Spacer()
            if let state {
                Text(state)
                    .font(.footnote)
                    .foregroundStyle(Theme.textSecondary)
            } else {
                Button("Разрешить", action: action)
                    .buttonStyle(.bordered)
                    .controlSize(.small)
            }
        }
        .padding(Theme.Space.m)
        .background(Theme.surface, in: RoundedRectangle(cornerRadius: Theme.Radius.card, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: Theme.Radius.card, style: .continuous).strokeBorder(Theme.hairline))
    }
}
