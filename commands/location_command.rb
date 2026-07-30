# commands/location_command.rb
# encoding: UTF-8

class LocationCommand
  MAX_CHARS = 1000

  def initialize(sheet_manager, mastodon_client, sender, location_code, status)
    @sheet_manager   = sheet_manager
    @mastodon_client = mastodon_client
    @sender          = sender.to_s.gsub('@', '')
    @location_code   = location_code.to_s.strip
    @status          = status
  end

  def execute
    user = @sheet_manager.find_user(@sender)
    unless user
      dm("아직 등록되지 않은 계정입니다.", @status['id'])
      return
    end

    location = @sheet_manager.find_location(@location_code)
    unless location
      dm("#{@location_code} 은(는) 존재하지 않는 위치입니다.", @status['id'])
      return
    end

    unless location[:public]
      dm("#{location_title(location)} 은(는) 현재 접근할 수 없는 장소입니다.", @status['id'])
      return
    end

    @sheet_manager.update_scout_state(@sender, {
      location:    location[:code],
      last_action: '이동'
    })

    if location[:creature] && !location[:creature].to_s.strip.empty?
      trigger_encounter(location)
      return
    end

    send_threaded(build_lines(location), @status['id'])
  rescue => e
    puts "[LocationCommand 오류] #{e.class}: #{e.message}"
    puts e.backtrace.first(5)
    dm("처리 중 오류가 발생했습니다.", @status['id']) if @status
  end

  def self.build_location_message(location)
    new(nil, nil, '', '', nil).send(:build_lines, location).join("\n")
  end

  def self.build_lines(location)
    new(nil, nil, '', '', nil).send(:build_lines, location)
  end

  private

  GRID_COORD_RE = /\A[C-O][2-8]\z/.freeze

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
    runners = [{ acct: @sender, name: @sender }] if runners.empty?

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

    # 조사는 DM 흐름이므로 전투 전환 안내도 같은 DM 스레드에 고정한다.
    dm(encounter_text, @status['id'])

    @sheet_manager.update_scout_state(@sender, {
      location:    location[:code],
      last_action: '전투전환'
    })
  end

  def build_lines(location)
    lines = []
    lines << "[ #{location_title(location)} ]"
    lines << "──────────────────"
    lines << location[:desc] unless location[:desc].to_s.empty?

    if location[:code].to_s.upcase.match?(GRID_COORD_RE)
      directions = grid_available_directions(location)
      prev = @sheet_manager.find_grid_prev(@sender)
      has_prev = prev && valid_grid_coord?(prev[:prev].to_s)

      if directions.any? || has_prev
        lines << ""
        lines << "이동 가능한 방향:"
        directions.each { |name| lines << "[탐사/#{name}]" }
        lines << "[탐사/돌아가기]" if has_prev
      end
    end

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

  # ── 격자 이동 방향 계산 (grid_move_command.rb와 동일한 좌표계 C~O, 2~8 사용) ──

  def valid_grid_coord?(coord)
    !!coord.to_s.strip.upcase.match(GRID_COORD_RE)
  end

  def grid_blocked_directions(location)
    location[:blocked].to_s.split(/[,\s\/]+/).map(&:strip).reject(&:empty?)
  end

  def grid_neighbor_coord(coord, delta)
    m = coord.to_s.strip.upcase.match(/\A([C-O])([2-8])\z/)
    return nil unless m

    cols = GridMoveCommand::COLS
    rows = GridMoveCommand::ROWS

    col_idx = cols.index(m[1])
    row_idx = rows.index(m[2].to_i)
    return nil unless col_idx && row_idx

    new_col_idx = col_idx + delta[0]
    new_row_idx = row_idx + delta[1]

    return nil unless new_col_idx.between?(0, cols.length - 1)
    return nil unless new_row_idx.between?(0, rows.length - 1)

    "#{cols[new_col_idx]}#{rows[new_row_idx]}"
  end

  def grid_available_directions(location)
    blocked = grid_blocked_directions(location)

    GridMoveCommand::DIRECTIONS.each_with_object([]) do |(name, delta), list|
      next if blocked.include?(name)

      target = grid_neighbor_coord(location[:code], delta)
      next unless target

      target_location = @sheet_manager.find_location(target)
      list << name if target_location && target_location[:public]
    end
  end

  def send_threaded(lines, reply_id)
    chunks = []
    current = "@#{@sender}"

    lines.each do |line|
      candidate = "#{current}\n#{line}"
      if candidate.length > MAX_CHARS
        chunks << current unless current.strip.empty?
        current = "@#{@sender}\n#{line}"
      else
        current = candidate
      end
    end

    chunks << current unless current.strip.empty?

    chunks.each do |chunk|
      dm(chunk, reply_id)
      # MastodonClient가 HTTPResponse를 반환하지 않는 구조에서도 안전하게 동작하도록
      # res.body 파싱을 하지 않는다. 스레드의 첫 원글에 계속 답글로 단다.
      sleep 0.5
    end
  end

  def dm(text, reply_id)
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
