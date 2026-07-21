# commands/scout_start_command.rb
# encoding: UTF-8

require_relative 'location_command'

class ScoutStartCommand
  START_ROW = 2  # 장소 시트 2행 고정

  def initialize(sheet_manager, mastodon_client, sender, status)
    @sheet_manager   = sheet_manager
    @mastodon_client = mastodon_client
    @sender          = sender.to_s.gsub('@', '')
    @status          = status
  end

  def execute
    user = @sheet_manager.find_user(@sender)
    unless user
      dm("아직 등록되지 않은 계정입니다.")
      return
    end

    start_location = fetch_start_location
    unless start_location
      dm("시작 장소를 불러올 수 없습니다. 장소 시트 2행을 확인해주세요.")
      return
    end

    @sheet_manager.update_scout_state(@sender, {
      location:    start_location[:code],
      last_action: '탐험'
    })

    lines = []
    lines << "탐험을 시작합니다."
    lines << "──────────────────"
    lines.concat(LocationCommand.build_lines(start_location))

    dm(lines.join("\n"))
  rescue => e
    puts "[ScoutStartCommand 오류] #{e.message}"
    dm("처리 중 오류가 발생했습니다.")
  end

  private

  # 장소 시트 2행(첫 데이터 행)의 장소를 시작 위치로 사용
  def fetch_start_location
    rows = @sheet_manager.read(SheetManager::LOCATION_SHEET, 'A:S')
    return nil if rows.length < START_ROW

    headers   = @sheet_manager.header_map(rows[0])
    start_row = rows[START_ROW - 1]
    return nil unless start_row

    code = @sheet_manager.cell(start_row, headers, '위치')
    code = @sheet_manager.cell(start_row, headers, '이름') if code.empty?
    return nil if code.empty?

    @sheet_manager.find_location(code)
  end

  def dm(text)
    @mastodon_client.post_status(
      "@#{@sender} #{text}",
      reply_to_id: @status['id'],
      visibility: 'direct'
    )
  end
end
