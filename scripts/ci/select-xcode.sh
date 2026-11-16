#!/bin/bash
# Выбирает Xcode на раннере GitHub Actions.
# Meta DAT 1.0.1 собран Swift 6.3.3, поэтому нужен Xcode 26.4 или новее.
# Конкретную версию можно задать переменной репозитория XCODE_VERSION (например, 26.4.1).
set -euo pipefail

if [[ -n "${XCODE_VERSION:-}" ]]; then
  XCODE_APP="/Applications/Xcode_${XCODE_VERSION}.app"
else
  # Самая новая стабильная версия (без beta/RC в имени).
  XCODE_APP=$(ls -d /Applications/Xcode_*.app 2>/dev/null \
    | grep -E '/Xcode_[0-9]+(\.[0-9]+)*\.app$' \
    | sort -V | tail -1 || true)
fi

if [[ -z "$XCODE_APP" || ! -d "$XCODE_APP" ]]; then
  echo "::error::Xcode не найден (${XCODE_APP:-нет кандидатов}). Установленные версии:"
  ls -d /Applications/Xcode*.app || true
  exit 1
fi

sudo xcode-select -s "$XCODE_APP/Contents/Developer"
# awk читает вывод до конца: с head xcodebuild иногда падал на закрытом канале (Broken pipe).
VERSION=$(xcodebuild -version | awk 'NR == 1 {print $2}')
echo "Выбран $XCODE_APP (Xcode $VERSION)"

MAJOR=${VERSION%%.*}
REST=${VERSION#*.}
MINOR=${REST%%.*}
[[ "$MINOR" =~ ^[0-9]+$ ]] || MINOR=0
if (( MAJOR < 26 || (MAJOR == 26 && MINOR < 4) )); then
  echo "::error::Нужен Xcode 26.4+ для Meta DAT 1.0.1, выбран $VERSION. Задайте переменную XCODE_VERSION."
  exit 1
fi
xcrun swift --version
