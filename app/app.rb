#!/usr/bin/env ruby

$stdout.sync = true

require 'json'
require 'date'
require 'net/http'
require 'uri'

require_relative 'utils'

appOutcomeTotal = ENV.fetch('APP_OUTCOME_TOTAL').to_i

zenMoneyApiToken = ENV.fetch('ZENMONEY_API_TOKEN')
zenMoneyApiUri = URI(ENV.fetch('ZENMONEY_API_URL'))
zenMoneyCheckTimeout = ENV.fetch('ZENMONEY_CHECK_TIMEOUT').to_i
zenMoneyCheckAccounts = ENV.fetch('ZENMONEY_CHECK_ACCOUNTS').strip.split(',')

telegramBotId = ENV.fetch('TELEGRAM_BOT_ID')
telegramBotToken = ENV.fetch('TELEGRAM_BOT_TOKEN')

telegramSummaryChatId = ENV.fetch('TELEGRAM_SUMMARY_CHAT_ID')
telegramWarningsChatId = ENV.fetch('TELEGRAM_WARNINGS_CHAT_ID')
telegramNoticesChatId = ENV.fetch('TELEGRAM_NOTICES_CHAT_ID')

telegramOutcomeNotMathMessageSended = false
telegramDaySummaryMessageSended = false

lastTotalOutcomeFact = 0

puts 'App is now running'

while true
  puts 'Check - process'

  nowTime = Time.now
  todayDate = Date.today
  todayDay = todayDate.day
  todayYearMonthStr = todayDate.strftime('%Y-%m')
  todayDateStr = todayDate.to_date.to_s
  startTimestamp = (todayDate - todayDate.mday + 1).to_time.to_i
  endTimestamp = (todayDate.next_day.to_time - 1).to_i

  daysInMonth = Date.new(todayDate.year, todayDate.month, -1).day
  todayOutcomeCalc = (appOutcomeTotal / daysInMonth).to_i
  totalOutcomeCalc = todayOutcomeCalc * todayDay

  apiJson = Net::HTTP.start(zenMoneyApiUri.host, zenMoneyApiUri.port, :use_ssl => true) { |http|
    apiRequest = Net::HTTP::Post.new(zenMoneyApiUri)
    apiRequest['Authorization'] = "Bearer #{zenMoneyApiToken}"
    apiRequest['Content-Type'] = 'application/json'
    apiRequest.body = {
      lastServerTimestamp: startTimestamp,
      currentClientTimestamp: endTimestamp,
    }.to_json

    apiResponse = http.request(apiRequest)
    if apiResponse.code.to_i == 200
      JSON.parse(apiResponse.body)
    else
      raise "Api response returns no 200 code = #{apiResponse.code}"
    end
  }

  if apiJson.key?('transaction')
    outcomeFact = apiJson['transaction']
      .select {|t| ! t['hold'].nil?}
      .select {|t| ! t['deleted']}
      .select {|t| zenMoneyCheckAccounts.include?(t['outcomeAccount'])}

    totalOutcomeFact = outcomeFact
      .select {|t| t['date'].match?(/^#{todayYearMonthStr}\-.*$/)}
      .sum{|t| t['outcome']}
      .to_i

    todayOutcomeFact = outcomeFact
      .select {|t| t['date'] == todayDateStr}
      .sum{|t| t['outcome']}
      .to_i

    if totalOutcomeFact > totalOutcomeCalc
      if telegramOutcomeNotMathMessageSended
        puts "Problem - calculated (#{numberFormat(totalOutcomeCalc)} rur) and actual (#{numberFormat(totalOutcomeFact)} rur) total outcomes do not match!"
      else
        telegramMessage = []
        telegramMessage.push('Внимание: фактический расход больше расчетного!')
        telegramMessage.push('')
        telegramMessage.push("→ Перерасход: #{numberFormat(totalOutcomeFact - totalOutcomeCalc)}р")
        telegramMessage.push("→ Фактический расход: #{numberFormat(todayOutcomeFact)}р")
        telegramMessage.push("→ Расчетный расход: #{numberFormat(todayOutcomeCalc)}р")

        telegramResponse = telegramMessageSend(telegramBotId, telegramBotToken, telegramWarningsChatId, telegramMessage.join("\n"))
        if telegramResponse.code.to_i == 200
          telegramOutcomeNotMathMessageSended = true
          puts 'Outcomes not match message succesfully sended'
        else
          raise "Telegram response returns no 200 code = #{telegramResponse.code}"
        end
      end
    else
      puts "Everything is fine - calculated (#{numberFormat(totalOutcomeCalc)} rur) and actual (#{numberFormat(totalOutcomeFact)} rur) total outcomes match"
    end

    if totalOutcomeFact > lastTotalOutcomeFact && lastTotalOutcomeFact > 0
      puts 'Actual outcome changed - process'

      telegramMessage = []
      telegramMessage.push("Изменение суммы расхода: #{numberFormat(lastTotalOutcomeFact)}р → #{numberFormat(totalOutcomeFact)}р")
      telegramMessage.push("Сумма, реально доступная для расхода: #{numberFormat(totalOutcomeCalc - totalOutcomeFact)}р")

      telegramResponse = telegramMessageSend(telegramBotId, telegramBotToken, telegramNoticesChatId, telegramMessage.join("\n"))
      if telegramResponse.code.to_i == 200
        puts 'Actual outcome changed message succesfully sended'
      else
        raise "Telegram response returns no 200 code = #{telegramResponse.code}"
      end
    elsif lastTotalOutcomeFact == totalOutcomeFact
      puts 'Actual outcome is not changed - skip'
    end

    lastTotalOutcomeFact = totalOutcomeFact
  end

  if nowTime.hour.to_i == 4 && ! telegramDaySummaryMessageSended
    puts 'Day summary - process'

    telegramMessage = []
    telegramMessage.push('Бюджет на день')
    telegramMessage.push('')
    telegramMessage.push("→ Расчетная дневная сумма расхода: #{numberFormat(todayOutcomeCalc)}р")
    telegramMessage.push("→ Сумма, реально доступная для расхода: #{numberFormat(totalOutcomeCalc - totalOutcomeFact)}р")

    telegramResponse = telegramMessageSend(telegramBotId, telegramBotToken, telegramSummaryChatId, telegramMessage.join("\n"))
    if telegramResponse.code.to_i == 200
      telegramDaySummaryMessageSended = true
      puts 'Day summary message succesfully sended'
    else
      raise "Telegram response returns no 200 code = #{telegramResponse.code}"
    end
  end

  if nowTime.hour.to_i == 0 && nowTime.min.to_i == 0
    telegramOutcomeNotMathMessageSended = false
    telegramDaySummaryMessageSended = false
  end

  puts "Sleep #{zenMoneyCheckTimeout}s"
  sleep zenMoneyCheckTimeout
end
