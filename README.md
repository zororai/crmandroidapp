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

## Leave module

Staff apply for leave, see their balances and history, and line managers approve or reject requests. The code is in `lib/leave/`, and it's opened from **My leave** and **Leave approvals** in the menu.

**Setup:** nothing to configure in the app. It uses the CRM's `/api/v1/leave` endpoints with the normal login. On the CRM side, run the migration and `LeaveSeeder`, set each person's supervisor, and tick the leave permissions. See `docs/leave-module.md` in the CRM repo.

The app has no permission logic. Everyone sees the same menus, and the CRM decides what each screen contains:

| Who | What they see |
|---|---|
| Any active staff member | Their own balances and requests. They can apply and cancel their own pending requests. **Leave approvals** is empty, and **Team calendar** explains that it is for approvers |
| Approver (`leave_approve`, and the requester's supervisor in the CRM) | Also their direct reports' pending requests to approve or reject (a comment is required to reject), and their team's calendar |
| Leave admin (CRM admin or director, or `leave_admin`) | Everyone's pending requests and the whole calendar. Settings, reports and corrections are in the CRM |
| Deactivated user | Sent back to the login screen, which then refuses them |

**Screens:**
- **Leave dashboard:** a balance card per leave type.
- **Apply:** type, date range, a live working-day count from the server, a reason, and an optional photo of a supporting document.
- **My leave:** history with status chips and a status filter.
- **Request detail:** a status timeline, and Cancel while pending (or Approve/Reject for an approver).
- **Approvals.**
- **Team calendar:** a month grid; tap a day to see who is off.

Every screen has pull-to-refresh, plus loading, empty and error states. A 403 shows the server's explanation instead of an error. Leave needs a connection; nothing is queued offline.

**Attachments:** the app attaches a photo from the camera or gallery. PDFs can only be uploaded through the API, since the app has no file picker.

**Trying it without the CRM:** `flutter run --dart-define=DC_MOCK_API=true` also replaces leave with an in-memory server.

**Tests:** `flutter test test/leave` checks the API client against the CRM's JSON shapes: parsing, 401, 403 and 422 handling, and JSON and multipart applications.

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
