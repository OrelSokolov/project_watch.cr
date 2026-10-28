# project_watch.cr

Project tree watching for Crystal — the policy layer above
[fswatch.cr](https://github.com/OrelSokolov/fswatch.cr).

fswatch.cr reports raw filesystem events. Hosts watching a *project*
tree (an editor, a dev-server rebuild loop) all rebuild the same
policy on top of it, project after project. This shard is that
policy, written once:

* **ignore-aware skipping** — hidden entries (`.git` above all) and
  subtrees the root `.gitignore` excludes never reach the kernel
  watch tables: no wasted watches on `node_modules`, no event noise
  from vendored trees;
* **extra roots** — watch real directories outside the project root
  alongside it (a monorepo app whose `lib/` entries are symlinks to
  sibling checkouts needs events from the checkouts themselves;
  inotify does not follow symlinks by design);
* **quiet-window coalescing** — the event storm of one logical edit
  (atomic saves, `git checkout`, a formatter pass) is delivered as
  one `Batch` with paths deduplicated.

The batch is a dumb set of paths (plus an overflow flag). What a path
*means* — rebuild, restart, reindex — is the host's business and
stays out of this shard.

## Usage

```crystal
require "project_watch"

watcher = ProjectWatch.watch("myproj",
  extra_roots: ["/home/me/monorepo/shards/my_shard"],
  quiet: 300.milliseconds) do |batch|
  next puts "events were dropped — rescan" if batch.overflow?
  rebuild if batch.paths.any? { |p| p.ends_with?(".cr") }
end
# ... later:
watcher.stop
```

## Semantics

* `Batch#paths` — absolute paths that changed (created, modified,
  deleted, moved — indistinguishable by design), deduplicated within
  the quiet window: however many times one file was rewritten inside
  the window, it is in the batch once.
* `Batch#overflow?` — the backend event queue overflowed and events
  were dropped; `paths` may be incomplete. Rescan anything cached.
* A batch is delivered after `quiet` (default 300ms) passes with no
  new events. The handler runs on the watcher's own fiber — don't
  block it.
* Only the **root** `.gitignore` of each watched root is consulted
  (nested ones are not), read once at construction. Over-watching a
  nested-ignored subtree is the only possible staleness, and it is
  bounded. An extra `skip: (String -> Bool)` predicate composes with
  the defaults for host-specific noise.
* `stop` is idempotent; in-flight events may land in one final batch.

## Installation

```yaml
dependencies:
  project_watch:
    github: OrelSokolov/project_watch.cr
```

## License

MIT — see [LICENSE](LICENSE).
