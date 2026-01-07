#!/usr/bin/env ruby

$stdout.sync = true

require 'json'
require 'date'
require 'net/http'
require 'uri'
require 'fileutils'

require_relative 'utils'

appOutcomeTotal = ENV.fetch('APP_OUTCOME_TOTAL', 0).to_i
appOutcomePerDay = ENV.fetch('APP_OUTCOME_PER_DAY', 0).to_i

appBackupSpendingPlansEnabled = ENV.fetch('APP_BACKUP_SPENDING_PLANS_ENABLED', false).to_s == 'true'
appBackupSpendingPlansMessageSendHour = ENV.fetch('APP_BACKUP_SPENDING_PLANS_MESSAGGE_SEND_HOUR', 0).to_i
appSummaryMessageSendHour = ENV.fetch('APP_SUMMARY_MESSAGE_SEND_HOUR').to_i

appTmpDir = ENV.fetch('APP_TMP_DIR', '/tmp')
appClearAllLocksTime = ENV.fetch('APP_CLEAR_ALL_LOCKS_TIME', '0:0')

zenMoneyApiToken = ENV.fetch('ZENMONEY_API_TOKEN', '')
zenMoneyApiUri = URI(ENV.fetch('ZENMONEY_API_URL', ''))
zenMoneyCheckTimeout = ENV.fetch('ZENMONEY_CHECK_TIMEOUT', 60).to_i
zenMoneyCheckAccounts = ENV.fetch('ZENMONEY_CHECK_ACCOUNTS', '').strip.split(',')
zenMoneyCheckExcludeIncomeAccounts = ENV.fetch('ZENMONEY_CHECK_EXCLUDE_INCOME_ACCOUNTS', '').strip.split(',')

telegramBotId = ENV.fetch('TELEGRAM_BOT_ID')
telegramBotToken = ENV.fetch('TELEGRAM_BOT_TOKEN')

telegramSummaryChatId = ENV.fetch('TELEGRAM_SUMMARY_CHAT_ID')
telegramWarningsChatId = ENV.fetch('TELEGRAM_WARNINGS_CHAT_ID')
telegramNoticesChatId = ENV.fetch('TELEGRAM_NOTICES_CHAT_ID')

telegramOutcomeNotMathLockFile = "#{appTmpDir}/telegram_outcome_not_math.lock"
telegramDaySummaryLockFile = "#{appTmpDir}/telegram_day_summary.lock"
telegramReminderMarkerBackupLockFile = "#{appTmpDir}/telegram_reminder_marker_backup.lock"

lastTotalOutcomeFact = 0

clearAllLocksEnabled = true

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
  todayOutcomeCalc = if appOutcomePerDay > 0
    appOutcomePerDay
  else
    (appOutcomeTotal / daysInMonth).to_i
  end
  totalOutcomeCalc = todayOutcomeCalc * todayDay

  clearAllLocksHour = appClearAllLocksTime.split(':')[0].to_i
  clearAllLocksMinute = appClearAllLocksTime.split(':')[1].to_i
  if nowTime.hour.to_i == clearAllLocksHour
    if nowTime.min.to_i == clearAllLocksMinute
      puts 'Clear all locks process'

      if clearAllLocksEnabled
        FileUtils.rm([
          telegramOutcomeNotMathLockFile,
          telegramDaySummaryLockFile,
          telegramReminderMarkerBackupLockFile
        ], :force => true)

        clearAllLocksEnabled = false

        puts 'Clear all locks successful'
      else
        puts 'Clear all locks skipped (zenmoney check timemout trottling)'
        sleep zenMoneyCheckTimeout
        next
      end
    elsif nowTime.min.to_i == clearAllLocksMinute + 1
      clearAllLocksEnabled = true
    end
  end

  telegramOutcomeNotMathMessageSended = File.exist?(telegramOutcomeNotMathLockFile)
  telegramDaySummaryMessageSended = File.exist?(telegramDaySummaryLockFile)
  telegramReminderMarkerBackupMessageSended = File.exist?(telegramReminderMarkerBackupLockFile)

  begin
    zenMoneyApiJson = Net::HTTP.start(zenMoneyApiUri.host, zenMoneyApiUri.port, :use_ssl => true) { |http|
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
        puts "Api response returns no 200 code: #{apiResponse.code}"
      end
    }
  rescue => e
    puts "Cannot connect to #{zenMoneyApiUri.host}: #{e.message}"
  end

  unless zenMoneyApiJson.nil?
    if zenMoneyApiJson.key?('transaction')
      puts 'Transactions - process'

      outcomeFact = zenMoneyApiJson['transaction']
        .select {|t| ! t['hold'].nil?}
        .select {|t| ! t['deleted']}
        .select {|t| zenMoneyCheckAccounts.include?(t['outcomeAccount'])}
        .select {|t| ! zenMoneyCheckExcludeIncomeAccounts.include?(t['incomeAccount'])}

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
            FileUtils.touch(telegramOutcomeNotMathLockFile)
            puts 'Outcomes not match message succesfully sended'
          else
            puts "Telegram response returns no 200 code: #{telegramResponse.code}"
          end
        end
      else
        puts "Everything is fine - calculated (#{numberFormat(totalOutcomeCalc)} rur) and actual (#{numberFormat(totalOutcomeFact)} rur) total outcomes match"
      end

      if totalOutcomeFact > lastTotalOutcomeFact && lastTotalOutcomeFact > 0
        puts 'Actual outcome changed - process'

        telegramMessage = []
        telegramMessage.push("Изменение суммы расхода: #{numberFormat(lastTotalOutcomeFact)}р → #{numberFormat(totalOutcomeFact)}р")
        telegramMessage.push("Сумма расхода: #{numberFormat(totalOutcomeFact - lastTotalOutcomeFact)}р")
        telegramMessage.push("Сумма, реально доступная для расхода: #{numberFormat(totalOutcomeCalc - totalOutcomeFact)}р")

        telegramResponse = telegramMessageSend(telegramBotId, telegramBotToken, telegramNoticesChatId, telegramMessage.join("\n"))
        if telegramResponse.code.to_i == 200
          puts 'Actual outcome changed message succesfully sended'
        else
          puts "Telegram response returns no 200 code: #{telegramResponse.code}"
        end
      elsif lastTotalOutcomeFact == totalOutcomeFact
        puts 'Actual outcome is not changed - skip'
      end

      lastTotalOutcomeFact = totalOutcomeFact
    end

    if nowTime.hour.to_i == appSummaryMessageSendHour && ! telegramDaySummaryMessageSended
      puts 'Day summary - process'

      telegramMessage = []
      telegramMessage.push('Бюджет на день')
      telegramMessage.push('')
      telegramMessage.push("→ Расчетная дневная сумма расхода: #{numberFormat(todayOutcomeCalc)}р")
      telegramMessage.push("→ Сумма, реально доступная для расхода: #{numberFormat(totalOutcomeCalc - totalOutcomeFact)}р")

      telegramResponse = telegramMessageSend(telegramBotId, telegramBotToken, telegramSummaryChatId, telegramMessage.join("\n"))
      if telegramResponse.code.to_i == 200
        FileUtils.touch(telegramDaySummaryLockFile)
        puts 'Day summary message succesfully sended'
      else
        puts "Telegram response returns no 200 code: #{telegramResponse.code}"
      end
    end

    if appBackupSpendingPlansEnabled && zenMoneyApiJson.key?('reminder')
      if nowTime.hour.to_i == appBackupSpendingPlansMessageSendHour && ! telegramReminderMarkerBackupMessageSended
        puts 'reminder - process'

        telegramMessage = 'Бекап ключа reminder - планов расходов'
        telegramResponse = telegramJsonSend(telegramBotId, telegramBotToken, telegramNoticesChatId, telegramMessage, JSON.pretty_generate(zenMoneyApiJson['reminder']), 'reminderBackup.json')
        if telegramResponse.code.to_i == 200
          FileUtils.touch(telegramReminderMarkerBackupLockFile)
          puts 'Reminder backup message succesfully sended'
        else
          puts "Telegram response returns no 200 code: #{telegramResponse.code}"
        end
      end
    end
  end

  puts "Sleep #{zenMoneyCheckTimeout}s"
  sleep zenMoneyCheckTimeout
end
