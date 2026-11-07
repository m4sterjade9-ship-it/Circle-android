# Circle – handoff notes (for the next developer / AI)

Updated: 2026-11-07

## Project layout
- **Website** (single-page app, vanilla JS + Supabase): `index.html`, `sw.js`, `manifest.webmanifest`, SQL migrations `update13-18.sql`.
  Hosted on Cloudflare Workers at https://mycircle.banaagjade9.workers.dev (uploaded by hand via dashboard "Create deployment").
- **Android app** (this repo): Capacitor 6 shell that opens the live website (`capacitor.config.json` -> `server.url`).
  `www/index.html` is only a placeholder ("Loading Circle…"). It must NEVER be uploaded to Cloudflare.
  Native code is in `native/*.java`; `.github/workflows/android.yml` copies it into the generated `android/` project,
  patches AndroidManifest (permissions + services) and builds `app-debug.apk` (Actions artifact `circle-apk`).
- Site source lives in `site/` in this repo (copy of what is deployed to Cloudflare).

## Changes made on 2026-11-07
### 1. Message notifications (site `index.html`, `sw.js`)
Problem: chat messages never raised any notification (only a badge). Other alerts used `new Notification()`, which
does not exist in the Android WebView and throws on Chrome for Android.
- New helpers near `ntOff`: `sysNote()` (native plugin -> service-worker `showNotification` -> `new Notification`),
  `notifState()`, `notifAsk()`, `askNotifOnce()`, `keepAlive()`, `msgPop()`.
- `msgPop` handles direct messages (`messages` realtime channel `inbox-<uid>`) and group messages
  (new channel `ginbox-<uid>` on `group_messages`). Respects `ntOff('message')` and per-chat mute (`chat_settings.muted`).
  Visible app -> toast; hidden app -> system notification.
- Settings > Notifications and the Notifications page now work for both the native app and browsers.
- `sw.js` bumped (cache `circle-v48`), added `notificationclick` handler.
### 2. Android native (`native/`)
- `NotifyPlugin.java` (Capacitor plugin "Notify": `check`, `request`, `show`, `keepAlive`), registered in `MainActivity.java`.
- `KeepAliveService.java`: foreground service (type dataSync) so Android doesn't freeze the page/websocket in background.
- Workflow adds permissions `POST_NOTIFICATIONS`, `FOREGROUND_SERVICE_DATA_SYNC` and the `KeepAliveService` entry.
### 3. Screen-share full view (site `callBox`)
- Remote screen share auto-focuses (own tile becomes a small picture-in-picture).
- Tap shared screen again, or the new "Full view" button, to hide header/controls and fill the display
  (also requests browser fullscreen + landscape lock where supported). Exit button top-right.
- Android native share (`scOffer` / `sc-*` signalling) now also triggers focus via `peerState`.

### 4. Call picture-in-picture tile (site `callBox`, functions `pipDrag` / `untuck`)
- The small non-sharing tile can be dragged anywhere, dragged past the left/right edge to tuck it away (tap the visible tab
  to bring it back), and pinch-resized with two fingers. Tap still swaps which tile is big. Cache bumped to `circle-v49`.

## Known limits / TODO
- No real push (FCM). If the app is swiped away or killed by battery saver, no notifications arrive.
  Proper fix: Firebase project + `google-services.json` + server-side sender (e.g. Supabase Edge Function on insert into
  `messages` / `group_messages` / `notifications`). User must supply the Firebase project.
- None of the Java was compiled locally; the first GitHub Actions build is the real test.
- Watch out: Android 15 limits dataSync foreground services to ~6h if targetSdk is raised to 35.
- Tablet should have battery set to "Unrestricted" for Circle.
- Supabase realtime publication must include `messages`, `group_messages`, `notifications`.
