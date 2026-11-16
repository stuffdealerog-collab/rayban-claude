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
                // Язык выбирается первым: на нём и интерфейс, и разговор с ассистентом.
                Picker("Til · Язык · Language", selection: $settings.language) {
                    ForEach(AssistantLanguage.allCases) { Text($0.title).tag($0) }
                }
                .pickerStyle(.segmented)
                .padding(.top, Theme.Space.m)
                RouteMap(hub: settings.persona.displayName)
                    .frame(height: 300)
                VStack(alignment: .leading, spacing: Theme.Space.m) {
                    Text(L("Ассистент в ваших очках"))
                        .font(.sign(.largeTitle))
                        .foregroundStyle(Theme.textPrimary)
                    Text(L("Слышит вас через очки Ray-Ban Meta и отвечает голосом. Видит их камерой, помнит вас, ведёт календарь и почту, переводит разговор. Сначала придумайте, каким он будет."))
                        .font(.body)
                        .foregroundStyle(Theme.textSecondary)
                }
                Spacer()
            }
            .padding(.horizontal, Theme.Space.xl)

        case .name:
            StepPage(title: L("Как его зовут"), subtitle: L("По этому имени он будет откликаться в режиме «Без рук».")) {
                TextField(L("Имя"), text: $settings.persona.assistantName)
                    .font(.sign(.largeTitle))
                    .foregroundStyle(Theme.textPrimary)
                    .textInputAutocapitalization(.words)
                    .autocorrectionDisabled()
                    .padding(.vertical, Theme.Space.s)
                    .overlay(alignment: .bottom) { Capsule().fill(tone.color).frame(height: 6) }
                FlowChips(options: Persona.suggestedNames, selected: settings.persona.assistantName) {
                    settings.persona.assistantName = $0
                }
            }

        case .character:
            StepPage(title: L("Какой у него характер"), subtitle: L("Это определяет, как %@ говорит и шутит. Можно поменять в настройках.", settings.persona.displayName)) {
                VStack(alignment: .leading, spacing: 0) {
                    // Характеры — станции одной линии: выбранная становится пересадкой.
                    let characters = PersonaCharacter.allCases
                    ForEach(Array(characters.enumerated()), id: \.element) { index, character in
                        let isSelected = settings.persona.character == character
                        LineRow(
                            stop: isSelected ? .interchange : .station, tone: tone,
                            isFirst: index == 0, isLast: index == characters.count - 1
                        ) {
                            ChoiceRow(title: character.title, detail: character.summary, isSelected: isSelected, tone: tone) {
                                withAnimation(Theme.ease(0.2)) { settings.persona.character = character }
                            }
                        }
                    }
                    if settings.persona.character == .custom {
                        TextField(L("Например: спокойный, говорит как старый друг, немного философ"), text: $settings.persona.customCharacter, axis: .vertical)
                            .lineLimit(3...5)
                            .padding(Theme.Space.m)
                            .padding(.top, Theme.Space.s)
                            .background(Theme.surface, in: RoundedRectangle(cornerRadius: Theme.Radius.control + 2, style: .continuous))
                            .overlay(RoundedRectangle(cornerRadius: Theme.Radius.control + 2, style: .continuous).strokeBorder(Theme.hairline))
                    }
                }
            }

        case .manner:
            StepPage(title: L("Как ему с вами говорить"), subtitle: L("Язык управления — на нём %@ слушает. Заговорите на другом из трёх — ответит на нём.", settings.persona.displayName)) {
                VStack(alignment: .leading, spacing: Theme.Space.xl) {
                    LabeledControl(title: L("Язык")) {
                        Picker(L("Язык"), selection: $settings.language) {
                            ForEach(AssistantLanguage.allCases) { Text($0.title).tag($0) }
                        }
                        .pickerStyle(.segmented)
                    }
                    LabeledControl(title: L("Обращение")) {
                        Picker(L("Обращение"), selection: $settings.persona.address) {
                            ForEach(AddressForm.allCases) { Text($0.title).tag($0) }
                        }
                        .pickerStyle(.segmented)
                    }
                    LabeledControl(title: L("Ответы")) {
                        Picker(L("Ответы"), selection: $settings.persona.length) {
                            ForEach(AnswerLength.allCases) { Text($0.title).tag($0) }
                        }
                        .pickerStyle(.segmented)
                    }
                    LabeledControl(title: L("Юмор")) {
                        Slider(value: $settings.persona.humor, in: 0...1) {
                            Text(L("Юмор"))
                        } minimumValueLabel: {
                            Text(L("Серьёзно")).font(.caption).foregroundStyle(Theme.textMuted)
                        } maximumValueLabel: {
                            Text(L("Шутливо")).font(.caption).foregroundStyle(Theme.textMuted)
                        }
                    }
                }
            }

        case .about:
            StepPage(title: L("Расскажите о себе"), subtitle: L("%@ запишет это в память и будет учитывать. Можно пропустить — он узнает вас в разговоре.", settings.persona.displayName)) {
                VStack(spacing: Theme.Space.m) {
                    TextField(L("Ваше имя"), text: $settings.persona.userName)
                        .textInputAutocapitalization(.words)
                        .padding(Theme.Space.m)
                        .background(Theme.surface, in: RoundedRectangle(cornerRadius: Theme.Radius.control + 2, style: .continuous))
                        .overlay(RoundedRectangle(cornerRadius: Theme.Radius.control + 2, style: .continuous).strokeBorder(Theme.hairline))
                    TextField(L("Чем занимаетесь, где живёте, что важно помнить: «Живу в Ташкенте, работаю дизайнером, не ем острое, у жены день рождения 3 мая»"), text: $aboutText, axis: .vertical)
                        .lineLimit(5...10)
                        .padding(Theme.Space.m)
                        .background(Theme.surface, in: RoundedRectangle(cornerRadius: Theme.Radius.control + 2, style: .continuous))
                        .overlay(RoundedRectangle(cornerRadius: Theme.Radius.control + 2, style: .continuous).strokeBorder(Theme.hairline))
                }
            }

        case .keys:
            StepPage(title: L("Ключи"), subtitle: L("Ключи хранятся только в Keychain этого iPhone.")) {
                VStack(alignment: .leading, spacing: Theme.Space.xl) {
                    KeyField(
                        title: L("Claude — обязательно"),
                        detail: L("platform.claude.com → API Keys. Это «мозг» ассистента; оплата — за использование."),
                        placeholder: "sk-ant-…",
                        text: $settings.apiKey
                    )
                    KeyField(
                        title: L("ElevenLabs — живой голос"),
                        detail: L("elevenlabs.io → Developers → API Keys. Есть бесплатный тариф. Нужен для узбекского языка."),
                        placeholder: L("Необязательно"),
                        text: $settings.elevenLabsAPIKey
                    )
                }
            }

        case .access:
            StepPage(title: L("Микрофон и очки"), subtitle: L("Календарь, контакты и геолокацию %@ попросит, когда они впервые понадобятся.", settings.persona.displayName)) {
                VStack(spacing: Theme.Space.s) {
                    AccessRow(
                        symbol: "mic",
                        title: L("Микрофон и речь"),
                        state: micGranted == true ? L("Разрешено") : nil
                    ) {
                        Task { micGranted = await SpeechListener.requestPermissions() }
                    }
                    if micGranted == false {
                        ServiceNotice(text: L("Микрофон запрещён. Разрешите его: Настройки iPhone → это приложение → Микрофон."))
                    }
                    AccessRow(
                        symbol: "eyeglasses",
                        title: L("Очки Ray-Ban"),
                        state: glasses.isRegistered ? L("Подключены") : nil
                    ) {
                        Task { await glasses.connect() }
                    }
                    Text(L("Для очков нужен Meta AI с режимом разработчика: Meta AI → Настройки → ваши очки → Developer Mode. Подключить можно и позже."))
                        .font(.footnote)
                        .foregroundStyle(Theme.textMuted)
                        .frame(maxWidth: .infinity, alignment: .leading)
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
        .accessibilityLabel(L("Шаг %@ из %@", step.rawValue, Step.allCases.count - 1))
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
                .accessibilityLabel(L("Назад"))
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
        case .welcome: return L("Создать ассистента")
        case .about: return aboutText.isEmpty && settings.persona.userName.isEmpty ? L("Пропустить") : L("Дальше")
        case .keys: return settings.trimmedAPIKey.isEmpty ? L("Добавлю позже") : L("Дальше")
        case .access: return L("Готово")
        default: return L("Дальше")
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
                await assistant.prepareVoice()
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

/// Вариант на линии: название и пояснение. Отметку рисует сама линия.
private struct ChoiceRow: View {
    let title: String
    let detail: String
    let isSelected: Bool
    let tone: Theme.Tone
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.sign(.title3))
                    .foregroundStyle(isSelected ? tone.text : Theme.textPrimary)
                Text(detail)
                    .font(.subheadline)
                    .foregroundStyle(Theme.textSecondary)
                    .multilineTextAlignment(.leading)
            }
            .frame(maxWidth: .infinity, minHeight: 44, alignment: .topLeading)
            .contentShape(Rectangle())
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
                .foregroundStyle(Theme.textPrimary)
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

/// Строка разрешения: нажимается целиком.
private struct AccessRow: View {
    let symbol: String
    let title: String
    let state: String?
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: Theme.Space.m) {
                Image(systemName: symbol)
                    .font(.body.weight(.medium))
                    .frame(width: 26)
                    .foregroundStyle(Theme.textSecondary)
                Text(title)
                    .font(.body)
                    .foregroundStyle(Theme.textPrimary)
                    .multilineTextAlignment(.leading)
                Spacer(minLength: Theme.Space.s)
                if let state {
                    Label(state, systemImage: "checkmark")
                        .font(.subheadline.weight(.medium))
                        .foregroundStyle(Theme.positive)
                } else {
                    Text(L("Разрешить"))
                        .font(.sign(.subheadline, weight: .semibold))
                        .foregroundStyle(Theme.Tone.assistant.text)
                }
            }
            .padding(.horizontal, Theme.Space.l)
            .frame(maxWidth: .infinity, minHeight: 56)
            .background(Theme.surface, in: RoundedRectangle(cornerRadius: Theme.Radius.card, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: Theme.Radius.card, style: .continuous).strokeBorder(Theme.hairline))
        }
        .buttonStyle(PressScaleStyle())
        .disabled(state != nil)
    }
}
