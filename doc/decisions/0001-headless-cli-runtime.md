# ADR 0001: Reuse the desktop runtime for comic-source CLI commands

- Status: Proposed
- Date: 2026-08-22

## Context

Venera comic sources are JavaScript extensions evaluated by the application's QuickJS bridge. Their behavior can depend on Venera-managed source data, cookies, account state, cache behavior, and UI bridge calls. Reimplementing those sources in a separate command-line client would duplicate the source contract and could produce different behavior from the GUI.

The existing `--headless` mode already exposes WebDAV and update tasks, but it has no stable command contract for source discovery, search, metadata, category, ranking, explore, or remote favorite operations. Starting a second runtime while the GUI is open could also race on SQLite files, source `.data`, cookies, and remote mutations.

## Decision

Extend the existing desktop executable and `--headless` entry point instead of introducing a separate pure-Dart executable.

The public automation contract consists of command flags, JSON schema version 1, documented exit codes, and observable cancellation rules. The internal transport is not public API.

Each application profile has one runtime owner:

- a direct CLI invocation acquires an exclusive profile lock before mutable application components are initialized;
- a running desktop GUI owns that lock and publishes a private loopback HTTP/JSON and SSE endpoint;
- a second CLI process discovers the GUI endpoint, performs a version handshake, and submits a cancellable job;
- no command falls back to a second runtime after a live but incompatible GUI is discovered.

The descriptor contains a random 256-bit bearer token, binds only to `127.0.0.1`, is written atomically, and is restricted to the current OS user. Tokens and credential-like fields pass through centralized diagnostic redaction.

Source work is capability-driven. There are no branches for specific source names. Up to four read operations may run concurrently, while source writes are serialized and exclude reads for that source. GUI and CLI favorite mutations share the same coordinator and change notifications.

Remote favorite changes follow a conservative state machine: inspect and, where needed, scan before dispatch; never retry a write automatically; reject unknown or implicit-move states; then bypass caches and verify the requested remote state. Folder deletion requires explicit confirmation and protects aggregate folders.

Source UI calls are divided into progress-only and interactive operations. Messages and loading events can be emitted as CLI events. Dialogs, inputs, selections, and URL launches fail with `interactive_required` unless the caller uses `--allow-gui` with a running, unlocked GUI. The CLI never accepts account credentials.

## Consequences

- CLI behavior stays aligned with installed QuickJS sources and the GUI's authenticated state.
- A CLI invocation may persist the same cookie, token, or source-data updates as a normal GUI source request.
- Automation remains safe while the GUI is open because database and source state are owned by one process.
- Packaged desktop applications remain the distribution unit; this decision does not add PATH installers or a standalone binary.
- CLI startup includes the Flutter engine and application initialization cost.
- Headless availability depends on each source's declared capabilities; custom GUI-only explore pages remain unsupported.
- The loopback job protocol must be versioned and tested, even though it is internal.

## Alternatives considered

### Separate pure-Dart CLI

Rejected because the QuickJS bridge and several Flutter plugins are part of source execution. Extracting them would be a substantially larger compatibility project and would still need shared-profile coordination.

### Read the application database directly

Rejected because remote search and favorite behavior lives in source scripts, not only in SQLite. Direct writes would bypass source semantics, cache invalidation, verification, and GUI notifications.

### Allow independent GUI and CLI runtimes

Rejected because concurrent ownership of the same profile can race on local state and issue duplicate or toggling remote favorite writes.

### Expose a permanent public GUI API

Rejected for this change. A session-scoped, authenticated loopback transport is sufficient for local process coordination. Keeping it internal allows the protocol to evolve while the documented CLI contract remains stable.
