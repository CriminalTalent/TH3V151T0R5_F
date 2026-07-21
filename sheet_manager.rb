# sheet_manager.rb
# encoding: UTF-8

require 'google/apis/sheets_v4'
require 'googleauth'

class SheetManager
  USERS_SHEET    = '사용자'.freeze
  LOCATION_SHEET = '장소'.freeze
  SCOUT_SHEET    = '조사상태'.freeze
  BOSS_SHEET     = '보스'.freeze

  def initialize(service, sheet_id, creature_sheet_id = nil)
    @service           = service
    @sheet_id          = sheet_id
    @creature_sheet_id = creature_sheet_id.to_s.strip.empty? ? sheet_id : creature_sheet_id
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

      next unless id.gsub('@', '').strip == acct

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

      next unless id.gsub('@', '').strip == acct

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
      next unless id.gsub('@', '').strip == acct

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
      next unless id.gsub('@', '').strip == acct

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
  # 장소
  #
  # 헤더:
  # 위치 / 이름 / 지문 / 선택지1~선택지6 / 공개여부
  # 오브젝트명 / 조사결과 / 획득아이템 / 1회한정 / 획득자ID
  # 크레딧 / 크레딧수령자ID / 크레딧대사 / 크리쳐
  # ──────────────────────────────────────────────

  def find_location(location_code)
    rows = read(LOCATION_SHEET, 'A:S')
    return nil if rows.empty?

    headers = header_map(rows[0])
    location_lookup = build_location_lookup(rows, headers)

    query = location_code.to_s.strip
    query_upper = query.upcase

    resolved = location_lookup[query_upper] || location_lookup[query]
    target_code = resolved ? resolved[:code].to_s.strip : query_upper
    target_name = resolved ? resolved[:label].to_s.strip : query

    result = nil
    objects = []
    current_code = ''
    current_name = ''

    rows[1..].to_a.each do |row|
      row_code = cell(row, headers, '위치').upcase
      row_name = cell(row, headers, '이름')
      canonical_code = row_code.empty? ? row_name : row_code
      canonical_code = canonical_code.to_s.strip
      canonical_code_upper = canonical_code.upcase

      unless canonical_code.empty?
        current_code = canonical_code
        current_name = row_name.empty? ? canonical_code : row_name
      end

      row_matches =
        (!row_code.empty? && row_code == target_code.to_s.upcase) ||
        (!row_name.empty? && row_name == query) ||
        (!row_name.empty? && row_name == target_name) ||
        (!canonical_code.empty? && canonical_code_upper == target_code.to_s.upcase)

      if row_matches
        choices = []

        (1..6).each do |n|
          raw = cell(row, headers, "선택지#{n}")
          next if raw.empty?

          resolved_choice = resolve_location_choice(raw, location_lookup)

          choices << {
            code:  resolved_choice[:code],
            label: resolved_choice[:label]
          }
        end

        result = {
          code:     canonical_code,
          name:     row_name,
          label:    row_name.empty? ? canonical_code : row_name,
          desc:     cell(row, headers, '지문'),
          choices:  choices,
          public:   truthy?(cell(row, headers, '공개여부')),
          creature: cell(row, headers, '크리쳐')
        }

        target_code = canonical_code
      end

      next unless current_code.to_s.upcase == target_code.to_s.upcase || current_name == query || current_name == target_name

      obj_name = cell(row, headers, '오브젝트명')
      next if obj_name.empty?

      objects << {
        location:         current_code,
        name:             obj_name,
        result:           cell(row, headers, '조사결과'),
        item:             cell(row, headers, '획득아이템'),
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
    location_code = location_code.to_s.strip.upcase
    obj_name      = obj_name.to_s.strip
    acct          = acct.to_s.gsub('@', '').strip

    rows = read(LOCATION_SHEET, 'A:S')
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

      write(LOCATION_SHEET, "#{taken_col}#{i + 2}", [[new_val]])
      return true
    end

    false
  rescue => e
    puts "[update_object_taken 오류] #{e.class} - #{e.message}"
    false
  end

  def update_credit_taken(location_code, obj_name, acct)
    location_code = location_code.to_s.strip.upcase
    obj_name      = obj_name.to_s.strip
    acct          = acct.to_s.gsub('@', '').strip

    rows = read(LOCATION_SHEET, 'A:S')
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

      write(LOCATION_SHEET, "#{taken_col}#{i + 2}", [[new_val]])
      return true
    end

    false
  rescue => e
    puts "[update_credit_taken 오류] #{e.class} - #{e.message}"
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

  def activate_creature_boss(creature_name, location_code = nil)
    creature_name = creature_name.to_s.strip
    location_code = location_code.to_s.strip.upcase

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
        write_to(@creature_sheet_id, '스탯', "#{location_col}#{row_num}", [[location_code]]) unless location_code.empty?
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
      [[true, creature_name, location_code]]
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
