require "./spec_helper"

describe ProjectWatch::Watcher do
  # The quiet window is what the batching specs measure against: keep
  # it short so the specs are fast, and sleep well past it.
  quiet = 100.milliseconds

  it "coalesces an edit storm into one deduplicated batch" do
    with_temp_dir do |dir|
      batches = [] of ProjectWatch::Batch
      watcher = ProjectWatch.watch(dir, quiet: quiet) { |b| batches << b }

      # One logical edit: three files, one of them rewritten — inside
      # a single quiet window. Top-level files: the root watch is
      # armed synchronously, no arming race.
      File.write(File.join(dir, "a.cr"), "1")
      File.write(File.join(dir, "b.cr"), "1")
      File.write(File.join(dir, "c.txt"), "1")
      sleep quiet / 2
      File.write(File.join(dir, "a.cr"), "2")

      eventually("no batch was delivered") { !batches.empty? }
      sleep (quiet * 3) # a second batch must NOT materialize
      batches.size.should eq(1)
      batch = batches.first
      batch.overflow?.should be_false
      batch.paths.size.should eq(3) # a.cr deduplicated
      ["a.cr", "b.cr", "c.txt"].each do |name|
        batch.includes?(File.join(dir, name)).should be_true
      end
      watcher.stop
    end
  end

  it "delivers sequential edits as separate batches" do
    with_temp_dir do |dir|
      batches = [] of ProjectWatch::Batch
      watcher = ProjectWatch.watch(dir, quiet: quiet) { |b| batches << b }

      File.write(File.join(dir, "one.cr"), "1")
      eventually("first batch missing") { batches.size == 1 }
      File.write(File.join(dir, "two.cr"), "1")
      eventually("second batch missing") { batches.size == 2 }
      batches[1].includes?(File.join(dir, "two.cr")).should be_true
      batches[0].includes?(File.join(dir, "two.cr")).should be_false
      watcher.stop
    end
  end

  it "never raises events from gitignored or hidden subtrees" do
    with_temp_dir do |dir|
      File.write(File.join(dir, ".gitignore"), "vendor/\n")
      vendor = File.join(dir, "vendor", "pkg")
      hidden = File.join(dir, ".git")
      Dir.mkdir_p(vendor)
      Dir.mkdir(hidden)
      batches = [] of ProjectWatch::Batch
      watcher = ProjectWatch.watch(dir, quiet: quiet) { |b| batches << b }

      # Let the recursive arming walk pass over the subtrees first:
      # writes that predate arming produce no kernel events (and the
      # skip filter keeps these dirs unarmed anyway).
      sleep 0.3.seconds
      File.touch(File.join(vendor, "v.txt"))
      File.touch(File.join(hidden, "h.txt"))

      # The root itself stays live despite the filter — one positive
      # event proves the watch works while the skipped stay silent.
      File.touch(File.join(dir, "top.txt"))
      eventually("top-level event never arrived") do
        batches.any?(&.includes?(File.join(dir, "top.txt")))
      end
      sleep (quiet * 3) # bounded wait, then silence is the assertion
      batches.each do |batch|
        batch.paths.any? { |p| p.ends_with?("v.txt") || p.ends_with?("h.txt") }
          .should be_false
      end
      watcher.stop
    end
  end

  it "watches extra roots alongside the project root" do
    with_temp_dir do |dir|
      with_temp_dir do |dep|
        batches = [] of ProjectWatch::Batch
        watcher = ProjectWatch.watch(dir, extra_roots: [dep],
                                     quiet: quiet) { |b| batches << b }

        Dir.mkdir_p(File.join(dep, "src"))
        sleep 0.3.seconds # arming of the extra root's tree
        File.write(File.join(dep, "src", "dep.cr"), "1")
        eventually("no batch from the extra root") do
          batches.any?(&.includes?(File.join(dep, "src", "dep.cr")))
        end
        watcher.stop
      end
    end
  end
end
