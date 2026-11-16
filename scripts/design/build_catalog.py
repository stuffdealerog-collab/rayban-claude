#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""Собирает каталоги переводов Xcode из keys.json и translations.<язык>.json.

    python3 scripts/design/build_catalog.py

Пишет RayBanClaude/Resources/Localizable.xcstrings (надписи интерфейса; ключи — русские строки из кода)
и RayBanClaude/Resources/InfoPlist.xcstrings (тексты системных запросов разрешений).
"""
import json
import os
import sys

HERE = os.path.dirname(__file__)
RESOURCES = os.path.join(HERE, "..", "..", "RayBanClaude", "Resources")
LANGUAGES = ["uz", "en"]


def load(name):
    return json.load(open(os.path.join(HERE, name), encoding="utf-8"))


def unit(value):
    return {"stringUnit": {"state": "translated", "value": value}}


keys = load("keys.json")
translations = {language: load(f"translations.{language}.json") for language in LANGUAGES}
problems = []
strings = {}
for key in keys:
    localizations = {}
    for language in LANGUAGES:
        value = translations[language].get(key)
        if value is None:
            problems.append(f"{language}: нет перевода для {key!r}")
            continue
        if value.count("%@") != key.count("%@"):
            problems.append(f"{language}: число подстановок не совпало в {key!r}")
        localizations[language] = unit(value)
    strings[key] = {"extractionState": "manual", "localizations": localizations}
for language in LANGUAGES:
    for extra in set(translations[language]) - set(keys):
        problems.append(f"{language}: лишний ключ {extra!r}")

json.dump(
    {"sourceLanguage": "ru", "strings": strings, "version": "1.0"},
    open(os.path.join(RESOURCES, "Localizable.xcstrings"), "w", encoding="utf-8"),
    ensure_ascii=False, indent=2, sort_keys=True,
)

info = {"ru": load("infoplist.ru.json")}
for language in LANGUAGES:
    info[language] = load(f"infoplist.{language}.json")
info_strings = {}
for key, russian in info["ru"].items():
    localizations = {"ru": unit(russian)}
    for language in LANGUAGES:
        if key not in info[language]:
            problems.append(f"{language}: нет текста разрешения {key}")
            continue
        localizations[language] = unit(info[language][key])
    info_strings[key] = {"extractionState": "manual", "localizations": localizations}
json.dump(
    {"sourceLanguage": "ru", "strings": info_strings, "version": "1.0"},
    open(os.path.join(RESOURCES, "InfoPlist.xcstrings"), "w", encoding="utf-8"),
    ensure_ascii=False, indent=2, sort_keys=True,
)

print(f"надписей: {len(strings)}, разрешений: {len(info_strings)}, языки: {', '.join(LANGUAGES)}")
if problems:
    print("\n".join(problems))
    sys.exit(1)
