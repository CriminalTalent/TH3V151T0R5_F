# mastodon_client.rb
# encoding: UTF-8
require 'net/http'
require 'json'
require 'uri'

class MastodonClient
  def initialize(base_url:, token:)
    @base_url = base_url.to_s.sub(%r{/\z}, '')
    @token    = token.to_s
    @post_block_until = Time.at(0)
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

  def post_status(text, reply_to_id: nil, visibility: 'direct', media_ids: [])
    return if Time.now < @post_block_until
    form = { status: safe_utf8(text), visibility: visibility }
    form[:in_reply_to_id] = reply_to_id if reply_to_id
    Array(media_ids).each_with_index { |id, i| form["media_ids[#{i}]"] = id }
    res, _ = request(method: :post, path: "/api/v1/statuses", form: form)
    if res&.code.to_s == '429'
      @post_block_until = Time.now + 600
      puts "[POST] rate limit"
    end
    res
  end

  def broadcast(text, visibility: 'public')
    post_status(text, visibility: visibility)
  end
end
