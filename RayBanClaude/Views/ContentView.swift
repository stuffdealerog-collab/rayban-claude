import SwiftUI

struct ContentView: View {
    @Environment(AssistantController.self) private var assistant
    @Environment(GlassesManager.self) private var glasses
    @Environment(AppSettings.self) private var settings
    @Environment(\.scenePhase) private var scenePhase

    @State private var showSettings = false
    @State private var typedText = ""

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                GlassesStatusView()
                    .padding(.horizontal)
                    .padding(.top, 8)

                TranscriptView(entries: assistant.entries, partial: assistant.phase == .listening ? assistant.partialTranscript : "")

                controls
            }
            .navigationTitle("Claude в очках")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button {
                        assistant.newConversation()
                    } label: {
                        Image(systemName: "square.and.pencil")
                    }
                    .accessibilityLabel("Новый диалог")
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        showSettings = true
                    } label: {
                        Image(systemName: "gearshape")
                    }
                    .accessibilityLabel("Настройки")
                }
            }
            .sheet(isPresented: $showSettings) {
                SettingsView()
            }
            .alert("Ошибка", isPresented: errorBinding) {
                Button("OK") {
                    assistant.dismissError()
                    glasses.clearError()
                }
            } message: {
                Text(assistant.errorMessage ?? glasses.lastError ?? "")
            }
            .onAppear {
                if settings.trimmedAPIKey.isEmpty { showSettings = true }
            }
            .onChange(of: scenePhase) { _, phase in
                if phase == .active { Task { await glasses.refreshCameraPermission() } }
            }
        }
    }

    private var errorBinding: Binding<Bool> {
        Binding(
            get: { assistant.errorMessage != nil || glasses.lastError != nil },
            set: { if !$0 { assistant.dismissError(); glasses.clearError() } }
        )
    }

    private var controls: some View {
        VStack(spacing: 12) {
            HStack {
                TextField("Спросить текстом…", text: $typedText)
                    .textFieldStyle(.roundedBorder)
                    .submitLabel(.send)
                    .onSubmit(sendTyped)
                Button(action: sendTyped) {
                    Image(systemName: "arrow.up.circle.fill").font(.title2)
                }
                .disabled(typedText.trimmingCharacters(in: .whitespaces).isEmpty)
            }

            HStack(alignment: .center, spacing: 24) {
                Toggle(isOn: handsFreeBinding) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Без рук").font(.subheadline.weight(.semibold))
                        Text(settings.wakeWordEnabled ? "по слову «\(settings.wakeWord)»" : "слушать всё")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                .toggleStyle(.switch)
                .frame(maxWidth: 170)

                Spacer()

                MicButton(phase: assistant.phase) {
                    Task { await assistant.mainButtonTapped() }
                }
            }
            Text(phaseTitle)
                .font(.footnote)
                .foregroundStyle(.secondary)
        }
        .padding()
        .background(.bar)
    }

    private var handsFreeBinding: Binding<Bool> {
        Binding(
            get: { assistant.handsFree },
            set: { enabled in Task { await assistant.setHandsFree(enabled) } }
        )
    }

    private var phaseTitle: String {
        switch assistant.phase {
        case .idle: return assistant.handsFree ? "Готов" : "Нажмите на микрофон и говорите"
        case .listening: return "Слушаю… (микрофон: \(assistant.microphone))"
        case .thinking: return "Думаю… нажмите, чтобы прервать"
        case .speaking: return "Отвечаю… нажмите, чтобы прервать"
        }
    }

    private func sendTyped() {
        assistant.submitTyped(typedText)
        typedText = ""
    }
}

private struct MicButton: View {
    let phase: AssistantController.Phase
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            ZStack {
                Circle()
                    .fill(color.gradient)
                    .frame(width: 76, height: 76)
                    .shadow(color: color.opacity(0.4), radius: phase == .listening ? 12 : 4)
                Image(systemName: icon)
                    .font(.system(size: 30, weight: .semibold))
                    .foregroundStyle(.white)
            }
        }
        .buttonStyle(.plain)
        .accessibilityLabel(phase == .idle ? "Говорить" : "Остановить")
        .animation(.easeInOut(duration: 0.2), value: phase)
    }

    private var icon: String {
        switch phase {
        case .idle: return "mic.fill"
        case .listening: return "waveform"
        case .thinking: return "ellipsis"
        case .speaking: return "stop.fill"
        }
    }

    private var color: Color {
        switch phase {
        case .idle: return .accentColor
        case .listening: return .red
        case .thinking: return .orange
        case .speaking: return .purple
        }
    }
}

/// Состояние очков: регистрация, связь, камера, превью.
struct GlassesStatusView: View {
    @Environment(GlassesManager.self) private var glasses

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            if let preview = glasses.previewImage {
                Image(uiImage: preview)
                    .resizable()
                    .scaledToFill()
                    .frame(width: 54, height: 96)
                    .clipShape(RoundedRectangle(cornerRadius: 8))
            } else {
                RoundedRectangle(cornerRadius: 8)
                    .fill(.quaternary)
                    .frame(width: 54, height: 96)
                    .overlay(Image(systemName: "eyeglasses").foregroundStyle(.secondary))
            }

            VStack(alignment: .leading, spacing: 6) {
                Label(statusTitle, systemImage: statusIcon)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(statusColor)

                if !glasses.isRegistered {
                    Text("Нужен Meta AI с включённым режимом разработчика.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Button("Подключить очки") {
                        Task { await glasses.connect() }
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)
                    .disabled(glasses.registrationState == .registering)
                } else if glasses.cameraPermissionGranted != true {
                    Button("Разрешить камеру") {
                        Task { await glasses.requestCameraPermission() }
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                } else {
                    Text(glasses.isStreaming ? "Камера активна" : "Камера включится по запросу")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            Spacer(minLength: 0)
        }
        .padding(10)
        .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 14))
        .task { await glasses.refreshCameraPermission() }
    }

    private var statusTitle: String {
        switch glasses.registrationState {
        case .registered: return glasses.hasActiveDevice ? "Очки на связи" : "Очки не найдены рядом"
        case .registering: return "Подключение через Meta AI…"
        case .available: return "Очки не подключены"
        case .unavailable: return "Meta AI недоступен"
        }
    }

    private var statusIcon: String {
        glasses.isRegistered && glasses.hasActiveDevice ? "eyeglasses" : "exclamationmark.triangle"
    }

    private var statusColor: Color {
        glasses.isRegistered && glasses.hasActiveDevice ? .green : .orange
    }
}
