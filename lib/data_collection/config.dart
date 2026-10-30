// Data collection settings, kept in one place so each is a one-line change.

// Path prefix for the data collection endpoints, after ApiClient.baseUrl
// (http://host/api/). Field devices can't be force-updated, so these routes
// are versioned; login and the older endpoints are not.
const dataCollectionApiPrefix = 'v1/';

// POST /submissions/batch accepts at most this many submissions.
const submissionBatchSize = 50;

// Sent submissions (and their photos) are purged from the device after this.
const sentRetentionDays = 30;

// Photos are recompressed until they fit under this size.
const maxPhotoBytes = 1024 * 1024;

// Sent with every submission. Keep in step with `version:` in pubspec.yaml.
const appVersion = '1.0.0+1';

// `flutter run --dart-define=DC_MOCK_API=true` swaps the CRM for the bundled
// sample form and an in-memory server, so the module can be exercised before
// the Laravel endpoints exist. Login still goes to the real CRM.
const useMockDataCollectionApi = bool.fromEnvironment('DC_MOCK_API');
