# project_watch.cr — Watcher: the project-tree policy over fswatch.
#
# One recursive FSWatch per root (the project root plus any
# `extra_roots` — real directories outside it, e.g. the checkouts a
# monorepo app's `lib/` symlinks point at; inotify does not follow
# symlinks by design). Each root's watch skips what the project
# itself ignores: hidden entries and the root .gitignore's subtrees
# never reach the kernel watch tables.
#
# Events from every root land in one channel; the pump fiber coalesces
# them: a batch is delivered after a QUIET window passes with no new
# events, so the storm of one logical edit (atomic save, `git
# checkout`, a formatter pass) arrives as one `Batch` with paths
# deduplicated. `Overflow` events set the batch's flag instead of a
# path — the host rescans.

require "fswatch"
require "./batch"

module ProjectWatch
  class Watcher
    # How long the pump waits for further events after the last one
    # before delivering the batch. Long enough to swallow an edit's
    # event storm, short enough to feel immediate.
    DEFAULT_QUIET = 300.milliseconds

    getter root : String
    getter? stopped : Bool = false

    @events = Channel(FSWatch::Event).new
    @watches = [] of FSWatch::Watch

    def initialize(@root : String, *, extra_roots : Enumerable(String) = [] of String,
                   quiet : Time::Span = DEFAULT_QUIET,
                   interval : Time::Span? = nil,
                   skip : (String -> Bool)? = nil,
                   &handler : Batch ->)
      @quiet = quiet
      @handler = handler
      roots = [@root] + extra_roots.to_a
      roots.each do |r|
        path = File.expand_path(r)
        ignore = Ignore.load(File.join(path, ".gitignore"))
        # The ignore is memoized per root at construction (kodkod's
        # trade-off): .gitignore edits during a session change nothing
        # — over-watching is the only possible staleness.
        @watches << FSWatch.watch(path, interval: interval,
                                  skip: skip_proc(path, ignore, skip)) do |e|
          next if stopped?
          # Raced with #stop between the check and the send — dropping
          # the event then is exactly what stopping means.
          @events.send(e) rescue Channel::ClosedError
        end
      end
      spawn(name: "project-watch-pump") { pump }
    end

    # Tear the watcher down. Idempotent. In-flight events may still
    # land in one final batch; nothing is delivered after the pump
    # fiber observes the stop.
    def stop : Nil
      return if stopped?
      @stopped = true
      @watches.each(&.stop)
      @events.close
    end

    # --- internals -----------------------------------------------------

    private def skip_proc(watch_root : String, ignore : Ignore?,
                          user_skip : (String -> Bool)?) : String -> Bool
      prefix = watch_root.ends_with?('/') ? watch_root : watch_root + '/'
      ->(path : String) {
        # Hidden entries (`.git` above all) are never watched.
        if File.basename(path).starts_with?('.')
          true
        elsif path.starts_with?(prefix) && (gi = ignore) &&
              gi.ignores?(path.lchop(prefix), dir: true)
          true
        else
          user_skip.try(&.call(path)) || false
        end
      }
    end

    # The coalescing loop: absorb events, extend the window on every
    # new one, deliver when quiet. Runs on its own fiber; the handler
    # runs here too (don't block).
    private def pump : Nil
      loop do
        first = @events.receive?
        break unless first # stopped & channel drained
        pending = Set(String).new
        overflow = false
        event = first
        loop do
          if event.overflow?
            overflow = true
          elsif !event.self_removed?
            pending << event.path
          end
          select
          when received = @events.receive?
            break if received.nil? # stopped & channel drained
            event = received # absorb it, window restarts
          when timeout(@quiet)
            @handler.call(Batch.new(pending, overflow))
            break
          end
          break if stopped?
        end
        break if stopped?
      end
    end
  end
end
