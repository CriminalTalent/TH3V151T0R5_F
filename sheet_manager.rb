# sheet_manager.rb
# encoding: UTF-8
require 'google/apis/sheets_v4'
require 'googleauth'

class SheetManager
  USERS_SHEET    = '사용자'.freeze
  LOCATION_SHEET = '장소'.freeze
  SCOUT_SHEET    = '조사상태'.freeze

  def initialize(service, sheet_id)
    @service  = service
    @sheet_id = sheet_id
  end

  def read(sheet, range = 'A:Z')
    @service.get_spreadsheet_values(@sheet_id, "#{sheet}!#{range}").values || []
  rescue => e
    puts "[시트 읽기 오류] #{e.message}"
    []
  end

  def write(sheet, range, values)
    body = Google::Apis::SheetsV4::ValueRange.new(values: values)
    @service.update_spreadsheet_value(
      @sheet_id, "#{sheet}!#{range}", body,
      value_input_option: 'USER_ENTERED'
    )
  rescue => e
    puts "[시트 쓰기 오류] #{e.message}"
    false
  end

  def append(sheet, row)
    body = Google::Apis::SheetsV4::ValueRange.new(values: [row])
    @service.append_spreadsheet_value(
      @sheet_id, "#{sheet}!A:Z", body,
      value_input_option: 'USER_ENTERED'
    )
  rescue => e
    puts "[시트 추가 오류] #{e.message}"
    false
  end

  # ──────────────────────────────────────────────
  # 사용자
  # ──────────────────────────────────────────────
  def find_user(acct)
    acct = acct.to_s.gsub('@', '').strip
    rows = read(USERS_SHEET, 'A:N')
    rows[1..].each_with_index do |row, i|
      next unless row[0]&.gsub('@', '')&.strip == acct
      return {
        row_num: i + 2,
        id:      row[0].to_s.strip,
        name:    row[1].to_s.strip,
        credits: (row[2] || 0).to_i,
        items:   row[3].to_s,
        house:   row[4].to_s.strip
      }
    end
    nil
  rescue => e
    puts "[find_user 오류] #{e.message}"
    nil
  end

  def update_user(acct, attrs)
    acct = acct.to_s.gsub('@', '').strip
    col_map = {
      credits: 'C',
      items:   'D',
      house:   'E'
    }
    rows = read(USERS_SHEET, 'A:N')
    rows[1..].each_with_index do |row, i|
      next unless row[0]&.gsub('@', '')&.strip == acct
      row_num = i + 2
      attrs.each do |key, val|
        col = col_map[key]
        next unless col
        write(USERS_SHEET, "#{col}#{row_num}", [[val]])
      end
      return true
    end
    false
  end

  # ──────────────────────────────────────────────
  # 조사상태
  # ──────────────────────────────────────────────
  def find_scout_state(acct)
    acct = acct.to_s.gsub('@', '').strip
    rows = read(SCOUT_SHEET, 'A:C')
    rows[1..].each_with_index do |row, i|
      next unless row[0]&.gsub('@', '')&.strip == acct
      return {
        row_num:     i + 2,
        id:          row[0].to_s.strip,
        location:    row[1].to_s.strip,
        last_action: row[2].to_s.strip
      }
    end
    nil
  end

  def update_scout_state(acct, attrs)
    acct = acct.to_s.gsub('@', '').strip
    col_map = { location: 'B', last_action: 'C' }
    rows = read(SCOUT_SHEET, 'A:C')
    rows[1..].each_with_index do |row, i|
      next unless row[0]&.gsub('@', '')&.strip == acct
      row_num = i + 2
      attrs.each do |key, val|
        col = col_map[key]
        next unless col
        write(SCOUT_SHEET, "#{col}#{row_num}", [[val]])
      end
      return true
    end
    append(SCOUT_SHEET, [acct, attrs[:location].to_s, attrs[:last_action].to_s])
    true
  end

  # ──────────────────────────────────────────────
  # 장소
  # ──────────────────────────────────────────────
  def find_location(location_name)
    rows = read(LOCATION_SHEET, 'A:L')
    location_name = location_name.to_s.strip
    result = nil
    objects = []
    current_loc = ''

    rows[1..].each do |row|
      next if row.nil?
      name = row[0].to_s.strip
      current_loc = name unless name.empty?

      if name == location_name
        result = {
          name:    name,
          desc:    row[1].to_s.strip,
          choices: [row[2], row[3], row[4], row[5]].map(&:to_s).map(&:strip).reject(&:empty?),
          public:  row[6].to_s.strip.upcase != 'FALSE'
        }
      end

      obj_name = row[7].to_s.strip
      next if obj_name.empty?
      next unless current_loc == location_name

      objects << {
        location:  current_loc,
        name:      obj_name,
        result:    row[8].to_s.strip,
        item:      row[9].to_s.strip,
        once:      row[10].to_s.strip.upcase == 'TRUE' || row[10] == true,
        taken_by:  row[11].to_s.strip
      }
    end

    return nil unless result
    result[:objects] = objects
    result
  end

  def update_object_taken(location_name, obj_name, acct)
    location_name = location_name.to_s.strip
    obj_name      = obj_name.to_s.strip
    acct          = acct.to_s.gsub('@', '').strip
    rows = read(LOCATION_SHEET, 'A:L')
    current_loc = ''
    rows[1..].each_with_index do |row, i|
      next if row.nil?
      loc = row[0].to_s.strip
      current_loc = loc unless loc.empty?
      next unless current_loc == location_name
      next unless row[7].to_s.strip == obj_name
      existing = row[11].to_s.strip
      new_val  = existing.empty? ? acct : "#{existing},#{acct}"
      write(LOCATION_SHEET, "L#{i + 2}", [[new_val]])
      return true
    end
    false
  end
end

  def available_locations
    rows = read(LOCATION_SHEET, 'A:G')
    result = []
    rows[1..].each do |row|
      next if row.nil? || row[0].to_s.strip.empty?
      next if row[6].to_s.strip.upcase == 'FALSE'
      result << row[0].to_s.strip
    end
    result
  end
