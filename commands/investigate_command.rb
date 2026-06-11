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
    unless state && !state[:location].empty?
      dm("현재 위치 정보가 없습니다. [위치/장소명]으로 먼저 이동해주세요.")
      return
    end

    location = @sheet_manager.find_location(state[:location])
    unless location
      dm("현재 위치 정보를 불러올 수 없습니다.")
      return
    end

    obj = location[:objects].find { |o| o[:name] == @obj_name }
    unless obj
      dm("#{@obj_name} 은(는) 현재 위치에서 찾을 수 없습니다.")
      return
    end

    # 1회 한정 아이템 체크
    if obj[:once]
      taken_ids = obj[:taken_by].split(',').map(&:strip).reject(&:empty?)
      if taken_ids.include?(@sender)
        dm("#{@obj_name} 은(는) 이미 조사한 적이 있습니다.")
        return
      end
    end

    lines = []
    lines << "[ #{@obj_name} ]"
    lines << "──────────────────"
    lines << obj[:result] unless obj[:result].empty?

    # 아이템 획득
    if !obj[:item].empty?
      if obj[:once]
        taken_ids = obj[:taken_by].split(',').map(&:strip).reject(&:empty?)
        if taken_ids.empty?
          items = user[:items].split(',').map(&:strip).reject(&:empty?)
          items << obj[:item]
          @sheet_manager.update_user(@sender, { items: items.join(',') })
          @sheet_manager.update_object_taken(state[:location], @obj_name, @sender)
          lines << ""
          lines << "#{obj[:item]} 을(를) 획득했습니다."
        else
          lines << ""
          lines << "누군가 이미 가져간 것 같습니다."
        end
      else
        items = user[:items].split(',').map(&:strip).reject(&:empty?)
        items << obj[:item]
        @sheet_manager.update_user(@sender, { items: items.join(',') })
        lines << ""
        lines << "#{obj[:item]} 을(를) 획득했습니다."
      end
    end

    @sheet_manager.update_scout_state(@sender, {
      location:    state[:location],
      last_action: '조사'
    })

    dm(lines.join("\n"))
  rescue => e
    puts "[InvestigateCommand 오류] #{e.message}"
    dm("처리 중 오류가 발생했습니다.")
  end

  private

  def dm(text)
    @mastodon_client.post_status(
      "@#{@sender} #{text}",
      reply_to_id: @status['id'],
      visibility: 'direct'
    )
  end
end
