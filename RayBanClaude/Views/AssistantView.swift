import SwiftUI

/// Главный экран: решётка-состояние, лента разговора, кнопка микрофона.
struct AssistantView: View {
    @Environment(AssistantController.self) private var assistant
    @Environment(GlassesManager.self) private var glasses
    @Environment(AppSettings.self) private var settings
    @Environment(\.scenePhase) private var scenePhase

    @State private var showGlasses = false
    @State private var showKeyboard = false
    @State private var typedText = ""
    @FocusState private var fieldFocused: Bool

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                header
                TranscriptView(
                    entries: assistant.entries,
                    partial: assistant.phase == .listening && !assistant.translatorActive ? assistant.partialTranscript : "",
                    emptyState: AnyView(suggestions)
                )
                controls
            }
            .background(Theme.background)
            .navigationTitle(settings.persona.displayName)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    GlassesChip { showGlasses = true }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        assistant.newConversation()
                    } label: {
                        Image(systemName: "square.and.pencil")
                    }
                    .accessibilityLabel("Новый разговор")
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

    // MARK: - Решётка и состояние

    private var header: some View {
        VStack(spacing: Theme.Space.m) {
            LatticeView(mode: latticeMode)
                .frame(height: assistant.entries.isEmpty ? 220 : 132)
                .padding(.horizontal, Theme.Space.l)
                .animation(Theme.ease(0.45), value: assistant.entries.isEmpty)
            Text(stateLine)
                .font(.subheadline)
                .foregroundStyle(Theme.textSecondary)
                .contentTransition(.opacity)
                .animation(Theme.ease(0.2), value: stateLine)
                .lineLimit(1)
                .padding(.horizontal, Theme.Space.l)
        }
        .padding(.top, Theme.Space.s)
        .padding(.bottom, Theme.Space.s)
    }

    private var latticeMode: LatticeMode {
        if assistant.translatorActive { return .idle }
        switch assistant.phase {
        case .idle: return .idle
        case .listening: return .listening
        case .thinking: return .thinking
        case .speaking: return .speaking
        }
    }

    private var stateLine: String {
        switch assistant.phase {
        case .idle:
            if assistant.translatorActive { return "Микрофон у переводчика" }
            if assistant.handsFree {
                return settings.wakeWordEnabled ? "Жду обращения «\(settings.effectiveWakeWord)»" : "Слушаю всё подряд"
            }
            return "Нажмите и говорите"
        case .listening: return "Слушаю · \(assistant.microphone)"
        case .thinking: return "Думаю"
        case .speaking: return "Отвечаю · нажмите, чтобы перебить"
        }
    }

    // MARK: - Пустое состояние

    private var suggestions: some View {
        VStack(alignment: .leading, spacing: Theme.Space.s) {
            Text("Например")
                .font(.footnote)
                .foregroundStyle(Theme.textMuted)
                .padding(.bottom, Theme.Space.xs)
            ForEach(Self.examples, id: \.self) { example in
                Button {
                    assistant.submitTyped(example)
                } label: {
                    HStack {
                        Text(example)
                            .font(.callout)
                            .foregroundStyle(Theme.textPrimary)
                            .multilineTextAlignment(.leading)
                        Spacer()
                        Image(systemName: "arrow.up.right")
                            .font(.footnote)
                            .foregroundStyle(Theme.textMuted)
                    }
                    .padding(.horizontal, Theme.Space.m)
                    .padding(.vertical, Theme.Space.m)
                    .background(Theme.surface, in: RoundedRectangle(cornerRadius: Theme.Radius.control + 2, style: .continuous))
                    .overlay(
                        RoundedRectangle(cornerRadius: Theme.Radius.control + 2, style: .continuous)
                            .strokeBorder(Theme.hairline)
                    )
                }
                .buttonStyle(PressScaleStyle())
            }
        }
        .padding(.top, Theme.Space.s)
    }

    private static let examples = [
        "Что передо мной?",
        "Какие у меня планы на завтра?",
        "Есть новые письма?",
        "Напомни через час позвонить маме",
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
                        .padding(.horizontal, Theme.Space.m)
                        .padding(.vertical, Theme.Space.s + 2)
                        .background(Theme.surface, in: RoundedRectangle(cornerRadius: Theme.Radius.control + 4, style: .continuous))
                        .overlay(
                            RoundedRectangle(cornerRadius: Theme.Radius.control + 4, style: .continuous)
                                .strokeBorder(Theme.hairline)
                        )
                    Button(action: sendTyped) {
                        Image(systemName: "arrow.up")
                            .font(.body.weight(.semibold))
                            .frame(width: 40, height: 40)
                            .background(Theme.accent, in: Circle())
                            .foregroundStyle(.white)
                    }
                    .disabled(typedText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    .accessibilityLabel("Отправить")
                }
                .transition(.move(edge: .bottom).combined(with: .opacity))
            }

            HStack(alignment: .center) {
                SideButton(
                    symbol: assistant.handsFree ? "ear.fill" : "ear",
                    label: "Без рук",
                    isOn: assistant.handsFree
                ) {
                    Task { await assistant.setHandsFree(!assistant.handsFree) }
                }
                .accessibilityValue(assistant.handsFree ? "включено" : "выключено")

                Spacer()

                MicButton(phase: assistant.translatorActive ? .idle : assistant.phase) {
                    Task { await assistant.mainButtonTapped() }
                }
                .disabled(assistant.translatorActive)

                Spacer()

                SideButton(symbol: showKeyboard ? "keyboard.chevron.compact.down" : "keyboard", label: "Текстом", isOn: showKeyboard) {
                    withAnimation(Theme.ease(0.3)) { showKeyboard.toggle() }
                    fieldFocused = showKeyboard
                }
            }
            .padding(.horizontal, Theme.Space.xl)
        }
        .padding(.horizontal, Theme.Space.l)
        .padding(.top, Theme.Space.m)
        .padding(.bottom, Theme.Space.s)
        .background(alignment: .top) {
            Rectangle().fill(Theme.hairline).frame(height: 1)
        }
        .sensoryFeedback(.impact(weight: .light), trigger: assistant.phase) { _, new in
            // Только когда слушать начали по кнопке, а не на каждом перезапуске «без рук».
            new == .listening && !assistant.handsFree
        }
    }

    private func sendTyped() {
        assistant.submitTyped(typedText)
        typedText = ""
    }
}

/// Кнопка микрофона. На iOS 26 — «жидкое стекло» системы.
struct MicButton: View {
    let phase: AssistantController.Phase
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 28, weight: .medium))
                .foregroundStyle(phase == .idle ? Color.white : Theme.textPrimary)
                .contentTransition(.symbolEffect(.replace))
                .symbolEffect(.variableColor.iterative, options: .repeating, isActive: phase == .listening)
                .frame(width: 76, height: 76)
                .background(background)
        }
        .buttonStyle(PressScaleStyle())
        .accessibilityLabel(accessibilityTitle)
        .animation(Theme.ease(0.25), value: phase)
    }

    @ViewBuilder
    private var background: some View {
        if #available(iOS 26.0, *) {
            Circle()
                .fill(.clear)
                .glassEffect(.regular.tint(phase == .idle ? Theme.accent : Theme.raised.opacity(0.6)).interactive(), in: .circle)
        } else {
            Circle()
                .fill(phase == .idle ? Theme.accent : Theme.raised)
                .overlay(Circle().strokeBorder(Theme.hairline))
                .shadow(color: .black.opacity(0.08), radius: 12, x: 0, y: 6)
        }
    }

    private var symbol: String {
        switch phase {
        case .idle: return "mic.fill"
        case .listening: return "waveform"
        case .thinking: return "stop.fill"
        case .speaking: return "stop.fill"
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

private struct SideButton: View {
    let symbol: String
    let label: String
    let isOn: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(spacing: Theme.Space.xs) {
                Image(systemName: symbol)
                    .font(.title3)
                    .frame(width: 48, height: 48)
                    .background(isOn ? Theme.accent.opacity(0.14) : Theme.surface, in: Circle())
                    .overlay(Circle().strokeBorder(Theme.hairline))
                    .foregroundStyle(isOn ? Theme.accent : Theme.textSecondary)
                Text(label)
                    .font(.caption2)
                    .foregroundStyle(Theme.textMuted)
            }
        }
        .buttonStyle(PressScaleStyle())
        .accessibilityLabel(label)
    }
}

/// Нажатие — лёгкое уменьшение; одна кривая на всё приложение.
struct PressScaleStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.97 : 1)
            .opacity(configuration.isPressed ? 0.9 : 1)
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
                Image(systemName: connected ? "eyeglasses" : "eyeglasses.slash")
                if let battery = glasses.batteryLevel, connected {
                    Text("\(battery)%")
                        .font(.footnote.monospacedDigit())
                }
            }
            .foregroundStyle(connected ? Theme.textPrimary : Theme.textMuted)
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
