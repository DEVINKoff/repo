# HomeMusic для iOS

Нативный клиент HomeMusic для iPhone и iPad (SwiftUI, iOS 18+, Liquid Glass на iOS 26). Работает с тем же Хабом,
что Android-приложение и PWA: вся логика сервера — подбор файлов, порядок источников и копии без цензуры, «Моя волна»,
«Микс дня», умное перемешивание, вкус — остаётся в Хабе и не меняется.

Клиентская логика перенесена из PWA один в один:

| PWA (`web/src/lib`) | iOS (`ios/HomeMusic`) |
|---|---|
| `plays.ts` — события прослушивания, очередь отправки | `Playback/PlayEvents.swift` |
| `listen.ts` — плеер, start/finish/skip, чекпоинты, очередь, режимы | `Playback/Player.swift` (AVPlayer) |
| `wave.ts` — «Моя волна» | `Playback/Wave.swift` |
| `smartShuffle.ts` — умное перемешивание | `Playback/SmartShuffle.swift` |
| `stars.ts`, `dislikes.ts` — ♥ и «Не нравится» | `Library/Stars.swift` |
| `events.ts` — SSE | `Core/HubEvents.swift` |
| `capabilities.ts` | `Core/Capabilities.swift` |
| `player.ts` — мост `HomeMusicAndroid` | `UI/Web/HubWebView.swift` (тот же мост) |

Главная, поиск (каталог и «Файлы»), библиотека, плейлисты, альбомы, исполнители, «Микс дня», плеер и загрузки —
нативные экраны. Ассистент, перенос музыки, загрузка своих файлов, редактор медиатеки и админка открываются страницами
Хаба внутри приложения (`/?embedded=1`), как в Android-приложении, и играют через нативный плеер.

`client` событий — `app/<версия>-ios`.

## Сборка без Mac

Сборка идёт на macOS-раннере GitHub Actions: `.github/workflows/ios.yml` генерирует проект XcodeGen'ом
(`ios/project.yml`) и собирает **неподписанный** `HomeMusic.ipa` (артефакт `HomeMusic-ipa`).
Подпишите и установите его через Sideloadly или AltStore.

## Первый запуск

Введите IP или имя ПК с HomeMusic (например, `192.168.1.10`): приложение подставит Хаб `http://192.168.1.10:8080`.
Войдите учётной записью Navidrome. iOS спросит доступ к локальной сети — разрешите.
