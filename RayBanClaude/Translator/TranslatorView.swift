import SwiftUI

/// Переводчик на синей линии: два языка — две конечные станции, каждая фраза — остановка между ними.
struct TranslatorView: View {
    @Environment(TranslatorController.self) private var translator
    @Environment(AssistantController.self) private var assistant
    @Environment(AppSettings.self) private var settings

    @State private var showToPartner = false

    private let tone = Theme.Tone.translator

    var body: some View {
        @Bindable var translator = translator
        @Bindable var settings = settings

        NavigationStack {
            VStack(spacing: 0) {
                route
                    .padding(.horizontal, Theme.Space.l)
                    .padding(.top, Theme.Space.xs)

                Picker(L("Режим"), selection: $translator.mode) {
                    ForEach(TranslatorController.Mode.allCases) { Text($0.title).tag($0) }
                }
                .pickerStyle(.segmented)
                .padding(.horizontal, Theme.Space.l)
                .padding(.top, Theme.Space.m)

                conversation

                controls
            }
            .background(Theme.background)
            .navigationTitle("")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                FixedTitle(title: L("Переводчик"))
                ToolbarItem(placement: .topBarTrailing) {
                    Menu {
                        Toggle(L("Озвучивать перевод"), isOn: $settings.translatorSpeaks)
                        Button(L("Показать собеседнику"), systemImage: "rectangle.portrait.rotate") { showToPartner = true }
                            .disabled(translator.latestTranslation == nil)
                        Button(L("Очистить"), systemImage: "trash", role: .destructive) { translator.clear() }
                            .disabled(translator.entries.isEmpty)
                    } label: {
                        Image(systemName: "ellipsis")
                    }
                    .accessibilityLabel(L("Действия переводчика"))
                }
            }
            .fullScreenCover(isPresented: $showToPartner) {
                PartnerView(entry: translator.latestTranslation) { showToPartner = false }
            }
            .alert(L("Переводчик"), isPresented: Binding(
                get: { translator.errorMessage != nil },
                set: { if !$0 { translator.errorMessage = nil } }
            )) {
                Button("OK") { translator.errorMessage = nil }
            } message: {
                Text(translator.errorMessage ?? "")
            }
        }
    }

    // MARK: - Маршрут: два языка

    private var route: some View {
        HStack(spacing: Theme.Space.s) {
            languageMenu(title: L("Вы"), selection: translator.mine) { translator.mine = $0 }
            Button {
                withAnimation(Theme.ease(0.3)) { translator.swapLanguages() }
            } label: {
                Image(systemName: "arrow.left.arrow.right")
                    .font(.subheadline.weight(.bold))
                    .foregroundStyle(tone.text)
                    .frame(width: 44, height: 44)
            }
            .accessibilityLabel(L("Поменять языки местами"))
            languageMenu(title: L("Собеседник"), selection: translator.theirs) { translator.theirs = $0 }
        }
    }

    private func languageMenu(title: String, selection: TranslatorLanguage, set: @escaping (TranslatorLanguage) -> Void) -> some View {
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
            HStack(spacing: Theme.Space.s) {
                Circle()
                    .fill(Theme.porcelain)
                    .overlay(Circle().strokeBorder(tone.color, lineWidth: 4))
                    .frame(width: 16, height: 16)
                VStack(alignment: .leading, spacing: 1) {
                    Text(title).plateStyle()
                    Text(selection.name)
                        .font(.sign(.title3))
                        .foregroundStyle(Theme.textPrimary)
                        .lineLimit(1)
                        .minimumScaleFactor(0.8)
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, Theme.Space.m)
            .frame(maxWidth: .infinity, minHeight: 56)
            .background(Theme.surface, in: RoundedRectangle(cornerRadius: Theme.Radius.card, style: .continuous))
        }
        .accessibilityLabel("\(title): \(selection.name)")
    }

    // MARK: - Разговор

    private var conversation: some View {
        ScrollViewReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    if translator.entries.isEmpty && translator.live == nil && !assistant.isTranslationListening {
                        emptyState
                    }
                    ForEach(Array(translator.entries.enumerated()), id: \.element.id) { index, entry in
                        LineRow(
                            stop: entry.fromMe ? .station : .interchange,
                            tone: tone,
                            isFirst: index == 0,
                            isLast: index == translator.entries.count - 1 && !hasLiveRow
                        ) {
                            TranslationStop(entry: entry, tone: tone)
                        }
                    }
                    liveRow
                    Color.clear.frame(height: 1).id("bottom")
                }
                .padding(.horizontal, Theme.Space.l)
                .padding(.top, Theme.Space.l)
                .padding(.bottom, Theme.Space.xl)
                .animation(Theme.ease(0.3), value: translator.entries.count)
            }
            .onChange(of: translator.entries.last?.translation) { _, _ in
                withAnimation(Theme.ease(0.25)) { proxy.scrollTo("bottom", anchor: .bottom) }
            }
            .onChange(of: translator.live) { _, _ in
                proxy.scrollTo("bottom", anchor: .bottom)
            }
        }
    }

    private var hasLiveRow: Bool {
        translator.live != nil || assistant.isTranslationListening
    }

    @ViewBuilder
    private var liveRow: some View {
        if let live = translator.live {
            LineRow(stop: .live(.listening), tone: tone, isFirst: translator.entries.isEmpty, isLast: true) {
                TranslationStop(entry: live, tone: tone, isLive: true)
                    .padding(.bottom, Theme.Space.m)
            }
        } else if assistant.isTranslationListening {
            LineRow(stop: .live(.listening), tone: tone, isFirst: translator.entries.isEmpty, isLast: true) {
                VStack(alignment: .leading, spacing: 3) {
                    Text(L("Слушаю")).plateStyle(tone.text)
                    Text(assistant.partialTranscript.isEmpty ? L("Говорите") : assistant.partialTranscript)
                        .font(.title3.weight(.semibold))
                        .foregroundStyle(assistant.partialTranscript.isEmpty ? Theme.textMuted : Theme.textPrimary)
                }
                .padding(.bottom, Theme.Space.m)
            }
        }
    }

    private var emptyState: some View {
        LineRow(stop: .interchange, tone: tone, isFirst: true, isLast: true) {
            VStack(alignment: .leading, spacing: Theme.Space.s) {
                Text(translator.mode == .dialog ? L("Говорите по очереди") : L("Говорите свободно"))
                    .font(.sign(.title))
                    .foregroundStyle(Theme.textPrimary)
                Text(emptyHint)
                    .font(.callout)
                    .foregroundStyle(Theme.textSecondary)
                if settings.trimmedElevenLabsKey.isEmpty, translator.mine.iso == "uz" || translator.theirs.iso == "uz" {
                    ServiceNotice(text: L("Узбекскую речь распознаёт и озвучивает ElevenLabs — добавьте его ключ в настройках."))
                        .padding(.top, Theme.Space.xs)
                }
            }
        }
    }

    private var emptyHint: String {
        if translator.mode == .dialog {
            return L("Нажмите свою кнопку и скажите фразу — перевод прозвучит и появится крупно. Потом кнопку нажимает собеседник.")
        }
        if translator.conversationDetectsLanguage {
            return L("Переводчик сам понимает, кто говорит. Вашу речь он переводит собеседнику, его речь — вам в очки, и показывает перевод, пока человек ещё говорит.")
        }
        return L("Переводчик слушает собеседника и переводит вам в очки. Чтобы он понимал обоих, добавьте ключ ElevenLabs.")
    }

    // MARK: - Кнопки

    private var controls: some View {
        HStack(spacing: Theme.Space.m) {
            if translator.mode == .dialog {
                SpeakerButton(title: L("Я"), language: Text(translator.mine.name), isActive: translator.activeSide == .me, filled: true, tone: tone) {
                    Task { await translator.toggle(.me) }
                }
                SpeakerButton(title: L("Собеседник"), language: Text(translator.theirs.name), isActive: translator.activeSide == .them, filled: false, tone: tone) {
                    Task { await translator.toggle(.them) }
                }
            } else {
                SpeakerButton(
                    title: translator.isRunning ? L("Остановить") : L("Начать разговор"),
                    language: Text("\(translator.mine.name) \(Image(systemName: "arrow.left.arrow.right")) \(translator.theirs.name)"),
                    isActive: translator.isRunning,
                    filled: true,
                    tone: tone
                ) {
                    Task { await translator.toggleConversation() }
                }
            }
        }
        .padding(.horizontal, Theme.Space.l)
        .padding(.top, Theme.Space.s)
        .padding(.bottom, Theme.Space.m)
        .sensoryFeedback(.selection, trigger: translator.activeSide)
        .sensoryFeedback(.selection, trigger: translator.isRunning)
    }
}

/// Остановка переводчика: кто сказал и на каких языках, оригинал мелко, перевод крупно.
private struct TranslationStop: View {
    let entry: TranslatorController.Entry
    let tone: Theme.Tone
    var isLive = false

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text("\(entry.fromMe ? L("Вы") : L("Собеседник")) · \(entry.sourceName) → \(entry.targetName)")
                .plateStyle(isLive ? tone.text : Theme.textMuted)
            Text(entry.original)
                .font(.subheadline)
                .foregroundStyle(Theme.textSecondary)
            if !entry.translation.isEmpty || !isLive {
                Text(entry.translation.isEmpty ? "…" : entry.translation)
                    .font(.title3.weight(.semibold))
                    .foregroundStyle(isLive ? Theme.textSecondary : Theme.textPrimary)
                    .textSelection(.enabled)
                    .contentTransition(.opacity)
            }
        }
        .accessibilityElement(children: .combine)
    }
}

private struct SpeakerButton: View {
    let title: String
    let language: Text
    let isActive: Bool
    let filled: Bool
    let tone: Theme.Tone
    let action: () -> Void
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        Button(action: action) {
            VStack(spacing: 2) {
                HStack(spacing: Theme.Space.s) {
                    Image(systemName: isActive ? "waveform" : "mic.fill")
                        .symbolEffect(.variableColor.iterative, options: .repeating, isActive: isActive && !reduceMotion)
                    Text(title).font(.sign(.title3))
                }
                language
                    .font(.caption.weight(.medium))
            }
            .frame(maxWidth: .infinity, minHeight: 64)
            .foregroundStyle(foreground)
            .background(
                RoundedRectangle(cornerRadius: Theme.Radius.card, style: .continuous)
                    .fill(fill)
            )
            .overlay(
                RoundedRectangle(cornerRadius: Theme.Radius.card, style: .continuous)
                    .strokeBorder(tone.color, lineWidth: isActive || !filled ? 3 : 0)
            )
        }
        .buttonStyle(PressScaleStyle())
        .animation(Theme.ease(0.25), value: isActive)
    }

    /// Работающая кнопка — фарфоровая в кольце линии, как станция; ждущая — залита цветом линии.
    private var fill: Color {
        if isActive { return Theme.porcelain }
        return filled ? tone.color : Theme.surface
    }

    private var foreground: Color {
        if isActive { return Theme.ink }
        return filled ? tone.onColor : Theme.textPrimary
    }
}

/// Перевод крупно — повернуть телефон к собеседнику.
private struct PartnerView: View {
    let entry: TranslatorController.Entry?
    let close: () -> Void

    var body: some View {
        ZStack(alignment: .topTrailing) {
            Theme.background.ignoresSafeArea()
            VStack(spacing: Theme.Space.l) {
                Text(entry?.translation ?? "")
                    .font(.system(size: 44, weight: .semibold))
                    .minimumScaleFactor(0.4)
                    .multilineTextAlignment(.center)
                    .foregroundStyle(Theme.textPrimary)
                if let entry {
                    LinePill(text: entry.targetName, tone: .translator)
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
            .accessibilityLabel(L("Закрыть"))
        }
    }
}
