#!/bin/bash
# Снимает экраны приложения в симуляторе: запускает сборку с `-demo <экран>` (см. DemoMode.swift)
# в светлой и тёмной теме и складывает PNG в папку.
#   screenshots.sh <путь к .app> <папка для снимков> [экраны через пробел]
set -euo pipefail

APP="$1"
OUT="$2"
SCREENS="${3:-}"
BUNDLE="com.example.raybanclaude"
if [[ -z "$SCREENS" ]]; then
  SCREENS="assistant-empty assistant-chat assistant-listening assistant-speaking translator translator-chat translator-live memory note settings onboarding-0 onboarding-1 onboarding-2 onboarding-3 onboarding-5 onboarding-6"
fi
mkdir -p "$OUT"

# Самый новый iPhone Pro на самой новой iOS.
UDID=$(xcrun simctl list devices available -j | python3 -c '
import json, re, sys
devices = json.load(sys.stdin)["devices"]
best = None
for runtime, items in devices.items():
    match = re.search(r"iOS-(\d+)-(\d+)", runtime)
    if not match:
        continue
    version = (int(match.group(1)), int(match.group(2)))
    for item in items:
        name = item["name"]
        if not name.startswith("iPhone"):
            continue
        numbers = re.findall(r"\d+", name)
        model = int(numbers[0]) if numbers else 0
        score = (version, "Pro" in name and "Max" not in name, model)
        if best is None or score > best[0]:
            best = (score, item["udid"], name, runtime)
print(best[1])
print("Симулятор:", best[2], best[3], file=sys.stderr)
')

xcrun simctl boot "$UDID" 2>/dev/null || true
xcrun simctl bootstatus "$UDID" -b
xcrun simctl status_bar "$UDID" override --time "9:41" --batteryState charged --batteryLevel 100 --cellularBars 4 --wifiBars 3 || true
xcrun simctl install "$UDID" "$APP"

# Прогрев: первый запуск после установки долгий, его снимок получался пустым.
xcrun simctl launch "$UDID" "$BUNDLE" -demo assistant-empty -AppleLanguages "(ru)" -AppleLocale ru_RU >/dev/null
sleep 18
xcrun simctl terminate "$UDID" "$BUNDLE" >/dev/null 2>&1 || true

for appearance in dark light; do
  xcrun simctl ui "$UDID" appearance "$appearance"
  sleep 1
  for item in $SCREENS; do
    # «экран@uz» — снимок на узбекском (или @en); без суффикса — на русском.
    # «экран+a11y» — снимок с очень крупным шрифтом (Dynamic Type).
    size="large"
    if [[ "$item" == *+a11y* ]]; then
      size="accessibility-large"
      item="${item/+a11y/}"
    fi
    xcrun simctl ui "$UDID" content_size "$size" >/dev/null 2>&1 || true
    screen="${item%@*}"
    language="ru"
    [[ "$item" == *@* ]] && language="${item##*@}"
    xcrun simctl launch "$UDID" "$BUNDLE" -demo "$screen" -demoLanguage "$language" -AppleLanguages "(ru)" -AppleLocale ru_RU >/dev/null
    sleep 6
    name="$screen-$appearance"
    [[ "$language" != "ru" ]] && name="$screen-$language-$appearance"
    [[ "$size" != "large" ]] && name="$name-a11y"
    xcrun simctl io "$UDID" screenshot --type=png "$OUT/$name.png" >/dev/null 2>&1
    # Иногда приложение не успевает нарисоваться, и снимок выходит пустым: ждём и снимаем ещё раз.
    if ! python3 -c "
import sys, zlib, struct
data = open(sys.argv[1], 'rb').read()
# Пустой кадр сжимается почти в ничто: настоящий экран весит сотни килобайт.
sys.exit(0 if len(data) > 60000 else 1)" "$OUT/$name.png"; then
      sleep 6
      xcrun simctl io "$UDID" screenshot --type=png "$OUT/$name.png" >/dev/null 2>&1
    fi
    xcrun simctl terminate "$UDID" "$BUNDLE" >/dev/null 2>&1 || true
  done
done

# Вдвое меньше: быстрее скачивать и смотреть.
for file in "$OUT"/*.png; do sips -Z 1320 "$file" >/dev/null; done
ls -lh "$OUT"
