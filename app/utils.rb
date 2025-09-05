require 'net/http'
require 'uri'
require 'json'

def telegramMessageSend(botId, botToken, chatId, message)
  uri = URI("https://api.telegram.org/bot#{botId}:#{botToken}/sendMessage")
  Net::HTTP.post(
    uri,
    {
      chat_id: chatId,
      text: message,
    }.to_json,
    'Content-Type' => 'application/json'
  )
end

def telegramJsonSend(botId, botToken, chatId, message, json, fileName = 'backup.json')
  uri = URI("https://api.telegram.org/bot#{botId}:#{botToken}/sendDocument")

  boundary = "----#{rand(0x100000000).to_s(36)}"

  body = []
  body.push("--#{boundary}\r\n")
  body.push("Content-Disposition: form-data; name=\"chat_id\"\r\n\r\n")
  body.push("#{chatId}\r\n")
  body.push("--#{boundary}\r\n")
  body.push("Content-Disposition: form-data; name=\"caption\"\r\n\r\n")
  body.push("#{message}\r\n")
  body.push("--#{boundary}\r\n")
  body.push("Content-Disposition: form-data; name=\"document\"; filename=\"#{fileName}\"\r\n")
  body.push("Content-Type: application/json\r\n\r\n")
  body.push(json)
  body.push("\r\n--#{boundary}--\r\n")

  http = Net::HTTP.new(uri.host, uri.port)
  http.use_ssl = true
  request = Net::HTTP::Post.new(uri.request_uri)
  request.body = body.join
  request['Content-Type'] = "multipart/form-data; boundary=#{boundary}"

  http.request(request)
end

def numberFormat(number)
  number.to_s.reverse.gsub(/(\d{3})(?=\d)/, '\\1 ').reverse
end
