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
    puts "[위치 진단] sender=#{@sender.inspect} location=#{@location_code.inspect} party=#{@party.inspect}"
    user = @sheet_manager.find_user(@sender)
    puts "[위치 진단] find_user=#{!user.nil?}"
    unless user
      dm_solo("아직 등록되지 않은 계정입니다.")
      return
    end

    location = @sheet_manager.find_location(@location_code)
    puts "[위치 진단] find_location=#{location.inspect}"
    unless location
      dm_solo("#{@location_code} 은(는) 존재하지 않는 위치입니다.")
      return
    end
    incapacitated = party_all_incapacitated?
    puts "[위치 진단] party_all_incapacitated=#{incapacitated.inspect}"

    if incapacitated
      dm_solo("전투불능 상태라 이동할 수 없습니다. 회복 후 다시 시도해주세요.")
      return
    end

    unless location[:public]
      dm_solo("#{location_title(location)} 은(는) 현재 접근할 수 없는 장소입니다.")
      return
    end

    puts "[위치 진단] move_party 진입 coord=#{location[:code].inspect} party=#{@party.inspect}"
    move_result = move_party!(location[:code])
    puts "[위치 진단] move_party 반환=#{move_result.inspect}"

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

  GRID_COORD_RE = /\A[C-O](?:[2-8]|1[0-6])\z/.freeze


  # 파티 전원이 전투불능이면 true. 1인일 때는 본인이 전투불능이면 true.
  # (1명이라도 전투 가능 상태면 false — 조사/이동 진행)
  def party_all_incapacitated?
    states = @sheet_manager.find_scout_states(@party)
    @party.all? do |acct|
      key = acct.to_s.gsub('@', '').strip
      state = states[key]
      state && state[:last_action].to_s.strip == '전투불능'
    end
  end

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
    @sheet_manager.update_scout_states_batch(@party, {
      location:    coord,
      last_action: '이동'
    })
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

  # 파티 전원의 표시이름을 사용자 시트에서 조회한다.
  # (방금 갱신한 조사상태를 다시 읽는 runners_at_location보다 신뢰도가 높다)
  def party_runners
    @party.map do |acct|
      user = @sheet_manager.find_user(acct)
      name = user && !user[:name].to_s.strip.empty? ? user[:name] : acct
      { acct: acct, name: name }
    end
  end

  def trigger_encounter(location)
    creature_name = location[:creature].to_s.strip
    creature_name = '크리쳐' if creature_name.empty?

    @sheet_manager.activate_creature_boss(creature_name, location[:code])

    runners = party_runners

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

    @sheet_manager.update_scout_states_batch(@party, {
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

    # 오브젝트명이 있는(named) 항목 = 조사가 필요한 대상.
    # 이 항목에 딸린 아이템은 조사(InvestigateCommand)를 거쳐야만 노출된다.
    investigate_points = visible_objects.select { |obj| obj[:named] }

    # 오브젝트명이 없는(named: false) 항목 = 조사 없이 바로 보이는 아이템.
    direct_items = visible_objects
      .reject { |obj| obj[:named] }
      .flat_map { |obj| obj[:item].to_s.split(',').map(&:strip).reject(&:empty?) }
      .uniq

    if investigate_points.any?
      lines << ""
      lines << "조사할 수 있는 것들:"
      investigate_points.each do |obj|
        lines << "・ #{obj[:name]}"
      end
      lines << "[조사/오브젝트명] 으로 자세히 살펴볼 수 있습니다."
    end

    if direct_items.any?
      lines << ""
      lines << "획득할 수 있는 것들:"
      direct_items.each do |item|
        lines << "・ #{item}"
      end
      lines << "[획득/아이템명] 으로 바로 가져갈 수 있습니다."
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
    m = coord.to_s.strip.upcase.match(GridMoveCommand::COORD_RE)
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
    return nil if GridMoveCommand.zone_of(m[2].to_i) != GridMoveCommand.zone_of(rows[new_row_idx])

    "#{cols[new_col_idx]}#{rows[new_row_idx]}"
  end

  def grid_available_directions(location)
    blocked = grid_blocked_directions(location)
    candidates = {}
    GridMoveCommand::DIRECTIONS.each do |name, delta|
      next if blocked.include?(name)
      target = grid_neighbor_coord(location[:code], delta)
      candidates[name] = target if target
    end
    return [] if candidates.empty?

    lookup = @sheet_manager.find_cells_public_batch(candidates.values)
    candidates.each_with_object([]) do |(name, target), list|
      info = lookup[target.to_s.strip.upcase]
      list << name if info && info[:public]
    end
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
    result = @mastodon_client.post_status(
      text,
      reply_to_id: reply_id,
      visibility: 'direct'
    )
    # post_status가 예외 없이 nil을 반환하는 경우(예: 429 재시도 소진)도 있어,
    # 이 경우는 rescue가 안 걸려 응답이 조용히 사라지던 문제가 있었다.
    # 추적을 위해 명시적으로 경고 로그를 남긴다.
    puts "[LocationCommand 게시 실패] post_status가 nil을 반환함 (reply_id=#{reply_id})" unless result
    result
  rescue => e
    puts "[LocationCommand DM 오류] #{e.class}: #{e.message}"
    nil
  end
end
