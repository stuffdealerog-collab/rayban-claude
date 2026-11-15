# Claude в очках Ray-Ban Meta

iOS-приложение: голосовой ассистент на Claude, который видит камерой очков Ray-Ban Meta (Gen 2), слышит их микрофонами и отвечает через их динамики.

```
Очки Ray-Ban Meta ── Bluetooth ──► iPhone: это приложение
  камера 12 МП (DAT SDK)            ├─ Apple Speech: речь → текст (на устройстве)
  5 микрофонов (HFP)                ├─ Claude API: текст + снимки, инструменты, веб-поиск
  динамики (HFP)                    └─ AVSpeechSynthesizer: ответ → речь в динамики очков
```

## Что умеет

- **Голосовой диалог.** Кнопка микрофона для одной фразы или режим «Без рук»: ассистент слушает постоянно и откликается на обращение («Клод, …»). Работает и при заблокированном экране.
- **Зрение.** Инструмент `take_photo`: Claude сам решает, когда сделать снимок камерой очков («что передо мной?», «прочитай вывеску», «переведи меню»). Снимок показывается в ленте.
- **Другие функции.** `get_location` (где я), `create_reminder` (системные Напоминания), веб-поиск Anthropic (погода, новости, расписания).
- **Быстрый отклик.** Ответ приходит потоком и озвучивается по фразам, не дожидаясь конца.
- **Прерывание.** Нажатие на кнопку во время ответа останавливает речь и запрос.

## Что нужно

| | |
|---|---|
| Сборка | **Xcode 26.4+** (Meta DAT 1.0.1 собран Swift 6.3.3). Свой Mac с Xcode не обязателен: собирает GitHub Actions |
| iPhone | iOS 17.2+, с установленным **Meta AI** и сопряжёнными очками |
| Очки | Ray-Ban Meta Gen 2 (подходят Gen 1, Oakley Meta HSTN/Vanguard) |
| Meta AI | Режим разработчика: Meta AI → Настройки → ваши очки → Developer Mode |
| Claude | API-ключ из [Claude Console](https://platform.claude.com) |
| Apple | Бесплатно: обычный Apple ID ([Sideloadly](#бесплатно-github-actions--sideloadly)). Платно: Apple Developer Program, 99 $ в год ([TestFlight](#testflight-без-xcode)) |

Способы поставить приложение на iPhone:

| Способ | Цена | Нужен Xcode | Срок работы |
|---|---|---|---|
| [GitHub Actions + Sideloadly](#бесплатно-github-actions--sideloadly) | бесплатно | нет | 7 дней, потом переустановить |
| [TestFlight](#testflight-без-xcode) | 99 $ в год | нет | 90 дней на сборку |
| [Из Xcode](#запуск-из-xcode) | бесплатно | да | 7 дней (бесплатный Apple ID) |

## Бесплатно: GitHub Actions + Sideloadly

Облачный Mac в GitHub Actions собирает приложение без подписи. Потом [Sideloadly](https://sideloadly.io) на вашем Mac подписывает его вашим обычным Apple ID и ставит на iPhone по кабелю. Платить Apple не нужно.

1. **Код на GitHub.** Загрузите эту папку в репозиторий. В **публичном** репозитории минуты GitHub Actions бесплатны без ограничений. В приватном бесплатно примерно 200 минут macOS в месяц, это около 15 сборок. Секретов в коде нет: API-ключ Claude вводится в самом приложении.
2. **Сборка.** После каждого push запускается workflow **CI**. Через 10–15 минут откройте: Actions → последний запуск → внизу **Artifacts → RayBanClaude-ipa**. Скачается zip; внутри `RayBanClaude.ipa`.
3. **Sideloadly.** Скачайте и установите с [sideloadly.io](https://sideloadly.io) (есть версия для macOS). Подключите iPhone кабелем и на телефоне нажмите «Доверять этому компьютеру».
4. **Установка.** Перетащите `RayBanClaude.ipa` в окно Sideloadly, введите Apple ID и нажмите **Start**. Пароль Apple ID попадает в стороннюю программу, поэтому лучше завести для этого отдельный бесплатный Apple ID. Если Sideloadly сообщит, что идентификатор приложения занят: Advanced options → Bundle ID → впишите свой, например `com.<ваше-имя>.raybanclaude`.
5. **Разрешить запуск на iPhone.**
   - Настройки → Конфиденциальность и безопасность → **Режим разработчика** → включить; телефон перезагрузится.
   - Настройки → Основные → VPN и управление устройством → ваш Apple ID → **Доверять**.
6. **Очки.** В Meta AI включите режим разработчика: Настройки → ваши очки → Developer Mode. Если переключателя нет: Настройки → App Info, нажмите 5 раз на номер версии. После обновления прошивки очков режим может выключиться — включите снова.
7. **Первый запуск.** Вставьте API-ключ Claude → «Подключить очки» (откроется Meta AI, подтвердите) → «Разрешить камеру» → нажмите микрофон и спросите «Что передо мной?».

Ограничения бесплатного Apple ID:
- **7 дней.** Через неделю приложение перестанет открываться. Повторите шаг 4 с тем же IPA: данные и API-ключ сохранятся. Sideloadly умеет обновлять подпись автоматически, если Mac включён и находится в той же сети Wi-Fi.
- **Не больше 3 приложений**, подписанных бесплатным Apple ID, одновременно на одном телефоне.
- **Без Wi-Fi-канала очков.** В неподписанной сборке нет разрешения Hotspot, поэтому SDK Meta передаёт видео с камеры по Bluetooth Classic. Так работает пример Meta BirdSpotter. Поток идёт в меньшем разрешении, но для снимков по запросу этого достаточно.
- Сборка в CI — Debug: в настройках приложения есть раздел «Отладка» с виртуальными очками (см. [«Без очков»](#без-очков)).

## Запуск из Xcode

1. Установите Xcode из App Store и выберите его:
   ```bash
   sudo xcode-select -s /Applications/Xcode.app/Contents/Developer
   ```
2. Откройте проект:
   ```bash
   open "RayBanClaude.xcodeproj"
   ```
   Xcode сам скачает Meta Wearables DAT SDK 1.0.1 (Swift Package).
3. В **Signing & Capabilities** выберите свою команду (Team) и замените Bundle Identifier `com.example.raybanclaude` на уникальный, например `com.<ваше-имя>.raybanclaude`. Надёжнее сделать это в `project.yml` (`DEVELOPMENT_TEAM`, `PRODUCT_BUNDLE_IDENTIFIER`) и выполнить `xcodegen generate`: тогда настройки не потеряются при пересоздании проекта. Если бесплатный аккаунт не даёт подписать приложение из-за Hotspot / Wi-Fi Info в `RayBanClaude.entitlements`, попробуйте убрать эти два ключа: по документации DAT видеопоток идёт по Bluetooth Classic, а Wi-Fi нужен для больших объёмов данных (без Wi-Fi-канала не проверялось).
4. Подключите iPhone, выберите его как устройство и нажмите **Run**.
5. В приложении: вставьте API-ключ → «Подключить очки» (откроется Meta AI, подтвердите) → «Разрешить камеру» → нажмите микрофон и спросите «Что передо мной?».

## TestFlight без Xcode

Собирает и подписывает облачный Mac в GitHub Actions; от вас нужны только браузер и iPhone.

**Обязательно:** платное членство [Apple Developer Program](https://developer.apple.com/programs/) (99 $ в год) — без него TestFlight недоступен. Оформить можно в приложении Apple Developer на iPhone.

1. **Код на GitHub.** Создайте приватный репозиторий и загрузите туда эту папку. Workflow **CI** (`.github/workflows/ci.yml`) сам запустится, прогонит тесты и соберёт приложение — так видно ошибки компиляции, аккаунт Apple для этого не нужен.
2. **Bundle ID.** [developer.apple.com → Identifiers](https://developer.apple.com/account/resources/identifiers/list) → «+» → App IDs → App. Explicit Bundle ID, например `com.<ваше-имя>.raybanclaude`. В Capabilities отметьте **Access Wi-Fi Information** и **Hotspot** (их требует Wi-Fi-канал Meta DAT).
3. **Приложение в App Store Connect.** [App Store Connect](https://appstoreconnect.apple.com) → Приложения → «+» → Новое приложение: iOS, уникальное название, язык, выбранный Bundle ID, любой SKU. Затем в «Информация о приложении» скопируйте **Apple ID** (10 цифр).
4. **API-ключ.** App Store Connect → Пользователи и доступ → Интеграции → App Store Connect API → «+». Доступ **App Manager**. Скачайте `.p8` (скачать можно только один раз) и запишите **Key ID** и **Issuer ID**.
5. **Ключ сертификата.** Один раз создайте RSA-ключ — по нему CI будет переиспользовать один и тот же сертификат дистрибуции:
   ```bash
   ssh-keygen -t rsa -b 2048 -m PEM -f ~/raybanclaude_cert_key -q -N ""
   ```
6. **Настройки в GitHub:** репозиторий → Settings → Secrets and variables → Actions.

   | Тип | Имя | Значение |
   |---|---|---|
   | Variable | `BUNDLE_ID` | Bundle ID из шага 2 |
   | Variable | `APP_STORE_APPLE_ID` | Apple ID приложения из шага 3 |
   | Variable | `APP_STORE_CONNECT_ISSUER_ID` | Issuer ID |
   | Variable | `APP_STORE_CONNECT_KEY_IDENTIFIER` | Key ID |
   | Variable | `APPLE_TEAM_ID` | Team ID (необязательно; developer.apple.com → Membership) |
   | Secret | `APP_STORE_CONNECT_PRIVATE_KEY` | всё содержимое `.p8`, вместе со строками `BEGIN/END` |
   | Secret | `CERTIFICATE_PRIVATE_KEY` | всё содержимое `~/raybanclaude_cert_key` |

7. **Сборка.** Actions → **TestFlight** → Run workflow. Минут через 15–20 сборка уйдёт в App Store Connect, ещё 10–30 минут Apple её обрабатывает.
8. **Установка.** App Store Connect → приложение → TestFlight → «Внутреннее тестирование» → создайте группу и добавьте себя. На iPhone поставьте приложение **TestFlight** и установите сборку оттуда.

Важно:
- **Только внутреннее тестирование.** Внутренним тестировщикам (до 100 человек из вашей команды App Store Connect) проверка Apple не нужна. Внешнее тестирование требует Beta App Review, а приложения с Meta DAT (протокол внешних аксессуаров) проверку Apple пока не проходят.
- **Лимиты GitHub.** В приватном репозитории бесплатно 2000 минут в месяц, но минуты macOS считаются ×10 — это примерно 200 минут, около 10 сборок. В публичном репозитории минуты бесплатны, но код увидят все (секретов в коде нет: API-ключ Claude вводится в самом приложении).
- **Первая сборка.** iOS-часть ещё ни разу не компилировалась, поэтому первый запуск CI, скорее всего, покажет ошибки — их нужно исправить до TestFlight.
- **Номер сборки** берётся автоматически: последний номер в TestFlight + 1.

### Без очков

В Debug-сборке в настройках есть раздел **«Отладка → Подключить виртуальные очки»** (MockDeviceKit из DAT):
- на iPhone «камерой очков» становится задняя камера телефона, микрофон — телефонный;
- в симуляторе снимок — тестовая картинка `RayBanClaude/Resources/mock_photo.jpg` (вывеска кафе и кружка), а вопрос можно напечатать в поле «Спросить текстом…».

## Устройство проекта

```
project.yml                     спецификация XcodeGen (xcodegen generate → .xcodeproj)
.github/workflows/ci.yml        тесты + неподписанный IPA (для Sideloadly) на каждый push
.github/workflows/testflight.yml  подпись через App Store Connect API и загрузка в TestFlight
scripts/ci/select-xcode.sh      выбор Xcode 26.4+ на раннере
Packages/ClaudeKit/             ядро без UIKit: собирается и тестируется на macOS
  JSONValue.swift               JSON-значения, детерминированная сериализация (для кэша)
  SSEParser.swift               разбор Server-Sent Events
  MessageAssembler.swift        сборка ответа из стрима (text, thinking+signature, tool_use)
  ClaudeClient.swift            POST /v1/messages со стримингом, повторы 429/5xx
  Conversation.swift            агентный цикл: tools, pause_turn, refusal, fallback, откат истории
  Tools.swift                   протокол ClaudeTool, проверка входа по схеме
  SpeechText.swift              разбиение на фразы и очистка текста для озвучки
RayBanClaude/
  Glasses/GlassesManager.swift  DAT: регистрация, сессия, видеопоток, снимки
  Audio/                        аудиосессия (HFP очков), распознавание, синтез речи
  Assistant/                    голосовой цикл, системный промпт, инструменты
  Views/                        SwiftUI-экраны
```

Запросы к Claude (`Packages/ClaudeKit/Sources/ClaudeKit/Conversation.swift`):
- модель по умолчанию **Claude Opus 5.5** (`claude-opus-5-5`), в настройках можно выбрать Sonnet 5.5;
- `output_config.effort: "low"` — для живого диалога важнее скорость (у Opus 5.5 по умолчанию `medium`);
- `fallbacks: "default"` + бета `server-side-fallback-2026-07-01` — если классификатор безопасности отклонит запрос, сервер сам повторит его на fallback-модели;
- автоматическое кэширование промпта (`cache_control` на уровне запроса); дата и время передаются в реплике пользователя, а не в системном промпте, чтобы не ломать кэш;
- история только дописывается — блоки thinking возвращаются без изменений; неудачный ход откатывается целиком.

Тесты ядра (на Mac без Xcode нужны пути к Testing.framework из Command Line Tools):

```bash
cd Packages/ClaudeKit && swift test -Xswiftc -F -Xswiftc /Library/Developer/CommandLineTools/Library/Developer/Frameworks -Xlinker -F -Xlinker /Library/Developer/CommandLineTools/Library/Developer/Frameworks -Xlinker -rpath -Xlinker /Library/Developer/CommandLineTools/Library/Developer/Frameworks -Xlinker -rpath -Xlinker /Library/Developer/CommandLineTools/Library/Developer/usr/lib
```

С установленным Xcode достаточно `swift test`.

## Ограничения

- **Публикация.** DAT 1.0 стабилен, но публичный каталог Meta для сторонних приложений ещё не открыт. Для себя — режим разработчика, для тестировщиков — release channels в Wearables Developer Center (там же берутся `MetaAppID` и `ClientToken`). В App Store такие приложения пока не проходят — используйте TestFlight.
- **«Hey Meta» занят Meta AI.** Своё приложение можно открыть голосом только через экспериментальные voice invocations DAT (здесь не используются). Внутри приложения работает своё обращение («Клод»), пока оно запущено.
- **Звук.** Пока включён микрофон, Bluetooth работает в режиме гарнитуры (HFP): голос ассистента звучит в моно и «телефонном» качестве, а музыка через A2DP не играет. HFP делит полосу Bluetooth Classic с видеопотоком камеры, поэтому SDK может снижать его качество (сам снимок от этого не страдает). Улучшение на будущее: в режиме кнопки выключать микрофон между вопросами и озвучивать ответ через A2DP.
- **API-ключ на устройстве.** Для личного прототипа ключ хранится в Keychain. Для раздачи другим людям ключ нужно спрятать за свой сервер-прокси.
- **Батарея очков.** Сессия с очками и видеопоток камеры включаются только по запросу снимка и отключаются через 90 секунд простоя.
- **Не проверено на устройстве.** Ядро ClaudeKit собрано и покрыто тестами; iOS-часть написана по интерфейсам DAT SDK 1.0.1, но на этом Mac нет Xcode, поэтому она ещё не собиралась.
