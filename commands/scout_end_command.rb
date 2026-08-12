# commands/scout_end_command.rb
# encoding: UTF-8
#
# [조사종료] [조사종료] @동료1 @동료2 ...
# 멘션을 함께 쓰면 멘션된 사람 전원 + 본인이 파티가 되어 함께 조사를
# 종료한다. 멘션 없이 혼자 쓰면 기존과 동일하게 개인 단위로 동작한다.
class ScoutEndCommand
  def initialize(sheet_manager, mastodon_client, sender, status)
    @sheet_manager   = sheet_manager
    @mastodon_client = mastodon_client
    @sender          = sender.to_s.gsub('@', '')
    @status          = status
    @party           = build_party
  end

  def execute
    user = @sheet_manager.find_user(@sender)
    unless user
      dm_solo("아직 등록되지 않은 계정입니다.")
      return
    end

    @party.each do |acct|
      @sheet_manager.update_scout_state(acct, {
        location:    '',
        last_action: '조사종료'
      })
    end

    dm_party("오늘의 조사를 종료합니다. 수고하셨습니다.")
  rescue => e
    puts "[ScoutEndCommand 오류] #{e.message}"
    dm_solo("처리 중 오류가 발생했습니다.")
  end

  private

  # ── 파티 구성 ──

  def build_party
    return [@sender] unless @status

    mentioned = @status['mentions'].to_a.map do |m|
      (m['username'] || m['acct']).to_s.gsub('@', '').split('@').first.strip
    end.reject(&:empty?)

    bot_username = defined?(CommandParser) ? CommandParser::BOT_USERNAME : nil
    mentioned = mentioned.reject { |u| bot_username && u.casecmp?(bot_username) }

    ([@sender] + mentioned).uniq
  end

  # ── 발송 ──

  def dm_solo(text)
    post("@#{@sender} #{text}", @status['id'])
  end

  def dm_party(text)
    tags = @party.map { |acct| "@#{acct}" }.join(' ')
    post("#{tags}\n#{text}", @status['id'])
  end

  def post(text, reply_id)
    @mastodon_client.post_status(
      text,
      reply_to_id: reply_id,
      visibility: 'direct'
    )
  rescue => e
    puts "[ScoutEndCommand DM 오류] #{e.class}: #{e.message}"
    nil
  end
end
