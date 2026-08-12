# commands/scout_start_command.rb
# encoding: UTF-8
#
# [탐험] [탐험] @동료1 @동료2 ...
# 멘션을 함께 쓰면 멘션된 사람 전원 + 본인이 파티가 되어 함께 시작 장소로
# 이동하고, 파티 전체에게 그룹 DM으로 안내된다(location_command.rb와 동일한
# 방식, 같은 탐사스레드 시트 공유). 멘션 없이 혼자 쓰면 기존과 동일하게
# 개인 단위로 동작한다.
require_relative 'location_command'

class ScoutStartCommand
  START_ROW = 2  # 장소 시트 2행 고정
  MAX_CHARS = 1000

  def initialize(sheet_manager, mastodon_client, sender, status)
    @sheet_manager   = sheet_manager
    @mastodon_client = mastodon_client
    @sender          = sender.to_s.gsub('@', '')
    @status          = status
    @party           = build_party
  end

  def execute
    user = @sheet_manager.find_user(@sender)
    unless user
      dm_solo("아직 등록되지 않은 계정입니다.")
      return
    end

    start_location = fetch_start_location
    unless start_location
      dm_solo("시작 장소를 불러올 수 없습니다. 장소 시트 2행을 확인해주세요.")
      return
    end

    @party.each do |acct|
      @sheet_manager.update_scout_state(acct, {
        location:    start_location[:code],
        last_action: '탐험'
      })
    end

    lines = []
    lines << "탐험을 시작합니다."
    lines << "──────────────────"
    lines.concat(LocationCommand.build_lines(start_location))

    send_party(lines)
  rescue => e
    puts "[ScoutStartCommand 오류] #{e.message}"
    dm_solo("처리 중 오류가 발생했습니다.")
  end

  private

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

  # ── 발송 ──

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
    puts "[ScoutStartCommand DM 오류] #{e.class}: #{e.message}"
    nil
  end
end
