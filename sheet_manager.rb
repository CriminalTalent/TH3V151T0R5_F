# sheet_manager.rb
# encoding: UTF-8

require 'google/apis/sheets_v4'
require 'googleauth'

class SheetManager
  USERS_SHEET    = '사용자'.freeze
  LOCATION_SHEET = '장소'.freeze
  EXTRA_LOCATION_SHEET = '추가'.freeze
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
    with_retry("읽기 #{sheet}!#{range}") do
      @service.get_spreadsheet_values(sheet_id, "#{sheet}!#{range}").values || []
    end
  rescue => e
    puts "[시트 읽기 오류] #{sheet}!#{range}: #{e.class} - #{e.message}"
    []
  end

  def write(sheet, range, values)
    write_to(@sheet_id, sheet, range, values)
  end

  def write_to(sheet_id, sheet, range, values)
    body = Google::Apis::SheetsV4::ValueRange.new(values: values)

    with_retry("쓰기 #{sheet}!#{range}") do
      @service.update_spreadsheet_value(
        sheet_id,
        "#{sheet}!#{range}",
        body,
        value_input_option: 'USER_ENTERED'
      )
    end

    true
  rescue => e
    puts "[시트 쓰기 오류] #{sheet}!#{range}: #{e.class} - #{e.message}"
    false
  end

  # 여러 셀을 한 번의 API 호출로 함께 쓴다. range_value_pairs는
  # [[범위문자열, [[값]]], ...] 형태.
  def write_batch(sheet, range_value_pairs)
    write_batch_to(@sheet_id, sheet, range_value_pairs)
  end

  def write_batch_to(sheet_id, sheet, range_value_pairs)
    return true if range_value_pairs.empty?

    data = range_value_pairs.map do |range, values|
      Google::Apis::SheetsV4::ValueRange.new(range: "#{sheet}!#{range}", values: values)
    end
    request = Google::Apis::SheetsV4::BatchUpdateValuesRequest.new(
      value_input_option: 'USER_ENTERED',
      data: data
    )
    with_retry("배치 쓰기 #{sheet} (#{range_value_pairs.size}건)") do
      @service.batch_update_values(sheet_id, request)
    end
    true
  rescue => e
    puts "[시트 배치 쓰기 오류] #{sheet}: #{e.class} - #{e.message}"
    false
  end

  def append(sheet, row)
    append_to(@sheet_id, sheet, row)
  end

  def append_to(sheet_id, sheet, row)
    body = Google::Apis::SheetsV4::ValueRange.new(values: [row])

    with_retry("추가 #{sheet}") do
      @service.append_spreadsheet_value(
        sheet_id,
        "#{sheet}!A:Z",
        body,
        value_input_option: 'USER_ENTERED'
      )
    end

    true
  rescue => e
    puts "[시트 추가 오류] #{sheet}: #{e.class} - #{e.message}"
    false
  end

  # 429 / 할당량 초과(RateLimitError) 등 일시적 오류에 대해 최대 3회
  # 재시도한다. 재시도 없이 바로 실패로 처리하면, 사람이 몰려 순간적으로
  # 할당량을 초과했을 때 실제로는 존재하는 계정/위치/오브젝트를 "없음"으로
  # 오판하는 문제가 생긴다 (등록 안 된 계정 오탐, 아이템 획득 실패, 파티
  # 스레드 유실 등).
  def with_retry(label, max_retries: 3)
    attempt = 0
    begin
      yield
    rescue Google::Apis::RateLimitError, Google::Apis::ServerError, Google::Apis::TransmissionError => e
      attempt += 1
      if attempt <= max_retries
        wait_seconds = 1.5 * attempt
        puts "[시트 재시도] #{label}: #{e.class} - #{wait_seconds}초 후 재시도 (#{attempt}/#{max_retries})"
        sleep(wait_seconds)
        retry
      else
        raise
      end
    end
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

    normalize_location_value(row[idx])
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

  # 여러 계정의 조사상태를 시트 1회 읽기로 한꺼번에 조회한다.
  # (파티원 수만큼 find_scout_state를 반복 호출하면 그 수만큼 시트 전체를
  # 매번 다시 읽게 되어 파티 인원이 많을수록 응답이 느려짐 — 2026-08-13
  # 전투불능 체크 추가 후 발견된 지연 원인. 이 메서드로 1회 조회로 대체.)
  def find_scout_states(accts)
    wanted = accts.to_a.map { |a| a.to_s.gsub('@', '').strip }
    result = {}
    return result if wanted.empty?

    rows = read(SCOUT_SHEET, 'A:Z')
    return result if rows.empty?

    headers = header_map(rows[0])

    rows[1..].to_a.each_with_index do |row, i|
      id = first_present(cell(row, headers, 'ID'), row[0]).to_s.strip
      norm_id = id.gsub('@', '').strip
      match = wanted.find { |w| norm_id.casecmp?(w) }
      next unless match

      result[match] = {
        row_num:     i + 2,
        id:          id,
        location:    first_present(cell(row, headers, '위치'), row[1]).to_s.strip,
        last_action: first_present(cell(row, headers, '최근행동'), cell(row, headers, 'last_action'), row[2]).to_s.strip
      }
    end

    result
  rescue => e
    puts "[find_scout_states 오류] #{e.class} - #{e.message}"
    {}
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

    # 추가 직전 한 번 더 최신 상태를 확인한다 (동시에 여러 명령이 겹치면
    # 둘 다 "없음"으로 판단해 중복 행을 만드는 경쟁 조건을 줄이기 위함).
    fresh_rows = read(SCOUT_SHEET, 'A:Z')
    if fresh_rows[0]
      fresh_headers = header_map(fresh_rows[0])
      fresh_location_col = header_col(fresh_headers, '위치', 'B')
      fresh_action_col   = header_col(fresh_headers, '최근행동', 'C')
      fresh_rows[1..].to_a.each_with_index do |row, i|
        id = first_present(cell(row, fresh_headers, 'ID'), row[0]).to_s.strip
        next unless id.gsub('@', '').strip.casecmp?(acct)
        row_num = i + 2
        write(SCOUT_SHEET, "#{fresh_location_col}#{row_num}", [[attrs[:location].to_s]]) if attrs.key?(:location)
        write(SCOUT_SHEET, "#{fresh_action_col}#{row_num}", [[attrs[:last_action].to_s]]) if attrs.key?(:last_action)
        return true
      end
    end

    append(SCOUT_SHEET, [acct, attrs[:location].to_s, attrs[:last_action].to_s])
    true
  rescue => e
    puts "[update_scout_state 오류] #{e.class} - #{e.message}"
    false
  end

  # 파티 전원의 조사상태를 한 번의 읽기 + 한 번의 배치 쓰기로 갱신한다.
  # (update_scout_state를 파티원 수만큼 반복 호출하면 각각 전체 시트를
  # 다시 읽고 셀마다 따로 쓰게 되어, 파티 5명이면 최대 15회까지 API를 호출하게 되던 문제를 개선.
  # 이제는 읽기 1회 + 배치 쓰기 1회로 파티 인원과 무관하게 고정된다.)
  def normalize_location_value(value)
    value.to_s.gsub("\u00A0", " ").gsub(/\s+/, ' ').strip
  end

  def update_scout_states_batch(accounts, attrs)
    accounts = accounts.to_a.map { |a| a.to_s.gsub('@', '').strip }.uniq
    return true if accounts.empty?
    attrs = attrs.dup
    attrs[:location] = normalize_location_value(attrs[:location]) if attrs.key?(:location)

    rows = read(SCOUT_SHEET, 'A:Z')

    if rows.empty?
      accounts.each { |acct| append(SCOUT_SHEET, [acct, attrs[:location].to_s, attrs[:last_action].to_s]) }
      return true
    end

    headers = header_map(rows[0])
    location_col = header_col(headers, '위치', 'B')
    action_col   = header_col(headers, '최근행동', 'C')

    found = {}
    rows[1..].to_a.each_with_index do |row, i|
      id = first_present(cell(row, headers, 'ID'), row[0]).to_s.strip
      norm = id.gsub('@', '').strip
      match = accounts.find { |a| norm.casecmp?(a) }
      next unless match
      found[match] = i + 2
    end

    pairs = []
    found.each do |acct, row_num|
      pairs << ["#{location_col}#{row_num}", [[attrs[:location].to_s]]] if attrs.key?(:location)
      pairs << ["#{action_col}#{row_num}", [[attrs[:last_action].to_s]]] if attrs.key?(:last_action)
    end
    write_batch(SCOUT_SHEET, pairs) unless pairs.empty?

    missing = accounts - found.keys
    if missing.any?
      # 추가 직전 한 번 더 최신 상태를 확인한다 (경쟁 조건으로 인한 중복 행 방지).
      still_missing = missing.dup
      fresh_rows = read(SCOUT_SHEET, 'A:Z')
      if fresh_rows[0]
        fresh_headers = header_map(fresh_rows[0])
        fresh_location_col = header_col(fresh_headers, '위치', 'B')
        fresh_action_col   = header_col(fresh_headers, '최근행동', 'C')
        fresh_found = {}
        fresh_rows[1..].to_a.each_with_index do |row, i|
          id = first_present(cell(row, fresh_headers, 'ID'), row[0]).to_s.strip
          norm = id.gsub('@', '').strip
          match = still_missing.find { |a| norm.casecmp?(a) }
          next unless match
          fresh_found[match] = i + 2
        end
        fresh_found.each do |acct, row_num|
          write(SCOUT_SHEET, "#{fresh_location_col}#{row_num}", [[attrs[:location].to_s]]) if attrs.key?(:location)
          write(SCOUT_SHEET, "#{fresh_action_col}#{row_num}", [[attrs[:last_action].to_s]]) if attrs.key?(:last_action)
        end
        still_missing -= fresh_found.keys
      end
      still_missing.each { |acct| append(SCOUT_SHEET, [acct, attrs[:location].to_s, attrs[:last_action].to_s]) }
    end

    true
  rescue => e
    puts "[update_scout_states_batch 오류] #{e.class} - #{e.message}"
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

    # 18자리 status ID가 USER_ENTERED 입력 옵션 때문에 숫자로 재해석되어
    # 과학적 표기법(예: 1.17E+17)으로 정밀도가 손실되는 사고를 막기 위해,
    # 앞에 작은따옴표를 붙여 시트에 무조건 텍스트로 저장되도록 강제한다.
    thread_id_safe = thread_id.empty? ? thread_id : "'#{thread_id}"

    sheet_id = grid_prev_sheet_id
    rows = read_from(sheet_id, PARTY_THREAD_SHEET, 'A:B')

    if rows.empty?
      append_to(sheet_id, PARTY_THREAD_SHEET, [party_key, thread_id_safe])
      return true
    end

    headers = header_map(rows[0])
    thread_col = header_col(headers, '스레드ID', 'B')

    rows[1..].to_a.each_with_index do |row, i|
      key = first_present(cell(row, headers, '파티키'), row[0]).to_s.strip
      next unless key == party_key

      write_to(sheet_id, PARTY_THREAD_SHEET, "#{thread_col}#{i + 2}", [[thread_id_safe]])
      return true
    end

    append_to(sheet_id, PARTY_THREAD_SHEET, [party_key, thread_id_safe])
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

  # 여러 좌표의 "공개여부/막힌방향"만 한 번의 시트 읽기로 배치 조회한다.
  # (available_directions가 방향마다 find_location을 개별 호출하면
  # 최악의 경우 [탐사/방향] 명령 하나에 최대 12번(4방향 x 3단계 폴백)의
  # 시트 API 호출이 발생하던 것을 3번 이하로 줄인다 — 2026-08-15 발견.
  # find_location과 달리 오브젝트/선택지 등 무거운 파싱은 하지 않는다.)
  def find_cells_public_batch(codes)
    codes = codes.to_a.map { |c| c.to_s.strip.upcase }.uniq
    result = {}
    return result if codes.empty?

    sources = [[@sheet_id, LOCATION_SHEET]]
    unless @grid_sheet_id.nil?
      sources << [@grid_sheet_id, LOCATION_SHEET]
      sources << [@grid_sheet_id, EXTRA_LOCATION_SHEET]
    end

    remaining = codes.dup
    sources.each do |sheet_id, sheet_name|
      break if remaining.empty?
      rows = read_from(sheet_id, sheet_name, 'A:T')
      next if rows.empty?

      headers = header_map(rows[0])
      rows[1..].to_a.each do |row|
        code = cell(row, headers, '위치').upcase
        next unless remaining.include?(code)

        result[code] = {
          public:  truthy?(cell(row, headers, '공개여부')),
          blocked: cell(row, headers, '막힌방향')
        }
        remaining.delete(code)
      end
    end

    result
  rescue => e
    puts "[find_cells_public_batch 오류] #{e.class} - #{e.message}"
    result
  end

  def find_location(location_code)
    found = find_location_in(@sheet_id, location_code)
    return found if found

    return nil if @grid_sheet_id.nil?
    found = find_location_in(@grid_sheet_id, location_code)
    return found if found
    find_location_in(@grid_sheet_id, location_code, EXTRA_LOCATION_SHEET)
  rescue => e
    puts "[find_location 오류] #{e.class} - #{e.message}"
    nil
  end

  def find_location_in(sheet_id, location_code, sheet_name = LOCATION_SHEET)
    rows = read_from(sheet_id, sheet_name, 'A:T')
    return nil if rows.empty?

    headers = header_map(rows[0])
    location_lookup = build_location_lookup(rows, headers)

    query = normalize_location_value(location_code)
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
      # 그 아이템명을 오브젝트명으로 삼아 인식한다. 이 경우 named: false로
      # 표시해, 안내 문구에서 "[조사]"를 권하지 않도록 구분한다
      # (K열이 비어있으면 조사결과도 없어 조사할 대상 자체가 없기 때문).
      effective_name = obj_name.empty? ? item_field.split(',').first.to_s.strip : obj_name
      next if effective_name.empty?

      objects << {
        location:         target_code,
        name:             effective_name,
        named:            !obj_name.empty?,
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
    return true if update_object_taken_in(@grid_sheet_id, location_code, obj_name, acct)
    update_object_taken_in(@grid_sheet_id, location_code, obj_name, acct, EXTRA_LOCATION_SHEET)
  rescue => e
    puts "[update_object_taken 오류] #{e.class} - #{e.message}"
    false
  end

  def update_object_taken_in(sheet_id, location_code, obj_name, acct, sheet_name = LOCATION_SHEET)
    location_code = location_code.to_s.strip.upcase
    obj_name      = obj_name.to_s.strip
    acct          = acct.to_s.gsub('@', '').strip

    rows = read_from(sheet_id, sheet_name, 'A:T')
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

      write_to(sheet_id, sheet_name, "#{taken_col}#{i + 2}", [[new_val]])
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
    return true if update_credit_taken_in(@grid_sheet_id, location_code, obj_name, acct)
    update_credit_taken_in(@grid_sheet_id, location_code, obj_name, acct, EXTRA_LOCATION_SHEET)
  rescue => e
    puts "[update_credit_taken 오류] #{e.class} - #{e.message}"
    false
  end

  def update_credit_taken_in(sheet_id, location_code, obj_name, acct, sheet_name = LOCATION_SHEET)
    location_code = location_code.to_s.strip.upcase
    obj_name      = obj_name.to_s.strip
    acct          = acct.to_s.gsub('@', '').strip

    rows = read_from(sheet_id, sheet_name, 'A:T')
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

      write_to(sheet_id, sheet_name, "#{taken_col}#{i + 2}", [[new_val]])
      return true
    end

    false
  rescue => e
    puts "[update_credit_taken_in 오류] #{e.class} - #{e.message}"
    false
  end

  def available_locations
    rows = read(LOCATION_SHEET, 'A:T')
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

    # 크리쳐 시트의 스탯 탭에서 이름이 같은 행을 활성화한다.
    # (구버전 '보스' 탭 폴백은 제거했습니다 — 해당 탭이 시트에 더 이상
    # 존재하지 않아 매칭 실패 시마다 badRequest만 발생시키며 API 호출만
    # 낭비하고 있었습니다. README/STANDARD 상으로도 '보스 탭 사용 안 함'이
    # 이미 확정된 사양입니다.)
    rows = read_from(@creature_sheet_id, '스탯', 'A:Z')
    return false if rows.empty?

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

    false
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
