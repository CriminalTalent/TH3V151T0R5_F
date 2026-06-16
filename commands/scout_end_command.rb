# commands/scout_end_command.rb
# encoding: UTF-8

class ScoutEndCommand
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

    @sheet_manager.update_scout_state(@sender, {
      location:    '',
      last_action: '조사종료'
    })

    dm("오늘의 조사를 종료합니다. 수고하셨습니다.")
  rescue => e
    puts "[ScoutEndCommand 오류] #{e.message}"
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
