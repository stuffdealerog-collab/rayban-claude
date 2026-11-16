import SwiftUI

/// Переводчик: пара языков, разговор переводами, кнопки «Я» и «Собеседник» или субтитры.
struct TranslatorView: View {
    @Environment(TranslatorController.self) private var translator
    @Environment(AssistantController.self) private var assistant
    @Environment(AppSettings.self) private var settings

    @State private var showToPartner = false

    var body: some View {
        @Bindable var translator = translator
        @Bindable var settings = settings

        NavigationStack {
            VStack(spacing: 0) {
                languageBar
                    .padding(.horizontal, Theme.Space.l)
                    .padding(.bottom, Theme.Space.m)

                Picker("Режим", selection: $translator.mode) {
                    ForEach(TranslatorController.Mode.allCases) { Text($0.title).tag($0) }
                }
                .pickerStyle(.segmented)
                .padding(.horizontal, Theme.Space.l)

                conversation

                controls
            }
            .background(Theme.background)
            .navigationTitle("Переводчик")
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Menu {
                        Toggle("Озвучивать перевод", isOn: $settings.translatorSpeaks)
                        Button("Показать собеседнику", systemImage: "rectangle.portrait.rotate") { showToPartner = true }
                            .disabled(translator.latestTranslation == nil)
                        Button("Очистить", systemImage: "trash", role: .destructive) { translator.clear() }
                            .disabled(translator.entries.isEmpty)
                    } label: {
                        Image(systemName: "ellipsis.circle")
                    }
                    .accessibilityLabel("Действия переводчика")
                }
            }
            .fullScreenCover(isPresented: $showToPartner) {
                PartnerView(entry: translator.latestTranslation) { showToPartner = false }
            }
            .alert("Переводчик", isPresented: Binding(
                get: { translator.errorMessage != nil },
                set: { if !$0 { translator.errorMessage = nil } }
            )) {
                Button("OK") { translator.errorMessage = nil }
            } message: {
                Text(translator.errorMessage ?? "")
            }
        }
    }

    private var languageBar: some View {
        HStack(spacing: Theme.Space.s) {
            languageMenu(selection: translator.mine) { translator.mine = $0 }
            Button {
                withAnimation(Theme.ease(0.3)) { translator.swapLanguages() }
            } label: {
                Image(systemName: "arrow.left.arrow.right")
                    .font(.body.weight(.medium))
                    .frame(width: 44, height: 44)
            }
            .accessibilityLabel("Поменять языки местами")
            languageMenu(selection: translator.theirs) { translator.theirs = $0 }
        }
    }

    private func languageMenu(selection: TranslatorLanguage, set: @escaping (TranslatorLanguage) -> Void) -> some View {
        Menu {
            ForEach(TranslatorLanguage.all) { language in
                Button {
                    translator.stop()
                    set(language)
                } label: {
                    if language == selection {
                        Label(language.name, systemImage: "checkmark")
                    } else {
                        Text(language.name)
                    }
                }
            }
        } label: {
            Text(selection.name)
                .font(.body.weight(.medium))
                .foregroundStyle(Theme.textPrimary)
                .frame(maxWidth: .infinity, minHeight: 44)
                .background(Theme.surface, in: RoundedRectangle(cornerRadius: Theme.Radius.control + 2, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: Theme.Radius.control + 2, style: .continuous).strokeBorder(Theme.hairline))
        }
    }

    // MARK: - Разговор

    private var conversation: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: Theme.Space.l) {
                    if translator.entries.isEmpty && !assistant.isTranslationListening {
                        emptyState
                    }
                    ForEach(translator.entries) { entry in
                        TranslationRow(entry: entry).id(entry.id)
                    }
                    if assistant.isTranslationListening {
                        Text(assistant.partialTranscript.isEmpty ? "Слушаю…" : assistant.partialTranscript)
                            .font(.callout)
                            .foregroundStyle(Theme.textSecondary)
                            .id("partial")
                    }
                    Color.clear.frame(height: 1).id("bottom")
                }
                .padding(Theme.Space.l)
                .animation(Theme.ease(0.3), value: translator.entries.count)
            }
            .onChange(of: translator.entries.last?.translation) { _, _ in
                withAnimation(Theme.ease(0.25)) { proxy.scrollTo("bottom", anchor: .bottom) }
            }
            .onChange(of: assistant.partialTranscript) { _, _ in
                proxy.scrollTo("bottom", anchor: .bottom)
            }
        }
    }

    private var emptyState: some View {
        VStack(alignment: .leading, spacing: Theme.Space.s) {
            Text(translator.mode == .dialog ? "Говорите по очереди" : "Субтитры чужой речи")
                .font(.headline)
            Text(translator.mode == .dialog
                ? "Нажмите свою кнопку и скажите фразу — перевод прозвучит и появится крупно. Потом кнопку нажимает собеседник."
                : "Переводчик слушает собеседника фразу за фразой и переводит в очки. Чтобы остановить, нажмите кнопку ещё раз.")
                .font(.callout)
                .foregroundStyle(Theme.textSecondary)
            if translator.mine.iso == "uz" || translator.theirs.iso == "uz" {
                Text("Узбекскую речь распознаёт и озвучивает ElevenLabs — нужен его ключ в настройках.")
                    .font(.footnote)
                    .foregroundStyle(Theme.textMuted)
                    .padding(.top, Theme.Space.xs)
            }
        }
        .padding(.top, Theme.Space.l)
    }

    // MARK: - Кнопки

    private var controls: some View {
        HStack(spacing: Theme.Space.m) {
            if translator.mode == .dialog {
                SpeakerButton(title: "Я", language: translator.mine.name, isActive: translator.activeSide == .me, filled: true) {
                    Task { await translator.toggle(.me) }
                }
                SpeakerButton(title: "Собеседник", language: translator.theirs.name, isActive: translator.activeSide == .them, filled: false) {
                    Task { await translator.toggle(.them) }
                }
            } else {
                SpeakerButton(
                    title: translator.activeSide == nil ? "Начать субтитры" : "Остановить",
                    language: "\(translator.theirs.name) → \(translator.mine.name)",
                    isActive: translator.activeSide != nil,
                    filled: true
                ) {
                    Task { await translator.toggle(.them) }
                }
            }
        }
        .padding(Theme.Space.l)
        .background(alignment: .top) { Rectangle().fill(Theme.hairline).frame(height: 1) }
        .sensoryFeedback(.selection, trigger: translator.activeSide)
    }
}

private struct TranslationRow: View {
    let entry: TranslatorController.Entry

    var body: some View {
        VStack(alignment: entry.fromMe ? .trailing : .leading, spacing: Theme.Space.xs) {
            Text(entry.original)
                .font(.footnote)
                .foregroundStyle(Theme.textMuted)
            Text(entry.translation.isEmpty ? "…" : entry.translation)
                .font(.title3)
                .foregroundStyle(Theme.textPrimary)
                .multilineTextAlignment(entry.fromMe ? .trailing : .leading)
                .textSelection(.enabled)
            Text("\(entry.sourceName) → \(entry.targetName)")
                .font(.caption2)
                .foregroundStyle(Theme.textMuted)
        }
        .frame(maxWidth: .infinity, alignment: entry.fromMe ? .trailing : .leading)
    }
}

private struct SpeakerButton: View {
    let title: String
    let language: String
    let isActive: Bool
    let filled: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(spacing: 2) {
                HStack(spacing: Theme.Space.s) {
                    Image(systemName: isActive ? "waveform" : "mic.fill")
                        .symbolEffect(.variableColor.iterative, options: .repeating, isActive: isActive)
                    Text(title).font(.body.weight(.semibold))
                }
                Text(language)
                    .font(.caption)
                    .opacity(0.8)
            }
            .frame(maxWidth: .infinity, minHeight: 64)
            .foregroundStyle(filled ? Color.white : Theme.accent)
            .background(
                RoundedRectangle(cornerRadius: Theme.Radius.card, style: .continuous)
                    .fill(filled ? Theme.accent : Theme.accent.opacity(isActive ? 0.18 : 0.08))
            )
            .overlay(
                RoundedRectangle(cornerRadius: Theme.Radius.card, style: .continuous)
                    .strokeBorder(isActive ? Theme.accent : .clear, lineWidth: 2)
            )
        }
        .buttonStyle(PressScaleStyle())
    }
}

/// Перевод крупно — повернуть телефон к собеседнику.
private struct PartnerView: View {
    let entry: TranslatorController.Entry?
    let close: () -> Void

    var body: some View {
        ZStack(alignment: .topTrailing) {
            Theme.surface.ignoresSafeArea()
            VStack(spacing: Theme.Space.l) {
                Text(entry?.translation ?? "")
                    .font(.system(size: 40, weight: .medium))
                    .minimumScaleFactor(0.4)
                    .multilineTextAlignment(.center)
                    .foregroundStyle(Theme.textPrimary)
                if let entry {
                    Text(entry.targetName)
                        .font(.footnote)
                        .foregroundStyle(Theme.textMuted)
                }
            }
            .padding(Theme.Space.xxl)
            .frame(maxWidth: .infinity, maxHeight: .infinity)

            Button(action: close) {
                Image(systemName: "xmark")
                    .font(.body.weight(.semibold))
                    .frame(width: 44, height: 44)
                    .background(Theme.raised, in: Circle())
            }
            .foregroundStyle(Theme.textPrimary)
            .padding(Theme.Space.l)
            .accessibilityLabel("Закрыть")
        }
    }
}
