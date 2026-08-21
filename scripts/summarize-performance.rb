#!/usr/bin/env ruby
# frozen_string_literal: true

require "csv"
require "json"

abort "usage: summarize-performance.rb SAMPLES SCENARIO BUDGET" unless ARGV.length == 3
samples_path, scenario_path, budget_path = ARGV
samples = CSV.read(samples_path, headers: true).map do |row|
  {
    elapsed: Integer(row.fetch("elapsed_seconds")),
    phase: row.fetch("phase"),
    rss_kb: Integer(row.fetch("rss_kb")),
    cpu: Float(row.fetch("cpu_percent")),
    physical_bytes: Integer(row.fetch("physical_footprint_bytes")),
    peak_physical_bytes: Integer(row.fetch("peak_physical_footprint_bytes"))
  }
end
abort "error: no performance samples" if samples.empty?

scenario = JSON.parse(File.read(scenario_path))
budget = JSON.parse(File.read(budget_path)).fetch(scenario.fetch("fixtureScale"))
abort "error: scenario failed" unless scenario.fetch("succeeded")

def mib(bytes)
  (bytes.to_f / 1024 / 1024).round(1)
end

def percentile(values, fraction)
  sorted = values.sort
  sorted[[(sorted.length * fraction).ceil - 1, 0].max]
end

cycle_groups = samples.select { |sample| sample[:phase].match?(/^cycle-\d\d$/) }
                      .group_by { |sample| sample[:phase] }
cycle_peaks = cycle_groups.sort.map { |phase, rows| [phase, rows.map { |row| row[:rss_kb] }.max] }
first_cycle_rss = cycle_peaks.first&.last || 0
last_cycle_rss = cycle_peaks.last&.last || 0
cycle_growth_percent = if first_cycle_rss.positive?
                         ((last_cycle_rss - first_cycle_rss).to_f / first_cycle_rss * 100).round(1)
                       else
                         0.0
                       end

refreshes = scenario.fetch("repeatedRefreshMilliseconds")
launch_samples = samples.select { |sample| sample[:elapsed] <= 10 }
idle_samples = samples.select { |sample| sample[:phase] == "idle" }
launch_peak_rss = launch_samples.map { |sample| sample[:rss_kb] }.max || samples.first[:rss_kb]
last_idle = idle_samples.last || launch_samples.last || samples.first
metrics = {
  "launch_peak_rss_mb" => (launch_peak_rss.to_f / 1024).round(1),
  "idle_final_rss_mb" => (last_idle[:rss_kb].to_f / 1024).round(1),
  "idle_final_physical_mb" => mib(last_idle[:physical_bytes]),
  "idle_final_cpu_percent" => last_idle[:cpu].round(1),
  "initial_scan_milliseconds" => scenario.fetch("initialScanMilliseconds"),
  "refresh_p95_milliseconds" => percentile(refreshes, 0.95),
  "peak_rss_mb" => (samples.map { |sample| sample[:rss_kb] }.max.to_f / 1024).round(1),
  "peak_physical_mb" => mib(samples.map { |sample| sample[:physical_bytes] }.max),
  "recovery_rss_mb" => begin
    recovery = samples.select { |sample| sample[:phase] == "recovery" }
    ((recovery.last || samples.last)[:rss_kb].to_f / 1024).round(1)
  end,
  "cycle_growth_percent" => cycle_growth_percent
}

checks = budget.map do |metric, maximum|
  actual = metrics.fetch(metric)
  [metric, actual, maximum, actual <= maximum]
end

puts "DevHub performance baseline"
puts "scale: #{scenario.fetch("fixtureScale")}"
puts "fixture: #{scenario.fetch("projectCount")} projects / #{scenario.fetch("sessionCount")} sessions"
puts "idle: #{scenario.fetch("idleSeconds")}s"
puts "cycles: #{scenario.fetch("cycles")}"
puts "clean launch peak RSS: #{metrics.fetch("launch_peak_rss_mb")} MiB"
puts "idle final RSS: #{metrics.fetch("idle_final_rss_mb")} MiB"
puts "idle final physical footprint: #{metrics.fetch("idle_final_physical_mb")} MiB"
puts "idle final CPU: #{metrics.fetch("idle_final_cpu_percent")} %"
puts "initial scan: #{metrics.fetch("initial_scan_milliseconds")}ms"
if scenario.key?("initialWritingMilliseconds")
  puts "  preparation: #{scenario.fetch("initialPreparationMilliseconds")}ms"
  puts "  discovery and dedupe: #{scenario.fetch("initialDiscoveryMilliseconds")}ms"
  puts "  project matching: #{scenario.fetch("initialProjectMatchingMilliseconds")}ms"
  puts "  SwiftData writing: #{scenario.fetch("initialWritingMilliseconds")}ms"
  if scenario.key?("initialWriteSaveMilliseconds")
    puts "    writer preparation: #{scenario.fetch("initialWritePreparationMilliseconds")}ms"
    puts "    model mutation: #{scenario.fetch("initialWriteModelMutationMilliseconds")}ms"
    puts "    SQLite save: #{scenario.fetch("initialWriteSaveMilliseconds")}ms"
    puts "    refresh cache: #{scenario.fetch("initialWriteCacheMilliseconds")}ms"
  end
end
puts "incremental refresh p95: #{metrics.fetch("refresh_p95_milliseconds")}ms"
puts "peak RSS: #{metrics.fetch("peak_rss_mb")} MiB"
puts "peak physical footprint: #{metrics.fetch("peak_physical_mb")} MiB"
puts "post-operation RSS: #{metrics.fetch("recovery_rss_mb")} MiB"
puts "cycle 1 to final cycle RSS growth: #{metrics.fetch("cycle_growth_percent")} %"
puts "navigation transitions: #{scenario.fetch("navigationTransitions")}"
puts "settings window opens: #{scenario.fetch("settingsWindowOpenCount")}"
puts "budget: #{checks.all?(&:last) ? "PASS" : "FAIL"}"
checks.each do |metric, actual, maximum, passed|
  puts "  #{passed ? "PASS" : "FAIL"} #{metric}: #{actual} <= #{maximum}"
end

exit(checks.all?(&:last) ? 0 : 1)
