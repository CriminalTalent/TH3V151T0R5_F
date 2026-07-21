# commands/acquire_command.rb
# encoding: UTF-8

class AcquireCommand
  def initialize(sheet_manager, mastodon_client, sender, obj_name, status)
    @sheet_manager   = sheet_manager
    @mastodon_client = mastodon_client
    @sender          = sender.to_s.gsub('@', '')
    @obj_name        = obj_name.to_s.strip
    @status          = status
  end

  def execute
    user = @sheet_manager.find_user(@sender)
    unless user
      dm("아직 등록되지 않은 계정입니다.")
      return
    end

    state = @sheet_manager.find_scout_state(@sender)
    unless state && !state[:location].to_s.empty?
      dm("현재 위치 정보가 없습니다. [위치/장소명] 형식으로 먼저 이동해주세요.")
      return
    end

    location = @sheet_manager.find_location(state[:location])
    unless location
      dm("현재 위치 정보를 불러올 수 없습니다.")
      return
    end

    # 오브젝트 매칭: 획득아이템 목록(콤마 구분)에 포함되거나 오브젝트명이 일치하는 행
    obj = location[:objects].to_a.find { |o| item_list(o).include?(@obj_name) } ||
          location[:objects].to_a.find { |o| o[:name].to_s.strip == @obj_name }

    # 이미 정산되어 장소 목록에서 숨겨진 오브젝트라면 응답하지 않는다.
    return if obj && hidden_object?(obj)

    unless obj
      dm("#{@obj_name}은(는) 가져갈 수 없습니다.")
      return
    end

    obj_items = item_list(obj)
    if obj_items.empty?
      dm("#{@obj_name}은(는) 가져갈 수 없습니다.")
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

    items = user[:items].to_s.split(',').map(&:strip).reject(&:empty?)
    items << target_item

    @sheet_manager.update_user(@sender, { items: items.join(',') })
    @sheet_manager.update_object_taken(state[:location], obj[:name], "#{@sender}:#{target_item}") if obj[:once]

    dm("[획득]\n현재 위치: #{location_title(location)}\n\n#{target_item} 을(를) 획득했습니다.")
  rescue => e
    puts "[AcquireCommand 오류] #{e.class}: #{e.message}"
    dm("처리 중 오류가 발생했습니다.")
  end

  private

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

  def location_title(location)
    code = location[:code].to_s.strip
    label = location[:label].to_s.strip
    label = location[:name].to_s.strip if label.empty?

    if code.empty?
      label
    elsif label.empty? || label == code
      code
    else
      "#{code} #{label}"
    end
  end

  def dm(text)
    @mastodon_client.post_status(
      "@#{@sender} #{text}",
      reply_to_id: @status['id'],
      visibility: 'direct'
    )
  end
end
