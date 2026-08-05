# mastodon_client.rb
# encoding: UTF-8
require 'net/http'
require 'json'
require 'uri'

class MastodonClient
  def initialize(base_url:, token:)
    @base_url = base_url.to_s.sub(%r{/\z}, '')
    @token    = token.to_s
  end

  def safe_utf8(str)
    return "" if str.nil?
    s = str.to_s.dup.force_encoding('UTF-8')
    s.valid_encoding? ? s : s.encode('UTF-8', 'binary', invalid: :replace, undef: :replace, replace: '?')
  rescue
    str.to_s
  end

  def request(method:, path:, params: {}, form: nil, headers: {})
    uri = URI.join(@base_url, path)
    uri.query = URI.encode_www_form(params) if method == :get && params&.any?
    base_headers = { "Authorization" => "Bearer #{@token}" }.merge(headers || {})
    req = case method
          when :get  then Net::HTTP::Get.new(uri, base_headers)
          when :post
            r = Net::HTTP::Post.new(uri, base_headers)
            r.set_form_data(form) if form
            r
          end
    res = Net::HTTP.start(uri.host, uri.port, use_ssl: uri.scheme == 'https',
                          open_timeout: 10, read_timeout: 30) { |http| http.request(req) }
    body = JSON.parse(res.body) rescue {}
    [res, body]
  rescue => e
    puts "[HTTP 오류] #{e.class} - #{e.message}"
    [nil, {}]
  end

  def notifications(limit: 30, since_id: nil)
    params = { limit: limit.to_i }
    params[:since_id] = since_id.to_s if since_id
    params["types[0]"] = "mention"
    res, body = request(method: :get, path: "/api/v1/notifications", params: params)
    return [] unless res && res.code.to_i.between?(200, 299)
    body.is_a?(Array) ? body : []
  end

  # 429 처리: 룰 10과 동일하게 Retry-After(있으면 그 값, 없으면 5초×시도횟수)로
  # 최대 3회까지 재시도하고, 소진되면 실패로 기록하고 nil을 반환한다.
  # 예전처럼 한 번의 429로 10분간 모든 후속 게시를 통째로 버리지 않는다 —
  # 그 10분 동안 DM 답장이 전부 조용히 유실되는 문제가 있었음.
  def post_status(text, reply_to_id: nil, visibility: 'direct', media_ids: [], max_attempts: 3)
    form = { status: safe_utf8(text), visibility: visibility }
    form[:in_reply_to_id] = reply_to_id if reply_to_id
    Array(media_ids).each_with_index { |id, i| form["media_ids[#{i}]"] = id }

    attempt = 0
    loop do
      attempt += 1
      res, _ = request(method: :post, path: "/api/v1/statuses", form: form)

      if res.nil?
        # 네트워크 레벨 오류는 request()에서 이미 로그를 남겼으므로 그대로 실패 반환
        return nil
      end

      if res.code.to_s == '429'
        retry_after = (res['Retry-After'] || res['retry-after']).to_s.to_f
        wait = retry_after.positive? ? retry_after : (5.0 * attempt)

        if attempt < max_attempts
          puts "[POST] rate limit - #{wait}초 후 재시도 (#{attempt}/#{max_attempts})"
          sleep(wait)
          next
        else
          puts "[POST] rate limit 재시도 소진 (#{max_attempts}회) — 게시 실패로 기록"
          return nil
        end
      end

      return res
    end
  end

  def broadcast(text, visibility: 'public')
    post_status(text, visibility: visibility)
  end
end
