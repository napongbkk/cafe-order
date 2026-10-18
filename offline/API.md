# Coconut POS Stand alone: local server API

Every version (Windows, Android, iOS) runs the same small HTTP server on the shop's main machine.
The POS app (`offline/www`, built by `tools/build_pos.py`) is served from it and talks only to it, so
other devices on the same Wi-Fi/LAN just open `http://<main-machine-ip>:8080` in a browser.

Storage: one SQLite table `docs(col, id, data JSON, seq)` plus files in `assets/`. A change counter `seq`
goes up on every write; clients long-poll `/api/changes` to refresh.

| Method | Path | Body | Reply |
|---|---|---|---|
| GET | `/api/info` | | `{app, version, deviceId, name, platform, port, lan[], seq, started}` |
| GET | `/api/col/:col?w=[[field,op,value]]&o=[field,dir]&l=N` | | `{seq, docs:[{id,data}]}` ops: `== != > >= < <= in` |
| GET | `/api/doc/:col/:id` | | `{data}` (null if missing) |
| PUT | `/api/doc/:col/:id` | `{data}` | `{ok, seq}` |
| PATCH | `/api/doc/:col/:id` | `{patch}` deep-merged | `{ok, data, seq}` or 404 `{error:"not_found"}` |
| DELETE | `/api/doc/:col/:id` | | `{ok, seq}` |
| POST | `/api/lease/:col/:id` | `{holder, ttlMs}` | `{acquired, expiresAt}` (no change event) |
| GET | `/api/changes?since=N&wait=25` | | waits until `seq != N` (max `wait` s) → `{seq, cols:[...]|null}` (`null` = reload all) |
| POST | `/api/asset` | raw bytes, `Content-Type: image/*|video/*` | `{id, sizeBytes, contentType}` |
| DELETE | `/api/asset/:id` | | `{ok}` |
| GET | `/assets/:id` | | the file (immutable cache) |
| GET | `/api/export` | | `{collections:{col:[{id,...data}]}}` |
| GET | anything else | | static file from `www/` (`index.html` for unknown paths without an extension) |

Names (`col`, `id`) match `^[A-Za-z0-9_.:-]{1,128}$`; query fields match `^[A-Za-z0-9_]+(\.[A-Za-z0-9_]+){0,3}$`.
The app keeps its licence (shop, offline-until date, cached sign-ins) in the doc `_sys/license`.
A daily copy of the database is kept in `backups/` (14 days).
