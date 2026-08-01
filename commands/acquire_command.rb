# commands/acquire_command.rb
# encoding: UTF-8
#
# [획득/아이템] [획득/아이템] @동료1 @동료2 ...
# 멘션을 함께 쓰면 멘션된 사람 전원 + 본인 소지품에 전부 지급된다.
# 멘션 없이 혼자 쓰면 기존과 동일하게 본인만 받는다.

class AcquireCommand
  MAX_CHARS = 1000

  def initialize(sheet_manager, mastodon_client, sender, obj_name, status)
    @sheet_manager   = sheet_manager
    @mastodon_client = mastodon_client
    @sender          = sender.to_s.gsub('@', '')
    @obj_name        = obj_name.to_s.strip
    @status          = status
    @party           = build_party
  end

  def execute
    user = @sheet_manager.find_user(@sender)
    unless user
      dm_solo("아직 등록되지 않은 계정입니다.")
      return
    end

    state = @sheet_manager.find_scout_state(@sender)
    unless state && !state[:location].to_s.empty?
      dm_solo("현재 위치 정보가 없습니다. [위치/장소명] 형식으로 먼저 이동해주세요.")
      return
    end

    location = @sheet_manager.find_location(state[:location])
    unless location
      dm_solo("현재 위치 정보를 불러올 수 없습니다.")
      return
    end

    # 오브젝트 매칭: 획득아이템 목록(콤마 구분)에 포함되거나 오브젝트명이 일치하는 행
    obj = location[:objects].to_a.find { |o| item_list(o).include?(@obj_name) } ||
          location[:objects].to_a.find { |o| o[:name].to_s.strip == @obj_name }

    # 이미 정산되어 장소 목록에서 숨겨진 오브젝트라면 응답하지 않는다.
    return if obj && hidden_object?(obj)

    unless obj
      dm_solo("#{@obj_name}은(는) 가져갈 수 없습니다.")
      return
    end

    obj_items = item_list(obj)
    if obj_items.empty?
      dm_solo("#{@obj_name}은(는) 가져갈 수 없습니다.")
      return
    end

    # 가져갈 아이템 결정: 아이템명으로 지정했으면 그 아이템, 오브젝트명으로 지정했으면 첫 아이템
    target_item = obj_items.include?(@obj_name) ? @obj_name : obj_items.first

    # 1회한정: "아이디:아이템명" 형식으로 기록해 아이템별로 소진 체크
    taken_records = split_ids(obj[:taken_by])
    if obj[:once]
      already_taken = taken_records.any? do |rec|
        rec_item = rec.include?(':') ? rec.split(':', 2)[1].to_s.strip : nil
        rec_item ? rec_item == target_item : true
      end
      return if already_taken
    end

    granted = []
    failed = []

    @party.each do |acct|
      member = @sheet_manager.find_user(acct)
      unless member
        failed << acct
        next
      end

      items = member[:items].to_s.split(',').map(&:strip).reject(&:empty?)
      items << target_item
      @sheet_manager.update_user(acct, { items: items.join(',') })
      @sheet_manager.update_object_taken(state[:location], obj[:name], "#{acct}:#{target_item}") if obj[:once]
      granted << acct
    end

    lines = []
    lines << "[획득]"
    lines << "현재 위치: #{location_title(location)}"
    lines << ""
    lines << "#{target_item} 을(를) 획득했습니다."
    if failed.any?
      lines << ""
      lines << "(등록되지 않은 계정이라 지급 못함: #{failed.join(', ')})"
    end

    send_party(lines)
  rescue => e
    puts "[AcquireCommand 오류] #{e.class}: #{e.message}"
    dm_solo("처리 중 오류가 발생했습니다.")
  end

  private

  # ── 파티 구성 ──

  def build_party
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

  def item_list(obj)
    obj[:item].to_s.split(',').map(&:strip).reject(&:empty?)
  end

  def split_ids(value)
    value.to_s.split(',').map(&:strip).reject(&:empty?)
  end

  def hidden_object?(obj)
    # 1회한정 오브젝트는 모든 아이템이 소진된 경우에만 숨긴다.
    if obj[:once] && !obj[:taken_by].to_s.strip.empty?
      obj_items = item_list(obj)
      taken_items = split_ids(obj[:taken_by]).map do |rec|
        rec.include?(':') ? rec.split(':', 2)[1].to_s.strip : nil
      end.compact

      # 구형 기록(아이디만 기록)이 있으면 전체 소진으로 간주
      legacy = split_ids(obj[:taken_by]).any? { |rec| !rec.include?(':') }
      all_taken = legacy || (obj_items.any? && (obj_items - taken_items).empty?)
      return true if all_taken
    end

    credit_settled = obj[:credit].to_i != 0 && !obj[:credit_taken_by].to_s.strip.empty?
    credit_settled
  end

  GRID_COORD_RE = /\A[C-O][2-8]\z/.freeze

  def location_title(location)
    code = location[:code].to_s.strip
    label = location[:label].to_s.strip
    label = location[:name].to_s.strip if label.empty?

    return label.empty? ? '알 수 없는 장소' : label if code.upcase.match?(GRID_COORD_RE)

    if code.empty?
      label
    elsif label.empty? || label == code
      code
    else
      "#{code} #{label}"
    end
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
    puts "[AcquireCommand DM 오류] #{e.class}: #{e.message}"
    nil
  end
end
