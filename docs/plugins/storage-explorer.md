# Storage Explorer

Storage Explorer is a metadata-only, user-initiated disk usage browser. It does not open file contents during scanning. Selecting a local regular file in the inspector can request a Quick Look preview.

## Scanning and shared metadata

`MacToolsFileSystem` is a static module shared with Disk Clean. Its bulk parser preserves the existing Disk Clean attribute contract; Storage Explorer requests additional allocation, modification date, and file flag attributes. Unsupported bulk reads fall back to descriptor-relative enumeration. Directory opens reject symbolic-link path components. Unreadable directories, cloud-only directories, mount boundaries, invalid filename encodings, and missing metadata make results incomplete instead of appearing empty and complete.

The scanner defaults to two workers, capped at four. Blocking calls stay outside Swift's cooperative executor. Progress is time-throttled to 150 ms with initial and final updates. Cancellation is checked between batches and jobs; a blocking filesystem syscall cannot be forcibly interrupted. Packages remain atomic in the results, with nested payload included. Hard links are deduplicated across all workers and package boundaries; the first encountered link receives the counted bytes.

The app scanner retains every directory, the largest file in each directory, and the 50,000 largest files overall. Exact scan and file-type totals are stored separately, so omitted small files remain represented by aggregate tiles. Full-tree scanner clients can opt into publishing every file. The hierarchical treemap shows several directory levels and keeps colors tied to top-level items. Logical and allocated sizes are separate, and neither is a promise of recoverable disk space.

## Refresh and retention

Scan snapshots remain in memory. Directory metadata is cached for at most 30 seconds and 10,000 entries. FSEvents invalidates affected ancestors/subtrees, and dropped or root-change events clear the cache. Refresh drains pending file events before cache reuse, re-enumerates invalidated directories and recomputes hard-link accounting. During refresh, the previous complete visualization remains stable until the replacement snapshot is ready. No scan paths or results are persisted or sent over the network.

Trash review is unavailable during scanning, for incomplete results, and for protected paths. Items can be added with the plus button or by dragging them from the treemap or list to the review basket. The basket normalizes ancestor/descendant overlap. Trash operations verify file identity and reject symbolic-link path changes immediately before recycling. Partial failures trigger a fresh scan, remove confirmed successes, and keep failed items selected for retry.

## Validation

Run the StorageExplorer scanner, progress, controller, presentation, and safety-policy XCTest classes, plus DiskClean bulk-parser and walker tests. Run `make script-tests` after changing module/project integration. Benchmark optimized builds on synthetic many-small-file trees, deep trees, packages, and sparse files; compare full duration, first useful update, callbacks, and memory separately. Local synthetic benchmarks do not establish external-drive, cloud-provider, or network-filesystem performance.

The standalone benchmark creates and deletes only its own temporary fixture:

```sh
DEVELOPER_DIR=/Applications/Xcode-beta.app/Contents/Developer python3 scripts/benchmark-storage-explorer.py --files 100000
```

The benchmark reports duration, callback count, retained node count, cache reuse, and process peak resident memory. Its progress-only run enforces a 200 MiB peak-memory ceiling by default. This is a warm-filesystem synthetic check, not a cold-disk or external-drive guarantee.
