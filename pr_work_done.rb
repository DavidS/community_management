#!/usr/bin/env ruby
# frozen_string_literal: true

# This script for every week will calculate:
# the number of closed prs
# the number of merged prs
# the number of comments made on prs

require 'concurrent'
require 'concurrent/executor/fixed_thread_pool'
require 'optparse'
require 'csv'
require 'pry'
require_relative 'octokit_utils'

modules = JSON.parse(File.read('modules.json'))
modules.each { |m| m[:type] = 'module' }
tools = JSON.parse(File.read('tools.json'))
tools.each { |m| m[:type] = 'tool' }
repos = tools + modules

options = { namespace: 'puppetlabs' }
options[:oauth] = ENV['GITHUB_TOKEN'] # if ENV['GITHUB_COMMUNITY_TOKEN']

# thanks, google!
def to_sheets(time)
  time&.getutc&.strftime '%Y-%m-%d %H:%M:%S'
end

# running this too often with a high thread count leads to temporary API lock out
pool = Concurrent::FixedThreadPool.new(2)
# mutex = Mutex.new

pr_futures = []
comment_futures = []

repos.each do |repo_data|
  repo = repo_data['github_namespace'] + '/' + repo_data['repo_name']

  pr_futures << Concurrent::Promises.future_on(pool) do
    util = OctokitUtils.new(options[:oauth])
    puts "#{repo}: fetching PRs"

    fetched_prs = util.client.pulls(repo, state: 'all')

    puts "#{repo}: got #{fetched_prs.length} PRs"
    fetched_prs.map do |pr|
      pr_labels = { feature: 0, enhancement: 0, bugfix: 0, maintenance: 0, all: 0 }
      pr_labels[:"backwards-incompatible"] = 0
      pr.labels.each do |label|
        # label_data << [repo, label.url, pr.url, label.name, pr.created_at]
        pr_labels[label.name.intern] ||= 0
        pr_labels[label.name.intern] += 1
        pr_labels[:all] += 1
      end

      # pr_data << [repo,
      [
        repo,
        pr.html_url,
        pr.user.login,
        pr.author_association,
        pr.state,
        to_sheets(pr.created_at),
        to_sheets(pr.merged_at),
        to_sheets(pr.closed_at),
        repo_data[:type],
        pr_labels[:"backwards-incompatible"],
        pr_labels[:feature] + pr_labels[:enhancement],
        pr_labels[:bugfix],
        pr_labels[:maintenance],
        pr_labels[:all]
      ]
    end
  end

  comment_futures << Concurrent::Promises.future_on(pool) do
    util = OctokitUtils.new(options[:oauth])
    puts "#{repo}: fetching comments"

    comments = util.client.issues_comments(repo, since: Time.new(2018))

    puts "#{repo}: got #{comments.length} comments"
    comments.map do |comment|
      [
        repo,
        comment.html_url,
        comment.user.login,
        comment.author_association,
        to_sheets(comment.created_at),
        to_sheets(comment.updated_at),
        repo_data[:type]
      ]
    end
  end
end

puts 'waiting for results'

pr_data = Concurrent::Promises.zip(*pr_futures).value!.flatten(1)
comment_data = Concurrent::Promises.zip(*comment_futures).value!.flatten(1)

binding.pry

pool.shutdown
pool.wait_for_termination

puts 'writing files'

CSV.open('pr_stats.csv', 'wb') do |pr_file|
  pr_file << %w[repo url author author_association state created_at merged_at closed_at type breaking feature bugfix maintenance all_labels]
  pr_data.each { |d| pr_file << d }
end
CSV.open('comment_stats.csv', 'wb') do |comment_file|
  comment_file << %w[repo comment_url author author_association created_at updated_at type]
  comment_data.each { |d| comment_file << d }
end
# CSV.open('label_stats.csv', 'wb') do |label_file|
#   label_file << %w[repo label_url pr_url name labeled_at]
#   label_data.each { |d| label_file << d }
# end
