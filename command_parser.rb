# command_parser.rb
# encoding: UTF-8
require 'cgi'

require_relative 'commands/location_command'
require_relative 'commands/investigate_command'
require_relative 'commands/acquire_command'
require_relative 'commands/scout_start_command'
require_relative 'commands/scout_end_command'

module CommandParser
  def self.parse(mastodon_client, sheet_manager, notification)
    content_raw = notification.dig('status', 'content') || ''
    sender      = notification.dig('account', 'acct') || ''
    content     = clean_html(content_raw)
    status      = notification['status']

    puts "[PARSER] @#{sender}: #{content}"

    case content
    when /\[위치\/(.+?)\]/
      LocationCommand.new(sheet_manager, mastodon_client, sender, $1.strip, status).execute

    when /\[조사\/(.+?)\]/
      InvestigateCommand.new(sheet_manager, mastodon_client, sender, $1.strip, status).execute

    when /\[획득\/(.+?)\]/
      AcquireCommand.new(sheet_manager, mastodon_client, sender, $1.strip, status).execute

    when /\[조사시작\]/
      ScoutStartCommand.new(sheet_manager, mastodon_client, sender, status).execute

    when /\[조사종료\]/
      ScoutEndCommand.new(sheet_manager, mastodon_client, sender, status).execute

    else
      return
    end

  rescue => e
    puts "[PARSER 오류] #{e.class}: #{e.message}"
  end

  def self.clean_html(html)
    return '' if html.nil?
    CGI.unescapeHTML(
      html.to_s
        .gsub(/<br\s*\/?>/i, "\n")
        .gsub(/<\/p\s*>/i, "\n")
        .gsub(/<p[^>]*>/i, '')
        .gsub(/<[^>]*>/, '')
    ).gsub("\u00A0", ' ').strip
  rescue
    html.to_s
  end
end
