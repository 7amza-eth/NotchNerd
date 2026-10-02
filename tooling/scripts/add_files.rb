#!/usr/bin/env ruby
# Adds Swift files under a folder of the app (e.g. NotchNerd/Mods) to its PBXGroup, creating the
# group if needed, and to the NotchNerd target's Sources phase. Idempotent. Needed because only
# private/ and NotchNerdXPCHelper/ are synchronized folders; anything else must be added by hand.
#
# Usage (from repo root):
#   ruby tooling/scripts/add_files.rb NotchNerd/Mods File1.swift File2.swift ...
require "xcodeproj"

PROJECT     = File.expand_path("NotchNerd.xcodeproj", Dir.pwd)
TARGET_NAME = "NotchNerd"

group_subpath = ARGV.shift or abort "usage: add_files.rb <group path> <file>..."
abort "no files given" if ARGV.empty?

project = Xcodeproj::Project.open(PROJECT)
target  = project.targets.find { |t| t.name == TARGET_NAME } or abort "target #{TARGET_NAME} not found"

group = project.main_group
group_subpath.split("/").each do |component|
  group = group.children.find { |c| c.is_a?(Xcodeproj::Project::Object::PBXGroup) && c.display_name == component } ||
          begin
            puts "added group: #{component}"
            group.new_group(component, component)
          end
end

ARGV.each do |name|
  name = File.basename(name)
  disk = File.join(File.dirname(PROJECT), group_subpath, name)
  abort "missing on disk: #{disk}" unless File.exist?(disk)

  ref = group.files.find { |f| f.display_name == name } || begin
    puts "added file reference: #{name}"
    group.new_reference(name)
  end

  if target.source_build_phase.files_references.include?(ref)
    puts "already in Sources phase: #{name}"
  else
    target.source_build_phase.add_file_reference(ref, true)
    puts "added to Sources phase: #{name}"
  end
end

project.save
