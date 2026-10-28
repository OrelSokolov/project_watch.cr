# project_watch.cr — the project-tree layer above fswatch.cr.
#
# fswatch.cr reports raw filesystem events; hosts watching a PROJECT
# tree (an editor, a dev server rebuild loop) all rebuild the same
# policy on top of it, again and again:
#
#   * skip the subtrees the project itself ignores — hidden entries
#     (`.git` above all) and everything the root .gitignore excludes —
#     so they never even reach the kernel watch tables;
#   * watch more roots than the project dir proper (a monorepo app
#     whose `lib/` entries are symlinks to sibling checkouts wants
#     events from the real directories);
#   * coalesce the event storm of one logical edit (atomic saves,
#     `git checkout`, a formatter rewriting a file) into ONE batch —
#     deduplicated by path and delivered after a quiet window.
#
# That policy lives here, once, instead of in every host:
#
#   require "project_watch"
#
#   watcher = ProjectWatch.watch("myproj",
#     extra_roots: ["/home/me/monorepo/shards/my_shard"],
#     quiet: 300.milliseconds) do |batch|
#     next puts "events were dropped — rescan" if batch.overflow?
#     rebuild if batch.paths.any? { |p| p.ends_with?(".cr") }
#   end
#   # ... later:
#   watcher.stop
#
# The batch is a dumb set of paths (plus an overflow flag) — what a
# path MEANS (rebuild, restart, reindex) is the host's business and
# stays out of this shard.

require "./project_watch/ignore"
require "./project_watch/batch"
require "./project_watch/watcher"

module ProjectWatch
  # Convenience constructor — see `Watcher#initialize`.
  def self.watch(path : String, *, extra_roots : Enumerable(String) = [] of String,
                 quiet : Time::Span = Watcher::DEFAULT_QUIET,
                 interval : Time::Span? = nil,
                 skip : (String -> Bool)? = nil,
                 &handler : Batch ->) : Watcher
    Watcher.new(path, extra_roots: extra_roots, quiet: quiet,
                interval: interval, skip: skip, &handler)
  end
end
