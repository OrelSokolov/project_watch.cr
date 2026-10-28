# project_watch.cr — Batch: what one coalesced round of filesystem
# activity looks like when it reaches the host handler.

module ProjectWatch
  struct Batch
    # The paths that changed (created/modified/deleted/moved — what a
    # path MEANS is the host's business), deduplicated: however many
    # times one file was rewritten inside the quiet window, it is here
    # once. Absolute paths.
    getter paths : Set(String)

    # The backend event queue overflowed — events were dropped and
    # `paths` may be incomplete. Hosts must rescan anything they cache
    # (stat the world like a poll watcher would).
    getter? overflow : Bool

    def initialize(@paths : Set(String), @overflow : Bool = false)
    end

    def includes?(path : String) : Bool
      paths.includes?(path)
    end

    def empty? : Bool
      paths.empty? && !@overflow
    end

    def to_s(io : IO) : Nil
      io << "ProjectWatch::Batch("
      io << "overflow, " if overflow?
      io << paths.join(", ")
      io << ')'
    end
  end
end
