#!/usr/bin/env ruby

require "open-uri"
require "csv"

require "bundler/inline"

gemfile do
  source "https://rubygems.org"
  gem "tablesmith"
  gem "activesupport"
  gem "dnsruby"
end

require "tablesmith"
require "active_support"

class Servers
  def self.latest_reliable_server_list
    url = "https://public-dns.info/nameservers.csv"

    download = open(url)
    CSV.new(download, headers: true).
      select { |r| r["reliability"].to_f >= 0.96 }.
      select { |r| r["ip"] =~ /\d+\.\d+\.\d+\.\d+/ }
  end

  def self.latest_reliable_global_servers
    latest_reliable_server_list.
      group_by { |r| r["country_id"] }.
      map { |_, rows| rows.first }.
      map { |row| {country_id: row["country_id"], name: row["name"], ip: row["ip"]} }
  end

  def self.latest_reliable_us_servers
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

    registrar_nameservers = `whois #{@domain}`.scan(/Name Server: (\S+).*/).flatten
    @result = group_by_domains(registrar_nameservers)
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
  attr_reader :authoritative, :ips, :results

  def initialize(domain, geo_area)
    @domain = domain
    @geo_area = ["global", "us"].include?(geo_area) ? geo_area : "global"
    lookup_authoritative
    lookup_ips
  end

  def dns_results
  # TODO: threaded lookups
  queue = Queue.new
    @ips.each { |ip| queue.push(ip) }

    @results = @ips.map do |r|
      r[:result] = Digger.new(r[:ip], @domain).dig_ns_records do |server_result|
        yield result_type(server_result) if block_given?
        server_result
    end
    r
  end
end

  private

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
    @ips = [{country_id: "US", name: "google", ip: "8.8.8.8", },
            {country_id: "US", name: "cloudflare", ip: "1.1.1.1", }] +
      Servers.send("latest_reliable_#{@geo_area}_servers")
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

    puts "Checking #{@aggregator.ips.length} servers"

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

def usage
  puts "Usage: #{File.basename(__FILE__)} [domain ['us' or 'global']]"
end

domain = ARGV[0]
if domain.nil?
  usage
  exit(1)
end

# TODO: options: filter out matches in table, and reliability factor

geo_area = ARGV[1]
ConsoleOutput.new(Aggregator.new(domain, geo_area))
