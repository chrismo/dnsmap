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
    @result = group_by_domains(dig)
    yield result_type if block_given?
    @result
  end

  def authoritative_ns_records
    registrar_name_servers
  end

  private

  def result_type
    if @result =~ /^DigError/
      :error
    elsif @result != authoritative
      :mismatch
    else
      :match
    end
  end

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
  def initialize(domain, geo_area)
    @domain = domain
    @geo_area = ["global", "us"].include?(geo_area) ? geo_area : "global"
  end

  def execute
    @authoritative = Digger.new(nil, @domain).authoritative_ns_records
    dns_results
  end

  def dns_results
  puts "Authoritative"
  puts "============="
    puts @authoritative
  puts

    lookup_ips

  # TODO: threaded lookups
  queue = Queue.new
    @ips.each { |ip| queue.push(ip) }

  puts "Checking #{ips.length} servers"
    results = @ips.map do |r|
      r[:result] = Digger.new(r[:ip], @domain).dig_ns_records do |server_result|
        case server_result
        when :error
        print "e"
        when :mismatch
        print "x"
      else
        print "."
      end
    end
    r
  end
  puts
  puts results.to_table.pretty_inspect
end

  private

  def lookup_ips
    @ips = [{country_id: "US", name: "google", ip: "8.8.8.8", },
            {country_id: "US", name: "cloudflare", ip: "1.1.1.1", }] +
      Servers.send("latest_reliable_#{@geo_area}_servers")
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
Aggregator.new(domain, geo_area).execute
