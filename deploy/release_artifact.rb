#!/usr/bin/env ruby
# frozen_string_literal: true

# Retain only the credential-free, executable portion of a standard Mix release.
require 'digest'
require 'fileutils'
require 'find'
require 'rubygems/package'
require 'stringio'
require 'tempfile'
require 'zlib'

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
        raise 'missing tar trailer' unless io.read(512) == ZERO_BLOCK

        while (tail = io.read(CHUNK))
          raise 'unexpected trailing tar data' unless tail.delete("\0").empty?
        end
        return
      end

      checksum_field = block.byteslice(148, 8)
      raise 'invalid tar checksum field' unless /\A[0-7 \x00]+\z/n.match?(checksum_field)

      checksum = checksum_field.delete("\0 ").to_i(8)
      checked = block.dup
      checked[148, 8] = ' ' * 8
      raise 'tar checksum mismatch' unless checked.bytes.sum == checksum
      raise 'unsupported tar format' unless block.byteslice(257, 6) == "ustar\0"

      header = Gem::Package::TarHeader.from(StringIO.new(block))
      raise 'unsupported tar member' unless %w[0 5].include?(header.typeflag)
      raise 'ambiguous tar name' unless raw_field(block, 0, 100) == header.name
      raise 'ambiguous tar prefix' unless raw_field(block, 345, 155) == header.prefix
      raise 'unexpected tar link' unless header.linkname.empty?
      raise 'invalid directory payload' if header.typeflag == '5' && header.size != 0

      drain_exact(io, ((header.size + 511) / 512) * 512)
    end
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
        executable = entry.file? && (entry.header.mode & 0111).positive?
      end
    end
    seen.each_key do |name|
      parent = File.dirname(name)
      until parent == '.'
        raise 'invalid archive parent' if seen.key?(parent) && !seen[parent]

        parent = File.dirname(parent)
      end
    end
    raise 'wrong release identity or missing executable' unless marker_valid && executable

    reader.rewind
  end

  def open_archive(path, identity)
    Tempfile.create('release-validation-') do |raw|
      raw.binmode
      Zlib::GzipReader.open(path) do |gzip|
        while (chunk = gzip.read(CHUNK)) && !chunk.empty?
          raw.write(chunk)
        end
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
    raise 'external link' unless target.start_with?(root + '/')

    resolved_name = target.delete_prefix(root + '/')
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

  def write_package(root, output, identity, snapshot: false)
    root = File.realpath(root)
    FileUtils.mkdir_p(output, mode: 0700)
    marker = File.join(root, 'ARTIFACT_ID')
    if snapshot && present?(marker)
      artifact_id = File.read(marker).strip
      raise 'invalid previous artifact identity' if File.symlink?(marker) ||
                                                  !/\A#{Regexp.escape(identity)}-[0-9a-f]{64}\z/.match?(artifact_id)

      verified_tar(File.join(output, artifact_id + '.tar.gz'), File.join(output, artifact_id + '.sha256'), identity)
      return
    end
    name = snapshot ? identity : 'release-' + identity
    final = File.join(output, name + '.tar.gz')
    manifest = File.join(output, name + '.sha256')
    if present?(final) || present?(manifest)
      verified_tar(final, manifest, identity)
      return
    end
    unless snapshot
      Find.find(root) { |path| raise 'configuration in build' if File.basename(path).start_with?('.env') }
    end
    entries = []
    Dir.children(root).sort.each do |child|
      collect(root, File.join(root, child), child, [], entries) if allowed?(child)
    end
    raise 'missing release' unless entries.any? { |relative, _, directory| relative == 'bin/residency_schedule' && !directory }

    Tempfile.create(['.pack-', '.tar.gz'], output) do |temporary|
      temporary.binmode
      gzip = Zlib::GzipWriter.new(temporary)
      gzip.mtime = 0
      Gem::Package::TarWriter.new(gzip) do |archive|
        entries.each do |relative, target, directory|
          mode = File.stat(target).mode & 0777
          if directory
            archive.mkdir(relative, mode)
          else
            archive.add_file_simple(relative, mode, File.size(target)) do |stream|
              File.open(target, 'rb') do |incoming|
                while (chunk = incoming.read(CHUNK))
                  stream.write(chunk)
                end
              end
            end
          end
        end
        archive.add_file_simple('RELEASE_ID', 0644, identity.bytesize + 1) { |stream| stream.write("#{identity}\n") }
      end
      gzip.finish
      temporary.flush
      open_archive(temporary.path, identity)
      if snapshot
        artifact_id = identity + '-' + digest(temporary.path)
        final = File.join(output, artifact_id + '.tar.gz')
        manifest = File.join(output, artifact_id + '.sha256')
        if present?(final) || present?(manifest)
          verified_tar(final, manifest, identity)
          return
        end
      end
      File.rename(temporary.path, final)
      File.write(manifest, "#{digest(final)}  #{File.basename(final)}\n")
    end
  end

  def stage(source, identity, destination, retained)
    path = File.join(source, "release-#{identity}.tar.gz")
    manifest = File.join(source, "release-#{identity}.sha256")
    verified_tar(path, manifest, identity) do |reader|
      Dir.mkdir(destination, 0700)
      reader.each do |entry|
        target = File.join(destination, member_name(entry))
        if entry.directory?
          FileUtils.mkdir_p(target)
        else
          FileUtils.mkdir_p(File.dirname(target))
          File.open(target, File::WRONLY | File::CREAT | File::EXCL, 0600) do |outgoing|
            while (chunk = entry.read(CHUNK)) && !chunk.empty?
              outgoing.write(chunk)
            end
          end
          File.chmod(entry.header.mode & 0777, target)
        end
      end
    end
    FileUtils.mkdir_p(retained, mode: 0700)
    artifact_id = identity + '-' + digest(path)
    saved = File.join(retained, artifact_id + '.tar.gz')
    saved_manifest = File.join(retained, artifact_id + '.sha256')
    if present?(saved) || present?(saved_manifest)
      verified_tar(saved, saved_manifest, identity)
      raise 'artifact identity collision' unless digest(saved) == digest(path)
    else
      FileUtils.copy_file(path, saved)
      File.write(saved_manifest, "#{digest(saved)}  #{File.basename(saved)}\n")
    end
    File.write(File.join(destination, 'ARTIFACT_ID'), artifact_id + "\n")
  end

  def main(arguments)
    command, *values = arguments
    case command
    when 'package', 'snapshot'
      raise 'invalid arguments' unless values.length == 3

      root, output, identity = values
      raise 'invalid release identity' if command == 'package' && !/\A[0-9a-f]{40}\z/.match?(identity)

      write_package(root, output, identity, snapshot: command == 'snapshot')
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
