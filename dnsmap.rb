#!/usr/bin/env ruby

require "open-uri"
require "csv"

require "bundler/inline"

gemfile do
  source "https://rubygems.org"
  gem "tablesmith"
  gem "activesupport"
  gem "dnsruby"
  gem "slop", "~> 4"
end

require "tablesmith"
require "active_support"
require "slop"

class Servers
  attr_reader :total_count

  def initialize(reliability_threshold = 96)
    @reliability_threshold = reliability_threshold * 0.01
  end

  def latest_reliable_server_list
    url = "https://public-dns.info/nameservers.csv"

    download = open(url)

    # select true is to read all the rows first, so then it's easy to get a count
    CSV.new(download, headers: true).
      select { true }.
      tap { |ary| @total_count = ary.count }.
      select { |r| r["reliability"].to_f >= @reliability_threshold }.
      select { |r| r["ip"] =~ /\d+\.\d+\.\d+\.\d+/ }
  end

  def latest_reliable_global_servers_one_per_country
    latest_reliable_server_list.
      group_by { |r| r["country_id"] }.
      map { |_, rows| rows.first }.
      map { |row| {country_id: row["country_id"], name: row["name"], ip: row["ip"]} }
  end

  def latest_reliable_global_servers
    latest_reliable_server_list.
      map { |row| {country_id: row["country_id"], name: row["name"], ip: row["ip"]} }
  end

  def latest_reliable_us_servers
    latest_reliable_server_list.
      select { |r| r["country_id"] == "US" }.
      map { |row| {country_id: row["country_id"], name: row["name"], ip: row["ip"]} }
  end
end

class Digger
  class DigError < StandardError;
  end

  attr_reader :result

  def initialize(dns_server_ip, domain)
    @dns_server_ip = dns_server_ip
    @domain = domain
  end

  def dig_ns_records
    @result = group_by_domains(dig).tap { |r| yield r if block_given? }
  end

  def authoritative_ns_records
    registrar_name_servers
  end

  private

  def registrar_name_servers
    # TODO: dnsruby has a Recursor class which is really complicated internally.
    # TODO: \ Trying to re-use it here looks like a lot of work. Cool to be able
    # TODO: \ to do, but, not worth my time right now.

    registrar_name_servers = `whois #{@domain}`.scan(/Name Server: (\S+).*/).flatten
    @result = group_by_domains(registrar_name_servers)
  end

  def dig
    # `dig @#{ip} ns #{domain} +short +time=1`.split("\n")
    opts = {nameserver: @dns_server_ip, do_caching: false, query_timeout: 1}
    Dnsruby::Resolver.new(opts).query(@domain, 'ns').answer.map(&:domainname).map(&:to_s)
  rescue => e
    "DigError: #{e.class.to_s}: #{e.message}"
  end

  def group_by_domains(output)
    return output if output =~ /^DigError/

    output.
      uniq.
      sort.
      map { |ln| ln.downcase.split(/\./) }.
      group_by { |ary| ary[1..2].join(".") }.
      map { |domain, servers| [domain, servers.map(&:first)] }.to_h
  end
end

class Aggregator
  attr_reader :authoritative, :ips, :results, :total_server_count

  def initialize(domain, geo_area, reliability:, diff_only:)
    @domain = domain
    @geo_area = ["global", "us"].include?(geo_area) ? geo_area : "global"
    @reliability = reliability
    @diff_only = diff_only
    lookup_authoritative
    lookup_ips
  end

  def dns_results
    queue = Queue.new
    @ips.each { |ip| queue.push(ip) }

    output_queue = Queue.new

    workers = (0..7).map do
      Thread.new do
        begin
          result_type = nil
          while ip_record = queue.pop(true)
            ip_record[:result] = Digger.new(ip_record[:ip], @domain).dig_ns_records do |server_result|
              # yielding up out of a thread isn't too awesome, but it's only for
              # console output for now, should be fine-ish.
              result_type = result_type(server_result)
              yield result_type if block_given?
              server_result
            end
            if (@diff_only && result_type == :mismatch) || !@diff_only
              output_queue << ip_record
            end
          end
        rescue ThreadError
          # ignored
        end
      end
    end
    workers.map(&:join)

    queue_to_array(output_queue)
  end

  private

  def queue_to_array(queue)
    [].tap do |ary|
      begin
        while item = queue.pop(true)
          ary << item
        end
      rescue ThreadError
        # ignored
      end
    end
  end

  def result_type(server_result)
    if server_result =~ /^DigError/
      :error
    elsif server_result != authoritative
      :mismatch
    else
      :match
    end
  end

  def lookup_authoritative
    @authoritative = Digger.new(nil, @domain).authoritative_ns_records
  end

  def lookup_ips
    servers = Servers.new(@reliability)
    selected_servers = servers.send("latest_reliable_#{@geo_area}_servers")
    @total_server_count = servers.total_count
    @ips = [{country_id: "US", name: "google", ip: "8.8.8.8", },
            {country_id: "US", name: "cloudflare", ip: "1.1.1.1", }] +
      selected_servers
  end
end

class ConsoleOutput
  def initialize(aggregator)
    @aggregator = aggregator
    execute
  end

  def execute
    puts "Authoritative"
    puts "============="
    puts @aggregator.authoritative
    puts

    puts "Checking #{@aggregator.ips.length}/#{@aggregator.total_server_count} servers"

    results = @aggregator.dns_results do |result|
      case result
      when :error
        print 'e'
      when :mismatch
        print 'x'
      else
        print '.'
      end
    end

    puts
    puts results.to_table.pretty_inspect
  end
end

opts = Slop.parse do |o|
  o.banner = "Usage: #{File.basename(__FILE__)} domain ['us' | 'global']"
  o.bool '-d', '--differences-only', 'only list differences from authoritative'
  o.integer '-r', '--reliability', 'server reliability threshold', default: 96
  o.on '-h', '--help' do
    puts o
    exit
  end
end

domain, geo_area = *opts.args
ConsoleOutput.new(Aggregator.new(domain, geo_area,
                                 reliability: opts[:reliability],
                                 diff_only: opts[:differences_only]))
