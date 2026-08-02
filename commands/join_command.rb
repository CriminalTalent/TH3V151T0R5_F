# commands/join_command.rb
# encoding: UTF-8
#
# [합류/@기존팀원]
#
# 좌표를 몰라도, 이미 조사 중인 팀원 한 명을 지정하면 그 팀원의 현재
# 위치(조사상태 시트의 '위치' 칸)로 그대로 이동해 합류한다.
# 파티 이동([탐사/방향] @동료...)과는 별개의 개인 단위 명령이다 — 합류
# 자체는 혼자 처리되며, 합류한 뒤에 [탐사/방향] @동료...로 함께 움직이면 됨.

class JoinCommand
  def initialize(sheet_manager, mastodon_client, sender, target_acct, status)
    @sheet_manager   = sheet_manager
    @mastodon_client = mastodon_client
    @sender          = sender.to_s.gsub('@', '').split('@').first.to_s.strip
    @target_acct     = target_acct.to_s.gsub('@', '').split('@').first.to_s.strip
    @status          = status
  end

  def execute
    if @target_acct.empty?
      dm("합류할 대상 계정을 알 수 없습니다. [합류/@아이디] 형식으로 입력해주세요.")
      return
    end

    if @target_acct.casecmp?(@sender)
      dm("본인에게는 합류할 수 없습니다.")
      return
    end

    user = @sheet_manager.find_user(@sender)
    unless user
      dm("아직 등록되지 않은 계정입니다.")
      return
    end

    target_user = @sheet_manager.find_user(@target_acct)
    unless target_user
      dm("@#{@target_acct} 계정을 찾을 수 없습니다.")
      return
    end

    target_state = @sheet_manager.find_scout_state(@target_acct)
    target_location = target_state ? target_state[:location].to_s.strip : ''

    if target_location.empty?
      dm("@#{@target_acct} 님은 현재 위치 정보가 없습니다 (아직 조사를 시작하지 않았거나 조사를 종료한 상태입니다).")
      return
    end

    location = @sheet_manager.find_location(target_location)
    unless location
      dm("@#{@target_acct} 님의 위치 정보를 불러올 수 없습니다.")
      return
    end

    @sheet_manager.update_scout_state(@sender, {
      location:    target_location,
      last_action: '합류'
    })

    loc_cmd = LocationCommand.new(@sheet_manager, @mastodon_client, @sender, target_location, @status)
    lines = ["@#{@target_acct} 님의 위치로 합류했습니다.", ""]
    lines.concat(loc_cmd.send(:build_lines, location))

    dm(lines.join("\n"))
  rescue => e
    puts "[JoinCommand 오류] #{e.class}: #{e.message}"
    puts e.backtrace.first(5)
    dm("처리 중 오류가 발생했습니다.")
  end

  private

  def dm(text)
    @mastodon_client.post_status(
      "@#{@sender} #{text}",
      reply_to_id: @status['id'],
      visibility: 'direct'
    )
  rescue => e
    puts "[JoinCommand DM 오류] #{e.class}: #{e.message}"
    nil
  end
end
