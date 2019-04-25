#!/usr/bin/env ruby

require "open-uri"
require "csv"

require "bundler/inline"

gemfile do
  source "https://rubygems.org"
  gem "tablesmith"
  gem "activesupport"
end

require "tablesmith"
require "active_support"

def latest_reliable_server_list
  url = "https://public-dns.info/nameservers.csv"

  download = open(url)
  CSV.new(download, headers: true).
    select { |r| r["reliability"].to_f > 0.95 }
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

registrar_nameservers = `whois clabs.org`.scan(/Name Server: (\S+).*/).flatten
puts "Registrar Nameservers:"
puts "======================"
puts group_by_domains(registrar_nameservers.uniq)
puts

ips = [{country_id: "US", name: "google", ip: "8.8.8.8", },
       {country_id: "US", name: "cloudflare", ip: "1.1.1.1", }] + latest_reliable_us_servers

results = ips.map do |r|
  print "."
  r[:result] = group_by_domains(`dig @#{r[:ip]} ns clabs.org +short +time=1`.split("\n"))
  r
end
puts
puts results.to_table.pretty_inspect