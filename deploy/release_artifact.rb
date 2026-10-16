#!/usr/bin/env ruby
# frozen_string_literal: true

require 'digest'
require 'fileutils'
require 'find'
require 'rubygems/package'
require 'stringio'
require 'tempfile'
require 'zlib'

# Retains only the credential-free, executable portion of a standard Mix release.
module ReleaseArtifact
  CHUNK = 1024 * 1024
  ZERO_BLOCK = ("\0" * 512).b.freeze
  module_function

  def allowed?(name)
    first = name.split('/').first
    %w[bin lib releases].include?(first) || first&.start_with?('erts-')
  end

  def private?(name)
    name.split('/').any? { |part| part.start_with?('.env') } || name == 'releases/COOKIE'
  end

  def present?(path)
    File.exist?(path) || File.symlink?(path)
  end

  def digest(path)
    Digest::SHA256.file(path).hexdigest
  end

  def raw_field(block, offset, length)
    value, padding = block.byteslice(offset, length).split("\0", 2)
    raise 'ambiguous tar field' if padding && !padding.delete("\0").empty?

    value
  end

  def drain_exact(io, bytes)
    while bytes.positive?
      chunk = io.read([bytes, CHUNK].min)
      raise 'truncated tar payload' if chunk.nil? || chunk.empty?

      bytes -= chunk.bytesize
    end
  end

  def validate_headers(io)
    loop do
      block = io.read(512)
      raise 'truncated tar header' unless block&.bytesize == 512

      if block == ZERO_BLOCK
        validate_trailer(io)
        return
      end

      header = validate_header(block)
      drain_exact(io, ((header.size + 511) / 512) * 512)
    end
  end

  def validate_trailer(io)
    raise 'missing tar trailer' unless io.read(512) == ZERO_BLOCK

    while (tail = io.read(CHUNK))
      raise 'unexpected trailing tar data' unless tail.delete("\0").empty?
    end
  end

  def validate_header(block)
    checksum_field = block.byteslice(148, 8)
    raise 'invalid tar checksum field' unless /\A[0-7 \x00]+\z/n.match?(checksum_field)

    checked = block.dup
    checked[148, 8] = ' ' * 8
    raise 'tar checksum mismatch' unless checked.bytes.sum == checksum_field.delete("\0 ").to_i(8)
    raise 'unsupported tar format' unless block.byteslice(257, 6) == "ustar\0"

    header = Gem::Package::TarHeader.from(StringIO.new(block))
    raise 'unsupported tar member' unless %w[0 5].include?(header.typeflag)
    raise 'ambiguous tar name' unless raw_field(block, 0, 100) == header.name
    raise 'ambiguous tar prefix' unless raw_field(block, 345, 155) == header.prefix
    raise 'unexpected tar link' unless header.linkname.empty?
    raise 'invalid directory payload' if header.typeflag == '5' && header.size != 0

    header
  end

  def member_name(entry)
    header = entry.header
    name = header.prefix.empty? ? header.name : "#{header.prefix}/#{header.name}"
    name = name.delete_suffix('/') if entry.directory?
    parts = name.split('/', -1)
    if name.empty? || name.include?("\0") || parts.any? { |part| ['', '.', '..'].include?(part) }
      raise 'unsafe archive path'
    end

    name
  end

  def checked_members(reader, identity)
    seen = {}
    marker_valid = false
    executable = false
    reader.each do |entry|
      name = member_name(entry)
      if seen.key?(name) || private?(name) || !(allowed?(name) || name == 'RELEASE_ID') ||
         !(entry.directory? || entry.file?)
        raise 'unsafe archive member'
      end
      seen[name] = entry.directory?
      if name == 'RELEASE_ID'
        marker_valid = entry.file? && entry.header.size == identity.bytesize + 1 &&
                       entry.read == "#{identity}\n"
      elsif name == 'bin/residency_schedule'
        executable = entry.file? && (entry.header.mode & 0o111).positive?
      end
    end
    validate_parents(seen)
    raise 'wrong release identity or missing executable' unless marker_valid && executable

    reader.rewind
  end

  def validate_parents(seen)
    seen.each_key do |name|
      parent = File.dirname(name)
      until parent == '.'
        raise 'invalid archive parent' if seen.key?(parent) && !seen[parent]

        parent = File.dirname(parent)
      end
    end
  end

  def copy_contents(incoming, outgoing)
    while (chunk = incoming.read(CHUNK)) && !chunk.empty?
      outgoing.write(chunk)
    end
  end

  def open_archive(path, identity)
    Tempfile.create('release-validation-') do |raw|
      raw.binmode
      Zlib::GzipReader.open(path) do |gzip|
        copy_contents(gzip, raw)
        raise 'unexpected gzip suffix' if gzip.unused && !gzip.unused.empty?
      end
      raw.rewind
      validate_headers(raw)
      raw.rewind
      Gem::Package::TarReader.new(raw) do |reader|
        checked_members(reader, identity)
        yield reader if block_given?
      end
    end
  end

  def verified_tar(path, manifest, identity, &block)
    raise 'linked artifact' if File.symlink?(path) || File.symlink?(manifest)

    checksum = digest(path)
    address = /-([0-9a-f]{64})\.tar\.gz\z/.match(File.basename(path))
    unless File.read(manifest).split == [checksum, File.basename(path)] &&
           (!address || address[1] == checksum)
      raise 'checksum mismatch'
    end

    open_archive(path, identity, &block)
  end

  def collect(root, path, relative, ancestors, entries)
    return if private?(relative)

    target = File.realpath(path)
    raise 'external link' unless target.start_with?("#{root}/")

    resolved_name = target.delete_prefix("#{root}/")
    raise 'external or private link' unless allowed?(resolved_name) && !private?(resolved_name)

    if File.directory?(target)
      raise 'cyclic link' if ancestors.include?(target)

      entries << [relative, target, true]
      Dir.children(target).sort.each do |child|
        collect(root, File.join(target, child), "#{relative}/#{child}", ancestors + [target], entries)
      end
    elsif File.file?(target)
      entries << [relative, target, false]
    else
      raise 'special file'
    end
  end

  def retained_snapshot(root, output, identity)
    marker = File.join(root, 'ARTIFACT_ID')
    return unless present?(marker)

    raise 'invalid previous artifact identity' if File.symlink?(marker)

    artifact_id = File.read(marker).strip
    pattern = /\A#{Regexp.escape(identity)}-[0-9a-f]{64}\z/
    raise 'invalid previous artifact identity' unless pattern.match?(artifact_id)

    verified_tar(*archive_paths(output, artifact_id), identity)
    artifact_id
  end

  def archive_paths(output, name)
    [File.join(output, "#{name}.tar.gz"), File.join(output, "#{name}.sha256")]
  end

  def package_entries(root, snapshot)
    unless snapshot
      Find.find(root) { |path| raise 'configuration in build' if File.basename(path).start_with?('.env') }
    end
    entries = []
    Dir.children(root).sort.each do |child|
      collect(root, File.join(root, child), child, [], entries) if allowed?(child)
    end
    executable = entries.any? do |relative, _, directory|
      relative == 'bin/residency_schedule' && !directory
    end
    raise 'missing release' unless executable

    entries
  end

  def add_tar_entry(archive, relative, target, directory)
    mode = File.stat(target).mode & 0o777
    return archive.mkdir(relative, mode) if directory

    archive.add_file_simple(relative, mode, File.size(target)) do |stream|
      File.open(target, 'rb') { |incoming| copy_contents(incoming, stream) }
    end
  end

  def build_tarfile(temporary, entries, identity)
    temporary.binmode
    gzip = Zlib::GzipWriter.new(temporary)
    gzip.mtime = 0
    Gem::Package::TarWriter.new(gzip) do |archive|
      entries.each { |entry| add_tar_entry(archive, *entry) }
      archive.add_file_simple('RELEASE_ID', 0o644, identity.bytesize + 1) do |stream|
        stream.write("#{identity}\n")
      end
    end
    gzip.finish
    temporary.flush
  end

  def persist_package(temporary, output, name, identity)
    final, manifest = archive_paths(output, name)
    if present?(final) || present?(manifest)
      verified_tar(final, manifest, identity)
      return name
    end

    File.rename(temporary.path, final)
    File.write(manifest, "#{digest(final)}  #{File.basename(final)}\n")
    name
  end

  def write_package(root, output, identity, snapshot: false)
    root = File.realpath(root)
    FileUtils.mkdir_p(output, mode: 0o700)
    retained = retained_snapshot(root, output, identity) if snapshot
    return retained if retained

    name = snapshot ? identity : "release-#{identity}"
    final, manifest = archive_paths(output, name)
    if present?(final) || present?(manifest)
      verified_tar(final, manifest, identity)
      return name
    end

    entries = package_entries(root, snapshot)
    Tempfile.create(['.pack-', '.tar.gz'], output) do |temporary|
      build_tarfile(temporary, entries, identity)
      open_archive(temporary.path, identity)
      name = "#{identity}-#{digest(temporary.path)}" if snapshot
      persist_package(temporary, output, name, identity)
    end
  end

  def extract_member(entry, destination)
    target = File.join(destination, member_name(entry))
    return FileUtils.mkdir_p(target) if entry.directory?

    FileUtils.mkdir_p(File.dirname(target))
    File.open(target, File::WRONLY | File::CREAT | File::EXCL, 0o600) do |outgoing|
      copy_contents(entry, outgoing)
    end
    File.chmod(entry.header.mode & 0o777, target)
  end

  def retain_archive(path, retained, identity)
    FileUtils.mkdir_p(retained, mode: 0o700)
    artifact_id = "#{identity}-#{digest(path)}"
    saved, saved_manifest = archive_paths(retained, artifact_id)
    if present?(saved) || present?(saved_manifest)
      verified_tar(saved, saved_manifest, identity)
      raise 'artifact identity collision' unless digest(saved) == digest(path)
    else
      FileUtils.copy_file(path, saved)
      File.write(saved_manifest, "#{digest(saved)}  #{File.basename(saved)}\n")
    end
    artifact_id
  end

  def stage(source, identity, destination, retained)
    path, manifest = archive_paths(source, "release-#{identity}")
    verified_tar(path, manifest, identity) do |reader|
      Dir.mkdir(destination, 0o700)
      reader.each { |entry| extract_member(entry, destination) }
    end
    artifact_id = retain_archive(path, retained, identity)
    File.write(File.join(destination, 'ARTIFACT_ID'), "#{artifact_id}\n")
  end

  def main(arguments)
    command, *values = arguments
    case command
    when 'package', 'snapshot'
      raise 'invalid arguments' unless values.length == 3

      root, output, identity = values
      raise 'invalid release identity' if command == 'package' && !/\A[0-9a-f]{40}\z/.match?(identity)

      artifact_id = write_package(root, output, identity, snapshot: command == 'snapshot')
      puts artifact_id if command == 'snapshot'
    when 'stage'
      raise 'invalid arguments' unless values.length == 4

      stage(*values)
    else
      raise 'invalid operation'
    end
  end
end

begin
  ReleaseArtifact.main(ARGV)
rescue StandardError
  warn 'Release artifact validation or packaging failed'
  exit 1
end
