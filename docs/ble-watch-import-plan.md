# Plan: backend-driven BLE import from Amazfit Cheetah Pro (bypass Gadgetbridge)

Status: proposal, 2026-10-12. **Phases 0+1 are implemented and verified live against the
watch** (see §7). Target: replace the `ble-health-import` branch approach with a
new architecture where the Rust backend owns **all** protocol logic and the Flutter app is a
thin BLE byte-relay.

---

## 1. Goals

- Fetch health and workout data directly from the watch over BLE, with no Gadgetbridge in the loop.
- Start with: daily HR + steps, HRV, resting/max HR, and workout exports (summary + GPS/route).
- All protocol logic (auth crypto, framing, fetch orchestration, parsing, state) lives in the
  **backend**. The Flutter frontend only shuttles raw GATT bytes over a WebSocket.
- Fix the #1 debugging pain: the watch "marks data as uploaded" and subsequent syncs silently
  time out. The design must make re-fetching and replay testing trivial.

Non-goals (for now): stress (0x13), sleep, SpO2, PAI, temperature, realtime HR streaming,
Wi-Fi file transfer, writing anything to the watch (other than time sync if needed).

## 2. What we learned (research summary)

### 2.1 The `ble-health-import` branch — why it's fragile

The branch (~4k lines) put *everything* in Flutter: auth, chunked protocol, fetch loops,
parsers, and sync state in SharedPreferences. Post-mortem from its commit history:

1. **The upload-once mechanism is the ACK byte.** After a fetch transfer, the phone acks with
   `{0x03, flag}` on the fetch channel. `flag=0x01` = "mark as saved on phone" → the watch
   *deletes the detailed data and advances its internal transfer pointer*; later requests with
   a `since` older than the pointer are **ignored silently** (15 s timeout, no `count=0` reply).
   `flag=0x09` = "ack but keep data marked unsent" → data can be fetched again.
   The branch acked `0x01` (deleting) for all health types — matching Gadgetbridge's default —
   so every bug that poisoned the locally stored `since` timestamp made the data permanently
   unreachable. Workouts used `0x09` (keep), which is why re-syncing runs kept working.
2. **State lived client-side** (SharedPreferences), so reinstalls / dev loops re-poisoned it,
   and the backend could not know what the watch had been told.
3. **Parsers were reverse-engineered from logcat** with subtle offset bugs (2-byte header skip,
   HR sentinel values 1/30/255, double-bookkept sample counts).
4. **No replay path**: every test needed the physical watch and consumed the one-shot upload.

Its empirical findings are still valuable and are reused below (psmh detail format, byte
layouts, quirks). The branch stays as reference; new work starts fresh off `main`.

### 2.2 Protocol facts (from the Gadgetbridge source in `Gadgetbridge/`, v0.95.1)

Device: `AmazfitCheetahProCoordinator` → plain `ZeppOsCoordinator` (`ZeppOsBtleSupport`).
No Wi-Fi FTP for this watch; BLE only. Bonding style: requires a 16-byte auth key
(32 hex chars — present in `gadgetbridge_export/preferences/device_*.json` under `authkey`).

**GATT** (service `0xFEE0`):
- `00000016-…-0009af100700` — write (phone → watch), chunked protocol
- `00000017-…-0009af100700` — notify (watch → phone), chunked protocol
- `00000005-…-0009af100700` — bulk data stream during fetch transfers (1-byte per-packet
  sequence counter prefix), as observed empirically by the branch
- `0x180D` — standard Heart Rate measurement (realtime, later)

**Auth** (endpoint `0x0082`, inside chunked framing; AES-128-ECB/NoPadding):
The branch proved this watch still accepts the *legacy* handshake, which is much simpler than
GB's current ECDH-B163 one:
1. phone → `{0x01, 0x00, 0x02, 0x00}`
2. watch → `{0x10, 0x01, 0x03, 0x05}` (ZeppOS 3.x firmware: "send encrypted key"; legacy
   firmware instead sends `{0x10, 0x00, 0x01, 0x00}` + 16-byte nonce)
3. phone → `{0x03, 0x00, AES-ECB(authkey, 16 zero bytes)}`
4. watch → `{0x10, 0x03, 0x05}` = success; status byte `0x02`/`0x25` = wrong key.
Fallback if firmware update kills the legacy path: port GB's ECDH handshake
(`ZeppOsAuthenticationService` + `ECDH_B163.java`, NIST B-163 binary-curve ECDH, session key =
`sharedEC[i+8] ^ authkey[i]`, per-message AES key = `sessionKey[i] ^ handle`, ~300 lines of
field math to port). Decision deferred until it actually breaks.

**Chunked framing** (`Huami2021ChunkedEncoder/Decoder`, extended_flags = true):
```
byte 0    0x03
byte 1    flags: 0x01 first chunk, 0x02 last chunk, 0x04 needs-ack, 0x08 encrypted
byte 2    0x00 (extended header marker)
byte 3    handle   (increments per message)
byte 4    count    (chunk index within message)
first chunk only:
bytes 5-8   u32 LE total payload length
bytes 9-10  u16 LE endpoint
bytes 11..  payload
continuation chunks: 5-byte header then payload
```
The branch's "11-byte header with BE u16 length" reading only coincides with this for
single-chunk messages < 256 bytes (byte 4 = count = 0 doubles as the high length byte) — that
is exactly why it "sort of worked". Implement GB's framing verbatim. If a received frame has
flag `0x04`, reply with the chunk ack `{0x04, 0x00, handle, 0x01, count}` written to the
*notify* characteristic (`0x0017`). MTU: request 247 after auth on Android; web stays at the
browser default — the codec must chunk to `min(512, mtu-3) - header`.

**Service discovery**: endpoint `0x0000`, cmd `0x03` → `0x04`, u16 LE count, then per service
`{u16 LE endpoint, u8 encrypted}`. Tells us which endpoints require payload encryption.

**Health/workout fetch** — everything tunnels through the **activity-fetch endpoint `0x004b`**
(encrypted by default), reusing the classic Huami fetch protocol:
```
request   {0x01, fetchType, yLo, yHi, month, day, hour, min, sec, tzQuarterHours}
response  {0x10, 0x01, 0x01, u32 LE expectedDataLength, 8-byte start-ts (y u16 LE…sec)}
start     phone sends {0x02}
data      packets {counterByte, payload…} (counter increments by 1)
end       {0x10, 0x02, 0x01[, u32 CRC32]}
ack       phone sends {0x03, 0x01|0x09}   ← 0x01 delete/reset pointer, 0x09 keep
```
Fetch types (from `HuamiFetchDataType.java`): `0x01` activity (8 B/min samples:
`kind, intensity, steps, hr, unk, sleep, deepSleep, remSleep`; HR sentinels 1/255, watch-off
kind 115, charging 118), `0x05` sports summaries, `0x06` sports details, `0x3a` resting HR
(6 B: `u32 LE epoch, i8 tzQuarter, u8 hr`), `0x3d` max HR, `0x49` **HRV** (6 B:
`u32 LE epoch, u8 unk, u8 value`) — HRV was *never implemented* in the branch, `0x13` stress
auto (1 B/min), plus future: `0x25/0x26` SpO2, `0x48` sleep, `0x0d` PAI, `0x2e` temperature.

**Sports summaries (0x05)**: payload = `[u16 LE 0x8000][protobuf WorkoutSummary]`
(`GBProtobufGenerator/.../huami.proto`: field 2 location, 3 type (8 = outdoor run on this
watch), 4 distance, 7 time, 19 heartRate{avg,max}, …). Validate against the 283
`RAW_SUMMARY_DATA` blobs in `gadgetbridge_export/database/Gadgetbridge`.

**Sports details (0x06)**: ASN.1-BER-style TLV, little-endian values, magic `psmh`:
`TIMESTAMP(1,len12)`, `GPS_COORDS(2)`, `GPS_DELTA(3)`, `STATUS(4)`, `SPEED(5)`
(cadence/stride/pace), `ALTITUDE(7)`, `HEARTRATE(8)`, `LAP(11)`, `DISTANCE(0x1F09)`.
Degrees = raw / 3,000,000 (empirically confirmed by the branch; GB's summary-proto locations
use /6,000,000 — different scale, don't mix them). The backend *already* has a parser for this
format (`parse_zeppos_raw_details_bin`, `backend/src/routes/runs.rs:922`) used for GB zip
imports — align/extend it rather than writing a third implementation.

**Retention / re-fetch**: the request's `since` timestamp *is* honored as long as the watch
still holds the data (GB re-fetches by lowering its stored `last…TimeMillis` prefs; default
lookback 100 days). The watch also aggregates/drops very old detail data on its own. There is
no "wipe counters" command; the only lever is the ack byte and the requested timestamp range.

### 2.3 Mont architecture fit (what already exists server-side)

- Backend is Axum + sqlx/SQLite with JWT auth on all protected routes; adding endpoints is a
  route module + `app.rs` registration. No WebSocket yet (axum `ws` feature would be the first).
- GB zip sync pipeline already exists: `daily_health` upserts, Zepp-OS raw-details bin parser,
  run dedupe via `source_file` / `blocked_runs`, weather fetch. A BLE import is mostly a *new
  transport + orchestration* bolted onto existing storage.
- Flutter has no BLE deps; the platform-abstraction pattern (`lib/src/platform/*` conditional
  exports) is the natural home for the relay client. No state management framework — plain
  StateWidgets, fine for a thin relay UI.
- Ground-truth oracle for testing: `gadgetbridge_export/` contains 335k activity samples,
  99k HRV values, 283 workout summaries, 196 rawDetails bins and GPX tracks — real data from
  this exact watch to validate every parser offline.

## 3. Target architecture

```
┌────────────┐  GATT (BLE)   ┌─────────────────┐  WebSocket  ┌────────────────────────┐
│  Amazfit   │◄─────────────►│ Flutter relay    │◄───────────►│ Rust backend           │
│  Cheetah   │  raw bytes    │ (dumb byte pipe: │  JSON+base64│ (protocol brain:       │
│  Pro       │               │ connect/subscribe│             │ auth, chunked codec,   │
└────────────┘               │ /write/notify)   │             │ fetch state machine,   │
                             └─────────────────┘             │ parsers, storage,      │
                                                             │ sync state, logs)      │
```

### 3.1 Backend components (new module `backend/src/ble/`)

| Component | Responsibility |
|---|---|
| `codec.rs` | Chunked encoder/decoder (GB framing), chunk-ack emission, MTU-aware splitting |
| `auth.rs` | Legacy handshake (+ ECDH-B163 contingency behind a feature flag) |
| `session.rs` | Per-session state machine: Disconnected → Connecting → Authenticating → Ready → Fetching(type) → Done/Error; owns handle/seq counters |
| `fetch.rs` | Generic 0x004b fetch engine: request → response → `{0x02}` → data stream w/ counter+CRC → ack(policy) → parser callback; retry ladder; multi-round loop while behind `now` (GB does max 10 rounds) |
| `parsers/` | activity 0x01, resting/max HR, HRV 0x49, (later stress), summary proto, details TLV |
| `store.rs` | Upserts into `daily_health`, `hrv_samples`, `runs`; sync-state table updates |
| `driver.rs` | The WS-facing driver: translates client GATT events into session progress and emits write/subscribe commands |
| `log.rs` | NDJSON session recording of every frame in/out + decisions (the replay/debug backbone) |

### 3.2 WebSocket relay protocol (`GET /ble/ws?token=<jwt>`)

One session per WS connection. JSON messages, binary payloads base64. Server → client **commands**:
`scan_start/stop`, `connect(mac)`, `disconnect`, `subscribe(char)`, `request_mtu(n)`,
`write(char, data, mode)`. Client → server **events**: `scanned(device)`, `connected(mtu?)`,
`disconnected(reason)`, `notify(char, data)` — notifications **batched** (flush every ~50 ms)
to keep bulk transfers cheap. Ordering is guaranteed by the ordered WS; the client applies
commands strictly in order and sends no logic of its own. Every frame is appended to the
session log with timestamps.

Auth note: browsers cannot set headers on WebSocket → token goes as query param (over TLS,
dev-only anyway); axum `ws` feature is the only new dependency on the backend.
Android is the primary target (`flutter_blue_plus`); Web Bluetooth works for
notify/write-without-response but has no MTU request API — acceptable secondary target; stub
for desktop via the existing platform-abstraction pattern.

### 3.3 Ack policy (the fix for the upload-once problem)

- **Default ack = `0x09` (keep on watch), always.** Mont dedupes on ingest; deleting from the
  watch buys nothing and destroys the ability to re-sync after a bug.
- Sync state (per data type `last_sync_ts`) lives in the **backend DB** (`watch_sync_state`),
  never in the frontend.
- Re-syncs simply request an older `since`; the watch honors it while it still holds the data.
- A "deep sync" command takes an explicit `since` (default 100 days back, GB's lookback) for
  backfills.
- `0x01` (delete) is not sent at all in phase 1–4. If watch retention ever becomes a concern,
  add an explicit opt-in "confirm and clean" action later.

### 3.4 Storage changes (migrations)

```sql
CREATE TABLE watch_sync_state (
  data_type INTEGER PRIMARY KEY,          -- 1, 58(0x3a), 61(0x3d), 73(0x49), 5, 6
  last_sync_ts INTEGER NOT NULL,          -- unix seconds UTC, last successful fetch start
  last_ack INTEGER NOT NULL,              -- ack byte used (always 9 for now)
  updated_at TEXT NOT NULL
);
CREATE TABLE hrv_samples (
  ts INTEGER PRIMARY KEY,                 -- unix seconds UTC
  value INTEGER NOT NULL,                 -- watch HRV reading (ms? — see GB FetchHrvOperation)
  source TEXT NOT NULL DEFAULT 'ble'
);
-- + daily_health gains nothing new; hrv_rmssd gets populated from hrv_samples nightly
--   aggregate (matching how GB zip sync fills it today).
```
Workouts reuse `runs` (dedupe via `source_file = 'ble:<started_at>'`, `blocked_runs` semantics,
weather via existing `weather.rs`). Optionally a `ble_session_log` dir next to the DB file
(`MONT_DATABASE_PATH` sibling, NDJSON per session, auto-pruned after N days).

### 3.5 Frontend pieces

- `lib/src/platform/ble_bridge.dart` (conditional export): `BleRelay` class — connect to WS,
  execute commands via `flutter_blue_plus`, emit events; zero parsing.
- Watch sync UI in Settings: device key field (32 hex, from GB device info — value present in
  `gadgetbridge_export/preferences/device_*.json`), MAC picker from scan results, buttons
  "Sync now" / "Deep sync…", live status/log stream, per-type last-sync display.
- Health screen: HRV chart from `/health/daily` (+ future samples endpoint).

## 4. Implementation phases

Each phase ends with something verifiable and merges cleanly to `main`.

### Phase 0 — groundwork (small)
- New branch `ble-backend-sync` off `main` (the old branch stays untouched for reference).
- Migrations above; backend feature flag/env (`MONT_BLE_ENABLED`, default off) so prod is
  unaffected until ready.
- Deliverable: schema + config in place, CI green.

### Phase 1 — transport bridge + recorder/replayer
- Backend: WS endpoint, driver skeleton, session NDJSON logging; `mont ble replay <file>` CLI
  subcommand that re-drives a recorded session through the protocol stack without hardware.
- Frontend: `BleRelay` + minimal debug screen (connect, subscribe, see notifications).
- Deliverable: from the app, connect to the watch, get GATT events flowing into a backend
  session log. No watch protocol yet.

### Phase 2 — auth + chunked codec
- Rust: chunked codec with GB framing + unit tests (golden vectors generated from the GB Java
  encoder, incl. multi-chunk and encrypted frames); legacy auth handshake; service discovery
  (`0x0000`); ping (`0x0015`); chunk-ack handling.
- AES-128-ECB via `aes` crate; CRC32 via `crc32fast`.
- Deliverable: backend authenticates through the phone, logs the service list
  (which endpoints are encrypted on this firmware). This also *verifies the auth path* without
  consuming any health data — a safe, repeatable end-to-end test.

### Phase 3 — health fetch engine (HR, steps, HRV)
- Generic fetch engine + parsers for `0x01`, `0x3a`, `0x3d`, `0x49`; ack `0x09` always;
  backend-owned `watch_sync_state`; retry ladder for the silent-timeout quirk (retry newer
  `since` → treat as up-to-date, never persist a poisoned timestamp).
- Parser tests against ground truth from `gadgetbridge_export` (per-day aggregates from the
  335k samples; HRV values from `GENERIC_HRV_VALUE_SAMPLE`).
- Endpoints: `POST /ble/sync` (full), `POST /ble/sync {since}` (deep), `GET /ble/status`.
- Deliverable: "Sync" in the app fills `daily_health` + `hrv_samples`; re-running sync twice
  in a row is a no-op the second time but *succeeds* (not silent-timeout), because data stays
  on the watch and state is range-based.
- Validation: diff mont's daily aggregates against GB's DB for overlapping days — they must
  match within sentinel-handling rules.

### Phase 4 — workouts (summary + details)
- `0x05` protobuf summary (via `prost` + a small `.proto` copied from GB's `huami.proto`
  field numbers) and `0x06` TLV details, reusing/extending
  `parse_zeppos_raw_details_bin`; resolve the /3,000,000 vs /6,000,000 scale question by
  cross-checking the 196 real bins against GB's GPX tracks.
- Orchestration: summary loop → upsert run → details fetch at workout start → route patch →
  weather. Advancement rules from the branch (min 1 h step, skip-on-parse-failure) to avoid
  loops; CRC verification before ack.
- Deliverable: runs imported with routes/HR/cadence, idempotent across repeated syncs.

### Phase 5 — hardening & dev UX
- Replay-based integration tests (record a real session, replay in `cargo test`).
- Error taxonomy surfaced in UI (wrong key vs out-of-range vs disconnected mid-transfer).
- Deep-sync UI; session log viewer (last session's frames) for debugging.
- Only now consider opt-in `0x01` cleanup ack — likely unnecessary.

### Phase 6 — later additions
Stress `0x13` (trivial, format known), sleep `0x48`, SpO2, PAI, temperature; realtime HR via
`0x180D` for live workouts; protobuf summary extras (calories, training effect).

## 5. Risks / open questions

1. **Legacy handshake longevity** — works today (branch proved it); GB's ECDH-B163 port is the
   contingency. Mitigate by implementing auth behind a trait so both can coexist.
2. **Framing discrepancies branch-vs-GB** — resolved in favor of GB's codec (verified against
   `Huami2021ChunkedEncoder/Decoder` source); recorded sessions will confirm on real hardware
   in phase 2.
3. **Bulk-data characteristic** — GB sources say fetch data is tunneled via chunked; the branch
   observed it on char `0x0005`. The relay handles both (subscribe to all FEE0 notify chars;
   the driver routes by characteristic). Confirm in phase 3.
4. **Watch retention window** — unknown how far back per-minute/HRV data is kept. Deep sync
   will discover it empirically; expect days-to-weeks for minute data, longer for dailies.
5. **WS in production** (`mont.matmoa.eu`) — reverse proxy must allow WS; irrelevant while the
   feature is used on LAN at home. Keep the flag off in prod until proven.
6. **Throughput** — backend roundtrips add ~ms per write; BLE timing dominates. Batched
   notifications keep the WS quiet during bulk transfers. Full history after months away is
   inherently slow (~min/data-type) but incremental daily syncs are tiny.
7. **Secrets** — the authkey must never be logged (scrub in session logger); store in DB only.

## 6. Immediate next steps

1. Review/adjust this plan (especially ack policy and scope of phase 3).
2. Phase 0+1: branch, migrations, WS bridge, recorder — hardware-independent.
3. Phase 2 with the watch present to validate auth + framing against reality.

---

## 7. Phase 0+1 implementation notes (2026-10-12, verified live)

What was built:
- Backend (`backend/src/ble/`): `protocol.rs` (WS relay message types, base64
  payloads), `recorder.rs` (per-session NDJSON recordings in
  `<db dir>/ble_sessions/`), `driver.rs` (phase-1 autopilot: hello → direct
  connect or scan → MTU 247 → subscribe FEE0 notify chars → observe 30 s →
  clean release). Routes: `GET /ble/ws` (JWT via `?token=` or header),
  `GET /ble/status`. Config: `MONT_BLE_ENABLED`, `MONT_BLE_WATCH_NAME`,
  `MONT_BLE_WATCH_MAC`, `MONT_BLE_SESSIONS_DIR`, `MONT_BLE_SESSION_TIMEOUT_SECS`.
- 5 WS integration tests (`backend/tests/ble_ws_tests.rs`) run a scripted fake
  relay through the full router — proves the WS upgrade passes the global
  middleware (rate-limit, payload-log) and the autopilot state machine.
- Flutter: `lib/src/ble/ble_relay_io.dart` (relay + `ble_auto.json` debug
  trigger, debug builds only), `lib/src/platform/ble_relay.dart` conditional
  export, hooked in `main.dart` before `runApp`. Deps: flutter_blue_plus,
  web_socket_channel. AndroidManifest BLE permissions added.
- `scripts/ble-debug.sh`: build / install / grant / seed / launch / logcat /
  result / session.

Unattended debug loop (all adb-driven, no user interaction):
1. `adb install -r -g app-dev-debug.apk` — **`-g` is required**: ColorOS refuses
   `pm grant` from adb; `-g` grants the BLE runtime permissions at install.
2. Auth: the dev app has no stored login. Mint access+refresh JWTs with the
   dev secret (`backend/.env`, git-ignored) and write them into
   `shared_prefs/FlutterSharedPreferences.xml` via `adb run-as` (app stopped).
3. Seed `app_flutter/ble_auto.json` via run-as, `adb reverse tcp:8080`,
   launch. App consumes the trigger, relays a session, prints
   `BLE_SYNC_RESULT: ok|fail reason=…` to logcat and writes
   `app_flutter/ble_last_result.json`.

Live findings (real watch):
- The phone holds a system bond to the watch (`C5:4C:46:40:42:01`, DUAL). A
  leftover system-level connection (open since Oct 5) kept the watch from
  advertising — scans found nothing. `adb shell cmd bluetooth_manager
  disable/enable` drops it; `Connections: 0` in `dumpsys bluetooth_manager`.
- The watch does not need to advertise: **direct connect to the bonded MAC
  works** (`MONT_BLE_WATCH_MAC`), skipping the scan entirely. Driver falls
  back to scanning if the direct connect fails.
- Connect → services discovered (GAP, device info, alert, FEE0 with auth
  0x0001, chunked write 0x0016, data 0x0005/0x0006, auth 0x0001 notify…),
  MTU negotiated to 247, subscriptions acknowledged. Session ended cleanly
  with `BLE_SYNC_RESULT: ok`.
- fbp pitfalls handled: `connectionState` emits the pre-connect `disconnected`
  state (must be ignored until established); backend-initiated releases must
  not surface as `device_disconnected` failures; scan results must be
  deduped by MAC (fbp re-emits its full list continuously — 82k events/150 s
  unfiltered).

Next: Phase 2 (auth + chunked codec in Rust) — the relay chain is proven, so
each step can be validated through this exact loop, recorded, and replayed.

---

## 8. Phase 2 results (2026-10-13, verified live)

Implemented:
- `backend/src/ble/codec.rs` — byte-exact port of GB's chunked encoder/decoder
  (extended flags, MTU-aware splitting, needs-ack tracking, `chunked_ack()`).
  Unit tests include golden vectors and multi-chunk round-trips.
- `backend/src/ble/auth.rs` — legacy auth handshake state machine (AES-128-ECB
  via the `aes` crate): `01 00 02 00` → `10 01 03 05` → `03 00 || AES(key, 0¹⁶)`
  → `10 03 05`. Handles the legacy-nonce variant, wrong-key rejection
  (status `0x02`/`0x25`) and the already-authenticated short-circuit. Key from
  `MONT_BLE_AUTH_KEY` (32 hex, taken from the Gadgetbridge export).
- Driver: after subscribing it runs the handshake, requests the service list
  (chunked endpoint `0x0000` cmd `0x03`), parses the response (count +
  per-service endpoint/encrypted flag), and answers watch chunk-acks.
  Integration test drives the whole flow through the WS with a fake relay.
- Relay: write-mode fallback by characteristic properties (the auth char
  advertises no write bits but accepts with-response writes).

Live run (real watch, 34 s): direct connect → MTU 247 → subscribe →
`AUTHENTICATED (variant 10 03 05)` → service list **60 services** → clean
release, `authenticated=Some(true)`.

Facts learned:
- The watch sends chunked frames **and** chunk-acks on BOTH 0x0016 and 0x0017;
  both must be routed through the decoder.
- Watch-initiated pushes on some services arrive **encrypted** (flag `0x08`;
  e.g. 0x000a config, 0x0014 contacts, 0x001e notifications, 0x0023 watchface,
  0x0026 display items). The legacy session key is *not* simply the authkey
  (CRC check in `tests/ble_legacy_decrypt.rs` disproved it) — but we don't need
  those services.
- **Endpoint 0x004b (activity fetch — all health/workout data) is served
  unencrypted**, as are 0x0016 (steps), 0x001d (heart rate), 0x0048 (sleep),
  0x0013 (stress). Phase 3 needs no crypto.
- Unencrypted watch pushes observed right after auth: time (0x0047), battery
  (0x0029), device info (0x0043), file-transfer caps (0x000d, version 3!),
  alarms, calendar, logs (`jaspp`), apps (0x00a0).

Next: Phase 3 — the 0x004b fetch engine (activity 0x01, resting/max HR,
HRV 0x49) with ack-0x09 policy and parsers validated against the GB export.

---

## 9. Phase 3 results (2026-10-13, verified live)

Implemented and verified against the real watch:
- Migration `00032_ble_sync.sql`: `activity_samples` (per-minute, insert-or-
  replace → idempotent re-fetches), `hrv_samples`, `daily_hr_marks`,
  `watch_sync_state`. Migration `00033`: normalize REAL leakage into the
  INTEGER columns of `daily_health`.
- `parsers.rs` — activity 0x01 (8-byte samples, NO header — GB is the truth;
  the branch's 2-byte skip was its own assembly bug), resting/max HR 0x3a/0x3d
  and HRV 0x49 (6-byte records).
- `fetch.rs` — 0x004b fetch state machine (request → start-date response with
  expected length + watch start ts → `{0x02}` → counter-prefixed data packets
  on char 0x0005 → end marker with CRC32 → ack). **Always acks `0x09` (keep on
  watch)** — the delete/pointer problem can never be triggered by mont.
- `store.rs` — raw samples + `daily_health` recomputed with the exact GB-zip
  SQL conventions (UTC date, `hr > 0 AND < 255`, steps summed over valid-hr
  rows, `hrv_rmssd` = daily HRV average). Aggregates CAST to INTEGER (AVG
  leaking REAL into the INTEGER column broke sqlx decoding — migration 00033).
- Driver fetch phase (behind `MONT_BLE_FETCH_ENABLED`, lookback
  `MONT_BLE_FETCH_LOOKBACK_DAYS`, session timeout raised to 1800 s): quick
  types first, multi-round activity catch-up (max 12 rounds), 20 s/30 s
  deadlines, retry-once-from-yesterday for the watch's silent pointer,
  no-progress → caught-up detection.
- `GET /ble/debug` — one JSON blob for the debug tab (sync state, sample
  range, last 14 daily rows, last 50 HRV readings, HR marks, sessions).
- Flutter: debug tab (5th tab, kDebugMode only) showing all of the above with
  a **Sync now** button that runs the whole relay session in-app — no adb
  needed for day-to-day syncs anymore.

Live verification (real watch):
- Session 1: fetched until the loop stalled at the watch's oldest retained
  minute data (2026-09-26) — root cause was a 1 h resume overlap cancelling
  the batch end; removed (GB resumes exactly at the batch end) + no-progress
  detection added.
- Session 2 (52 s, 414 KB): RestingHr (sparse — none retained), MaxHr 19
  marks, **HRV 10,080 samples**, **activity 19,296 + 24,024 samples covering
  2026-09-13 → today**, all stored, `BLE_SYNC_RESULT: ok`, watch released.
- `daily_health` populated with plausible values (avg HR 63–110, steps
  3.5k–41k, max HR 105–181); visible in the debug tab on the phone.

Known quirks discovered:
- The fetch resume pointer per type must reset each type (fetch_since leaked
  across types in the first integration attempt — caught by the WS test).
- `activity_wants_another_round` treats "no data" as caught-up and advances
  the pointer to now (else the catch-up loop never ends).
- Watch retention: minute-level data was available for the full 30-day
  lookback; resting-HR marks were not returned (sparse type).

Next: Phase 4 — workouts (0x05 summary protobuf + 0x06 details TLV → runs).

---

## 10. Phase 4 results (2026-10-15)

Implemented:
- `workout.rs` — minimal protobuf decoder for 0x05 summaries (`Type.type` top-
  level field 3 message: **type 1 = outdoor run, verified 196/196 running rows
  in the GB export with zero ambiguity**; the branch's "8" was actually
  `Location.f3`, which is ambiguous). Unit tests + a 283-blob fixture test
  against the GB export (all parse; duration matches GB's activeSeconds).
- 0x06 details parsing reuses `parse_zeppos_raw_details_bin` (now
  `pub(crate)`), extended with the TIMESTAMP TLV's start epoch.
- Workout storage: `upsert_ble_run` + `update_run_route` (route, elevation,
  distance fallback from route haversine, weather) keyed by
  `source_file = ble-<started_at>`.

**Critical firmware discovery: the 0x05 summaries endpoint on this watch
ignores `since` completely (always returns its oldest summary) and neither
0x01 nor 0x09 acks change that. Workout enumeration therefore walks the 0x06
details endpoint, which DOES honor `since`.** Each 0x06 round: request since =
pointer → watch returns the first workout ending at-or-after since → details
payload gives start (TIMESTAMP TLV), duration (last point), distance
(haversine), HR → upsert run → pointer = workout end + 60 s (the watch's
boundary is end-inclusive; requesting since=end re-returns the same workout —
GB issue #6072 is the same behavior) → repeat until "no data", duplicate, or
the 20-round cap. Duplicate/known workouts are skipped; imports are idempotent
via `source_file` upsert. Workouts are acked `0x01` (mark sent); health data
stays `0x09` (keep, re-fetchable).

All backend gates green (unit + WS integration incl. a full fake-watch workout
import asserting the runs row, route points, and values).

Pending: live validation of the workout walk (phone needs to be plugged in;
one `Sync now` / adb trigger away — pointer state type 6 may need a
`DELETE FROM watch_sync_state WHERE data_type = 6` reset first).

### Phase 4 live findings (Oct 15 session) and the 0x06 boundary model

The first live walk revealed the precise workout-filter semantics: the 0x06
endpoint returns the first workout whose **END time is at-or-after `since`**
(end-inclusive). A workout that *straddles* the since boundary (started before
it, ended after) is returned legitimately — the duplicate check must compare
the workout's **end** to the round base, not its start. Additional guards:
- pointer = workout end + 60 s (end-inclusive boundary, same as GB #6072);
- a re-served identical workout end means the watch isn't advancing → caught
  up, stop the loop;
- FETCH_MAX_ROUNDS raised to 20; workouts acked `0x01` (mark sent) — the
  summary endpoint is unused for enumeration (it ignores `since` entirely on
  this firmware: it returned its oldest summary even with `since` = today).

The live session correctly returned the Sept 15 run (2655 points, 2819 s,
7725 m haversine, HR 129/141) at the walk's first round and it was stored
idempotently; the loop then needs one more round (end+60 < now) — validated in
the WS integration test. Remaining: one more live walk to confirm the full
enumeration through today's run (state type 6 already reset).

### Phase 4 LIVE VERIFIED (Oct 15)

Full enumeration works: two sessions imported **24 runs** (Sept 14 → Oct 15,
every one with GPS route + elevation + weather + HR), idempotent across
sessions. Discovery: the 0x06 since-filter is DAY-granular on this firmware —
after importing a workout, the same-day workout may be re-sent even with
since past its end; the driver detects the re-send (start <= round since) and
jumps the pointer to the next local midnight, then continues. Non-advance
guard (same workout end twice) and the 20-round cap both fire as backstops.
Daily syncs now: health no-data + workout no-data within seconds.
