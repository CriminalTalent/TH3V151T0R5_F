# command_parser.rb
# encoding: UTF-8
require 'cgi'

require_relative 'commands/location_command'
require_relative 'commands/investigate_command'
require_relative 'commands/acquire_command'
require_relative 'commands/scout_start_command'
require_relative 'commands/scout_end_command'

module CommandParser
  BOT_USERNAME    = (ENV['BOT_USERNAME'] || 'DOWN').freeze
  MASTER_USERNAME = (ENV['MASTER_USERNAME'] || 'THEVISITORS').freeze

  def self.parse(mastodon_client, sheet_manager, notification)
    content_raw = notification.dig('status', 'content') || ''
    sender      = notification.dig('account', 'acct') || ''
    content     = clean_html(content_raw)
    status      = notification['status']

    puts "[PARSER] @#{sender}: #{content}"

    if battle_trigger_from_master?(sender, content)
      handle_battle_trigger(mastodon_client, status)
      return
    end

    case content
    when /\[위치\/(.+?)\]/
      LocationCommand.new(sheet_manager, mastodon_client, sender, $1.strip, status).execute

    when /\[조사\/(.+?)\]/
      InvestigateCommand.new(sheet_manager, mastodon_client, sender, $1.strip, status).execute

    when /\[획득\/(.+?)\]/
      AcquireCommand.new(sheet_manager, mastodon_client, sender, $1.strip, status).execute

    when /\[탐험\]/
      ScoutStartCommand.new(sheet_manager, mastodon_client, sender, status).execute

    when /\[조사종료\]/
      ScoutEndCommand.new(sheet_manager, mastodon_client, sender, status).execute

    else
      return
    end

  rescue => e
    puts "[PARSER 오류] #{e.class}: #{e.message}"
  end

  def self.battle_trigger_from_master?(sender, content)
    sender_name = normalize_acct(sender)
    return false unless sender_name.casecmp?(MASTER_USERNAME)

    content.include?('크리쳐') && content.include?('전투를 시작합니다')
  end

  def self.handle_battle_trigger(mastodon_client, status)
    runners = extract_runner_mentions(status)

    if runners.empty?
      mastodon_client.post_status(
        "@#{MASTER_USERNAME} [전투 오류]\n참여 러너 태그를 찾을 수 없습니다.",
        reply_to_id: status['id'],
        visibility: 'direct'
      )
      return
    end

    mastodon_client.post_status(
      "[전투시작] #{runners.map { |u| "@#{u}" }.join(' ')}",
      visibility: 'public'
    )
  end

  def self.extract_runner_mentions(status)
    mentions = status['mentions'].to_a.map do |m|
      (m['username'] || m['acct']).to_s.gsub('@', '').split('@').first.strip
    end

    mentions
      .reject(&:empty?)
      .reject { |u| u.casecmp?(BOT_USERNAME) }
      .reject { |u| u.casecmp?(MASTER_USERNAME) }
      .uniq
  end

  def self.normalize_acct(acct)
    acct.to_s.gsub('@', '').split('@').first.strip
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
