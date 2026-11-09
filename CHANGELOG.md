# Changelog — xpk84 fork

Все версии поверх upstream `mikrotik-user/IPSec-IKE-v2-auto-script` (заморожен 2022-01-13).

## v2.3 — 2026-10-23

- Промпты: все примеры замаскированы — без реальных доменов, IP и имён
  (пример домена `vpn.example.com`, пример IP из RFC 5737 `203.0.113.10`).
- Подсказка имени пира — живой шаблон `ike2_<user>_<device>_<текущий год>`
  (год вычисляется из `system clock`).
- Заголовок скрипта: комментарий «запускать только из терминала» с командой запуска
  и пояснением, почему кнопка Run в WinBox не работает.
- IKEv2-rollback: первая строка итогового скрипта — `# WARNING` о полном сносе
  IKEv2-сервера; WARNING также вшит в генератор (новые инсталлы).

## v2.2 — 2026-10-23

- FIX (критично): интерполяция `$var` внутри строки-аргумента вызова `[$func "..."]` —
  синтаксическая ошибка парсера RouterOS (в выражениях `("...")` работает).
  Все промпты с переменными переведены на конкатенацию `("..." . $var . "...")`.
- Реальная дата истечения сертификата печатается после подписания
  (из `invalid-after` самого сертификата): date-math в RouterOS отсутствует —
  `:todate` не существует, `:totime` + дни даёт длительность, а не дату.

## v2.1 — 2026-10-23

- Примеры и вычисляемые подсказки во всех вопросах (домен, IP — с предрезолвом,
  имя пира → итоговое имя сертификата, срок).
- Исправлены опечатки оригинала: «enict» → «encrypt», «more than 8 digits» →
  «at least 8 characters».

## v2.0 — 2026-10-23

- Пароль pkcs12: минимум 8 символов, не печатается в консоль (только длина).
- Срок клиентского сертификата спрашивается; Enter = случайное значение 330–395 дней
  (разнос сроков истечения по клиентам), минимум 30 дней, не-число → 365.
- Перед выпуском выставляется `days-valid` шаблона `~client-template@<host>`.
- Отзыв пира (меню 3) и генерируемые rollback-скрипты: полный cleanup —
  identity → revoke → `/certificate remove` → удаление p12 из Files → самоудаление rollback.
- Крипто-ужесточение новых инсталляций: dh-group только modp2048, без sha1 и aes-192-*
  (CBC 256/128 оставлены для совместимости с Windows-клиентами).
- Имя скрипта: `IKEv2_run_to_create`. RouterOS 7.x (зависимость `:rnd` была ошибкой —
  такой команды в RouterOS нет, см. v2.3.2).

## v2.3.1 — 2026-10-23

- Финальное сообщение «Create peer» называет конкретный файл для копирования:
  `<peername>@<host>.p12` из Files и напоминает про пароль импорта.

## v2.3.2 — 2026-10-28

- Фикс «Press ENTER = random 330-395»: ветка пустого ввода отсутствовала в коде,
  а `:rnd` в RouterOS не существует вовсе (7.24.5: `bad command name rnd`).
  Рандом теперь из системных часов: `(мин*60+сек) mod 66 + 330` → 330–395 дней.
  Ручной ввод ≥30 дней и фоллбек 365 — без изменений.
- Меню 2 и 3: авто-детект домена сервера по единственному сертификату `CA.<домен>` —
  подсказка `Press ENTER to use <домен>` (домен читается с роутера в рантайме,
  в коде не зашит). Нет CA (свежая установка) — прежний путь через `/ip cloud`.

## v2.3.2 (доп.) — 2026-10-28

- README: задокументирован дефект импорта macOS — RouterOS 7.24+ пакует ключ p12
  как PBES2/AES-256, Keychain молча теряет ключ (серт без ключа); рецепт пересборки
  в legacy-3DES добавлен в README.fork.md.

## v2.3.3 — 2026-10-28

- Финальное сообщение Create-peer печатает подсказку для macOS (vpn-import-mac).
- В репо добавлен tools/vpn-import-mac.sh — helper импорта p12 в macOS System keychain
  (автоскачивание с роутера по scp, пересборка legacy-3DES, чистка дублей, импорт, проверка);
  пример конфига — tools/vpn-import-mac.conf.example.

## v2.3.4 — 2026-11-04

- Меню 2 (Create peer): к введённому имени автоматически дописывается суффикс даты выпуска
  _YYYYMMDD (из часов роутера); CN/SAN/p12/rollback наследуют его. Решает путаницу `_2026`
  («действует до 2026» у декабрьской партии vs «выпущен в 2026» у октябрьской).
- Меню 3 (Revoke peer): принимает базовое имя или префикс — скрипт сам листает совпадающие
  сертификаты с датами истечения, выбор по номеру, подтверждение показывает выбранное имя.
- Существующие сертификаты не переименовываются (переименование = перевыпуск).

## v2.3.5 — 2026-11-04

- Из меню вырезан пункт 4 (Remove IKE v2 server): он запускал полный демонтаж IKEv2-сервера
  (все пиры, пул, сертификаты) и был слишком деструктивен для повседневного меню.
- Ввод «4» теперь печатает явный отказ с указанием ручного пути (скрипт IKEv2-rollback напрямую
  из терминала), сам мастер-IKEv2-rollback не изменён.
- Мотивация: при тестовом запуске старый rollback удалял policy-шаблон и падал на удалении
  группы («Used in identity configuration») — частичный урон без результата.

## v2.3.6 — 2026-11-04

- Меню 2 спрашивает только `<user>_<device>`: `Input peer name. (<user>_<device>)`.
- Префикс `ike2_` и суффикс даты выпуска `_YYYYMMDD` дописываются автоматически;
  введённый по привычке префикс `ike2_` не дублируется (стриппится).
- Из подсказки убраны лишние детали (шаблон полного имени, имя сертификата, домен).

## v2.3.7 — 2026-11-05

- Отзыв (меню 3) принимает только ТОЧНОЕ имя пира (`ike2_<user>_<device>_<дата>`):
  префиксный поиск и выбор из списка по номеру убраны — скрипт ничего не «додумывает».
  Если ввели имя с `@<домен>` — суффикс срезается, остальное используется как есть.
- Вместо жёсткого precheck — инвентаризация 4 объектов (сертификат / identity /
  p12-файл / rollback-скрипт) с отчётом found/absent по каждому.
- Устойчивость к частично удалённому состоянию: если что-то уже снесено руками
  (например, серт удалён в WinBox, а identity осталась) — отзыв не падает:
  найденное удаляется по шагам, каждый шаг печатает removed / already absent.
- Ничего не найдено (все 4 объекта отсутствуют, включая опечатку в имени) —
  «Nothing to remove» и чистый выход без ошибки.

## v2.3.8 — 2026-11-05

- Меню 2 после выпуска пира печатает iOS-note: RouterOS-p12 содержит клиентский серт + CA
  (два серта), iOS отвергает такой контейнер при установке identity-профиля.
- В подсказке — готовые команды пересборки через openssl (leaf+ключ, читаемое имя),
  одинаковые для macOS/Linux/Windows (для Windows — сначала `winget install ... openssl`),
  и указание на хелпер tools/vpn-cert-for-ios.sh в репозитории форка.
## 2026-11-05 (helper fix) — Apple legacy p12
- vpn-cert-for-ios.sh: re-export with 3DES/PBES1 (`-legacy` + explicit
  `-certpbe/-keypbe PBE-SHA1-3DES -macalg sha1`, LibreSSL fallback). Apple
  (iOS/macOS) silently drops PBES2 keys: identity imports half-broken — the
  certificate picker offers it once, then removes it. Verified by synthetic
  end-to-end test: 1 cert + 1 key, both bags 3DES, readable friendlyName,
  clean error on wrong passphrase.
- vpn-cert-for-ios.bat: same 3DES re-export with -legacy / no-legacy retry
  and a 3DES presence check (warning if missing).
- README: manual macOS/Linux openssl commands now include -legacy; added the
  Apple PBES2 half-import explanation.

## 2026-11-05 (plan B) — vpn-ios-profile.sh (.mobileconfig generator)
- New helper: builds a single iOS configuration profile embedding CA root,
  client identity (leaf-only, 3DES/PBES1, password prompted at install —
  never embedded) and a ready IKEv2 VPN payload
  (AuthenticationMethod=Certificate, PayloadCertificateUUID linkage,
  LocalIdentifier=CN, ServerCertificateIssuerCommonName=CA CN,
  exactly-one proposal AES-256/SHA2-256/modp2048 IKE and AES-256/SHA2-256
  child without PFS — matches the profile/proposal the script installs).
  Bypasses the unreliable manual certificate picker entirely.
- Verified on synthetic RouterOS-style input: plist lints, 3 payloads,
  UUID linkage correct, embedded p12 = 1 cert + key, 3DES x2, same-pass
  unwrap, no Password key in the profile.

## 2026-11-05 (Android) — vpn-android-profile.sh (.sswan generator)
- New helper for the strongSwan Android client: builds a self-contained
  .sswan profile (uuid/type=ikev2-cert, remote.addr+id+CA pin via
  remote.cert, local.id + PKCS#12 embedded via local.p12 — imported into
  the app keystore, not the system one; exactly one proposal:
  aes256-sha256-modp2048 IKE, aes256-sha256 ESP without DH for pfs=none).
  The Android analog of the iOS .mobileconfig; the built-in Android client
  has NO profile import at all (certs only), so strongSwan is the only
  file-provisionable path. Identity is re-exported leaf-only 3DES/PBES1
  with a readable name (fixes the hex localKeyID alias too); passphrase
  is asked by the app at import, never embedded.
- Verified on synthetic RouterOS-style input: JSON valid, p12 = 1 cert +
  key (3DES x2, same-pass unwrap), CA DER decodes, clean wrong-pass error.
