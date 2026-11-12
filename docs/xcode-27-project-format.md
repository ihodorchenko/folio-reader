# Инструкция по созданию и редактированию проектов Xcode 27.2+ (формат JSON / .xcproj)

При создании нового проекта Xcode или изменении структуры существующего используй нативный формат конфигурации JSON5 (`project.xcproj`) вместо устаревшего `project.pbxproj`.

## 1. Структура пакета `.xcodeproj`
Пакет `<ProjectName>.xcodeproj` представляет собой директорию со следующей минимальной структурой:
```text
<ProjectName>.xcodeproj/
├── project.xcproj               # Основной файл конфигурации проекта (JSON5)
└── project.xcworkspace/
    └── contents.xcworkspacedata # Ссылка на сам проект
```

### Содержимое `contents.xcworkspacedata`
```xml
<?xml version="1.0" encoding="UTF-8"?>
<Workspace version = "1.0">
   <FileRef location = "self:"></FileRef>
</Workspace>
```

## 2. Правила синтаксиса `project.xcproj`
1. **Формат:** Используется JSON5 (допускаются висячие запятые и комментарии, строковые ключи в kebab-case).
2. **Без UUID:** Никогда не генерируй 24-символьные шестнадцатеричные ID. Ссылки на таргеты и фазы сборки указываются по их строковым именам.
3. **Иерархия файлов:** Дерево исходников описывается в массиве `files` через объекты групп (`"kind": "group"`) и файлов.
4. **Привязка к таргетам (Target Membership):** Указывается прямо внутри объекта файла через ключ `"target-membership": ["<TargetName>/<phase>"]` (например, `"MyApp/compile-sources"` или `"MyApp/resources"`).
5. **Настройки сборки (Build Settings):** Описываются в объекте `settings` плоскими парами ключ-значение (без дублирования на каждый файл).

## 3. Шаблон минимального `project.xcproj` (iOS App)
Используй этот шаблон как основу при генерации нового проекта с нуля:

```json5
{
  "format-version": "27.0",
  "default-configuration": "Debug",
  "configurations": [
    "Debug",
    "Release"
  ],
  "settings": {
    "SWIFT_VERSION": "6.0",
    "IPHONEOS_DEPLOYMENT_TARGET": "18.0",
    "ENABLE_USER_SCRIPT_SANDBOXING": "YES"
  },
  "files": [
    {
      "kind": "group",
      "path": "Sources",
      "children": [
        {
          "path": "App.swift",
          "target-membership": [
            "MyApp/compile-sources"
          ]
        },
        {
          "path": "ContentView.swift",
          "target-membership": [
            "MyApp/compile-sources"
          ]
        }
      ]
    },
    {
      "kind": "group",
      "path": "Resources",
      "children": [
        {
          "path": "Assets.xcassets",
          "target-membership": [
            "MyApp/resources"
          ]
        }
      ]
    }
  ],
  "targets": [
    {
      "name": "MyApp",
      "product-type": "application",
      "platforms": [
        "ios"
      ],
      "settings": {
        "PRODUCT_BUNDLE_IDENTIFIER": "com.example.MyApp",
        "INFOPLIST_KEY_UIApplicationSceneManifest_Generation": "YES",
        "INFOPLIST_KEY_UILaunchScreen_Generation": "YES",
        "GENERATE_INFOPLIST_FILE": "YES"
      },
      "phases": [
        {
          "kind": "compile-sources"
        },
        {
          "kind": "frameworks"
        },
        {
          "kind": "resources"
        }
      ]
    }
  ]
}
```

## 4. Валидация и форматирование
После создания или любого ручного изменения `project.xcproj` обязательно выполни в терминале встроенный валидатор Xcode 27.2+:
```bash
xcprojformatter --in-place <ProjectName>.xcodeproj/project.xcproj
```
Если команда вернула ошибку валидации, исправь схему согласно выводу утилиты до завершения задачи.

---

## Проверено на этой машине (Xcode 27.2, build 27B52)

- Утилизатор существует: `/Applications/Xcode.app/Contents/Developer/usr/bin/xcprojformatter`.
- В этой версии флаг называется **`--update`**, а не `--in-place`:
  ```bash
  xcprojformatter --update Project.xcodeproj
  ```
  `xcprojformatter --help` также принимает `--input`/`--output`; без аргументов читает stdin и печатает канонический JSON5.
