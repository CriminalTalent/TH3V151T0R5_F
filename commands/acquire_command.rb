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

    if obj[:item].empty?
      dm("#{@obj_name} 은(는) 가져갈 수 있는 물건이 없습니다.")
      return
    end

    taken_ids = obj[:taken_by].split(',').map(&:strip).reject(&:empty?)

    if obj[:once] && taken_ids.include?(@sender)
      dm("이미 가져간 적이 있는 물건입니다.")
      return
    end

    if obj[:once] && !taken_ids.empty?
      dm("누군가 이미 가져간 것 같습니다.")
      return
    end

    items = user[:items].split(',').map(&:strip).reject(&:empty?)
    items << obj[:item]
    @sheet_manager.update_user(@sender, { items: items.join(',') })
    @sheet_manager.update_object_taken(state[:location], @obj_name, @sender) if obj[:once]

    dm("#{obj[:item]} 을(를) 획득했습니다.")
  rescue => e
    puts "[AcquireCommand 오류] #{e.message}"
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
