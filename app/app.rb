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

telegramBalanceNotMathMessageSended = false
telegramDaySummaryMessageSended = false

lastBalanceFact = 0

puts 'App is now running'

while true
  puts 'Check - process'

  todayDay = Date.today.day
  nowTime = Time.now
  daysInMonth = Date.new(Date.today.year, Date.today.month, -1).day
  outcomePerDay = (appOutcomeTotal / daysInMonth).to_i

  todayStartTimestamp = Date.today.prev_day.to_time.to_i
  todayEndTimestamp = (Date.today.next_day.to_time - 1).to_i

  apiJson = Net::HTTP.start(zenMoneyApiUri.host, zenMoneyApiUri.port, :use_ssl => true) { |http|
    apiRequest = Net::HTTP::Post.new(zenMoneyApiUri)
    apiRequest['Authorization'] = "Bearer #{zenMoneyApiToken}"
    apiRequest['Content-Type'] = 'application/json'
    apiRequest.body = {
      lastServerTimestamp: todayStartTimestamp,
      currentClientTimestamp: todayEndTimestamp,
    }.to_json

    apiResponse = http.request(apiRequest)
    if apiResponse.code.to_i == 200
      JSON.parse(apiResponse.body)
    else
      raise "Api response returns no 200 code = #{apiResponse.code}"
    end
  }

  if apiJson.key?('account')
    puts 'Accounts found - process'

    balanceCalc = if todayDay == daysInMonth
      0
    else
      (appOutcomeTotal - outcomePerDay * todayDay).to_i
    end

    balanceFact = apiJson['account']
      .select {|t| zenMoneyCheckAccounts.include?(t['id'])}
      .sum{|t| t['balance']}
      .to_i

    if balanceCalc >= balanceFact
      if telegramBalanceNotMathMessageSended
        puts "Problem - calculated (#{numberFormat(balanceCalc)} rur) and actual (#{numberFormat(balanceFact)} rur) balances do not match!"
      else
        telegramMessage = []
        telegramMessage.push('Внимание: фактический остаток меньше расчетного!')
        telegramMessage.push('')
        telegramMessage.push("→ Перерасход: #{numberFormat(balanceCalc - balanceFact)}р")
        telegramMessage.push("→ Фактический остаток: #{numberFormat(balanceFact)}р")
        telegramMessage.push("→ Расчетный остаток на текущую дату: #{numberFormat(balanceCalc)}р")

        telegramResponse = telegramMessageSend(telegramBotId, telegramBotToken, telegramWarningsChatId, telegramMessage.join("\n"))
        if telegramResponse.code.to_i == 200
          telegramBalanceNotMathMessageSended = true
          puts 'Balances not match message succesfully sended'
        else
          raise "Telegram response returns no 200 code = #{telegramResponse.code}"
        end
      end
    else
      puts "Everything is fine - calculated (#{numberFormat(balanceCalc)} rur) and actual (#{numberFormat(balanceFact)} rur) balances match"
    end

    if lastBalanceFact > balanceFact
      puts 'Actual balance changed - process'

      telegramMessage = []
      telegramMessage.push("Изменение фактического остатка: #{numberFormat(lastBalanceFact)}р → #{numberFormat(balanceFact)}р")
      telegramMessage.push("Сумма, реально доступная для расхода: #{numberFormat(balanceFact - balanceCalc)}р")

      telegramResponse = telegramMessageSend(telegramBotId, telegramBotToken, telegramNoticesChatId, telegramMessage.join("\n"))
      if telegramResponse.code.to_i == 200
        puts 'Actual balance changed message succesfully sended'
      else
        raise "Telegram response returns no 200 code = #{telegramResponse.code}"
      end
    elsif lastBalanceFact == balanceFact
      puts 'Actual balance is not changed - skip'
    end

    if nowTime.hour.to_i == 4 && ! telegramDaySummaryMessageSended
      puts 'Day summary - process'

      telegramMessage = []
      telegramMessage.push('Бюджет на день')
      telegramMessage.push('')
      telegramMessage.push("→ Расчетная дневная сумма расхода: #{numberFormat(outcomePerDay)}р")
      telegramMessage.push("→ Сумма, реально доступная для расхода: #{numberFormat(balanceFact - balanceCalc)}р")
      telegramMessage.push("→ Фактический остаток: #{numberFormat(balanceFact)}р")
      telegramMessage.push("→ Расчетный остаток на текущую дату: #{numberFormat(balanceCalc)}р")

      telegramResponse = telegramMessageSend(telegramBotId, telegramBotToken, telegramSummaryChatId, telegramMessage.join("\n"))
      if telegramResponse.code.to_i == 200
        telegramDaySummaryMessageSended = true
        puts 'Day summary message succesfully sended'
      else
        raise "Telegram response returns no 200 code = #{telegramResponse.code}"
      end
    end

    lastBalanceFact = balanceFact
  else
    puts 'Account key is not exists - skip'
  end

  if nowTime.hour.to_i == 0 && nowTime.min.to_i == 30
    telegramBalanceNotMathMessageSended = false
    telegramDaySummaryMessageSended = false
  end

  puts "Sleep #{zenMoneyCheckTimeout}s"
  sleep zenMoneyCheckTimeout
end
