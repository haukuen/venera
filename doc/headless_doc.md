# Venera Headless Mode

Venera exposes its existing comic-source runtime through the desktop executable. The CLI loads the same installed QuickJS sources, source data, cookies, settings, and remote accounts as the GUI; it does not implement source-specific HTTP clients.

Reading comic pages remains a GUI-only operation. The CLI does not return chapter images or comment content.

## Usage

```bash
venera --headless [global options] <resource> <command> [options]
```

The executable location depends on the installation method. On macOS, for example:

```bash
/Applications/venera.app/Contents/MacOS/venera --headless --version
```

Use `venera --headless --help` for the command inventory. Global options can appear before or after a command.

## Global options

| Option | Description |
| --- | --- |
| `--json` | Print exactly one schema-versioned JSON envelope to stdout. Progress and warnings use stderr. |
| `--timeout <duration>` | Cancel after a duration such as `500ms`, `30s`, `2m`, or `1h`. Default: `2m`. |
| `--allow-gui` | Allow a running GUI to handle source-requested interaction and wait for GUI unlock. |
| `--record-history` | Record search terms in Venera search history. Searches do not record history by default. |
| `--quiet` | Suppress progress output. |
| `--no-color` | Disable ANSI colors in human-readable errors. |
| `--ignore-disheadless-log` | Preserve the legacy option that mutes application logs. |
| `--help`, `-h` | Print help without initializing the application profile. |
| `--version` | Print the application and protocol version without initializing the profile. |

## Comic-source commands

### Source discovery

```bash
venera --headless source list
venera --headless source show <source-key>
```

`source list` includes both ready sources and scripts that failed to parse. Capabilities in the result determine which other commands a source supports.

### Search and comic metadata

```bash
venera --headless comic search "keyword" --source <source-key>
venera --headless comic search "keyword" --source <a> --source <b> --allow-partial
venera --headless comic search "keyword" --all-sources
venera --headless comic show --source <source-key> --id <comic-id>
venera --headless comic chapters --source <source-key> --id <comic-id>
venera --headless comic tags --source <source-key> --id <comic-id>
```

Without `--source`, search uses the sources selected in Venera settings. Repeating `--source` preserves the requested source order. Results remain grouped by source and are not deduplicated.

Source search options can be supplied as a full JSON array or by zero-based index:

```bash
venera --headless comic search "keyword" --source <source-key> \
  --options-json '["new","all"]'
venera --headless comic search "keyword" --source <source-key> \
  --option 0=popular
```

For a multi-source search, use `--source-options-json` with an object keyed by source:

```bash
venera --headless comic search "keyword" --source <a> --source <b> \
  --source-options-json '{"a":["new"],"b":["all"]}'
```

Comic details retain `commentCount` when supplied by the source, but omit comment bodies.

### Categories, rankings, and explore pages

```bash
venera --headless category list --source <source-key>
venera --headless category options --source <source-key> --category <category> [--param <value>]
venera --headless category comics --source <source-key> --category <category> [--param <value>]

venera --headless ranking list --source <source-key>
venera --headless ranking comics --source <source-key> [--ranking <value>]

venera --headless explore list --source <source-key>
venera --headless explore show --source <source-key> --index <one-based-index>
venera --headless explore show --source <source-key> --title <exact-title>
```

Category comic options use the same `--options-json` and `--option INDEX=VALUE` forms as a single-source search. Random category groups are listed in full so discovery is stable. Explore pages with a custom GUI override return `unsupported`.

### Pagination

All numeric CLI pages are one-based. A source may expose either page or cursor pagination; the response identifies the kind.

```bash
--page <number>
--cursor <opaque-cursor>
--all --max-pages <count>
--all --limit <comic-count>
```

Aggregated search does not accept a shared page or cursor. Bound it per source instead:

```bash
--all --max-pages-per-source <count>
--all --limit-per-source <comic-count>
```

Unbounded `--all` is rejected.

## Remote favorites

Remote favorite commands are available only when the selected source declares the corresponding capability.

```bash
venera --headless favorite remote list --source <source-key> [--folder <folder-id>]
venera --headless favorite remote status --source <source-key> --id <comic-id>

venera --headless favorite remote add --source <source-key> --id <comic-id> \
  [--folder <folder-id>] [--favorite-id <opaque-id>] [--dry-run]
venera --headless favorite remote remove --source <source-key> --id <comic-id> \
  [--folder <folder-id>] [--favorite-id <opaque-id>] [--dry-run]

venera --headless favorite remote folder list --source <source-key>
venera --headless favorite remote folder create --source <source-key> \
  --name <name> [--dry-run]
venera --headless favorite remote folder delete --source <source-key> \
  --folder <folder-id> [--dry-run] --yes [--force-non-empty]
```

Favorite writes use a strict preflight and post-write verification:

- a write is never automatically retried;
- an unknown preflight state is refused instead of risking a toggle;
- moving a favorite between folders is not inferred;
- aggregate “all favorites” folders cannot be write or delete targets;
- folder deletion needs `--yes`, plus `--force-non-empty` unless the folder is proven empty;
- `--dry-run` reports whether the operation is allowed and which flags are missing;
- if the remote outcome cannot be verified, the command returns `outcome_unknown`.

`--verify-max-pages <count>` bounds folder scans for add/remove and defaults to 3.

## GUI coexistence and source interaction

Only one Venera runtime may own an application profile at a time.

- If the GUI is not running, the CLI acquires the profile lock and runs the source directly.
- If the GUI is running, the CLI forwards the job to an authenticated loopback IPC endpoint. It does not open a second database or QuickJS runtime.
- If the application is locked, the command returns `app_locked`. With `--allow-gui`, Venera brings the GUI forward and waits for the user to unlock it.
- Non-interactive source messages become progress events. Source dialogs, text input, selection, and URL launches return `interactive_required` unless a running GUI is explicitly allowed.

The IPC endpoint binds to `127.0.0.1` on a random port and uses a per-session bearer token. Runtime descriptor files are private to the current OS user. The IPC protocol is internal; scripts should depend on command flags, JSON schema, and exit codes instead.

Normal source queries may update the same cookies, tokens, or source `.data` that the GUI would update. Search history changes only with `--record-history`. Remote favorite reads bypass the normal response cache.

## JSON output

With `--json`, stdout contains exactly one final object. Nullable fields are retained.

```json
{
  "schemaVersion": 1,
  "ok": true,
  "command": "comic.search",
  "data": {},
  "error": null,
  "warnings": [],
  "meta": {
    "appVersion": "1.15.0",
    "protocolVersion": 1,
    "transport": "direct",
    "partial": false,
    "requestId": "..."
  }
}
```

`meta.transport` is `direct` or `ipc`. Errors use the same envelope with `ok: false` and a structured `error`. Credentials, cookies, authorization values, and secret URL parameters are redacted from CLI and IPC diagnostics.

## Exit codes

| Code | Meaning |
| ---: | --- |
| 0 | Success |
| 2 | Invalid arguments |
| 3 | Authentication, locked app, or GUI interaction required |
| 4 | Unsupported source capability |
| 5 | Source, comic, or folder not found |
| 6 | State conflict, unsafe mutation, or confirmation required |
| 7 | Partial aggregate failure |
| 8 | Cancelled or timed out |
| 10 | Comic-source error |
| 69 | Runtime IPC or protocol error |
| 70 | Internal error |
| 130 | Forced termination after a second Ctrl-C |

The first Ctrl-C requests cooperative cancellation. A favorite write already dispatched to a remote service is verified once before Venera reports the observed result.

## Legacy commands

The existing commands remain available:

```bash
venera --headless webdav up
venera --headless webdav down
venera --headless updatescript all
venera --headless updatesubscribe
venera --headless updatesubscribe --update-comic-by-id-type <id> <source-key>
```

Without `--json`, these commands preserve their historical `[CLI PRINT]` records and `0`/`1` exit status. Adding `--json` selects the common JSON envelope and exit-code taxonomy described above.
