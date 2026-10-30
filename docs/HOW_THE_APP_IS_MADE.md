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
| Other | `intl` (dates), `path` / `path_provider` (files), `connectivity_plus` | |

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
  data_collection/
    form_logic.dart             Show-if (skip logic) and validation rules for CRM forms
  theme/
    brand_colors.dart           Youth Advocates logo colours
  screens/
    login_screen.dart           Server pop-up + login
    activity_screen.dart        Home screen (registers, profiling, data collection, sync, logout)
    capture_screen.dart         One beneficiary row of an attendance register
    profile_screen.dart         Beneficiary Profiling Tool
    signature_pad.dart          Finger-drawn signature, exported as PNG
    forms_screen.dart           List of downloaded CRM forms, and the submissions of one form
    form_fill_screen.dart       Draws any CRM form from its schema and saves the answers
assets/images/logo.png          Youth Advocates logo
test/form_logic_test.dart       Unit tests for skip logic and validation
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

`POST api/auth/login` checks the email and password against the CRM `users` table. Any **active** CRM user can log in. The returned token and user are stored in the SQLite `session` table, so the next launch skips the login screen, even offline.

---

## 4. Local database

The database is `beneficiary.db`, currently at schema **version 3**. Migrations live in `DatabaseHelper.onUpgrade`.

| Table | Holds | Sync flag |
|---|---|---|
| `session` | The logged-in user and API token (one row) | — |
| `activities` | Attendance register headers (activity name, date, compiled by, reviewed by) | `synced` 0/1 |
| `attendances` | One beneficiary row per register, with signature | `synced` 0/1 |
| `profiles` | Beneficiary profiles. About 40 answers are stored as one JSON blob, with name and phone split out for lookup. | `synced` 0/1 |
| `forms` | CRM form assignments as last downloaded, including each form's schema | — |
| `submissions` | Filled-in CRM forms (answers as JSON) | `status`: `draft` / `ready` / `synced` / `failed` |

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
| `_syncSubmissions` | `POST api/data-collection/submissions/sync` | Finalized (`ready`) form submissions |

**Sync is safe to retry.** Each record carries a UUID created on the device (`client_uuid` / `submission_uid`). The CRM skips any UUID it already has, so a failed or repeated sync never creates duplicates.

The "Pending sync" count on the home screen is unsynced attendances + unsynced profiles + `ready` submissions.

---

## 6. Data collection (Kobo-style forms)

Forms are **designed, versioned and assigned in the CRM** (Data Collection module). The app only collects data.

1. **Download.** `GET api/data-collection/my-forms` returns the logged-in user's assignments, each with its form version's schema. The list is stored in the `forms` table. A form stays available after one submission, so officers can collect from many respondents.
2. **Fill.** `FormFillScreen` builds the form from the schema at runtime. Nothing is hard-coded per form.
3. **Save.** **Save draft** keeps a submission editable. **Finalize** checks it and marks it `ready` for sync.
4. **Sync.** The CRM re-checks each submission against the exact form version. Rejected ones come back as `failed` with the reason, and the officer can correct and finalize again.

### Form schema (from the CRM)

```json
{
  "sections": [
    {
      "id": "s1", "title": "Household",
      "questions": [
        { "id": "age", "type": "integer", "label": "Age", "required": true },
        { "id": "in_school", "type": "yes_no", "label": "In school?" },
        { "id": "school", "type": "text", "label": "School name",
          "visible_if": { "question": "in_school", "operator": "equals", "value": "yes" } }
      ]
    }
  ]
}
```

**Supported question types:** `text`, `long_text`, `number`, `decimal`, `integer`, `email`, `phone`, `date`, `datetime`, `time`, `select_one`, `select_multiple`, `yes_no`.

**Answer formats**, which match the CRM web form:

| Type | Stored as |
|---|---|
| Dates | `yyyy-MM-dd` |
| Datetimes | `yyyy-MM-ddTHH:mm` |
| Times | `HH:mm` |
| Yes/no | `"yes"` / `"no"` |
| Multiple choice | A list of option values |
| Numbers | Numbers |

### Skip logic and validation

`lib/data_collection/form_logic.dart` copies the CRM's own rules:

- `ConditionEvaluator` decides when a question is shown.
- `SubmissionValidationService` checks the answers.

So an officer sees an error while still with the respondent, not after sync. Answers to questions hidden by skip logic are dropped on finalize.

**If you change those rules in the CRM, change `form_logic.dart` to match and update `test/form_logic_test.dart`.**

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
| GET | `api/data-collection/my-forms` | Download assigned forms |
| POST | `api/data-collection/submissions/sync` | Upload form submissions |

The last two are new, in `yazcrm/app/Http/Controllers/Api/DataCollectionController.php`. They reuse the CRM's `DataCollectionSubmissionService`, so app submissions follow the same rules and activity log as the web.

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

- **Downloaded forms are cleared on logout**, because assignments belong to a user. Unsynced submissions are kept. If a different user then syncs them, the CRM rejects them because the assignment isn't theirs.
- **No photo, GPS, group/repeat or calculated questions yet.** The CRM's form schema doesn't support them.
- **Reviewer feedback isn't shown in the app.** If a CRM reviewer asks for a correction, it isn't pulled back into the app yet.
- **Planned:** a fuller Kobo-style module (XLSForm upload, expression-based skip logic, analytics, CRM field mapping). An architecture proposal is waiting for sign-off.
