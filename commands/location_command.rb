# commands/location_command.rb
# encoding: UTF-8
class LocationCommand
  MAX_CHARS = 1000
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
      dm("아직 등록되지 않은 계정입니다.", @status['id'])
      return
    end
    location = @sheet_manager.find_location(@location_name)
    unless location
      dm("#{@location_name} 은(는) 존재하지 않는 장소입니다.", @status['id'])
      return
    end
    unless location[:public]
      dm("#{@location_name} 은(는) 현재 접근할 수 없는 장소입니다.", @status['id'])
      return
    end
    @sheet_manager.update_scout_state(@sender, {
      location:    @location_name,
      last_action: '이동'
    })
    send_threaded(build_lines(location), @status['id'])
  rescue => e
    puts "[LocationCommand 오류] #{e.message}"
    dm("처리 중 오류가 발생했습니다.", @status['id'])
  end
  def self.build_location_message(location)
    new(nil, nil, '', '', nil).send(:build_lines, location).join("\n")
  end
  def self.build_lines(location)
    new(nil, nil, '', '', nil).send(:build_lines, location)
  end
  private
  def build_lines(location)
    lines = []
    lines << "[ #{location[:name]} ]"
    lines << "──────────────────"
    lines << location[:desc] unless location[:desc].empty?
    if location[:choices].any?
      lines << ""
      lines << "이동 가능한 장소:"
      location[:choices].each { |c| lines << "・ #{c}" }
      lines << "[위치/장소명] 으로 이동할 수 있습니다."
    end
    if location[:objects].any?
      lines << ""
      lines << "주변에서 발견한 것들:"
      location[:objects].each do |obj|
        taken = obj[:once] && !obj[:taken_by].empty?
        lines << "・ #{obj[:name]}#{taken ? ' (이미 누군가 가져감)' : ''}"
      end
      lines << "[조사/오브젝트명] 으로 상호작용할 수 있습니다."
    end
    lines
  end
  def send_threaded(lines, reply_id)
    chunks = []
    current = "@#{@sender} "
    lines.each do |line|
      candidate = current.empty? ? "@#{@sender} #{line}" : "#{current}\n#{line}"
      if candidate.length > MAX_CHARS
        chunks << current unless current.strip.empty?
        current = "@#{@sender} #{line}"
      else
        current = candidate
      end
    end
    chunks << current unless current.strip.empty?
    chunks.each do |chunk|
      res = dm(chunk, reply_id)
      begin
        reply_id = JSON.parse(res.body)['id'] if res
      rescue
      end
      sleep 1
    end
  end
  def dm(text, reply_id)
    @mastodon_client.post_status(
      text,
      reply_to_id: reply_id,
      visibility: 'direct'
    )
  end
end
