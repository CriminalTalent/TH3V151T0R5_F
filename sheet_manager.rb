# sheet_manager.rb
# encoding: UTF-8

require 'google/apis/sheets_v4'
require 'googleauth'

class SheetManager
  USERS_SHEET    = '사용자'.freeze
  LOCATION_SHEET = '장소'.freeze
  SCOUT_SHEET    = '조사상태'.freeze
  BOSS_SHEET     = '보스'.freeze
  GRID_PREV_SHEET = '격자직전위치'.freeze
  PARTY_THREAD_SHEET = '탐사스레드'.freeze

  def initialize(service, sheet_id, creature_sheet_id = nil, grid_sheet_id = nil)
    @service           = service
    @sheet_id          = sheet_id
    @creature_sheet_id = creature_sheet_id.to_s.strip.empty? ? sheet_id : creature_sheet_id
    @grid_sheet_id     = grid_sheet_id.to_s.strip.empty? ? nil : grid_sheet_id
  end

  # ──────────────────────────────────────────────
  # 기본 I/O
  # ──────────────────────────────────────────────

  def read(sheet, range = 'A:Z')
    read_from(@sheet_id, sheet, range)
  end

  def read_from(sheet_id, sheet, range = 'A:Z')
    @service.get_spreadsheet_values(sheet_id, "#{sheet}!#{range}").values || []
  rescue => e
    puts "[시트 읽기 오류] #{sheet}!#{range}: #{e.class} - #{e.message}"
    []
  end

  def write(sheet, range, values)
    write_to(@sheet_id, sheet, range, values)
  end

  def write_to(sheet_id, sheet, range, values)
    body = Google::Apis::SheetsV4::ValueRange.new(values: values)

    @service.update_spreadsheet_value(
      sheet_id,
      "#{sheet}!#{range}",
      body,
      value_input_option: 'USER_ENTERED'
    )

    true
  rescue => e
    puts "[시트 쓰기 오류] #{sheet}!#{range}: #{e.class} - #{e.message}"
    false
  end

  def append(sheet, row)
    append_to(@sheet_id, sheet, row)
  end

  def append_to(sheet_id, sheet, row)
    body = Google::Apis::SheetsV4::ValueRange.new(values: [row])

    @service.append_spreadsheet_value(
      sheet_id,
      "#{sheet}!A:Z",
      body,
      value_input_option: 'USER_ENTERED'
    )

    true
  rescue => e
    puts "[시트 추가 오류] #{sheet}: #{e.class} - #{e.message}"
    false
  end

  # ──────────────────────────────────────────────
  # 헤더 유틸
  # ──────────────────────────────────────────────

  def normalize_header(value)
    value.to_s.strip.gsub(/\s+/, '')
  end

  def header_map(header_row)
    map = {}

    header_row.to_a.each_with_index do |header, idx|
      key = normalize_header(header)
      map[key] = idx unless key.empty?
    end

    map
  end

  def cell(row, headers, name)
    idx = headers[normalize_header(name)]
    return '' if idx.nil?

    row[idx].to_s.strip
  end

  def truthy?(value)
    text = value.to_s.strip.upcase

    value == true ||
      text == 'TRUE' ||
      text == '1' ||
      text == 'ON' ||
      text == 'YES' ||
      text == 'Y' ||
      text == '✓' ||
      text == '✔'
  end

  # ──────────────────────────────────────────────
  # 사용자
  # ──────────────────────────────────────────────

  def find_user(acct)
    acct = acct.to_s.gsub('@', '').strip
    rows = read(USERS_SHEET, 'A:Z')
    return nil if rows.empty?

    headers = header_map(rows[0])

    rows[1..].to_a.each_with_index do |row, i|
      id = cell(row, headers, 'ID')
      id = row[0].to_s.strip if id.empty?

      next unless id.gsub('@', '').strip.casecmp?(acct)

      return {
        row_num: i + 2,
        id:      id,
        acct:    id.gsub('@', ''),
        name:    first_present(cell(row, headers, '이름'), row[1]),
        credits: first_present(cell(row, headers, '크레딧'), row[2]).to_i,
        items:   first_present(cell(row, headers, '아이템'), row[3]).to_s,
        house:   first_present(cell(row, headers, '기숙사'), row[4]).to_s.strip
      }
    end

    nil
  rescue => e
    puts "[find_user 오류] #{e.class} - #{e.message}"
    nil
  end

  def update_user(acct, attrs)
    acct = acct.to_s.gsub('@', '').strip
    rows = read(USERS_SHEET, 'A:Z')
    return false if rows.empty?

    headers = header_map(rows[0])

    col_map = {
      credits: header_col(headers, '크레딧', 'C'),
      items:   header_col(headers, '아이템', 'D'),
      house:   header_col(headers, '기숙사', 'E')
    }

    rows[1..].to_a.each_with_index do |row, i|
      id = cell(row, headers, 'ID')
      id = row[0].to_s.strip if id.empty?

      next unless id.gsub('@', '').strip.casecmp?(acct)

      row_num = i + 2

      attrs.each do |key, val|
        col = col_map[key]
        next unless col

        write(USERS_SHEET, "#{col}#{row_num}", [[val]])
      end

      return true
    end

    false
  rescue => e
    puts "[update_user 오류] #{e.class} - #{e.message}"
    false
  end

  def adjust_credits(acct, delta)
    user = find_user(acct)
    return nil unless user

    new_credits = user[:credits].to_i + delta.to_i
    new_credits = 0 if new_credits < 0

    update_user(acct, { credits: new_credits })
    new_credits
  rescue => e
    puts "[adjust_credits 오류] #{e.class} - #{e.message}"
    nil
  end

  # ──────────────────────────────────────────────
  # 조사상태
  # ──────────────────────────────────────────────

  def find_scout_state(acct)
    acct = acct.to_s.gsub('@', '').strip
    rows = read(SCOUT_SHEET, 'A:Z')
    return nil if rows.empty?

    headers = header_map(rows[0])

    rows[1..].to_a.each_with_index do |row, i|
      id = first_present(cell(row, headers, 'ID'), row[0]).to_s.strip
      next unless id.gsub('@', '').strip.casecmp?(acct)

      return {
        row_num:     i + 2,
        id:          id,
        location:    first_present(cell(row, headers, '위치'), row[1]).to_s.strip,
        last_action: first_present(cell(row, headers, '최근행동'), cell(row, headers, 'last_action'), row[2]).to_s.strip
      }
    end

    nil
  rescue => e
    puts "[find_scout_state 오류] #{e.class} - #{e.message}"
    nil
  end

  def update_scout_state(acct, attrs)
    acct = acct.to_s.gsub('@', '').strip
    rows = read(SCOUT_SHEET, 'A:Z')

    if rows.empty?
      append(SCOUT_SHEET, [acct, attrs[:location].to_s, attrs[:last_action].to_s])
      return true
    end

    headers = header_map(rows[0])
    location_col = header_col(headers, '위치', 'B')
    action_col   = header_col(headers, '최근행동', 'C')

    rows[1..].to_a.each_with_index do |row, i|
      id = first_present(cell(row, headers, 'ID'), row[0]).to_s.strip
      next unless id.gsub('@', '').strip.casecmp?(acct)

      row_num = i + 2

      write(SCOUT_SHEET, "#{location_col}#{row_num}", [[attrs[:location].to_s]]) if attrs.key?(:location)
      write(SCOUT_SHEET, "#{action_col}#{row_num}", [[attrs[:last_action].to_s]]) if attrs.key?(:last_action)

      return true
    end

    append(SCOUT_SHEET, [acct, attrs[:location].to_s, attrs[:last_action].to_s])
    true
  rescue => e
    puts "[update_scout_state 오류] #{e.class} - #{e.message}"
    false
  end

  def runners_at_location(location_code)
    location_code = location_code.to_s.strip.upcase
    rows = read(SCOUT_SHEET, 'A:Z')
    return [] if rows.empty?

    headers = header_map(rows[0])

    rows[1..].to_a.each_with_object([]) do |row, result|
      acct = first_present(cell(row, headers, 'ID'), row[0]).to_s.gsub('@', '').strip
      loc  = first_present(cell(row, headers, '위치'), row[1]).to_s.strip.upcase

      next if acct.empty?
      next unless loc == location_code

      user = find_user(acct)

      result << {
        acct: acct,
        name: user ? user[:name] : acct
      }
    end
  rescue => e
    puts "[runners_at_location 오류] #{e.class} - #{e.message}"
    []
  end

  # ──────────────────────────────────────────────
  # 격자 이동([탐사/북쪽] 등) 전용 - 직전 좌표 저장
  #
  # 헤더: ID / 직전좌표
  # 기존 조사상태 시트와 별도의 시트를 사용하며,
  # 기존 위치 값(현재 좌표)은 그대로 조사상태 시트의 '위치' 칸을 사용한다.
  # ──────────────────────────────────────────────

  def grid_prev_sheet_id
    @grid_sheet_id || @sheet_id
  end

  def find_grid_prev(acct)
    acct = acct.to_s.gsub('@', '').strip
    rows = read_from(grid_prev_sheet_id, GRID_PREV_SHEET, 'A:B')
    return nil if rows.empty?

    headers = header_map(rows[0])

    rows[1..].to_a.each_with_index do |row, i|
      id = first_present(cell(row, headers, 'ID'), row[0]).to_s.strip
      next unless id.gsub('@', '').strip.casecmp?(acct)

      return {
        row_num: i + 2,
        id:      id,
        prev:    first_present(cell(row, headers, '직전좌표'), row[1]).to_s.strip
      }
    end

    nil
  rescue => e
    puts "[find_grid_prev 오류] #{e.class} - #{e.message}"
    nil
  end

  def update_grid_prev(acct, coord)
    acct  = acct.to_s.gsub('@', '').strip
    coord = coord.to_s.strip.upcase
    sheet_id = grid_prev_sheet_id

    rows = read_from(sheet_id, GRID_PREV_SHEET, 'A:B')

    if rows.empty?
      append_to(sheet_id, GRID_PREV_SHEET, [acct, coord])
      return true
    end

    headers = header_map(rows[0])
    prev_col = header_col(headers, '직전좌표', 'B')

    rows[1..].to_a.each_with_index do |row, i|
      id = first_present(cell(row, headers, 'ID'), row[0]).to_s.strip
      next unless id.gsub('@', '').strip.casecmp?(acct)

      write_to(sheet_id, GRID_PREV_SHEET, "#{prev_col}#{i + 2}", [[coord]])
      return true
    end

    append_to(sheet_id, GRID_PREV_SHEET, [acct, coord])
    true
  rescue => e
    puts "[update_grid_prev 오류] #{e.class} - #{e.message}"
    false
  end

  # ──────────────────────────────────────────────
  # 탐사 파티 스레드([탐사/방향] 단체 멘션 전용) - 마지막 봇 메시지 ID 저장
  #
  # 헤더: 파티키 / 스레드ID
  # 파티키는 참여자 계정을 정렬 후 '+'로 이어붙인 문자열.
  # 같은 파티가 이동할 때마다 이 스레드ID에 이어서 답장하면
  # 그룹 DM 전체가 하나의 스레드로 계속 이어진다.
  # ──────────────────────────────────────────────

  def find_party_thread(party_key)
    party_key = party_key.to_s.strip
    return nil if party_key.empty?

    rows = read_from(grid_prev_sheet_id, PARTY_THREAD_SHEET, 'A:B')
    return nil if rows.empty?

    headers = header_map(rows[0])

    rows[1..].to_a.each_with_index do |row, i|
      key = first_present(cell(row, headers, '파티키'), row[0]).to_s.strip
      next unless key == party_key

      return {
        row_num:   i + 2,
        thread_id: first_present(cell(row, headers, '스레드ID'), row[1]).to_s.strip
      }
    end

    nil
  rescue => e
    puts "[find_party_thread 오류] #{e.class} - #{e.message}"
    nil
  end

  def update_party_thread(party_key, thread_id)
    party_key = party_key.to_s.strip
    thread_id = thread_id.to_s.strip
    return false if party_key.empty?

    sheet_id = grid_prev_sheet_id
    rows = read_from(sheet_id, PARTY_THREAD_SHEET, 'A:B')

    if rows.empty?
      append_to(sheet_id, PARTY_THREAD_SHEET, [party_key, thread_id])
      return true
    end

    headers = header_map(rows[0])
    thread_col = header_col(headers, '스레드ID', 'B')

    rows[1..].to_a.each_with_index do |row, i|
      key = first_present(cell(row, headers, '파티키'), row[0]).to_s.strip
      next unless key == party_key

      write_to(sheet_id, PARTY_THREAD_SHEET, "#{thread_col}#{i + 2}", [[thread_id]])
      return true
    end

    append_to(sheet_id, PARTY_THREAD_SHEET, [party_key, thread_id])
    true
  rescue => e
    puts "[update_party_thread 오류] #{e.class} - #{e.message}"
    false
  end

  # ──────────────────────────────────────────────
  # 장소
  #
  # 헤더:
  # 위치 / 이름 / 지문 / 선택지1~선택지6 / 공개여부
  # 오브젝트명 / 조사결과 / 획득아이템 / 1회한정 / 획득자ID
  # 크레딧 / 크레딧수령자ID / 크레딧대사 / 크리쳐
  #
  # 행 구조: 위치 칸이 채워진 행이 "헤더 행"(그 위치 자체)이며,
  # 바로 뒤에 위치 칸이 비어있는 행들이 이어지면 그 헤더 행에 속한
  # 하위 오브젝트 행으로 취급한다. 위치 칸이 다시 채워진 행이 나오면
  # 새로운 위치로 넘어간 것으로 보고 이전 그룹은 종료한다.
  #
  # 주의: 같은 "이름"을 여러 좌표가 재사용하는 경우(예: "텅 빈 공터"가
  # 여러 칸에 반복 사용)가 있으므로, 오브젝트 그룹핑은 반드시 좌표(또는
  # 명시적 위치 칸) 기준으로만 하고 이름으로는 하지 않는다. 이름으로
  # 그룹핑하면 이름이 같은 다른 칸의 오브젝트/아이템이 섞여 들어온다.
  # ──────────────────────────────────────────────

  def find_location(location_code)
    found = find_location_in(@sheet_id, location_code)
    return found if found

    return nil if @grid_sheet_id.nil?
    find_location_in(@grid_sheet_id, location_code)
  rescue => e
    puts "[find_location 오류] #{e.class} - #{e.message}"
    nil
  end

  def find_location_in(sheet_id, location_code)
    rows = read_from(sheet_id, LOCATION_SHEET, 'A:S')
    return nil if rows.empty?

    headers = header_map(rows[0])
    location_lookup = build_location_lookup(rows, headers)

    query = location_code.to_s.strip
    query_upper = query.upcase

    resolved = location_lookup[query_upper] || location_lookup[query]
    target_code = (resolved ? resolved[:code] : query_upper).to_s.strip.upcase

    result = nil
    objects = []
    in_group = false

    rows[1..].to_a.each do |row|
      row_code = cell(row, headers, '위치').upcase
      row_name = cell(row, headers, '이름')
      canonical_code = row_code.empty? ? row_name : row_code
      canonical_code = canonical_code.to_s.strip

      if !canonical_code.empty?
        # 위치 칸이 채워진 행 = 새 위치의 시작. 이전 그룹은 여기서 끝난다.
        if canonical_code.upcase == target_code
          in_group = true

          choices = []
          (1..6).each do |n|
            raw = cell(row, headers, "선택지#{n}")
            next if raw.empty?

            resolved_choice = resolve_location_choice(raw, location_lookup)
            choices << { code: resolved_choice[:code], label: resolved_choice[:label] }
          end

          result = {
            code:     canonical_code,
            name:     row_name,
            label:    row_name.empty? ? canonical_code : row_name,
            desc:     cell(row, headers, '지문'),
            choices:  choices,
            public:   truthy?(cell(row, headers, '공개여부')),
            creature: cell(row, headers, '크리쳐'),
            blocked:  cell(row, headers, '막힌방향')
          }
        else
          in_group = false
        end
      end

      next unless in_group

      obj_name = cell(row, headers, '오브젝트명')
      item_field = cell(row, headers, '획득아이템')

      # 오브젝트명(K열)이 비어있어도 획득아이템(M열)만 채워져 있으면
      # 그 아이템명을 오브젝트명으로 삼아 인식한다.
      effective_name = obj_name.empty? ? item_field.split(',').first.to_s.strip : obj_name
      next if effective_name.empty?

      objects << {
        location:         target_code,
        name:             effective_name,
        result:           cell(row, headers, '조사결과'),
        item:             item_field,
        once:             truthy?(cell(row, headers, '1회한정')),
        taken_by:         cell(row, headers, '획득자ID'),
        credit:           cell(row, headers, '크레딧').gsub(/[^\-0-9]/, '').to_i,
        credit_taken_by:  cell(row, headers, '크레딧수령자ID'),
        credit_message:   cell(row, headers, '크레딧대사'),
        credit_line:      cell(row, headers, '크레딧대사'),
        creature:         cell(row, headers, '크리쳐')
      }
    end

    return nil unless result

    result[:objects] = objects
    result
  rescue => e
    puts "[find_location 오류] #{e.class} - #{e.message}"
    nil
  end

  def update_object_taken(location_code, obj_name, acct)
    return true if update_object_taken_in(@sheet_id, location_code, obj_name, acct)
    return false if @grid_sheet_id.nil?
    update_object_taken_in(@grid_sheet_id, location_code, obj_name, acct)
  rescue => e
    puts "[update_object_taken 오류] #{e.class} - #{e.message}"
    false
  end

  def update_object_taken_in(sheet_id, location_code, obj_name, acct)
    location_code = location_code.to_s.strip.upcase
    obj_name      = obj_name.to_s.strip
    acct          = acct.to_s.gsub('@', '').strip

    rows = read_from(sheet_id, LOCATION_SHEET, 'A:S')
    return false if rows.empty?

    headers = header_map(rows[0])
    taken_col = header_col(headers, '획득자ID', 'O')

    current_code = ''

    rows[1..].to_a.each_with_index do |row, i|
      row_code = cell(row, headers, '위치').upcase
      current_code = row_code unless row_code.empty?

      next unless current_code == location_code
      next unless cell(row, headers, '오브젝트명') == obj_name

      existing = cell(row, headers, '획득자ID')
      new_val = existing.empty? ? acct : "#{existing},#{acct}"

      write_to(sheet_id, LOCATION_SHEET, "#{taken_col}#{i + 2}", [[new_val]])
      return true
    end

    false
  rescue => e
    puts "[update_object_taken_in 오류] #{e.class} - #{e.message}"
    false
  end

  def update_credit_taken(location_code, obj_name, acct)
    return true if update_credit_taken_in(@sheet_id, location_code, obj_name, acct)
    return false if @grid_sheet_id.nil?
    update_credit_taken_in(@grid_sheet_id, location_code, obj_name, acct)
  rescue => e
    puts "[update_credit_taken 오류] #{e.class} - #{e.message}"
    false
  end

  def update_credit_taken_in(sheet_id, location_code, obj_name, acct)
    location_code = location_code.to_s.strip.upcase
    obj_name      = obj_name.to_s.strip
    acct          = acct.to_s.gsub('@', '').strip

    rows = read_from(sheet_id, LOCATION_SHEET, 'A:S')
    return false if rows.empty?

    headers = header_map(rows[0])
    taken_col = header_col(headers, '크레딧수령자ID', 'Q')

    current_code = ''

    rows[1..].to_a.each_with_index do |row, i|
      row_code = cell(row, headers, '위치').upcase
      current_code = row_code unless row_code.empty?

      next unless current_code == location_code
      next unless cell(row, headers, '오브젝트명') == obj_name

      existing = cell(row, headers, '크레딧수령자ID')
      new_val = existing.empty? ? acct : "#{existing},#{acct}"

      write_to(sheet_id, LOCATION_SHEET, "#{taken_col}#{i + 2}", [[new_val]])
      return true
    end

    false
  rescue => e
    puts "[update_credit_taken_in 오류] #{e.class} - #{e.message}"
    false
  end

  def available_locations
    rows = read(LOCATION_SHEET, 'A:S')
    return [] if rows.empty?

    headers = header_map(rows[0])

    rows[1..].to_a.each_with_object([]) do |row, result|
      code = cell(row, headers, '위치').upcase
      next if code.empty?
      next unless truthy?(cell(row, headers, '공개여부'))

      label = cell(row, headers, '이름')

      result << {
        code: code,
        label: label.empty? ? code : label
      }
    end
  rescue => e
    puts "[available_locations 오류] #{e.class} - #{e.message}"
    []
  end

  # ──────────────────────────────────────────────
  # 전투봇 연동
  #
  # 보스 탭은 CREATURE_SHEET_ID의 보스 탭을 사용한다.
  # A = 활성화
  # B = 크리쳐명
  # C = 위치
  # ──────────────────────────────────────────────

  # 조사맵 좌표계(C~O, 2~8)와 전투봇 좌표계(A~G, 1~8)는 서로 다른 체계이므로,
  # 전투봇이 이해할 수 있는 좌표일 때만 위치를 함께 넘긴다. 그 외에는 크리쳐
  # 활성화만 하고 위치는 건드리지 않아 전투봇 쪽 기존 위치(또는 기본값)를 그대로 둔다.
  def battle_grid_coord?(code)
    !!code.to_s.strip.upcase.match(/\A[A-G][1-8]\z/)
  end

  def activate_creature_boss(creature_name, location_code = nil)
    creature_name = creature_name.to_s.strip
    location_code = location_code.to_s.strip.upcase
    battle_pos = battle_grid_coord?(location_code) ? location_code : ''

    return false if creature_name.empty?

    # 1순위: 크리쳐 시트의 스탯 탭에서 이름이 같은 행을 활성화한다.
    rows = read_from(@creature_sheet_id, '스탯', 'A:Z')
    unless rows.empty?
      headers = header_map(rows[0])
      active_col = header_col(headers, '활성', 'A')
      location_col = header_col(headers, '위치', 'C')

      rows[1..].to_a.each_with_index do |row, i|
        name = cell(row, headers, '이름')
        next unless name == creature_name

        row_num = i + 2
        write_to(@creature_sheet_id, '스탯', "#{active_col}#{row_num}", [[true]])
        write_to(@creature_sheet_id, '스탯', "#{location_col}#{row_num}", [[battle_pos]]) unless battle_pos.empty?
        return true
      end
    end

    # 2순위: 구버전 보스 탭이 존재하는 경우만 사용한다.
    boss_rows = read_from(@creature_sheet_id, BOSS_SHEET, 'A:C')
    return false if boss_rows.empty?

    write_to(
      @creature_sheet_id,
      BOSS_SHEET,
      'A2:C2',
      [[true, creature_name, battle_pos]]
    )
  rescue => e
    puts "[activate_creature_boss 오류] #{e.class} - #{e.message}"
    false
  end

  private

  def first_present(*values)
    values.each do |value|
      text = value.to_s
      return text unless text.strip.empty?
    end

    ''
  end

  def header_col(headers, name, fallback)
    idx = headers[normalize_header(name)]
    return fallback if idx.nil?

    column_letter(idx + 1)
  end

  def column_letter(number)
    result = ''
    n = number.to_i

    while n > 0
      n -= 1
      result.prepend((65 + (n % 26)).chr)
      n /= 26
    end

    result
  end

  def build_location_lookup(rows, headers)
    lookup = {}

    rows[1..].to_a.each do |row|
      code = cell(row, headers, '위치').upcase
      name = cell(row, headers, '이름')
      canonical_code = code.empty? ? name : code
      canonical_code = canonical_code.to_s.strip
      next if canonical_code.empty?

      label = name.empty? ? canonical_code : name

      lookup[canonical_code.upcase] = { code: canonical_code, label: label }
      lookup[canonical_code] = { code: canonical_code, label: label }
      lookup[name] = { code: canonical_code, label: label } unless name.empty?
    end

    lookup
  end

  def resolve_location_choice(raw, lookup)
    text = raw.to_s.strip
    upper = text.upcase

    return lookup[upper] if lookup[upper]
    return lookup[text] if lookup[text]

    if upper.match?(/\A[A-Z]+\d+\z/)
      return { code: upper, label: upper }
    end

    { code: text, label: text }
  end
end
