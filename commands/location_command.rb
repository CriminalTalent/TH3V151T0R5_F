# commands/location_command.rb
# encoding: UTF-8
#
# [위치/장소명] [위치/장소명] @동료1 @동료2 ...
# 멘션을 함께 쓰면 멘션된 사람 전원 + 본인이 파티가 되어 함께 이동하고,
# 파티 전체에게 그룹 DM으로 안내되며 같은 파티가 다시 이동하면 이전 스레드에
# 이어서 안내된다 (grid_move_command.rb와 동일한 방식, 같은 탐사스레드 시트 공유).
# 멘션 없이 혼자 쓰면 기존과 동일하게 개인 단위로 동작한다.

class LocationCommand
  MAX_CHARS = 1000

  def initialize(sheet_manager, mastodon_client, sender, location_code, status)
    @sheet_manager   = sheet_manager
    @mastodon_client = mastodon_client
    @sender          = sender.to_s.gsub('@', '')
    @location_code   = location_code.to_s.strip
    @status          = status
    @party           = build_party
  end

  def execute
    user = @sheet_manager.find_user(@sender)
    unless user
      dm_solo("아직 등록되지 않은 계정입니다.")
      return
    end

    location = @sheet_manager.find_location(@location_code)
    unless location
      dm_solo("#{@location_code} 은(는) 존재하지 않는 위치입니다.")
      return
    end

    unless location[:public]
      dm_solo("#{location_title(location)} 은(는) 현재 접근할 수 없는 장소입니다.")
      return
    end

    move_party!(location[:code])

    if location[:creature] && !location[:creature].to_s.strip.empty?
      trigger_encounter(location)
      return
    end

    send_party(build_lines(location))
  rescue => e
    puts "[LocationCommand 오류] #{e.class}: #{e.message}"
    puts e.backtrace.first(5)
    dm_solo("처리 중 오류가 발생했습니다.") if @status
  end

  def self.build_location_message(location)
    new(nil, nil, '', '', nil).send(:build_lines, location).join("\n")
  end

  def self.build_lines(location)
    new(nil, nil, '', '', nil).send(:build_lines, location)
  end

  private

  GRID_COORD_RE = /\A[C-O][2-8]\z/.freeze

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

  def party?
    @party.size > 1
  end

  def party_key
    @party.sort.join('+')
  end

  # 파티 전원의 조사상태 위치를 함께 갱신한다.
  def move_party!(coord)
    @party.each do |acct|
      @sheet_manager.update_scout_state(acct, {
        location:    coord,
        last_action: '이동'
      })
    end
  end

  def location_title(location)
    code = location[:code].to_s.strip
    label = location[:label].to_s.strip
    label = location[:name].to_s.strip if label.empty?

    # 격자 좌표(C2~O8)는 러너에게 노출하지 않는다.
    return label.empty? ? '알 수 없는 장소' : label if code.upcase.match?(GRID_COORD_RE)

    if code.empty?
      label
    elsif label.empty? || label == code
      code
    else
      "#{code} #{label}"
    end
  end

  def choice_title(choice)
    if choice.is_a?(Hash)
      code = choice[:code].to_s.strip
      label = choice[:label].to_s.strip

      return label.empty? ? code : label if code.upcase.match?(GRID_COORD_RE)

      if code.empty?
        label
      elsif label.empty? || label == code
        code
      else
        "#{code} #{label}"
      end
    else
      choice.to_s
    end
  end

  def visible_object?(obj)
    return false if obj.nil?

    once_taken = obj[:once] && !obj[:taken_by].to_s.strip.empty?
    credit_settled = obj[:credit].to_i != 0 && !obj[:credit_taken_by].to_s.strip.empty?

    !(once_taken || credit_settled)
  end

  def trigger_encounter(location)
    creature_name = location[:creature].to_s.strip
    creature_name = '크리쳐' if creature_name.empty?

    @sheet_manager.activate_creature_boss(creature_name, location[:code])

    runners = @sheet_manager.runners_at_location(location[:code])
    runners = @party.map { |acct| { acct: acct, name: acct } } if runners.empty?

    tags  = runners.map { |r| "@#{r[:acct]}" }.join(' ')
    names = runners.map { |r| r[:name].to_s.empty? ? r[:acct] : r[:name] }.join(', ')

    encounter_text = "#{tags}\n\n" \
                     "━━━━━━━━━━━━━━\n\n" \
                     "#{location_title(location)}\n\n" \
                     "크리쳐 「#{creature_name}」 출현!\n" \
                     "조우 인원 #{names}!\n\n" \
                     "전투를 시작합니다.\n\n" \
                     "행동은 DM으로 입력해주세요.\n\n" \
                     "사용 가능 행동:\n" \
                     "[공격/#{creature_name}]\n" \
                     "[회복/아이디]\n" \
                     "[방어/아이디]\n" \
                     "[이동/좌표]\n\n" \
                     "━━━━━━━━━━━━━━\n" \
                     "[전투시작]"

    # 조사는 DM 흐름이므로 전투 전환 안내도 이번 명령의 스레드에 고정한다.
    post(encounter_text, @status['id'])

    @party.each do |acct|
      @sheet_manager.update_scout_state(acct, {
        location:    location[:code],
        last_action: '전투전환'
      })
    end
  end

  def build_lines(location)
    lines = []
    lines << "[ #{location_title(location)} ]"
    lines << "──────────────────"
    lines << location[:desc] unless location[:desc].to_s.empty?

    if location[:choices].to_a.any?
      lines << ""
      lines << "이동 가능한 장소:"
      location[:choices].each do |choice|
        title = choice_title(choice)
        lines << "・ #{title}" unless title.empty?
      end
      lines << "[위치/장소명] 형식으로 이동할 수 있습니다."
    end

    visible_objects = location[:objects].to_a.select { |obj| visible_object?(obj) }

    if visible_objects.any?
      lines << ""
      lines << "주변에서 발견한 것들:"
      visible_objects.each do |obj|
        lines << "・ #{obj[:name]}"
      end
      lines << "[조사/오브젝트명] 으로 상호작용할 수 있습니다."
    end

    lines
  end

  # ── 발송 ──

  # 파티가 2명 이상이면 파티 전용 스레드(탐사스레드 시트, grid_move_command.rb와 공유)에
  # 이어서 보내고, 혼자면 이번 명령 상태에 답장한다.
  def thread_anchor
    return @status['id'] unless party?

    stored = @sheet_manager.find_party_thread(party_key)
    stored && !stored[:thread_id].to_s.strip.empty? ? stored[:thread_id] : @status['id']
  end

  def send_party(lines)
    tags = @party.map { |acct| "@#{acct}" }.join(' ')
    send_threaded(lines, thread_anchor, tags)
  end

  def dm_solo(text)
    post("@#{@sender} #{text}", @status['id'])
  end

  def send_threaded(lines, reply_id, header_tags)
    chunks = []
    current = header_tags

    lines.each do |line|
      candidate = "#{current}\n#{line}"
      if candidate.length > MAX_CHARS
        chunks << current unless current.strip.empty?
        current = "#{header_tags}\n#{line}"
      else
        current = candidate
      end
    end

    chunks << current unless current.strip.empty?

    last_id = reply_id
    chunks.each do |chunk|
      response = post(chunk, last_id)
      last_id = response['id'] if response && response['id']
      sleep 0.5
    end

    @sheet_manager.update_party_thread(party_key, last_id) if party? && last_id
  end

  def post(text, reply_id)
    @mastodon_client.post_status(
      text,
      reply_to_id: reply_id,
      visibility: 'direct'
    )
  rescue => e
    puts "[LocationCommand DM 오류] #{e.class}: #{e.message}"
    nil
  end
end
