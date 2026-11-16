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
            // Имя ассистента крупно и всегда на месте: лента под ним прокручивается, заголовок — нет.
            .navigationTitle("")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                FixedTitle(title: settings.persona.displayName)
                ToolbarItem(placement: .topBarTrailing) {
                    GlassesChip { showGlasses = true }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        assistant.newConversation()
                    } label: {
                        Image(systemName: "square.and.pencil")
                    }
                    .accessibilityLabel(L("Новый разговор"))
                    .disabled(assistant.entries.isEmpty)
                }
            }
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
        if assistant.translatorActive { return L("Микрофон у переводчика") }
        switch assistant.callState {
        case .ringing: return L("Звоню вам")
        case .connecting: return L("Соединяю")
        case .held: return L("На удержании")
        case .active, .idle: break
        }
        switch assistant.phase {
        case .idle:
            if assistant.onCall { return L("На связи") }
            return assistant.handsFree ? L("Слушаю без звонка") : L("Линия свободна")
        case .listening: return assistant.onCall ? L("На связи · слушаю") : L("Слушаю")
        case .thinking: return L("Думаю")
        case .speaking: return L("Отвечаю")
        }
    }

    private var stateDetail: String? {
        guard !assistant.translatorActive else { return nil }
        switch assistant.phase {
        case .listening: return assistant.microphone == "—" ? nil : L("микрофон: %@", assistant.microphone)
        case .speaking, .thinking: return L("нажмите, чтобы перебить")
        case .idle: return assistant.onCall || assistant.handsFree ? addressingHint : nil
        }
    }

    private var addressingHint: String {
        switch settings.addressing {
        case .smart: return L("поймёт, когда обращаются к нему")
        case .name: return L("отвечает на «%@»", settings.effectiveWakeWord)
        case .always: return L("отвечает на каждую фразу")
        }
    }

    private var listeningCaption: String {
        (assistant.handsFree || assistant.onCall) && assistant.partialTranscript.isEmpty ? L("На линии") : L("Слушаю")
    }

    // MARK: - Пустое состояние

    /// Разговора ещё нет: первая станция — приветствие, дальше — куда можно поехать.
    private var emptyState: some View {
        VStack(alignment: .leading, spacing: 0) {
            LineRow(stop: .interchange, tone: tone, isFirst: true) {
                VStack(alignment: .leading, spacing: Theme.Space.xs) {
                    Text(greeting)
                        .font(.sign(.title))
                        .foregroundStyle(Theme.textPrimary)
                    Text(L("Спросите голосом или выберите, с чего начать."))
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
        case 5..<12: hello = L("Доброе утро")
        case 12..<18: hello = L("Добрый день")
        case 18..<23: hello = L("Добрый вечер")
        default: hello = L("Доброй ночи")
        }
        let user = settings.persona.userName.trimmingCharacters(in: .whitespaces)
        return user.isEmpty ? hello : "\(hello), \(user)"
    }

    /// Вычисляется заново: надписи зависят от языка интерфейса.
    private static var examples: [(plate: String, text: String)] {
        [
        (L("Камера очков"), L("Что передо мной?")),
        (L("Календарь"), L("Какие у меня планы на завтра?")),
        (L("Почта"), L("Есть новые письма?")),
        (L("Напоминания"), L("Напомни через час позвонить маме")),
        ]
    }

    // MARK: - Управление

    private var controls: some View {
        VStack(spacing: Theme.Space.m) {
            if showKeyboard {
                HStack(spacing: Theme.Space.s) {
                    TextField(L("Спросить текстом"), text: $typedText, axis: .vertical)
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
                    .accessibilityLabel(L("Отправить"))
                }
                .transition(.move(edge: .bottom).combined(with: .opacity))
            }

            // Микрофон строго по центру, боковым кнопкам — поровну места: иначе стопка делит ширину
            // по-разному для разных подписей, и одна из них теряет текст.
            HStack(alignment: .center, spacing: Theme.Space.s) {
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
                            Label(assistant.handsFree ? L("Перестать слушать") : L("Слушать без звонка"), systemImage: "ear")
                        }
                    }
                }
                .disabled(assistant.translatorActive)
                .accessibilityValue(assistant.onCall ? L("на связи") : (assistant.handsFree ? L("слушает") : L("выключено")))
                .accessibilityHint(L("Разговор продолжается с заблокированным телефоном"))
                .frame(maxWidth: .infinity, alignment: .leading)

                MicButton(phase: assistant.translatorActive ? .idle : assistant.phase) {
                    Task { await assistant.mainButtonTapped() }
                }
                .disabled(assistant.translatorActive)

                SideControl(
                    symbol: showKeyboard ? "keyboard.chevron.compact.down" : "keyboard",
                    label: L("Текстом"),
                    isOn: showKeyboard,
                    tone: tone
                ) {
                    withAnimation(Theme.ease(0.3)) { showKeyboard.toggle() }
                    fieldFocused = showKeyboard
                }
                .frame(maxWidth: .infinity, alignment: .trailing)
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
        if assistant.onCall { return L("Отбой") }
        return assistant.handsFree ? L("Слушаю") : L("На связи")
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
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 28, weight: .semibold))
                .foregroundStyle(phase == .idle ? Theme.ink : .white)
                .contentTransition(.symbolEffect(.replace))
                .symbolEffect(.variableColor.iterative, options: .repeating, isActive: phase == .listening && !reduceMotion)
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
        case .idle: return L("Говорить")
        case .listening: return L("Перестать слушать")
        case .thinking, .speaking: return L("Остановить ответ")
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
            // При очень крупном шрифте подпись не сжимается и не обрезается: остаётся значок,
            // а название читает VoiceOver.
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 6) {
                    icon
                    Text(label)
                        .font(.sign(.subheadline, weight: .semibold))
                        .lineLimit(1)
                        .contentTransition(.opacity)
                }
                icon
            }
            .foregroundStyle(isOn ? tone.onColor : Theme.textPrimary)
            .padding(.horizontal, Theme.Space.m)
            .frame(minWidth: 56, minHeight: 50)
            .background(background)
        }
        .buttonStyle(PressScaleStyle())
        .animation(Theme.ease(0.25), value: isOn)
        .accessibilityLabel(label)
    }

    private var icon: some View {
        Image(systemName: symbol)
            .font(.subheadline.weight(.semibold))
            .contentTransition(.symbolEffect(.replace))
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
            HStack(spacing: Theme.Space.xs) {
                Image(systemName: "eyeglasses")
                    // Не на связи — жёлтая отметка, как объявление о сбое: кнопка при этом работает.
                    .overlay(alignment: .topTrailing) {
                        if !connected {
                            Circle()
                                .fill(Theme.negative)
                                .frame(width: 8, height: 8)
                                .offset(x: 4, y: -3)
                        }
                    }
                if connected, let battery = glasses.batteryLevel {
                    Text("\(battery)%")
                        .font(.sign(.subheadline, weight: .semibold).monospacedDigit())
                }
            }
        }
        .accessibilityLabel(connected ? L("Очки на связи") : L("Очки не подключены"))
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
                                Text(L("Заряд %@%", battery))
                                    .font(.footnote.monospacedDigit())
                                    .foregroundStyle(Theme.textSecondary)
                            }
                        }
                    }
                    .padding(.vertical, Theme.Space.xs)
                }
                .listRowBackground(Theme.surface)

                Section {
                    if !glasses.isRegistered {
                        Button(L("Подключить через Meta AI")) {
                            Task { await glasses.connect() }
                        }
                        .disabled(glasses.registrationState == .registering)
                    } else {
                        if glasses.cameraPermissionGranted != true {
                            Button(L("Разрешить камеру в Meta AI")) {
                                Task { await glasses.requestCameraPermission() }
                            }
                        }
                        Button(L("Отключить приложение от очков"), role: .destructive) {
                            Task { await glasses.disconnect() }
                        }
                    }
                } footer: {
                    Text(L("Нужен Meta AI с включённым режимом разработчика: Meta AI → Настройки → ваши очки → Developer Mode."))
                        .foregroundStyle(Theme.textMuted)
                }
                .listRowBackground(Theme.surface)
            }
            .navigationTitle(L("Очки"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button(L("Готово")) { dismiss() }
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
        case .registered: return glasses.hasActiveDevice ? L("Очки на связи") : L("Очки не рядом")
        case .registering: return L("Подключение через Meta AI")
        case .available: return L("Очки не подключены")
        case .unavailable: return L("Meta AI недоступен")
        }
    }

    private var statusDetail: String {
        if !glasses.isRegistered { return L("Разрешите приложению доступ в Meta AI.") }
        if glasses.cameraPermissionGranted != true { return L("Камера пока не разрешена.") }
        return glasses.isStreaming ? L("Камера включена") : L("Камера включится по запросу")
    }
}
