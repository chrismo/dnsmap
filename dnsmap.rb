#!/usr/bin/env ruby

# "Global" is a bit of a misnomer here. A good site for this is
# https://dnschecker.org/. The following dig commands simply cherry-pick a few
# "global" DNS IPs that seemed to give varying results when we were in a
# Primary/Primary setup.
#
# https://public-dns.info/nameserver/ to look up more servers.
#
# Another good general purpose dns site: https://dnslytics.com/


# Download .csv from public-dns.info
#
# Parse it, grab everything .96 reliability or higher, select 1 per country.
# Have at it.
#
# Do a whois to grab the configured nameservers

require "open-uri"
require "csv"

def download_latest_reliable_dns_servers
  url = "https://public-dns.info/nameservers.csv"

  download = open(url)
  CSV.new(download, headers: true).
    select { |r| r["reliability"].to_f > 0.95 }.
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
       {country_id: "US", name: "cloudflare", ip: "1.1.1.1", }] +
  download_latest_reliable_dns_servers

ips.each do |r|
  title = r[:name] || r[:country_id]
  puts title
  puts '-' * title.length
  puts group_by_domains(`dig @#{r[:ip]} ns clabs.org +short +time=1`.split("\n"))
  puts
end