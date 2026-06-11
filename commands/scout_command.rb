# commands/scout_command.rb
# encoding: UTF-8

class ScoutCommand
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

    state = @sheet_manager.find_scout_state(@sender)
    unless state && !state[:location].empty?
      dm("현재 위치 정보가 없습니다. [위치/장소명]으로 먼저 이동해주세요.")
      return
    end

    location = @sheet_manager.find_location(state[:location])
    unless location
      dm("현재 위치 정보를 불러올 수 없습니다.")
      return
    end

    objects = location[:objects]
    if objects.empty?
      dm("[ #{state[:location]} ]\n──────────────────\n조사할 수 있는 것이 없습니다.")
      return
    end

    lines = []
    lines << "[ #{state[:location]} ]"
    lines << "──────────────────"
    lines << "주변에서 발견한 것들:"
    objects.each do |obj|
      taken = obj[:once] && !obj[:taken_by].empty?
      lines << "・ #{obj[:name]}#{taken ? ' (이미 누군가 가져감)' : ''}"
    end
    lines << "──────────────────"
    lines << "[조사/오브젝트명] 으로 상호작용할 수 있습니다."

    dm(lines.join("\n"))
  rescue => e
    puts "[ScoutCommand 오류] #{e.message}"
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
