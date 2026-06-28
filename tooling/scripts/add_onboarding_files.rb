#!/usr/bin/env ruby
# Adds Swift files under NotchNerd/components/Onboarding/ to the Onboarding PBXGroup + the
# NotchNerd app target's Sources build phase. Idempotent. Required because components/Onboarding
# is a normal PBXGroup (not a synchronized folder) — new files are NOT auto-built.
#
# Usage (from repo root):
#   ruby tooling/scripts/add_onboarding_files.rb File1.swift File2.swift ...
require "xcodeproj"

PROJECT       = File.expand_path("NotchNerd.xcodeproj", Dir.pwd)
GROUP_SUBPATH = "NotchNerd/components/Onboarding"
TARGET_NAME   = "NotchNerd"

abort "no files given" if ARGV.empty?

project = Xcodeproj::Project.open(PROJECT)
target  = project.targets.find { |t| t.name == TARGET_NAME } or abort "target #{TARGET_NAME} not found"
group   = project.main_group.find_subpath(GROUP_SUBPATH, false) or abort "group #{GROUP_SUBPATH} not found"

changed = false
ARGV.each do |name|
  name = File.basename(name)
  disk = File.join(File.dirname(PROJECT), GROUP_SUBPATH, name)
  abort "missing on disk: #{disk}" unless File.exist?(disk)

  ref = group.files.find { |f| f.display_name == name } || begin
    r = group.new_reference(name)
    puts "added file reference: #{name}"
    changed = true
    r
  end

  if target.source_build_phase.files_references.include?(ref)
    puts "already in Sources phase: #{name}"
  else
    target.source_build_phase.add_file_reference(ref, true)
    puts "added to Sources phase: #{name}"
    changed = true
  end
end

if changed
  project.save
  puts "saved #{PROJECT}"
else
  puts "no changes"
end
