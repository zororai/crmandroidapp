# yazcrm_beneficiary_flutter

A new Flutter project.

## Getting Started

This project is a starting point for a Flutter application.

A few resources to get you started if this is your first Flutter project:

- [Learn Flutter](https://docs.flutter.dev/get-started/learn-flutter)
- [Write your first Flutter app](https://docs.flutter.dev/get-started/codelab)
- [Flutter learning resources](https://docs.flutter.dev/reference/learning-resources)

For help getting started with Flutter development, view the
[online documentation](https://docs.flutter.dev/), which offers tutorials,
samples, guidance on mobile development, and a full API reference.

## Data Collection module

KoboToolbox-style form filling: staff download forms defined in the CRM, fill them in offline, and the app syncs the submissions to the CRM. The code is in `lib/data_collection/`, and it's opened from **Fill Forms** on the home screen.

### How it works

1. **Forms.** `GET /api/v1/forms` lists the user's assigned forms. Any schema that is missing or older (by version/checksum) is fetched from `GET /api/v1/forms/{id}/schema` and cached in SQLite (`dc_forms`, `dc_form_schemas`). Every version is kept, so a draft started on an old version still opens.
2. **Filling.** `engine/form_engine.dart` applies the schema to the answers:
   - skip logic (`relevant`)
   - `required`, `constraint` / `constraint_message`
   - `default`, `calculation`
   - group and repeat instances

   It uses a small XLSForm expression evaluator in `expression/`. The screen is one scrolling page with a progress bar. Drafts autosave, and a review screen comes before **Finalize**. Answers to hidden questions are left out of the payload.
3. **Queue.** `dc_submissions` holds each submission (`draft → finalized → syncing → sent`, or `failed` with the server's reason). Photos are in `dc_media`, compressed to at most 1 MB. Unsent submissions belong to the user who collected them and are only ever sent under that account.
4. **Sync.** `sync/sync_engine.dart` works as follows:
   - **Batches:** submissions go to `POST /api/v1/submissions/batch` in batches of up to 50.
   - **Results:** each item is marked from the per-item result. `duplicate` counts as success.
   - **Photos:** uploaded to `POST /submissions/{client_uuid}/media`, but only once the data is accepted.
   - **Retries:** only transient errors (network, 5xx, 429) are retried, with exponential backoff.
   - **Expired login:** a 401 stops the run and asks the user to log in again, without touching the queue.
   - **History:** sent records are kept for 30 days.

   **When it runs:**
   - on app start
   - when connectivity returns
   - after finalizing a submission
   - on "Sync now"
   - on Android, in the background via WorkManager (every 15 minutes, network required)

Settings such as the API prefix, batch size, retention period, photo size limit and app version are in `lib/data_collection/config.dart`.

### Trying it without the CRM endpoints

```bash
flutter run -d chrome --dart-define=DC_MOCK_API=true
```

Login still uses the real CRM. Data collection then uses the bundled sample form (`assets/data_collection/household_survey.json`, a household survey with a repeat group, skip logic, constraints and calculations) and an in-memory server that accepts every submission.

### Tests

```bash
flutter test test/data_collection
```

- `expression_test.dart`: operators, functions, dates, lists from repeats, error handling.
- `form_engine_test.dart`: schema parsing (flat and nested), skip logic, required/constraints, defaults, calculations and repeats, using the sample form.
- `sync_engine_test.dart`: tested against a fake CRM and an in-memory SQLite database. Covers:
  - retry/backoff
  - duplicates
  - partial batch failure
  - token expiry
  - photos only after data
  - the 50-item batch limit
  - per-user queues
  - purging old sent records
