# commands/grid_move_command.rb
# encoding: UTF-8
#
# [탐사/북쪽] [탐사/남쪽] [탐사/동쪽] [탐사/서쪽] [탐사/돌아가기]
#
# 기존 [위치/장소명] [조사/오브젝트명] [획득/오브젝트명] 명령어와는
# 완전히 별개의 명령어이며, 기존 파일(location_command.rb 등)은 수정하지 않는다.
#
# 좌표 칸은 기존 "장소" 시트를 그대로 사용한다.
# (위치 칸에 좌표코드 예: A1 ~ M7 을 넣어두면 기존 [조사]/[획득] 명령어가 그대로 동작함)
# 직전 좌표만 별도 시트(격자직전위치)에 새로 저장한다.

class GridMoveCommand
  MAX_CHARS = 1000
  COLS = ('A'..'M').to_a.freeze # 13칸
  ROWS = (1..7).to_a.freeze     # 7칸

  DIRECTIONS = {
    '북쪽' => [0, -1],
    '남쪽' => [0, 1],
    '동쪽' => [1, 0],
    '서쪽' => [-1, 0]
  }.freeze

  def initialize(sheet_manager, mastodon_client, sender, direction, status)
    @sheet_manager   = sheet_manager
    @mastodon_client = mastodon_client
    @sender          = sender.to_s.gsub('@', '')
    @direction       = direction.to_s.strip
    @status          = status
  end

  def execute
    user = @sheet_manager.find_user(@sender)
    unless user
      dm("아직 등록되지 않은 계정입니다.", @status['id'])
      return
    end

    scout_state = @sheet_manager.find_scout_state(@sender)
    current_coord = scout_state ? scout_state[:location].to_s.strip.upcase : ''

    unless valid_coord?(current_coord)
      dm("현재 위치가 격자 좌표가 아닙니다. [위치/좌표] 명령으로 먼저 격자 칸(예: A1)으로 이동해주세요.", @status['id'])
      return
    end

    if @direction == '돌아가기'
      handle_return(current_coord)
    else
      handle_direction(current_coord)
    end
  rescue => e
    puts "[GridMoveCommand 오류] #{e.class}: #{e.message}"
    puts e.backtrace.first(5)
    dm("처리 중 오류가 발생했습니다.", @status['id']) if @status
  end

  private

  def handle_direction(current_coord)
    delta = DIRECTIONS[@direction]
    unless delta
      dm("알 수 없는 방향입니다.", @status['id'])
      return
    end

    target_coord = neighbor_coord(current_coord, delta)

    unless target_coord
      dm("그 방향으로는 더 이상 이동할 수 없습니다.", @status['id'])
      return
    end

    location = @sheet_manager.find_location(target_coord)
    unless location && location[:public]
      dm("그 방향은 갈 수 없는 곳입니다.", @status['id'])
      return
    end

    @sheet_manager.update_grid_prev(@sender, current_coord)

    @sheet_manager.update_scout_state(@sender, {
      location:    target_coord,
      last_action: '이동'
    })

    if location[:creature] && !location[:creature].to_s.strip.empty?
      trigger_encounter(location)
      return
    end

    send_threaded(build_lines(target_coord, location), @status['id'])
  end

  def handle_return(current_coord)
    prev = @sheet_manager.find_grid_prev(@sender)
    prev_coord = prev ? prev[:prev].to_s.strip.upcase : ''

    unless valid_coord?(prev_coord)
      dm("돌아갈 수 있는 이전 위치가 없습니다.", @status['id'])
      return
    end

    location = @sheet_manager.find_location(prev_coord)
    unless location && location[:public]
      dm("이전 위치로 돌아갈 수 없습니다.", @status['id'])
      return
    end

    @sheet_manager.update_grid_prev(@sender, current_coord)

    @sheet_manager.update_scout_state(@sender, {
      location:    prev_coord,
      last_action: '이동'
    })

    if location[:creature] && !location[:creature].to_s.strip.empty?
      trigger_encounter(location)
      return
    end

    send_threaded(build_lines(prev_coord, location), @status['id'])
  end

  def valid_coord?(coord)
    !!coord.to_s.strip.upcase.match(/\A[A-M](?:[1-7])\z/)
  end

  def neighbor_coord(coord, delta)
    m = coord.match(/\A([A-M])([1-7])\z/)
    return nil unless m

    col_idx = COLS.index(m[1])
    row_idx = ROWS.index(m[2].to_i)
    return nil unless col_idx && row_idx

    new_col_idx = col_idx + delta[0]
    new_row_idx = row_idx + delta[1]

    return nil unless new_col_idx.between?(0, COLS.length - 1)
    return nil unless new_row_idx.between?(0, ROWS.length - 1)

    "#{COLS[new_col_idx]}#{ROWS[new_row_idx]}"
  end

  def location_title(location)
    label = location[:label].to_s.strip
    label = location[:name].to_s.strip if label.empty?

    # 격자 이동은 좌표를 러너에게 노출하지 않는다. 이름이 비어 있으면
    # 좌표 대신 일반 문구로 대체한다.
    label.empty? ? '알 수 없는 장소' : label
  end

  def visible_object?(obj)
    return false if obj.nil?

    once_taken = obj[:once] && !obj[:taken_by].to_s.strip.empty?
    credit_settled = obj[:credit].to_i != 0 && !obj[:credit_taken_by].to_s.strip.empty?

    !(once_taken || credit_settled)
  end

  def available_directions(coord)
    DIRECTIONS.each_with_object([]) do |(name, delta), list|
      target = neighbor_coord(coord, delta)
      next unless target

      target_location = @sheet_manager.find_location(target)
      list << name if target_location && target_location[:public]
    end
  end

  def build_lines(coord, location)
    lines = []
    lines << "[ #{location_title(location)} ]"
    lines << "──────────────────"
    lines << location[:desc] unless location[:desc].to_s.empty?

    directions = available_directions(coord)
    prev = @sheet_manager.find_grid_prev(@sender)
    has_prev = prev && valid_coord?(prev[:prev].to_s)

    if directions.any? || has_prev
      lines << ""
      lines << "이동 가능한 방향:"
      directions.each { |name| lines << "[탐사/#{name}]" }
      lines << "[탐사/돌아가기]" if has_prev
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

    dm(encounter_text, @status['id'])

    @sheet_manager.update_scout_state(@sender, {
      location:    location[:code],
      last_action: '전투전환'
    })
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
    puts "[GridMoveCommand DM 오류] #{e.class}: #{e.message}"
    nil
  end
end
