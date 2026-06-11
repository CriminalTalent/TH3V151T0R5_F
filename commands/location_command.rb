# commands/location_command.rb
# encoding: UTF-8

class LocationCommand
  def initialize(sheet_manager, mastodon_client, sender, location_name, status)
    @sheet_manager   = sheet_manager
    @mastodon_client = mastodon_client
    @sender          = sender.to_s.gsub('@', '')
    @location_name   = location_name.to_s.strip
    @status          = status
  end

  def execute
    user = @sheet_manager.find_user(@sender)
    unless user
      dm("아직 등록되지 않은 계정입니다.")
      return
    end

    location = @sheet_manager.find_location(@location_name)
    unless location
      dm("#{@location_name} 은(는) 존재하지 않는 장소입니다.")
      return
    end

    unless location[:public]
      dm("#{@location_name} 은(는) 현재 접근할 수 없는 장소입니다.")
      return
    end

    @sheet_manager.update_scout_state(@sender, {
      location:    @location_name,
      last_action: '이동'
    })

    lines = []
    lines << "[ #{@location_name} ]"
    lines << "──────────────────"
    lines << location[:desc] unless location[:desc].empty?
    lines << ""

    if location[:choices].any?
      lines << "이동 가능한 장소:"
      location[:choices].each { |c| lines << "・ #{c}" }
    end

    dm(lines.join("\n"))
  rescue => e
    puts "[LocationCommand 오류] #{e.message}"
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
