require 'net/http'
require 'uri'

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

def numberFormat(number)
  number.to_s.reverse.gsub(/(\d{3})(?=\d)/, '\\1 ').reverse
end
