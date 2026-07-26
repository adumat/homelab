// SINGLE SOURCE OF TRUTH for the app version. Bump this one line on every change.
// - index.html loads it before app.js (shown in the header)
// - app.js registers the service worker as /sw.js?v=<APP_VERSION>
// - sw.js reads that query to name its cache -> bumping here busts the SW cache too.
// Fetched fresh (never cached) so a version bump always propagates past a stale SW.
self.APP_VERSION = "v9";
