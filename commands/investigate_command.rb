# commands/investigate_command.rb
# encoding: UTF-8
#
# [조사/오브젝트명] [조사/오브젝트명] @동료1 @동료2 ...
# 멘션을 함께 쓰면 멘션된 사람 전원 + 본인이 파티가 되어 함께 조사 결과를
# 그룹 DM으로 받는다. 크레딧이 걸린 오브젝트라면 파티 전원에게 지급된다.
# 멘션 없이 혼자 쓰면 기존과 동일하게 개인 단위로 동작한다.
class InvestigateCommand
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
    if party_all_incapacitated?
      dm_solo("전투불능 상태라 조사를 진행할 수 없습니다. 회복 후 다시 시도해주세요.")
      return
    end
    location = @sheet_manager.find_location(state[:location])
    unless location
      dm_solo("현재 위치 정보를 불러올 수 없습니다.")
      return
    end
    obj = location[:objects].to_a.find { |o| o[:name] == @obj_name }
    # 이미 누군가 획득했거나 크레딧 정산이 끝난 오브젝트는 응답하지 않는다.
    return if obj && hidden_object?(obj)
    unless obj
      dm_solo("#{@obj_name} 은(는) 현재 위치 #{location_title(location)} 에서 찾을 수 없습니다.")
      return
    end

    if obj[:creature] && !obj[:creature].to_s.strip.empty?
      trigger_encounter(location, obj, state[:location])
      return
    end

    lines = []
    lines << "[ #{@obj_name} ]"
    lines << "──────────────────"
    lines << "현재 위치: #{location_title(location)}"
    lines << ""
    lines << obj[:result] unless obj[:result].to_s.empty?

    item_list = obj[:item].to_s.split(',').map(&:strip).reject(&:empty?)
    if item_list.any?
      lines << ""
      lines << "획득 가능: #{item_list.join(', ')}"
      lines << "[획득/아이템명] 으로 가져갈 수 있습니다."
    end

    if obj[:credit].to_i != 0
      credit_ids = split_ids(obj[:credit_taken_by])
      # 이미 정산된 크레딧 사건은 응답하지 않는다.
      return if credit_ids.any?

      credit_message = obj[:credit_message].to_s
      credit_message = obj[:credit_line].to_s if credit_message.empty?
      lines << ""
      lines << credit_message unless credit_message.empty?

      @party.each do |acct|
        new_credits = @sheet_manager.adjust_credits(acct, obj[:credit])
        next unless new_credits
        @sheet_manager.update_credit_taken(state[:location], @obj_name, acct)
        if obj[:credit].to_i > 0
          lines << "@#{acct} 크레딧 +#{obj[:credit]} 획득! (보유 크레딧: #{new_credits})"
        else
          lines << "@#{acct} 크레딧 #{obj[:credit]} 차감... (보유 크레딧: #{new_credits})"
        end
      end
    end

    @sheet_manager.update_scout_states_batch(@party, {
      location:    state[:location],
      last_action: '조사'
    })

    send_party(lines)
  rescue => e
    puts "[InvestigateCommand 오류] #{e.class}: #{e.message}"
    dm_solo("처리 중 오류가 발생했습니다.")
  end

  private


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

  # ── 크리쳐 조우 ──

  def party_runners
    @party.map do |acct|
      user = @sheet_manager.find_user(acct)
      name = user && !user[:name].to_s.strip.empty? ? user[:name] : acct
      { acct: acct, name: name }
    end
  end

  def trigger_encounter(location, obj, location_code)
    creature_name = obj[:creature].to_s.strip
    creature_name = '크리쳐' if creature_name.empty?

    @sheet_manager.activate_creature_boss(creature_name, location_code)

    runners = party_runners
    tags  = runners.map { |r| "@#{r[:acct]}" }.join(' ')
    names = runners.map { |r| r[:name].to_s.empty? ? r[:acct] : r[:name] }.join(', ')

    result_text = obj[:result].to_s.strip

    encounter_text = "#{tags}\n\n" \
                     "━━━━━━━━━━━━━━\n\n" \
                     "[ #{@obj_name} ]\n\n" \
                     "#{result_text.empty? ? '' : "#{result_text}\n\n"}" \
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

    post(encounter_text, thread_anchor)

    @sheet_manager.update_scout_states_batch(@party, {
      location:    location_code,
      last_action: '전투전환'
    })
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

  def split_ids(value)
    value.to_s.split(',').map(&:strip).reject(&:empty?)
  end

  def hidden_object?(obj)
    once_taken = obj[:once] && !obj[:taken_by].to_s.strip.empty?
    # 크레딧 정산 완료로 숨기는 것은 1회 한정(once) 오브젝트에만 적용한다.
    # once 체크가 꺼져 있으면 크레딧을 이미 받았어도 재조사 시 지문과 아이템 안내를 계속 준다.
    credit_settled = obj[:once] && obj[:credit].to_i != 0 && !obj[:credit_taken_by].to_s.strip.empty?
    once_taken || credit_settled
  end

  GRID_COORD_RE = /\A[C-O](?:[2-8]|1[0-6])\z/.freeze

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
    result = @mastodon_client.post_status(
      text,
      reply_to_id: reply_id,
      visibility: 'direct'
    )
    # post_status가 예외 없이 nil을 반환하는 경우(예: 429 재시도 소진)도 있어,
    # 이 경우는 rescue가 안 걸려 응답이 조용히 사라지던 문제가 있었다.
    # 추적을 위해 명시적으로 경고 로그를 남긴다.
    puts "[InvestigateCommand 게시 실패] post_status가 nil을 반환함 (reply_id=#{reply_id})" unless result
    result
  rescue => e
    puts "[InvestigateCommand DM 오류] #{e.class}: #{e.message}"
    nil
  end
end
