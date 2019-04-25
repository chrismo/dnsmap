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

def latest_reliable_server_list
  url = "https://public-dns.info/nameservers.csv"

  download = open(url)
  CSV.new(download, headers: true).
    select { |r| r["reliability"].to_f > 0.95 }.
    select { |r| r["ip"] =~ /\d+\.\d+\.\d+\.\d+/ }
end

def latest_reliable_global_servers
  latest_reliable_server_list.
    group_by { |r| r["country_id"] }.
    map { |_, rows| rows.first }.
    map { |row| {country_id: row["country_id"], name: row["name"], ip: row["ip"]} }
end

def latest_reliable_us_servers
  latest_reliable_server_list.
    select { |r| r["country_id"] == "US" }.
    map { |row| {country_id: row["country_id"], name: row["name"], ip: row["ip"]} }
end

def group_by_domains(output)
  output.
    uniq.
    sort.
    map { |ln| ln.split(/\./) }.
    group_by { |ary| ary[1..2].join(".") }.
    map { |domain, servers| [domain, servers.map(&:first)] }.to_h
rescue
  output.join.split(";;").last
end

def registrar_nameservers(domain)
  # TODO: dnsruby has a Recursor class which is really complicated internally.
  # TODO: \ Trying to re-use it here looks like a lot of work. Cool to be able
  # TODO: \ to do, but, not worth my time right now.

  registrar_nameservers = `whois #{domain}`.scan(/Name Server: (\S+).*/).flatten
  puts "Registrar Nameservers:"
  puts "======================"
  puts group_by_domains(registrar_nameservers)
  puts
end

def dns_results(domain, geo_area)
  geo_area = ["global", "us"].include?(geo_area) ? geo_area : "global"
  ips = [{country_id: "US", name: "google", ip: "8.8.8.8", },
         {country_id: "US", name: "cloudflare", ip: "1.1.1.1", }] +
    send("latest_reliable_#{geo_area}_servers")

  results = ips.map do |r|
    print "."
    r[:result] = group_by_domains(`dig @#{r[:ip]} ns #{domain} +short +time=1`.split("\n"))
    r
  end
  puts
  puts results.to_table.pretty_inspect
end

def usage
  puts "#{File.basename(__FILE__)} [domain ['us' or 'global']]"
end

domain = ARGV[0]
if domain.nil?
  usage; exit(1)
end

geo_area = ARGV[1]
registrar_nameservers domain
dns_results domain, geo_area