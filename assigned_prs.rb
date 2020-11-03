#!/usr/bin/env ruby

require 'optparse'
require "graphql/client"
require "graphql/client/http"

options = {}
options[:oauth] = ENV['GITHUB_COMMUNITY_TOKEN'] if ENV['GITHUB_COMMUNITY_TOKEN']
parser = OptionParser.new do |opts|
  opts.banner = 'Usage: stats.rb [options]'
  opts.on('-u MANDATORY', '--url=MANDATORY', String, 'Link to json file for tools') { |v| options[:url] = v }
  opts.on('-d','--date DATE','Check from date') { |v| options[:date] = v }
  opts.on('-t', '--oauth-token TOKEN', 'OAuth token. Required.') { |v| options[:oauth] = v }
end

parser.parse!

options[:url] = 'https://puppetlabs.github.io/iac/tools.json' if options[:url].nil?
options[:date] = '31-05-2020' if options[:date].nil?
missing = []
missing << '-t' if options[:oauth].nil?
unless missing.empty?
  puts "Missing options: #{missing.join(', ')}"
  puts parser
  exit
end

HTTP = GraphQL::Client::HTTP.new("https://api.github.com/graphql") do
  define_method(:headers) do |context|
    # Optionally set any HTTP headers
    { "Authorization": "bearer #{options[:oauth]}" }
  end
end

# Fetch latest schema on init, this will make a network request
if File.exist?('github_schema.json')
  Schema = GraphQL::Client.load_schema("github_schema.json")
else
  Schema = GraphQL::Client.load_schema(HTTP)
  GraphQL::Client.dump_schema(HTTP, "github_schema.json")
end

Client = GraphQL::Client.new(schema: Schema, execute: HTTP)

TeamReposQuery = Client.parse <<~'GRAPHQL'
  query ($organization: String = "puppetlabs", $teamSlug: String = "modules", $repoPageSize: Int = 100, $repoCursor: String) {
    organization(login: $organization) {
      team(slug: $teamSlug) {
        id
        combinedSlug
        repositories(first: $repoPageSize, after: $repoCursor, orderBy: {field: NAME, direction: ASC}) {
          totalCount
          edges {
            node {
              id
              name
              owner {
                id
                login
              }
            }
            cursor
          }
          pageInfo {
            endCursor
            hasNextPage
          }
        }
      }
    }
  }
GRAPHQL


AssignedPrsQuery = Client.parse <<~'GRAPHQL'
  query ($organization: String = "puppetlabs", $repoName: String!, $prPageSize: Int = 100, $prCursor: String) {
    repository(name: $repoName, owner: $organization) {
      id
      name
      pullRequests(first: $prPageSize, after: $prCursor, orderBy: {field: UPDATED_AT, direction: DESC}) {
        totalCount
        edges {
          node {
            id
            title
            updatedAt
            assignees(first: 20) {
              nodes {
                id
                login
              }
              totalCount
            }
          }
          cursor
        }
        pageInfo {
          endCursor
          hasNextPage
        }
      }
    }
  }
GRAPHQL

def process_results(query:, variables: {}, cursor_name:, connection:)
  results = Client.query(query, variables: variables)
  while c = connection.call(results)
    c.edges.each do |edge|
      yield edge.node
    end

    break unless c.page_info.has_next_page

    results = Client.query(query, variables: variables.merge({cursor_name => c.edges.last.cursor}))
  end
end

pr_count = 0
assigned_pr_count = Hash.new { 0 }
last_week = Time.new - (7*24*60*60)

process_results(
  query: TeamReposQuery,
  variables: {},
  cursor_name: :repoCursor,
  connection: Proc.new { |result| result.data.organization.team.repositories }
) do |repo|
  # next if repo.name == 'provision_service'
  # puts({ organization: repo.owner.login, repoName: repo.name }.inspect)
  process_results(
    query: AssignedPrsQuery,
    variables: { organization: repo.owner.login, repoName: repo.name },
    cursor_name: :prCursor,
    connection: Proc.new {|result| result.data.repository.pull_requests }
  ) do |pr|
    next if Time.parse(pr.updated_at) < last_week
    # puts "#{pr.updated_at}, #{pr.title}"
    pr_count += 1
    pr.assignees.nodes.each do |assignee|
      assigned_pr_count[assignee.login] += 1
    end
  end
end


puts( {prs_total: pr_count, assigned_prs: assigned_pr_count })
