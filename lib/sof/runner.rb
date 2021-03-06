require 'syslog'

module Sof
class Runner

  attr_accessor :server_concurrency, :check_concurrency, :manifest, :results, :options

  def initialize(manifest, options)
    @server_concurrency ||= 10
    @check_concurrency ||= 5
    @manifest = manifest
    @options = options
  end

  def servers
    manifest['servers'].map do |server_record|
      server_record['username'] ||= manifest['username']
      server_record['port'] ||= manifest['port']
      Sof::Server.new(server_record)
    end
  end

  def run_checks
    @results = []
    @results = Parallel.map_with_index(servers, :in_processes => server_concurrency, :progress => 'Running checks') do |server|
      checks = Sof::Check.load(server.categories, @options)
      check_results = []
      checks.each{ |check| check.options = @options }

      ssh_check = checks.find{ |check| check.name == 'ssh' }
      checks.delete(ssh_check)

      ssh_check_result = { :check => ssh_check, :return => ssh_check.run_check(server) }
      check_results << ssh_check_result

      if ssh_check_result[:return].first[1]['status'] != :pass
        checks.select!{ |check| check.dependencies.nil? || !check.dependencies.include?('ssh') }
      end

      check_results += Parallel.map_with_index(checks, :in_threads => check_concurrency) do |check|
        { :check => check, :return => check.run_check(server) }
      end
      { :server => server, :result => check_results }
    end
  end

  def output_results(verbose = false)
    munged_output = {}
    @results.each do |single_result|
      check_results = []
      check_results << "#{single_result[:result].size} checks completed"
      single_result[:result].each do |check_result|
        if check_result[:return].first[1]['status'] != :pass || options[:verbose]
          check_results << check_result[:return]
        end
      end
      munged_output[single_result[:server].hostname] = check_results
    end
    puts munged_output.to_yaml
  end

  def log_results
    Syslog.open('sof', Syslog::LOG_CONS) do |s|
      @results.each do |single_result|
        server = single_result[:server]
        single_result[:result].each do |check_result|
          result_return = check_result[:return].first[1]
          if result_return['status'] != :pass
            s.err(format_log_message(server, check_result[:check], result_return))
          end
        end
      end
    end
  end

  def format_log_message(server, check, result)
    output = result['output'].nil? ? '-' : result['output'].strip
    "sof #{server.hostname} #{check.name} #{result['status']} #{output}"
  end
end
end
