# commands/scout_start_command.rb
# encoding: UTF-8

class ScoutStartCommand
  def initialize(sheet_manager, mastodon_client, sender, status)
    @sheet_manager   = sheet_manager
    @mastodon_client = mastodon_client
    @sender          = sender.to_s.gsub('@', '')
    @status          = status
  end

  def execute
    user = @sheet_manager.find_user(@sender)
    unless user
      dm("아직 등록되지 않은 계정입니다.")
      return
    end

    locations = @sheet_manager.available_locations
    if locations.empty?
      dm("현재 이동 가능한 장소가 없습니다.")
      return
    end

    lines = []
    lines << "조사를 시작합니다."
    lines << "──────────────────"
    lines << "이동 가능한 장소:"
    locations.each { |l| lines << "・ #{l}" }
    lines << ""
    lines << "[위치/장소명] 으로 이동할 수 있습니다."

    dm(lines.join("\n"))
  rescue => e
    puts "[ScoutStartCommand 오류] #{e.message}"
    dm("처리 중 오류가 발생했습니다.")
  end

  private

  def dm(text)
    @mastodon_client.post_status(
      "@#{@sender} #{text}",
      reply_to_id: @status['id'],
      visibility: 'direct'
    )
  end
end
