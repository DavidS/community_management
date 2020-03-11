require 'erb'
require 'optparse'
require_relative 'octokit_utils'

options = {}
options[:oauth] = ENV['GITHUB_COMMUNITY_TOKEN'] if ENV['GITHUB_COMMUNITY_TOKEN']
parser = OptionParser.new do |opts|
  opts.banner = 'Usage: stats.rb [options]'
  opts.on('-f', '--file NAME', String, 'Module file list') { |v| options[:file] = v }
  opts.on('-t', '--oauth-token TOKEN', 'OAuth token. Required.') { |v| options[:oauth] = v }
end

parser.parse!

options[:file] = 'tools.json' if options[:file].nil?

missing = []
missing << '-t' if options[:oauth].nil?
unless missing.empty?
  puts "Missing options: #{missing.join(', ')}"
  puts parser
  exit
end

util = OctokitUtils.new(options[:oauth])
parsed = util.load_module_list(options[:file])

open_prs = []

def does_array_have_pr(array, pr_number)
  found = false
  array.each do |entry|
    found = true if pr_number == entry.number
  end
  found
end

parsed.each do |m|
  sleep(2)
  pr_information_cache = util.fetch_async("#{m['github_namespace']}/#{m['tool_name']}")
  # no comment from a puppet employee
  puppet_uncommented_pulls = util.fetch_pull_requests_with_no_puppet_personnel_comments(pr_information_cache)
  # last comment mentions a puppet person
  mentioned_pulls = util.fetch_pull_requests_mention_member(pr_information_cache)

  # loop through open pr's and create a row that has all the pertinant info
  pr_information_cache.each do |pr|
    sleep(2)
    row = {}
    row[:tool] = m['tool_name']
    row[:address] = "https://github.com/#{m['github_namespace']}/#{m['tool_name']}"
    row[:pr] = pr[:pull].number
    row[:age] = ((Time.now - pr[:pull].created_at) / 60 / 60 / 24).round
    row[:owner] = pr[:pull].user.login
    row[:owner] += " <span class='label label-primary'>iac</span>" if util.iac_member?(pr[:pull].user.login)
    row[:owner] += " <span class='label label-warning'>puppet</span>" if util.puppet_member?(pr[:pull].user.login)
    row[:owner] += " <span class='badge badge-secondary'>vox</span>" if util.voxpupuli_member?(pr[:pull].user.login)
    row[:title] = pr[:pull].title

    if !pr[:issue_comments].empty?

      if pr[:issue_comments].last.user.login =~ /\Acodecov/
        begin
          row[:last_comment] = pr[:issue_comments].body(-2).gsub(%r{<\/?[^>]*>}, '')
        rescue StandardError
          row[:last_comment] = 'No previous comment other than codecov-io'
          row[:by] = ''
        end

      else
        row[:last_comment] = pr[:issue_comments].last.body.gsub(%r{<\/?[^>]*>}, '')
        row[:by] = pr[:issue_comments].last.user.login

      end
      row[:age_comment] = ((Time.now - pr[:issue_comments].last.updated_at) / 60 / 60 / 24).round
    else
      row[:last_comment] = '0 comments'
      row[:by] = ''
      row[:age_comment] = 0
    end

    open_prs.push(row)
  end
end

html = ERB.new(File.read('tools.html.erb')).result(binding)

open_prs.each do |row|
  puts(row)
end

File.open('report_tools.html', 'wb') do |f|
  f.puts(html)
end

File.open('report_tools.json', 'wb') do |f|
  JSON.dump(open_prs, f)
end
