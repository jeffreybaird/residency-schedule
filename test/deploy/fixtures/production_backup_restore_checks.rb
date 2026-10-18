#!/usr/bin/env ruby
# frozen_string_literal: true

# Read-only verification and preflight for decrypted SYNTHETIC backups only.
# Database/role creation and pg_restore remain separately reviewed operations.
require 'digest'
require 'json'
require 'open3'
require 'time'

module SyntheticRestoreChecks
  NEW_CLUSTER = '7697672234186579740'
  SOURCE_DATABASE = 'residency_schedule_prod'
  module_function

  class UniqueObject < Hash
    def []=(key, value)
      raise 'duplicate JSON key' if key?(key)

      super
    end
  end

  def private_directory!(path)
    raise 'private canonical directory required' unless File.directory?(path) && !File.symlink?(path) &&
      File.realpath(path) == File.expand_path(path) && (File.stat(path).mode & 0o777) == 0o700
  end

  def private_file!(path)
    raise 'private canonical regular file required' unless File.file?(path) && !File.symlink?(path) &&
      File.realpath(path) == File.expand_path(path) && (File.stat(path).mode & 0o777) == 0o600
  end

  def json(path)
    private_file!(path)
    JSON.parse(File.read(path), object_class: UniqueObject)
  end

  def qualified(value)
    parts = value.split('.')
    raise 'unsupported identifier' unless parts.length == 2 &&
      parts.all? { |part| part.bytesize <= 63 && /\A[a-z][a-z0-9_]*\z/.match?(part) }

    parts.map { |part| %Q("#{part}") }.join('.')
  end

  def psql(config, database, sql)
    environment = ENV.keys.grep(/\APG/).to_h { |key| [key, nil] }.merge(
      'PGPASSFILE' => '/dev/null', 'PGCONNECT_TIMEOUT' => '5')
    output, _error, status = Open3.capture3(environment, '/usr/sbin/runuser', '-u', 'postgres', '--',
      config.fetch('psql_path'), '--host', config.fetch('pg_host'), '--port', '5544',
      '--username', 'postgres', '--dbname', database, '--no-password', '-X', '-qAt',
      '--set', 'ON_ERROR_STOP=1', stdin_data: "BEGIN READ ONLY;\nSET LOCAL search_path=pg_catalog;\nSET LOCAL DateStyle=ISO;\nSET LOCAL TimeZone=UTC;\n#{sql};\nCOMMIT;\n")
    raise 'isolated read-only query failed' unless status.success?

    output.strip
  end

  def guarded_cluster!(config, database)
    actual = JSON.parse(psql(config, database, <<~SQL))
      SELECT json_build_object('identifier',system_identifier::text,'database',current_database(),
        'port',current_setting('port'),'primary',NOT pg_is_in_recovery()) FROM pg_control_system()
    SQL
    raise 'actual isolated cluster mismatch' unless actual == {
      'identifier' => NEW_CLUSTER, 'database' => database, 'port' => '5544', 'primary' => true}
  end

  def main(arguments)
    operation, config_path, directory = arguments
    raise 'unsupported fixture operation' unless %w[preflight verify].include?(operation) && arguments.length == 3
    raise 'root fixture caller required' unless Process.uid.zero?
    raise 'production installation forbidden' if File.exist?('/home/deploy/residency_schedule')

    private_directory!(File.dirname(File.expand_path(config_path)))
    config = json(config_path)
    keys = %w[expected_cluster_identifier pg_host pg_port psql_path target_database source_helper_path]
    raise 'unsupported fixture configuration' unless (config.keys - keys).empty?
    raise 'new synthetic cluster required' unless config.fetch('expected_cluster_identifier') == NEW_CLUSTER && config.fetch('pg_port') == 5544
    host = config.fetch('pg_host')
    raise 'local socket required' unless host.start_with?('/') && !host.match?(/[\x00-\x20:,=]/)
    raise 'absolute psql required' unless config.fetch('psql_path').start_with?('/') && File.executable?(config.fetch('psql_path'))
    target = config.fetch('target_database')
    raise 'fresh disposable target required' unless target.bytesize <= 63 &&
      /\Aresidency_schedule_recovery_[a-z0-9][a-z0-9_]*\z/.match?(target) &&
      !target.start_with?('residency_schedule_recovery_source_')

    private_directory!(directory)
    raise 'unexpected plaintext bundle files' unless Dir.children(directory).sort == %w[database.dump manifest.json]
    private_file!(File.join(directory, 'database.dump'))
    manifest = json(File.join(directory, 'manifest.json'))
    raise 'synthetic production-format manifest required' unless manifest['schema_version'] == 1 &&
      manifest['profile'] == 'production' && manifest['source_database'] == SOURCE_DATABASE &&
      manifest['cluster_identifier'] == NEW_CLUSTER && manifest['sequence_state'] == 'archive_authoritative_non_mvcc'
    raise 'dump and manifest pairing mismatch' unless manifest['dump_sha256'] == Digest::SHA256.file(File.join(directory, 'database.dump')).hexdigest
    Time.iso8601(manifest.fetch('snapshot_started_at'))

    guarded_cluster!(config, SOURCE_DATABASE)
    if operation == 'preflight'
      absent = psql(config, SOURCE_DATABASE,
        "SELECT NOT EXISTS(SELECT 1 FROM pg_database WHERE datname='#{target}')")
      raise 'existing target refused' unless absent == 't'

      puts JSON.generate(preflight_complete: true, new_synthetic_cluster: true,
        target_absent: true, dump_pairing_verified: true)
      return
    end

    guarded_cluster!(config, target)
    helper = config.fetch('source_helper_path')
    raise 'trusted root-owned source helper required' unless File.file?(helper) && !File.symlink?(helper) &&
      File.realpath(helper) == File.expand_path(helper) && File.stat(helper).uid.zero? &&
      (File.stat(helper).mode & 0o022).zero?
    ancestor = File.dirname(helper)
    loop do
      stat = File.stat(ancestor)
      raise 'mutable source helper ancestor refused' unless stat.directory? && stat.uid.zero? &&
        (stat.mode & 0o022).zero? && File.realpath(ancestor) == ancestor
      break if ancestor == '/'

      ancestor = File.dirname(ancestor)
    end

    require helper
    actual = JSON.parse(psql(config, target, ProductionBackup.inventory_sql))
    raise 'unsupported restored objects' unless actual.fetch('unsupported').empty?
    tables = actual.fetch('tables').to_h do |table|
      raw = psql(config, target, <<~SQL)
        SELECT COALESCE(jsonb_agg(to_jsonb(t) ORDER BY to_jsonb(t)::text COLLATE "C"),'[]'::jsonb)::text
        FROM #{qualified(table)} t
      SQL
      rows = JSON.parse(raw)
      raise 'table JSON array required' unless rows.is_a?(Array)

      [table, {'count' => rows.length, 'sha256' => Digest::SHA256.hexdigest(raw)}]
    end
    actual['tables'] = tables
    expected = manifest.fetch('inventory')
    %w[tables sequences schema constraints extensions migrations unsupported].each do |key|
      raise 'restored manifest coverage mismatch' unless expected.key?(key) && actual[key] == expected[key]
    end

    owned = JSON.parse(psql(config, target, <<~SQL))
      SELECT COALESCE(jsonb_agg(jsonb_build_object(
        'sequence',format('%I.%I',ns.nspname,q.relname),
        'table',format('%I.%I',nt.nspname,t.relname),'column',a.attname,
        'increment',s.seqincrement,'min',s.seqmin,'max',s.seqmax,'cycle',s.seqcycle) ORDER BY ns.nspname,q.relname),'[]'::jsonb)
      FROM pg_sequence s JOIN pg_class q ON q.oid=s.seqrelid JOIN pg_namespace ns ON ns.oid=q.relnamespace
      JOIN pg_depend d ON d.classid='pg_class'::regclass AND d.objid=q.oid
        AND d.refclassid='pg_class'::regclass AND d.deptype IN ('a','i')
      JOIN pg_class t ON t.oid=d.refobjid JOIN pg_namespace nt ON nt.oid=t.relnamespace
      JOIN pg_attribute a ON a.attrelid=t.oid AND a.attnum=d.refobjsubid
      WHERE nt.nspname !~ '^pg_' AND nt.nspname<>'information_schema'
    SQL
    raise 'owned sequence safety coverage required' if owned.empty?
    owned.each do |entry|
      raise 'unsupported owned sequence direction or cycle' unless entry.fetch('increment').positive? && entry.fetch('cycle') == false
      values = JSON.parse(psql(config, target,
        "SELECT json_build_object('last_value',last_value,'is_called',is_called) FROM #{qualified(entry.fetch('sequence'))}"))
      next_value = values.fetch('last_value') + (values.fetch('is_called') ? entry.fetch('increment') : 0)
      raise 'restored owned sequence is exhausted or outside bounds' unless next_value.between?(entry.fetch('min'), entry.fetch('max'))
      column = entry.fetch('column')
      raise 'unsupported owning column' unless column.bytesize <= 63 && /\A[a-z][a-z0-9_]*\z/.match?(column)
      maximum = psql(config, target, "SELECT max(\"#{column}\")::text FROM #{qualified(entry.fetch('table'))}")
      next if maximum.empty?

      raise 'restored sequence could collide with existing identity' unless next_value > Integer(maximum)
    end
    puts JSON.generate(full_row_fingerprints: true, owner_neutral_schema: true,
      constraints_extensions_migrations: true, table_count: tables.length,
      owned_sequence_safety: true, checked_owned_sequences: owned.length,
      sequence_snapshot_equality_claimed: false)
  end
end

begin
  SyntheticRestoreChecks.main(ARGV)
rescue StandardError
  warn 'guarded synthetic restore verification failed'
  exit 1
end
