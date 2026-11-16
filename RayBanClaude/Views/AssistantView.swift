import SwiftUI

/// Главный экран: имя ассистента, состояние линии, разговор-линия и кнопки внизу.
struct AssistantView: View {
    @Environment(AssistantController.self) private var assistant
    @Environment(GlassesManager.self) private var glasses
    @Environment(AppSettings.self) private var settings
    @Environment(\.scenePhase) private var scenePhase

    @State private var showGlasses = false
    @State private var showKeyboard = false
    @State private var typedText = ""
    @FocusState private var fieldFocused: Bool

    private let tone = Theme.Tone.assistant

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                ScreenHeader(title: settings.persona.displayName) {
                    GlassesChip { showGlasses = true }
                    Button {
                        assistant.newConversation()
                    } label: {
                        HeaderGlyph(symbol: "square.and.pencil")
                    }
                    .accessibilityLabel("Новый разговор")
                    .disabled(assistant.entries.isEmpty)
                    .opacity(assistant.entries.isEmpty ? 0.45 : 1)
                }

                LineStatus(tone: tone, text: stateLine, detail: stateDetail, active: assistant.phase != .idle || assistant.onCall)
                    .padding(.horizontal, Theme.Space.l + 4)
                    .padding(.top, Theme.Space.xs)
                    .padding(.bottom, Theme.Space.s)

                TranscriptView(
                    entries: assistant.entries,
                    phase: assistant.translatorActive ? .idle : assistant.phase,
                    partial: assistant.translatorActive ? "" : assistant.partialTranscript,
                    assistantName: settings.persona.displayName,
                    listeningCaption: listeningCaption,
                    emptyState: AnyView(emptyState)
                )
                .mask(
                    // Лента мягко уходит под кнопки, а не обрывается линией.
                    LinearGradient(
                        stops: [
                            .init(color: .clear, location: 0), .init(color: .black, location: 0.035),
                            .init(color: .black, location: 0.93), .init(color: .clear, location: 1),
                        ],
                        startPoint: .top, endPoint: .bottom
                    )
                )

                controls
            }
            .background(Theme.background)
            .toolbar(.hidden, for: .navigationBar)
            .sheet(isPresented: $showGlasses) {
                GlassesSheet()
                    .presentationDetents([.medium, .large])
            }
            .onChange(of: scenePhase) { _, phase in
                if phase == .active { Task { await glasses.refreshCameraPermission() } }
            }
        }
    }

    // MARK: - Состояние

    private var stateLine: String {
        if assistant.translatorActive { return "Микрофон у переводчика" }
        switch assistant.callState {
        case .ringing: return "Звоню вам"
        case .connecting: return "Соединяю"
        case .held: return "На удержании"
        case .active, .idle: break
        }
        switch assistant.phase {
        case .idle:
            if assistant.onCall { return "На связи" }
            return assistant.handsFree ? "Слушаю без звонка" : "Линия свободна"
        case .listening: return assistant.onCall ? "На связи · слушаю" : "Слушаю"
        case .thinking: return "Думаю"
        case .speaking: return "Отвечаю"
        }
    }

    private var stateDetail: String? {
        guard !assistant.translatorActive else { return nil }
        switch assistant.phase {
        case .listening: return "микрофон: \(assistant.microphone)"
        case .speaking, .thinking: return "нажмите, чтобы перебить"
        case .idle: return assistant.onCall || assistant.handsFree ? addressingHint : nil
        }
    }

    private var addressingHint: String {
        switch settings.addressing {
        case .smart: return "поймёт, когда обращаются к нему"
        case .name: return "отвечает на «\(settings.effectiveWakeWord)»"
        case .always: return "отвечает на каждую фразу"
        }
    }

    private var listeningCaption: String {
        (assistant.handsFree || assistant.onCall) && assistant.partialTranscript.isEmpty ? "На линии" : "Слушаю"
    }

    // MARK: - Пустое состояние

    /// Разговора ещё нет: первая станция — приветствие, дальше — куда можно поехать.
    private var emptyState: some View {
        VStack(alignment: .leading, spacing: 0) {
            LineRow(stop: .interchange, tone: tone, isFirst: true) {
                VStack(alignment: .leading, spacing: Theme.Space.xs) {
                    Text(settings.persona.displayName).plateStyle(tone.text)
                    Text(greeting)
                        .font(.sign(.title))
                        .foregroundStyle(Theme.textPrimary)
                    Text("Спросите голосом или выберите, с чего начать.")
                        .font(.callout)
                        .foregroundStyle(Theme.textSecondary)
                }
                .padding(.bottom, Theme.Space.s)
            }
            ForEach(Array(Self.examples.enumerated()), id: \.offset) { index, example in
                LineRow(stop: .station, tone: tone, isLast: index == Self.examples.count - 1, planned: true) {
                    Button {
                        assistant.submitTyped(example.text)
                    } label: {
                        HStack(spacing: Theme.Space.s) {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(example.plate).plateStyle()
                                Text(example.text)
                                    .font(.body.weight(.medium))
                                    .foregroundStyle(Theme.textPrimary)
                                    .multilineTextAlignment(.leading)
                            }
                            Spacer(minLength: Theme.Space.s)
                            Image(systemName: "chevron.right")
                                .font(.footnote.weight(.semibold))
                                .foregroundStyle(Theme.textMuted)
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(PressScaleStyle())
                }
            }
        }
    }

    private var greeting: String {
        let hour = Calendar.current.component(.hour, from: Date())
        let hello: String
        switch hour {
        case 5..<12: hello = "Доброе утро"
        case 12..<18: hello = "Добрый день"
        case 18..<23: hello = "Добрый вечер"
        default: hello = "Доброй ночи"
        }
        let user = settings.persona.userName.trimmingCharacters(in: .whitespaces)
        return user.isEmpty ? hello : "\(hello), \(user)"
    }

    private static let examples: [(plate: String, text: String)] = [
        ("Камера очков", "Что передо мной?"),
        ("Календарь", "Какие у меня планы на завтра?"),
        ("Почта", "Есть новые письма?"),
        ("Напоминания", "Напомни через час позвонить маме"),
    ]

    // MARK: - Управление

    private var controls: some View {
        VStack(spacing: Theme.Space.m) {
            if showKeyboard {
                HStack(spacing: Theme.Space.s) {
                    TextField("Спросить текстом", text: $typedText, axis: .vertical)
                        .lineLimit(1...4)
                        .focused($fieldFocused)
                        .submitLabel(.send)
                        .onSubmit(sendTyped)
                        .padding(.horizontal, Theme.Space.l)
                        .padding(.vertical, Theme.Space.m)
                        .background(Theme.surface, in: RoundedRectangle(cornerRadius: Theme.Radius.panel, style: .continuous))
                    Button(action: sendTyped) {
                        Image(systemName: "arrow.up")
                            .font(.body.weight(.bold))
                            .frame(width: 44, height: 44)
                            .background(tone.color, in: Circle())
                            .foregroundStyle(.white)
                    }
                    .disabled(typedText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    .accessibilityLabel("Отправить")
                }
                .transition(.move(edge: .bottom).combined(with: .opacity))
            }

            HStack(alignment: .center, spacing: 0) {
                SideControl(
                    symbol: assistant.onCall ? "phone.down.fill" : "phone.arrow.up.right.fill",
                    label: lineButtonLabel,
                    isOn: assistant.onCall || assistant.handsFree,
                    tone: tone
                ) {
                    Task {
                        if assistant.handsFree && !assistant.onCall {
                            await assistant.setHandsFree(false)
                        } else {
                            await assistant.toggleCall()
                        }
                    }
                }
                .contextMenu {
                    if !assistant.onCall {
                        Button {
                            Task { await assistant.setHandsFree(!assistant.handsFree) }
                        } label: {
                            Label(assistant.handsFree ? "Перестать слушать" : "Слушать без звонка", systemImage: "ear")
                        }
                    }
                }
                .disabled(assistant.translatorActive)
                .accessibilityValue(assistant.onCall ? "на связи" : (assistant.handsFree ? "слушает" : "выключено"))
                .accessibilityHint("Разговор продолжается с заблокированным телефоном")

                Spacer(minLength: Theme.Space.s)

                MicButton(phase: assistant.translatorActive ? .idle : assistant.phase) {
                    Task { await assistant.mainButtonTapped() }
                }
                .disabled(assistant.translatorActive)

                Spacer(minLength: Theme.Space.s)

                SideControl(
                    symbol: showKeyboard ? "keyboard.chevron.compact.down" : "keyboard",
                    label: "Текстом",
                    isOn: showKeyboard,
                    tone: tone
                ) {
                    withAnimation(Theme.ease(0.3)) { showKeyboard.toggle() }
                    fieldFocused = showKeyboard
                }
            }
        }
        .padding(.horizontal, Theme.Space.l)
        .padding(.top, Theme.Space.xs)
        .padding(.bottom, Theme.Space.m)
        .sensoryFeedback(.impact(weight: .light), trigger: assistant.phase) { _, new in
            // Только когда слушать начали по кнопке, а не на каждом перезапуске «без рук».
            new == .listening && !assistant.handsFree
        }
        .sensoryFeedback(.success, trigger: assistant.onCall)
    }

    private var lineButtonLabel: String {
        if assistant.onCall { return "Отбой" }
        return assistant.handsFree ? "Слушаю" : "На связи"
    }

    private func sendTyped() {
        assistant.submitTyped(typedText)
        typedText = ""
    }
}

/// Главная кнопка — станция ассистента: фарфоровый диск в кольце цвета линии.
struct MicButton: View {
    let phase: AssistantController.Phase
    var tone = Theme.Tone.assistant
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 28, weight: .semibold))
                .foregroundStyle(phase == .idle ? Theme.ink : .white)
                .contentTransition(.symbolEffect(.replace))
                .symbolEffect(.variableColor.iterative, options: .repeating, isActive: phase == .listening)
                .frame(width: 80, height: 80)
                .background(
                    Circle()
                        .fill(phase == .idle ? Theme.porcelain : tone.color)
                        .overlay(Circle().strokeBorder(phase == .idle ? tone.color : Theme.porcelain, lineWidth: 6))
                        .shadow(color: Color.black.opacity(0.22), radius: 14, x: 0, y: 8)
                )
        }
        .buttonStyle(PressScaleStyle())
        .accessibilityLabel(accessibilityTitle)
        .animation(Theme.ease(0.25), value: phase)
    }

    private var symbol: String {
        switch phase {
        case .idle: return "mic.fill"
        case .listening: return "waveform"
        case .thinking, .speaking: return "stop.fill"
        }
    }

    private var accessibilityTitle: String {
        switch phase {
        case .idle: return "Говорить"
        case .listening: return "Перестать слушать"
        case .thinking, .speaking: return "Остановить ответ"
        }
    }
}

/// Боковая кнопка: значок и подпись в капсуле. Включённая заливается цветом линии.
struct SideControl: View {
    let symbol: String
    let label: String
    let isOn: Bool
    let tone: Theme.Tone
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 6) {
                Image(systemName: symbol)
                    .font(.subheadline.weight(.semibold))
                    .contentTransition(.symbolEffect(.replace))
                Text(label)
                    .font(.sign(.subheadline, weight: .semibold))
                    .lineLimit(1)
                    .contentTransition(.opacity)
            }
            .foregroundStyle(isOn ? tone.onColor : Theme.textPrimary)
            .frame(width: 112, height: 50)
            .background(background)
        }
        .buttonStyle(PressScaleStyle())
        .animation(Theme.ease(0.25), value: isOn)
        .accessibilityLabel(label)
    }

    @ViewBuilder
    private var background: some View {
        if isOn {
            Capsule().fill(tone.color)
        } else if #available(iOS 26.0, *) {
            Capsule().fill(.clear).glassEffect(.regular.interactive(), in: .capsule)
        } else {
            Capsule().fill(Theme.surface).overlay(Capsule().strokeBorder(Theme.hairline))
        }
    }
}

/// Нажатие — лёгкое уменьшение; одна кривая на всё приложение.
struct PressScaleStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.96 : 1)
            .opacity(configuration.isPressed ? 0.88 : 1)
            .animation(Theme.ease(0.15), value: configuration.isPressed)
    }
}

/// Значок очков в панели: связь и заряд.
private struct GlassesChip: View {
    @Environment(GlassesManager.self) private var glasses
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HeaderGlyph(
                symbol: connected ? "eyeglasses" : "eyeglasses.slash",
                text: connected ? glasses.batteryLevel.map { "\($0)%" } : nil
            )
            .opacity(connected ? 1 : 0.6)
        }
        .accessibilityLabel(connected ? "Очки на связи" : "Очки не подключены")
    }

    private var connected: Bool { glasses.isRegistered && glasses.hasActiveDevice }
}

/// Очки: регистрация, связь, камера, превью.
struct GlassesSheet: View {
    @Environment(GlassesManager.self) private var glasses
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            List {
                Section {
                    HStack(spacing: Theme.Space.l) {
                        preview
                        VStack(alignment: .leading, spacing: Theme.Space.xs) {
                            Text(statusTitle)
                                .font(.headline)
                            Text(statusDetail)
                                .font(.footnote)
                                .foregroundStyle(Theme.textSecondary)
                            if let battery = glasses.batteryLevel {
                                Text("Заряд \(battery)%")
                                    .font(.footnote.monospacedDigit())
                                    .foregroundStyle(Theme.textSecondary)
                            }
                        }
                    }
                    .padding(.vertical, Theme.Space.xs)
                }

                Section {
                    if !glasses.isRegistered {
                        Button("Подключить через Meta AI") {
                            Task { await glasses.connect() }
                        }
                        .disabled(glasses.registrationState == .registering)
                    } else {
                        if glasses.cameraPermissionGranted != true {
                            Button("Разрешить камеру в Meta AI") {
                                Task { await glasses.requestCameraPermission() }
                            }
                        }
                        Button("Отключить приложение от очков", role: .destructive) {
                            Task { await glasses.disconnect() }
                        }
                    }
                } footer: {
                    Text("Нужен Meta AI с включённым режимом разработчика: Meta AI → Настройки → ваши очки → Developer Mode.")
                }
            }
            .navigationTitle("Очки")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Готово") { dismiss() }
                }
            }
            .task { await glasses.refreshCameraPermission() }
        }
    }

    @ViewBuilder
    private var preview: some View {
        if let image = glasses.previewImage {
            Image(uiImage: image)
                .resizable()
                .scaledToFill()
                .frame(width: 64, height: 112)
                .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.control, style: .continuous))
        } else {
            RoundedRectangle(cornerRadius: Theme.Radius.control, style: .continuous)
                .fill(Theme.raised)
                .frame(width: 64, height: 112)
                .overlay(Image(systemName: "eyeglasses").foregroundStyle(Theme.textMuted))
        }
    }

    private var statusTitle: String {
        switch glasses.registrationState {
        case .registered: return glasses.hasActiveDevice ? "Очки на связи" : "Очки не рядом"
        case .registering: return "Подключение через Meta AI"
        case .available: return "Очки не подключены"
        case .unavailable: return "Meta AI недоступен"
        }
    }

    private var statusDetail: String {
        if !glasses.isRegistered { return "Разрешите приложению доступ в Meta AI." }
        if glasses.cameraPermissionGranted != true { return "Камера пока не разрешена." }
        return glasses.isStreaming ? "Камера включена" : "Камера включится по запросу"
    }
}
