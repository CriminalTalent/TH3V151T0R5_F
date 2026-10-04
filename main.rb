#!/usr/bin/env ruby
# encoding: UTF-8

require 'dotenv'
Dotenv.load('/root/TH3V151T0R5_F/.env')

require 'google/apis/sheets_v4'
require 'googleauth'

require_relative 'mastodon_client'
require_relative 'sheet_manager'
require_relative 'command_parser'

$stdout.sync = true
$stderr.sync = true

LAST_FILE = '/root/TH3V151T0R5_F/last_mention_id.txt'

BASE_URL          = ENV['MASTODON_BASE_URL']
TOKEN             = ENV['MASTODON_TOKEN']
SHEET_ID          = ENV['GOOGLE_SHEET_ID']
CREATURE_SHEET_ID = ENV['CREATURE_SHEET_ID']
GRID_SHEET_ID     = ENV['GRID_SHEET_ID']
CRED_PATH         = ENV['GOOGLE_APPLICATION_CREDENTIALS']

if [BASE_URL, TOKEN, SHEET_ID, CRED_PATH].any? { |v| v.nil? || v.empty? }
  puts '[ERROR] 환경변수 누락'
  exit 1
end

service = Google::Apis::SheetsV4::SheetsService.new
service.client_options.application_name = 'ScoutBot'
service.authorization = Google::Auth::ServiceAccountCredentials.make_creds(
  json_key_io: File.open(CRED_PATH),
  scope: ['https://www.googleapis.com/auth/spreadsheets']
)

sheet_manager = SheetManager.new(service, SHEET_ID, CREATURE_SHEET_ID, GRID_SHEET_ID)
client        = MastodonClient.new(base_url: BASE_URL, token: TOKEN)

begin
  latest = client.notifications(limit: 1)
  last_id = if latest&.any?
              id = latest.first['id'].to_i
              File.write(LAST_FILE, id.to_s)
              id
            elsif File.exist?(LAST_FILE)
              File.read(LAST_FILE).to_i
            else
              0
            end
rescue => e
  puts "[초기화 오류] #{e.message}"
  last_id = File.exist?(LAST_FILE) ? File.read(LAST_FILE).to_i : 0
end

puts '──────────────────────────────────'
puts "조사봇 시작 (last_id: #{last_id})"
puts '──────────────────────────────────'

loop do
  begin
    notifications = client.notifications(limit: 40, since_id: last_id)

    notifications.reverse_each do |n|
      nid = n['id'].to_i
      next unless nid > last_id
      next unless n['type'] == 'mention'

      puts "[멘션] ID=#{nid}, status_id=#{n.dig('status', 'id')}, from=@#{n.dig('account', 'acct')}"
      puts "[처리 시작] notification_id=#{nid}, status_id=#{n.dig('status', 'id')}"
      CommandParser.parse(client, sheet_manager, n)
      puts "[처리 종료] notification_id=#{nid}, status_id=#{n.dig('status', 'id')}"

      # last_id 저장을 처리 "성공 이후"로 미룬다. 처리 도중 프로세스가 강제
      # 종료(재시작 등으로 Interrupt)되면, 이전에는 이미 last_id가 앞서
      # 저장되어 있어 그 멘션이 다시는 처리되지 않고 조용히 유실되는 문제가
      # 있었다. 이제는 처리가 끝까지 성공한 뒤에만 저장하므로, 중간에 죽으면
      # 다음 폴링에서 같은 멘션을 자동으로 다시 처리한다 (위치 갱신 등은
      # 같은 값으로 다시 써도 무해하며, 응답 게시도 이번엔 성공할 수 있다).
      last_id = nid
      File.write(LAST_FILE, last_id.to_s)

      sleep 1
    end
  rescue => e
    puts "[루프 오류] #{e.class}: #{e.message}"
  end

  sleep 7
end
