# How the Beneficiary App Is Made

The Youth Advocates beneficiary app is a Flutter app that field officers use to capture data **offline** and later sync it to the Youth Advocates CRM (the Laravel project `yazcrm`). It does three jobs:

1. **Attendance registers.** It replaces the paper register: an activity header, then one row per beneficiary with a signature.
2. **Beneficiary profiling.** This is the Youth Enterprise Graduate Model profiling form.
3. **Data collection (Kobo-style).** Officers fill in forms that were designed and assigned in the CRM.

All data is saved on the device first. Sending it to the CRM is a separate, explicit step ("Sync Now"), so the app works with no signal.

---

## 1. Tech stack

| Part | Choice | Why |
|---|---|---|
| Framework | Flutter (Dart ≥ 3.3), Material 3 | One codebase for Android, iOS, web (Chrome) and desktop |
| Local database | SQLite via `sqflite` | Offline-first storage |
| SQLite on desktop | `sqflite_common_ffi` | `sqflite` has no Windows/Linux implementation |
| SQLite on web | `sqflite_common_ffi_web` | Runs SQLite as WebAssembly and stores it in the browser's IndexedDB (`web/sqlite3.wasm`, `web/sqflite_sw.js`) |
| HTTP | `http` | Calls the CRM REST API |
| Settings | `shared_preferences` | Stores the server address the user enters |
| IDs | `uuid` | Every record gets a UUID on the device, which makes sync safe to retry |
| Secure storage | `flutter_secure_storage` | Keeps the API token in the platform keystore, not in SQLite |
| Data collection | `geolocator` (GPS), `image_picker` + `flutter_image_compress` (photos), `workmanager` (Android background sync), `connectivity_plus` (sync when back online) | |
| Other | `intl` (dates), `path` / `path_provider` (files) | |

The server side is the existing **Laravel 12 CRM**. It authenticates the app with **Sanctum** bearer tokens.

---

## 2. Folder structure

```
lib/
  main.dart                     App entry: picks the SQLite engine, loads the saved server address, sets the theme
  api/
    api_client.dart             All HTTP calls to the CRM, plus server-address handling
  db/
    database_helper.dart        Opens SQLite and creates and migrates the tables
    repository.dart             The only place screens read or write data, and where sync lives
  data_collection/              Kobo-style forms (see section 6)
    config.dart                 API prefix, batch size, retention, photo size, app version, mock switch
    models/                     Form schema, local submission, and API contract shapes
    api/                        CRM client for /api/v1 (+ mock server)
    db/                         dc_* table access
    expression/                 XLSForm expression parser and evaluator
    engine/form_engine.dart     Skip logic, required, constraints, defaults, calculations, repeats, payload
    sync/                       Sync engine, foreground triggers, WorkManager background task
    media/                      Photo capture/compression, GPS capture, photo files
    screens/ widgets/           Forms list, form filling, review, submissions, sync status
  theme/
    brand_colors.dart           Youth Advocates logo colours
  screens/
    login_screen.dart           Server pop-up + login
    activity_screen.dart        Home screen (registers, profiling, data collection, sync, logout)
    capture_screen.dart         One beneficiary row of an attendance register
    profile_screen.dart         Beneficiary Profiling Tool
    signature_pad.dart          Finger-drawn signature, exported as PNG
assets/images/logo.png          Youth Advocates logo
assets/data_collection/        Sample household survey form (tests and mock mode)
test/data_collection/           Unit tests: expressions, form engine, sync engine
web/                            Web build files, including the SQLite WebAssembly files
```

**Rule of thumb:** screens never call `ApiClient` or SQLite directly for stored data. They go through `Repository`. The one exception is phone-number lookups that check the server live.

---

## 3. How the app flows

```
App start (main.dart)
  ├─ choose SQLite engine (mobile / desktop FFI / web WASM)
  ├─ load saved server address
  └─ LoginScreen
       ├─ already logged in and server known? ──► ActivityScreen (works offline)
       └─ otherwise: "Connect to server" pop-up ──► email + password ──► ActivityScreen

ActivityScreen (home)
  ├─ New Attendance Register ──► CaptureScreen (one row per beneficiary)
  ├─ New Beneficiary Profile ──► ProfileScreen
  ├─ Fill Forms ──► FormsScreen ──► FormSubmissionsScreen ──► FormFillScreen
  ├─ Sync Now (uploads everything pending)
  └─ Log Out
```

### Server address

On the login screen a pop-up asks for the CRM address. Users can type any of these:

- `192.168.10.149`
- `yazcrm.test`
- `http://host/api`

`ApiClient.normalizeBaseUrl` turns any of them into `http://host/api/`. The address is saved with `shared_preferences` and shown under the LOGIN button, where a tap changes it.

### Login

`POST api/auth/login` checks the email and password against the CRM `users` table. Any **active** CRM user can log in. The user is stored in the SQLite `session` table and the token in secure storage (`flutter_secure_storage`), so the next launch skips the login screen, even offline. Tokens saved by older builds are moved to secure storage on first launch, so nobody is logged out. If secure storage isn't available (Chrome on a plain-http address), the token falls back to the session row.

---

## 4. Local database

The database is `beneficiary.db`, currently at schema **version 4**. Migrations live in `DatabaseHelper.onUpgrade`.

| Table | Holds | Sync flag |
|---|---|---|
| `session` | The logged-in user and API token (one row) | — |
| `activities` | Attendance register headers (activity name, date, compiled by, reviewed by) | `synced` 0/1 |
| `attendances` | One beneficiary row per register, with signature | `synced` 0/1 |
| `profiles` | Beneficiary profiles. About 40 answers are stored as one JSON blob, with name and phone split out for lookup. | `synced` 0/1 |
| `dc_forms` | Forms assigned to the user: latest version on the server, version cached on the device | — |
| `dc_form_schemas` | Every downloaded schema version | — |
| `dc_submissions` | Filled-in forms; also the sync queue | `status`: `draft` / `finalized` / `syncing` / `sent` / `failed` |
| `dc_media` | Photos attached to submissions | `uploaded` 0/1 |
| `dc_sync_runs` | Sync history for the sync status screen | — |

The version 3 tables from the first, simpler data collection feature (`forms`, `submissions`) are renamed to `legacy_v3_*` by the version 4 upgrade, not dropped.

**Signatures** are saved as PNG files on the device. On web, where the browser can't write files, they're kept inline as a `data:` URI. They're sent as base64 during sync.

**Adding a table or column:**
1. Bump `version` in `database_helper.dart`.
2. Add an `if (oldVersion < N)` step in `onUpgrade`.
3. Call the same create code from `onCreate`.

---

## 5. Sync

"Sync Now" calls `Repository.syncPending()`, which runs three steps in order:

| Step | CRM endpoint | Sends |
|---|---|---|
| `_syncAttendances` | `POST api/beneficiary-attendances/sync` | Unsynced activities with their attendances |
| `_syncProfiles` | `POST api/beneficiary-profiles/sync` | Unsynced profiles |
| `SyncCoordinator.sync` | `POST api/v1/submissions/batch`, then `.../media` | Finalized data collection submissions (see section 6) |

**Sync is safe to retry.** Each record carries a UUID created on the device (`client_uuid` / `submission_uid`). The CRM skips any UUID it already has, so a failed or repeated sync never creates duplicates.

The "Pending sync" count on the home screen is unsynced attendances + unsynced profiles + the current user's finalized data collection submissions.

---

## 6. Data collection (Kobo-style forms)

Forms are defined in the CRM. The app downloads each user's assigned forms, fills them in offline, and syncs the submissions back. It's opened from **Fill Forms** on the home screen. Settings are in `lib/data_collection/config.dart`.

### Forms
- **Listing:** `GET /api/v1/forms` returns the forms assigned to the user (id, title, version, checksum, updated_at).
- **Refreshing:** pull-to-refresh compares version and checksum, then downloads any missing or newer schema from `GET /api/v1/forms/{id}/schema?version=`.
- **Old versions:** every version is kept, so drafts started on an older version still open.
- **"Update available" badge:** comes from `GET /api/v1/sync/status`.

### Form schema

The schema follows XLSForm, either as flat survey rows (`begin_group` … `end_group`) or as nested `children` (pyxform JSON).

**Question types:** `text`, `integer`, `decimal`, `select_one`, `select_multiple`, `date`, `time`, `datetime`, `geopoint`, `photo`, `note`, `calculate`, `group`, `repeat`.

**Columns:** `relevant`, `required`, `constraint` + `constraint_message`, `default`, `calculation`, `hint`, `read_only`, `appearance`.

**Choices:** inline on the question, or a top-level `choices` list referenced as `select_one list_name`.

`assets/data_collection/household_survey.json` is a full example.

### Expressions

`lib/data_collection/expression/` implements the XLSForm subset:
- references: `${field}`, `.`
- operators: `= != < <= > >= and or + - * div mod`
- functions: `selected`, `count-selected`, `if`, `concat`, `join`, `string-length`, `substr`, `contains`, `starts-with`, `ends-with`, `regex`, `today`, `now`, `int`, `number`, `round`, `coalesce`, `count`, `sum`, `min`, `max`, `position`, `not`

How values behave:
- **Dates** compare and subtract as days.
- **Repeats:** a question inside a repeat, referenced from outside it, gives a list. That's how `count()` and `sum()` work across repeat instances.
- **Unreadable expressions** don't crash the form. The form shows a warning naming the expression, so it can be fixed in the CRM.

### Answers (the `data` sent to the CRM)

Answers are a flat map of field name → value. Each repeat is a list of maps.

| Type | Stored as |
|---|---|
| `integer` / `decimal` | Number |
| `select_multiple` | `"a b"` (space-separated, as XLSForm stores it) |
| `date` | `yyyy-MM-dd` |
| `time` | `HH:mm` |
| `datetime` | `yyyy-MM-ddTHH:mm:ss` |
| `geopoint` | `"lat lng altitude accuracy"` |
| `photo` | The file name. The file itself goes to the media endpoint. |

Answers to questions hidden by skip logic are left out when the submission is finalized.

### Submission lifecycle

`draft → finalized → syncing → sent`, or `failed` with the server's reason.

- **New submissions** get a `client_uuid` (UUID v4) when they open. Drafts autosave as answers change.
- **Finalizing** goes through a review screen. **Finalized but unsent** submissions can still be edited; editing one moves it back to draft. **Sent** submissions are read-only.
- **Ownership.** Each submission belongs to the user who collected it and is only ever sent under that account. If another user logs in on the device, they choose:
  - keep the submissions locked to the original user, or
  - discard them.
- **Photos** are compressed to at most 1 MB on Android. Chrome uses the picker's own scaling instead. Location and camera permissions are asked for when first used.

### Sync engine (`sync/sync_engine.dart`)

1. **Data first.** Submissions go to `POST /api/v1/submissions/batch` in batches of up to 50. Each one is marked from the server's per-item result:
   - `accepted` or `duplicate`: stored on the server.
   - `rejected`: marked `failed`, with the server's reason shown to the user.
2. **Then photos.** Photos are uploaded to `POST /api/v1/submissions/{client_uuid}/media`, but only for submissions whose data was stored. A submission becomes `sent` once every photo is in.
3. **Errors.**
   - **Transient** (no network, timeouts, 5xx, 429): retried with exponential backoff (30 s doubling to 1 h; `Retry-After` is respected).
   - **401:** stops the run with the queue untouched, and the app asks the user to log in again.
   - **Nothing is deleted** locally until the server confirms it. Sent records are purged after 30 days.

**When sync runs:**
- on app start
- when connectivity returns
- right after finalizing a submission
- "Sync now" (home screen, submissions screen, sync status screen)
- on Android, in the background: WorkManager every 15 minutes, plus a one-off task after finalizing. Both need a network.

The background task runs in its own isolate and reads the database, token and server address from storage itself. In Chrome, sync runs only while the app is open.

### Trying it without the CRM endpoints

`flutter run -d chrome --dart-define=DC_MOCK_API=true` serves the sample form from an in-memory server. Login still uses the real CRM.

---

## 7. CRM endpoints the app uses

All of them except login need the `Authorization: Bearer <token>` header.

| Method | Path | Used for |
|---|---|---|
| POST | `api/auth/login` | Login, returns `{ user, token }` |
| GET | `api/beneficiary-attendances/search?phone=` | "Already captured?" check |
| POST | `api/beneficiary-attendances/sync` | Upload registers |
| GET | `api/beneficiary-profiles/search?phone=` | "Already profiled?" check |
| POST | `api/beneficiary-profiles/sync` | Upload profiles |
| GET | `api/v1/forms` | Assigned forms (id, title, version, checksum, updated_at) |
| GET | `api/v1/forms/{id}/schema?version=` | One form version's schema |
| POST | `api/v1/submissions/batch` | Up to 50 submissions; per-item accepted / duplicate / rejected |
| POST | `api/v1/submissions/{client_uuid}/media` | One photo (multipart) |
| GET | `api/v1/sync/status` | Latest form versions and server time |

The `api/v1` routes **don't exist in the CRM yet**. They must use the same Sanctum guard as the existing login, so the same token works. Until they exist, use mock mode (section 6).

---

## 8. Look and feel

- **Brand colours** live in `lib/theme/brand_colors.dart` and were taken from the Youth Advocates logo:
  - orange `#F15A29`
  - purple `#6A2C91`
  - ink `#111111`
- **The theme** in `main.dart` uses purple as the primary colour and orange as the secondary, so standard widgets pick them up automatically.
- **The login screen** has a white background (to match the logo), orange-to-purple gradient shapes and button, and it scrolls on short screens.

---

## 9. Running and building

```bash
flutter pub get
flutter run -d chrome          # web, for quick testing
flutter run -d windows         # desktop (enable Windows Developer Mode first)
flutter run                    # connected Android phone
flutter test                   # unit tests
flutter build apk --release    # Android install file
flutter build web              # web build in build/web
```

### Testing tips

- **Fresh profile on every run.** `flutter run -d chrome` starts with a fresh Chrome profile each time, so the saved server address and local data reset. Installed apps keep them.
- **Phones need the PC's LAN IP.** A phone can't resolve `yazcrm.test`, so enter the PC's LAN IP (e.g. `192.168.10.149`), and the CRM must be reachable on that network.
- **The CRM needs PHP 8.3+.** The `php` on PATH is 8.2. Use Herd's PHP (e.g. `~/.config/herd/bin/php84/php.exe artisan …`).
- **Web builds and CORS.** The web build calls the CRM from the browser, so the CRM's CORS settings must allow it. Laravel's default allows all origins on `api/*`.

---

## 10. Known limitations and next steps

- **The CRM `/api/v1` data collection endpoints still need to be built.** The app is built and tested against the contract and a mock server.
- **Not supported yet:** `select_one_from_file`, `repeat_count`, cascading choices (`choice_filter`), and multiple languages beyond picking one label.
- **Reviewer feedback isn't shown in the app.** If a CRM reviewer asks for a correction, it isn't pulled back into the app.
- **Plain-http CRM addresses** (e.g. `http://192.168.x.x`) are blocked by Android 9+ unless cleartext traffic is allowed, or the CRM is served over HTTPS. This hasn't been changed yet.
