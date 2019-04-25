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

def group_by_domains(output)
  output.
    uniq.
    sort.
    map { |ln| ln.split(/\./) }.
    group_by { |ary| ary[1..2].join(".") }.
    map { |domain, servers| [domain, servers.map(&:first)] }.to_h
end

registrar_nameservers = `whois clabs.org`.scan(/Name Server: (\S+).*/).flatten
puts "Registrar Nameservers:"
puts "======================"
puts group_by_domains(registrar_nameservers.uniq)
puts

ips = [{country_id: "US", name: "google", ip: "8.8.8.8", },
       {country_id: "US", name: "cloudflare", ip: "1.1.1.1", },
       {country_id: "JP", name: "[japan]", ip: "210.225.175.66"},
       {country_id: "DE", name: "mail.lkrauss.de", ip: "213.239.204.35"}]

ips.each do |r|
  puts r[:name]
  puts '-' * r[:name].length
  puts group_by_domains(`dig @#{r[:ip]} ns clabs.org +short`.split("\n"))
  puts
end