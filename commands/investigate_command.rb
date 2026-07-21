# commands/investigate_command.rb
# encoding: UTF-8

class InvestigateCommand
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

    obj = location[:objects].to_a.find { |o| o[:name] == @obj_name }

    # 이미 누군가 획득했거나 크레딧 정산이 끝난 오브젝트는 응답하지 않는다.
    return if obj && hidden_object?(obj)

    unless obj
      dm("#{@obj_name} 은(는) 현재 위치 #{location_title(location)} 에서 찾을 수 없습니다.")
      return
    end

    lines = []
    lines << "[ #{@obj_name} ]"
    lines << "──────────────────"
    lines << "현재 위치: #{location_title(location)}"
    lines << ""
    lines << obj[:result] unless obj[:result].to_s.empty?

    if obj[:credit].to_i != 0
      credit_ids = split_ids(obj[:credit_taken_by])

      # 이미 정산된 크레딧 사건은 응답하지 않는다.
      return if credit_ids.any?

      new_credits = @sheet_manager.adjust_credits(@sender, obj[:credit])
      if new_credits
        @sheet_manager.update_credit_taken(state[:location], @obj_name, @sender)

        credit_message = obj[:credit_message].to_s
        credit_message = obj[:credit_line].to_s if credit_message.empty?

        lines << ""
        lines << credit_message unless credit_message.empty?

        if obj[:credit].to_i > 0
          lines << "크레딧 +#{obj[:credit]} 획득! (보유 크레딧: #{new_credits})"
        else
          lines << "크레딧 #{obj[:credit]} 차감... (보유 크레딧: #{new_credits})"
        end
      else
        lines << ""
        lines << "(크레딧 정산 중 오류가 발생했습니다.)"
      end
    end

    @sheet_manager.update_scout_state(@sender, {
      location:    state[:location],
      last_action: '조사'
    })

    dm(lines.join("\n"))
  rescue => e
    puts "[InvestigateCommand 오류] #{e.class}: #{e.message}"
    dm("처리 중 오류가 발생했습니다.")
  end

  private

  def split_ids(value)
    value.to_s.split(',').map(&:strip).reject(&:empty?)
  end

  def hidden_object?(obj)
    once_taken = obj[:once] && !obj[:taken_by].to_s.strip.empty?
    credit_settled = obj[:credit].to_i != 0 && !obj[:credit_taken_by].to_s.strip.empty?
    once_taken || credit_settled
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
