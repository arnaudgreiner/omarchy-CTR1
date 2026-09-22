import QtQuick
import Quickshell
import Quickshell.Io
import Quickshell.Services.Mpris
import qs.Commons
import qs.Ui
import "Model.js" as Model

Panel {
  id: root
  moduleName: "omarchy-CTR1"
  ipcTarget: "omarchy-CTR1"
  manageIpc: false

  property var anchorItem: null
  property var hostWidget: null
  property int currentView: 0
  property date today: new Date()
  property int viewYear: today.getFullYear()
  property int viewMonth: today.getMonth()
  property real cpuUsage: 0
  property real memoryUsage: 0
  property real diskUsage: 0
  property var networkInfo: ({})
  property real networkRxRate: 0
  property real networkTxRate: 0
  property real previousRxBytes: -1
  property real previousTxBytes: -1
  property real previousNetworkSampleMs: 0
  property var weather: null
  property var forecast: []
  property real latitude: NaN
  property real longitude: NaN
  property string weatherLocation: ""
  property var marketQuotes: []
  property var marketSymbols: []
  property string marketPrimarySymbol: "BE"
  property bool marketDataEnabled: false
  property int marketRefreshIntervalSec: 900
  property bool marketRefreshing: false
  property string marketState: "waiting"
  property string marketLastError: ""
  property date marketLastUpdated: new Date(0)
  property real marketLastRequestMs: 0
  readonly property string marketHelperPath: Quickshell.env("HOME") + "/.config/omarchy/plugins/io.github.tcballard.omarchy-markets/scripts/fetch_quotes.py"
  readonly property string marketCacheFile: (Quickshell.env("XDG_CACHE_HOME") || Quickshell.env("HOME") + "/.cache") + "/omarchy-CTR1/markets-v1.json"
  property real sampledPosition: 0
  property string selectedPlayerKey: ""

  readonly property var barIdentity: hostWidget || root
  readonly property color foreground: bar ? bar.foreground : Color.foreground
  readonly property string fontFamily: bar ? bar.fontFamily : Style.font.family
  // Keep the panel tied to the active Omarchy palette: the accent is never
  // hard-coded, while the dark fill and subdued tracks remain legible.
  readonly property color accent: Color.accent
  readonly property color panelFill: Style.normalFillFor(root.foreground, root.accent)
  readonly property color mutedForeground: Qt.darker(root.foreground, 1.5)
  readonly property color meterTrack: Qt.rgba(root.foreground.r, root.foreground.g, root.foreground.b, 0.12)
  readonly property var players: Mpris.players ? Mpris.players.values : []
  readonly property var sourcePlayers: {
    var direct = []
    for (var i = 0; i < players.length; i++) {
      var candidate = players[i]
      if (candidate && String(candidate.dbusName || "").toLowerCase().indexOf("playerctld") === -1)
        direct.push(candidate)
    }
    return direct.length > 0 ? direct : players
  }
  readonly property var player: {
    for (var i = 0; i < sourcePlayers.length; i++)
      if (playerKey(sourcePlayers[i]) === selectedPlayerKey) return sourcePlayers[i]
    for (var j = 0; j < sourcePlayers.length; j++)
      if (sourcePlayers[j] && sourcePlayers[j].isPlaying) return sourcePlayers[j]
    return sourcePlayers.length > 0 ? sourcePlayers[0] : null
  }
  readonly property var sourceOptions: {
    var options = []
    for (var i = 0; i < sourcePlayers.length; i++) {
      var source = sourcePlayers[i]
      options.push({ value: playerKey(source), label: playerLabel(source) })
    }
    return options
  }
  readonly property real appVolume: player && player.volumeSupported ? player.volume : 0
  readonly property bool seekAvailable: player && player.canSeek && player.positionSupported
    && player.lengthSupported && player.length > 0
  readonly property real trackPosition: seekAvailable ? Math.max(0, Math.min(sampledPosition, player.length)) : 0
  readonly property real trackLength: seekAvailable ? player.length : 1
  readonly property var calendarCells: Model.monthCells(viewYear, viewMonth, today)

  onPlayerChanged: Qt.callLater(function() {
    root.sampledPosition = root.player && root.player.positionSupported ? root.player.position : 0
  })

  function open() {
    today = new Date()
    viewYear = today.getFullYear()
    viewMonth = today.getMonth()
    refreshSystem()
    weatherFile.reload()
    marketSettingsFile.reload()
    controller.show()
  }

  function close() { controller.hide() }
  function toggle() { opened ? close() : open() }

  function switchPanel(direction) {
    if (bar && typeof bar.switchPanelFrom === "function")
      return bar.switchPanelFrom(barIdentity, direction)
    return false
  }

  function moveMonth(delta) {
    var next = Model.stepMonth(viewYear, viewMonth, delta)
    viewYear = next.year
    viewMonth = next.month
  }

  function refreshSystem() {
    if (!systemProcess.running) systemProcess.running = true
    if (!networkProcess.running) networkProcess.running = true
  }

  function formatBytes(value) {
    var bytes = Math.max(0, Number(value) || 0)
    var units = ["B", "KB", "MB", "GB", "TB"]
    var unit = 0
    while (bytes >= 1024 && unit < units.length - 1) {
      bytes /= 1024
      unit++
    }
    return (unit === 0 ? Math.round(bytes) : bytes.toFixed(bytes >= 100 ? 0 : 1)) + " " + units[unit]
  }

  function formatPing(value) {
    var ping = Number(value)
    return isFinite(ping) && ping >= 0 ? ping.toFixed(ping < 10 ? 2 : 0) + " ms" : "UNAVAILABLE"
  }

  function networkTypeLabel(info) {
    if (!info || !info.iface) return "WAITING FOR NETWORK"
    if (info.type === "wifi") return info.iface + " · WIFI" + (info.ssid ? " " + info.ssid : "")
    return info.iface + " · " + String(info.type || "NETWORK").toUpperCase()
      + (info.speed ? " " + info.speed + " Mb/s" : "")
  }

  function parseNetworkStatus(raw) {
    var info = {}
    var lines = String(raw || "").trim().split(/\n/)
    for (var i = 0; i < lines.length; i++) {
      var separator = lines[i].indexOf("\t")
      if (separator <= 0) continue
      var key = lines[i].slice(0, separator)
      info[key] = lines[i].slice(separator + 1)
    }

    var rx = Number(info.rx_bytes)
    var tx = Number(info.tx_bytes)
    var now = Date.now()
    var elapsedSeconds = (now - previousNetworkSampleMs) / 1000
    if (isFinite(rx) && isFinite(tx) && previousRxBytes >= 0 && previousTxBytes >= 0 && elapsedSeconds > 0) {
      networkRxRate = Math.max(0, (rx - previousRxBytes) / elapsedSeconds)
      networkTxRate = Math.max(0, (tx - previousTxBytes) / elapsedSeconds)
    } else {
      networkRxRate = 0
      networkTxRate = 0
    }
    if (isFinite(rx)) previousRxBytes = rx
    if (isFinite(tx)) previousTxBytes = tx
    previousNetworkSampleMs = now
    networkInfo = info
  }

  function mediaAction(action) {
    if (!player) return
    if (action === "previous" && player.canGoPrevious) player.previous()
    else if (action === "next" && player.canGoNext) player.next()
    else if (action === "playPause") {
      if (player.isPlaying && player.canPause) player.pause()
      else if (!player.isPlaying && player.canPlay) player.play()
      else if (player.canTogglePlaying) player.togglePlaying()
    }
  }

  function playerKey(source) {
    if (!source) return ""
    return String(source.dbusName || source.desktopEntry || source.identity || "")
  }

  function playerLabel(source) {
    if (!source) return "Media source"
    var identity = String(source.identity || source.desktopEntry || "Media source")
    var title = String(source.trackTitle || "")
    return title && title !== identity ? identity + " - " + title : identity
  }

  function selectPlayer(key) {
    selectedPlayerKey = String(key || "")
  }

  function seekTo(value) {
    if (!seekAvailable || !player) return
    sampledPosition = Math.max(0, Math.min(Number(value), player.length))
    player.position = sampledPosition
  }

  function setAppVolume(value) {
    if (!player || !player.volumeSupported) return
    player.volume = Math.max(0, Math.min(1, Number(value)))
  }

  function formatDuration(seconds) {
    var value = Math.max(0, Math.floor(Number(seconds) || 0))
    var minutes = Math.floor(value / 60)
    var remainder = value % 60
    return minutes + ":" + (remainder < 10 ? "0" : "") + remainder
  }

  function loadWeather() {
    if (isNaN(latitude) || isNaN(longitude) || weatherProcess.running) return
    var url = "https://api.open-meteo.com/v1/forecast?latitude=" + encodeURIComponent(latitude)
      + "&longitude=" + encodeURIComponent(longitude)
      + "&current=temperature_2m,apparent_temperature,relative_humidity_2m,wind_speed_10m,weather_code,is_day"
      + "&daily=weather_code,temperature_2m_max,temperature_2m_min&forecast_days=5&timezone=auto"
    weatherProcess.command = ["curl", "-fsS", "--max-time", "8", url]
    weatherProcess.running = true
  }

  function parseWeatherLocation(raw) {
    try {
      var data = JSON.parse(String(raw || "{}"))
      latitude = Number(data.latitude)
      longitude = Number(data.longitude)
      weatherLocation = String(data.name || "")
      loadWeather()
    } catch (e) {}
  }

  function normalizeMarketSymbols(value) {
    var values = String(value || "").split(",")
    var result = []
    for (var i = 0; i < values.length && result.length < 12; i++) {
      var symbol = String(values[i] || "").trim().toUpperCase()
      if (symbol !== "" && result.indexOf(symbol) === -1) result.push(symbol)
    }
    return result
  }

  function configureFromMarketsSettings(raw) {
    try {
      var settings = JSON.parse(String(raw || "{}"))
      var entries = settings && settings.bar && settings.bar.layout && settings.bar.layout.center
        ? settings.bar.layout.center : []
      var widget = null
      for (var i = 0; i < entries.length; i++) {
        if (entries[i] && entries[i].id === "io.github.tcballard.omarchy-markets") {
          widget = entries[i]
          break
        }
      }
      if (!widget) throw new Error("Markets widget is not configured")
      marketSymbols = normalizeMarketSymbols(widget.symbols)
      marketPrimarySymbol = String(widget.primarySymbol || marketSymbols[0] || "").trim().toUpperCase()
      marketDataEnabled = widget.dataEnabled === true
      var configuredInterval = Number(widget.refreshIntervalSec)
      marketRefreshIntervalSec = isFinite(configuredInterval)
        ? Math.max(300, Math.min(3600, Math.round(configuredInterval))) : 900
      if (!marketDataEnabled || marketSymbols.length === 0) {
        marketState = marketQuotes.length > 0 ? "stale" : "waiting"
        return
      }
      refreshMarketsIfStale()
    } catch (error) {
      marketDataEnabled = false
      marketLastError = "MARKETS SETTINGS UNAVAILABLE"
      marketState = marketQuotes.length > 0 ? "stale" : "error"
    }
  }

  function marketQuote(symbol) {
    for (var i = 0; i < marketQuotes.length; i++)
      if (String(marketQuotes[i].symbol || "").toUpperCase() === String(symbol || "").toUpperCase()) return marketQuotes[i]
    return null
  }

  function formatMarketPrice(quote) {
    var rawPrice = quote && quote.regularMarketPrice !== undefined
      ? quote.regularMarketPrice : (quote ? quote.price : NaN)
    if (!isFinite(Number(rawPrice))) return "--"
    var price = Number(rawPrice)
    var digits = price >= 1 ? 2 : 4
    return price.toLocaleString(Qt.locale(), "f", digits) + (quote.currency ? " " + quote.currency : "")
  }

  function formatMarketChange(quote) {
    if (!quote || !isFinite(Number(quote.changePercent))) return "--"
    var percent = Number(quote.changePercent)
    return (percent > 0 ? "+" : "") + percent.toFixed(2) + "%"
  }

  function marketChangeColor(quote) {
    var change = quote ? Number(quote.changePercent) : NaN
    if (change > 0) return "#30d158"
    if (change < 0) return "#ff453a"
    return root.foreground
  }

  function formatFreshness(value) {
    var timestamp = value instanceof Date ? value.getTime() : Date.parse(String(value || ""))
    if (!isFinite(timestamp) || timestamp <= 0) return "NOT UPDATED"
    var seconds = Math.max(0, Math.floor((Date.now() - timestamp) / 1000))
    if (seconds < 60) return "UPDATED NOW"
    if (seconds < 3600) return "UPDATED " + Math.floor(seconds / 60) + "M AGO"
    return "UPDATED " + Math.floor(seconds / 3600) + "H AGO"
  }

  function refreshMarketsIfStale() {
    var updated = marketLastUpdated instanceof Date ? marketLastUpdated.getTime() : 0
    if (updated <= 0 || Date.now() - updated >= marketRefreshIntervalSec * 1000) reloadMarkets("stale")
  }

  function reloadMarkets(trigger) {
    if (!marketDataEnabled || marketSymbols.length === 0 || marketProcess.running) return false
    var now = Date.now()
    if (String(trigger || "") === "manual" && now - marketLastRequestMs < 30000) return false
    marketLastRequestMs = now
    marketRefreshing = true
    marketLastError = ""
    if (marketQuotes.length === 0) marketState = "loading"
    marketProcess.command = ["/usr/bin/python3", marketHelperPath, "--timeout", "8", "--symbols",
      marketSymbols.join(","), "--range", "1d", "--cache-file", marketCacheFile]
    marketProcess.running = true
    return true
  }

  function parseMarketResponse(raw) {
    marketRefreshing = false
    try {
      var response = JSON.parse(String(raw || "{}"))
      var quotes = Array.isArray(response.quotes) ? response.quotes : []
      if (quotes.length === 0) throw new Error("No quotes returned")
      marketQuotes = quotes
      var generated = new Date(response.generatedAt || Date.now())
      marketLastUpdated = isNaN(generated.getTime()) ? new Date() : generated
      marketState = (response.errors && response.errors.length > 0) ? "partial" : "ready"
      marketLastError = response.errors && response.errors.length > 0 ? "SOME SYMBOLS UNAVAILABLE" : ""
    } catch (error) {
      marketState = marketQuotes.length > 0 ? "stale" : "error"
      marketLastError = "MARKET DATA UNAVAILABLE"
    }
  }

  component LabelText: Text {
    color: root.foreground
    font.family: root.fontFamily
    font.pixelSize: Style.font.body
  }

  component MutedText: Text {
    color: root.mutedForeground
    font.family: root.fontFamily
    font.pixelSize: Style.font.bodySmall
  }

  component HeaderText: Text {
    color: root.mutedForeground
    font.family: root.fontFamily
    font.pixelSize: Style.font.caption
    font.bold: true
    font.letterSpacing: 1
  }

  component Card: BorderSurface {
    color: Qt.rgba(root.foreground.r, root.foreground.g, root.foreground.b, 0.05)
    borderSpec: Border.controlSpec("normal", root.foreground, root.accent)
    radius: Style.cornerRadius
    padding: Style.space(16)
  }

  component SystemMetric: Item {
    property string label: ""
    property string icon: ""
    property real value: 0
    width: Style.space(210)
    height: Style.space(58)

    Row {
      anchors.left: parent.left
      anchors.right: parent.right
      topPadding: Style.space(2)
      spacing: Style.space(7)
      OpticalGlyph {
        width: Style.space(18)
        height: Style.space(18)
        anchors.verticalCenter: parent.verticalCenter
        text: icon
        color: root.foreground
        fontFamily: root.fontFamily
        fontSize: Style.font.title
      }
      MutedText { anchors.verticalCenter: parent.verticalCenter; text: label; font.letterSpacing: 1; font.bold: true }
      LabelText {
        anchors.verticalCenter: parent.verticalCenter
        width: parent.width - Style.space(80)
        horizontalAlignment: Text.AlignRight
        text: Math.round(value) + "%"
        font.pixelSize: Style.font.title
        font.bold: true
      }
    }

    Rectangle {
      anchors.left: parent.left
      anchors.right: parent.right
      anchors.bottom: parent.bottom
      height: Style.space(7)
      radius: height / 2
      color: root.meterTrack
      Rectangle {
        width: parent.width * Math.max(0, Math.min(1, value / 100))
        height: parent.height
        radius: parent.radius
        color: Style.selectedStateColor(root.foreground, root.accent)
        Behavior on width { NumberAnimation { duration: 250; easing.type: Easing.OutCubic } }
      }
    }
  }

  FileView {
    id: weatherFile
    path: Quickshell.env("HOME") + "/.local/state/omarchy/settings/weather.json"
    watchChanges: true
    printErrors: false
    onLoaded: root.parseWeatherLocation(text())
    onFileChanged: reload()
  }

  FileView {
    id: marketSettingsFile
    path: Quickshell.env("HOME") + "/.config/omarchy/shell.json"
    watchChanges: true
    printErrors: false
    onLoaded: root.configureFromMarketsSettings(text())
    onFileChanged: reload()
  }

  Process {
    id: marketProcess
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: root.parseMarketResponse(text)
    }
    onExited: function(exitCode) {
      if (exitCode !== 0 && root.marketRefreshing) {
        root.marketRefreshing = false
        root.marketState = root.marketQuotes.length > 0 ? "stale" : "error"
        root.marketLastError = "MARKET DATA UNAVAILABLE"
      }
    }
  }

  Process {
    id: systemProcess
    command: ["bash", "-lc", "read _ u n s i w irq sirq st _ < /proc/stat; t1=$((u+n+s+i+w+irq+sirq+st)); z1=$((i+w)); sleep 0.25; read _ u n s i w irq sirq st _ < /proc/stat; t2=$((u+n+s+i+w+irq+sirq+st)); z2=$((i+w)); cpu=$((100*((t2-t1)-(z2-z1))/(t2-t1))); mem=$(awk '/MemTotal/{t=$2}/MemAvailable/{a=$2}END{printf \"%.0f\",100*(t-a)/t}' /proc/meminfo); disk=$(df -P / | awk 'NR==2{gsub(/%/,\"\",$5);print $5}'); printf '%s %s %s\\n' \"$cpu\" \"$mem\" \"$disk\""]
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: {
        var values = String(text || "").trim().split(/\s+/)
        if (values.length < 3) return
        root.cpuUsage = Number(values[0])
        root.memoryUsage = Number(values[1])
        root.diskUsage = Number(values[2])
      }
    }
  }

  Process {
    id: networkProcess
    command: ["omarchy-network-status", "--verbose"]
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: root.parseNetworkStatus(text)
    }
  }

  Process {
    id: weatherProcess
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: {
        try {
          var data = JSON.parse(String(text || "{}"))
          root.weather = data.current || null
          var days = []
          var daily = data.daily || {}
          for (var i = 0; daily.time && i < daily.time.length; i++) {
            days.push({
              date: daily.time[i],
              code: daily.weather_code[i],
              high: Math.round(daily.temperature_2m_max[i]),
              low: Math.round(daily.temperature_2m_min[i])
            })
          }
          root.forecast = days
        } catch (e) {}
      }
    }
  }

  Timer {
    interval: 3000
    running: root.opened
    repeat: true
    triggeredOnStart: true
    onTriggered: root.refreshSystem()
  }

  Timer {
    interval: 500
    running: root.opened && root.seekAvailable
    repeat: true
    triggeredOnStart: true
    onTriggered: {
      if (!seekSlider.dragging && !overviewSeekSlider.dragging && root.player)
        root.sampledPosition = root.player.position
    }
  }

  Timer {
    interval: 15 * 60 * 1000
    running: true
    repeat: true
    onTriggered: root.loadWeather()
  }

  Timer {
    interval: 30000
    running: root.opened && root.currentView === 3
    repeat: true
    triggeredOnStart: true
    onTriggered: root.refreshMarketsIfStale()
  }

  SystemClock {
    precision: SystemClock.Minutes
    onDateChanged: root.today = date
  }

  KeyboardPanel {
    id: dashboardPanel
    anchorItem: root.anchorItem
    owner: root.barIdentity
    bar: root.bar
    open: root.opened
    centerOnBar: true
    focusTarget: keyCatcher
    contentWidth: dashboardPanel.fittedContentWidth(Style.space(760))
    contentHeight: dashboardPanel.fittedContentHeight(Style.space(560))

    PanelKeyCatcher {
      id: keyCatcher
      anchors.fill: parent
      onCloseRequested: root.close()
      onTabRequested: function(direction) { root.switchPanel(direction) }

      Rectangle {
        anchors.fill: parent
        color: root.panelFill
        radius: Style.cornerRadius
        border.width: Style.spacing.hairline
        border.color: Qt.rgba(root.foreground.r, root.foreground.g, root.foreground.b, 0.14)

        Column {
          anchors.fill: parent
          anchors.margins: Style.space(18)
          spacing: Style.space(16)

        Row {
          id: tabs
          width: parent.width
          height: Style.space(32)
          spacing: 0

          Repeater {
            model: ["OVERVIEW", "MEDIA", "WEATHER", "MARKETS"]
            Item {
              id: tabItem
              required property string modelData
              required property int index
              readonly property bool active: root.currentView === index
              width: tabs.width / 4
              height: tabs.height

              Text {
                id: tabLabel
                anchors.centerIn: parent
                anchors.verticalCenterOffset: -Style.space(3)
                text: tabItem.modelData
                textFormat: Text.PlainText
                color: tabItem.active ? root.accent : root.mutedForeground
                opacity: tabItem.active ? 1.0 : (tabArea.containsMouse ? 0.9 : 0.55)
                font.family: root.fontFamily
                font.pixelSize: Style.font.caption
                font.bold: tabItem.active
                font.letterSpacing: 1.2
              }

              Rectangle {
                anchors.bottom: parent.bottom
                anchors.horizontalCenter: parent.horizontalCenter
                width: tabItem.active ? Style.space(28) : (tabArea.containsMouse ? Style.space(14) : 0)
                height: Style.space(2)
                radius: height / 2
                color: root.accent
                opacity: tabItem.active ? 1.0 : 0.5
                Behavior on width { NumberAnimation { duration: 160; easing.type: Easing.OutCubic } }
              }

              MouseArea {
                id: tabArea
                anchors.fill: parent
                hoverEnabled: true
                cursorShape: Qt.PointingHandCursor
                onClicked: root.currentView = tabItem.index
              }
            }
          }
        }

        Rectangle {
          width: parent.width
          height: Style.spacing.hairline
          color: root.foreground
          opacity: 0.12
        }

        Item {
          width: parent.width
          height: parent.height - tabs.height - Style.space(29)

          Item {
            visible: root.currentView === 0
            anchors.fill: parent

            Flickable {
              id: overviewFlick
              anchors.fill: parent
              contentWidth: width
              contentHeight: overviewFlow.implicitHeight
              clip: true
              interactive: contentHeight > height
              boundsBehavior: Flickable.StopAtBounds

              Column {
                id: overviewFlow
                width: overviewFlick.width
                spacing: Style.space(12)

                Row {
                  width: parent.width
                  spacing: Style.space(12)

                  // -------- left: calendar + now playing
                  Column {
                    width: (parent.width - parent.spacing) * 0.55
                    spacing: Style.space(12)

                    Card {
                      width: parent.width
                      height: calendarBody.implicitHeight + calendarBody.y + Style.space(14)

                      Column {
                        id: calendarBody
                        width: parent.width - parent.contentLeftInset - parent.contentRightInset
                        x: parent.contentLeftInset
                        y: parent.contentTopInset
                        spacing: Style.space(7)

                        Row {
                          width: parent.width
                          height: Style.space(40)
                          Column {
                            width: parent.width - monthNavigation.implicitWidth
                            spacing: Style.space(1)
                            LabelText {
                              text: Qt.formatDate(new Date(root.viewYear, root.viewMonth, 1), "MMMM yyyy")
                              textFormat: Text.PlainText
                              font.pixelSize: Style.font.heading
                              font.bold: true
                            }
                            MutedText {
                              text: Qt.formatDate(root.today, "dddd, MMMM d").toUpperCase()
                              textFormat: Text.PlainText
                              font.pixelSize: Style.font.caption
                              font.letterSpacing: 1
                            }
                          }
                          Row {
                            id: monthNavigation
                            anchors.verticalCenter: parent.verticalCenter
                            spacing: Style.space(2)
                            PanelActionButton {
                              size: Style.space(26)
                              iconText: "󰅁"
                              foreground: root.foreground
                              fontFamily: root.fontFamily
                              tooltipText: "Previous month"
                              onClicked: root.moveMonth(-1)
                            }
                            PanelActionButton {
                              size: Style.space(26)
                              iconText: "󰅂"
                              foreground: root.foreground
                              fontFamily: root.fontFamily
                              tooltipText: "Next month"
                              onClicked: root.moveMonth(1)
                            }
                          }
                        }

                        Grid {
                          width: parent.width
                          columns: 7
                          rowSpacing: Style.space(3)
                          columnSpacing: Style.space(3)
                          Repeater {
                            model: ["MON", "TUE", "WED", "THU", "FRI", "SAT", "SUN"]
                            MutedText {
                              required property string modelData
                              width: (parent.width - Style.space(18)) / 7
                              height: Style.space(18)
                              text: modelData
                              textFormat: Text.PlainText
                              horizontalAlignment: Text.AlignHCenter
                              verticalAlignment: Text.AlignVCenter
                              font.pixelSize: Style.font.caption
                              font.letterSpacing: 1
                            }
                          }
                          Repeater {
                            model: root.calendarCells
                            Rectangle {
                              required property var modelData
                              width: (parent.width - Style.space(18)) / 7
                              height: Style.space(30)
                              radius: Style.cornerRadius
                              color: modelData.today ? Style.selectedFillFor(root.foreground, root.accent) : "transparent"
                              border.width: modelData.today ? Style.spacing.hairline : 0
                              border.color: Style.selectedBorderFor(root.foreground, root.accent)
                              LabelText {
                                anchors.centerIn: parent
                                text: modelData.day
                                textFormat: Text.PlainText
                                color: modelData.inMonth
                                  ? (modelData.weekend ? Qt.darker(root.foreground, 1.4) : root.foreground)
                                  : Qt.darker(root.foreground, 2.1)
                                font.bold: modelData.today
                              }
                            }
                          }
                        }
                      }
                    }

                    Card {
                      width: parent.width
                      height: nowPlayingBody.implicitHeight + nowPlayingBody.y + Style.space(14)

                      Column {
                        id: nowPlayingBody
                        width: parent.width - parent.contentLeftInset - parent.contentRightInset
                        x: parent.contentLeftInset
                        y: parent.contentTopInset
                        spacing: Style.space(8)

                        HeaderText { text: "NOW PLAYING" }

                        Row {
                          width: parent.width
                          spacing: Style.space(10)

                          Rectangle {
                            width: Style.space(56)
                            height: Style.space(56)
                            radius: Style.cornerRadius
                            color: Qt.rgba(root.foreground.r, root.foreground.g, root.foreground.b, 0.08)
                            Image {
                              id: overviewAlbumArt
                              anchors.fill: parent
                              anchors.margins: Style.space(2)
                              source: root.player && root.player.trackArtUrl ? root.player.trackArtUrl : ""
                              fillMode: Image.PreserveAspectCrop
                              visible: source !== ""
                              asynchronous: true
                            }
                            LabelText {
                              anchors.centerIn: parent
                              visible: !overviewAlbumArt.visible
                              text: "󰝚"
                              font.pixelSize: 24
                            }
                          }

                          Column {
                            width: parent.width - Style.space(66)
                            anchors.verticalCenter: parent.verticalCenter
                            spacing: Style.space(2)
                            LabelText {
                              width: parent.width
                              text: root.player ? (root.player.trackTitle || "Unknown title") : "Nothing playing"
                              textFormat: Text.PlainText
                              font.bold: true
                              elide: Text.ElideRight
                            }
                            MutedText {
                              width: parent.width
                              text: root.player ? (root.player.trackArtist || root.player.identity || "") : "Start a media player"
                              textFormat: Text.PlainText
                              elide: Text.ElideRight
                            }
                          }
                        }

                        Column {
                          width: parent.width
                          spacing: Style.space(1)
                          Row {
                            width: parent.width
                            MutedText { text: "POSITION"; font.pixelSize: Style.font.caption; font.letterSpacing: 1 }
                            MutedText {
                              width: parent.width - Style.space(96)
                              horizontalAlignment: Text.AlignRight
                              text: root.seekAvailable
                                ? root.formatDuration(overviewSeekSlider.dragging ? overviewSeekSlider.liveValue : root.trackPosition)
                                  + " / " + root.formatDuration(root.trackLength)
                                : "--:-- / --:--"
                              font.pixelSize: Style.font.caption
                            }
                          }
                          PanelSlider {
                            id: overviewSeekSlider
                            width: parent.width
                            bar: root.bar
                            minimum: 0
                            maximum: root.trackLength
                            step: 5
                            knobSize: 0
                            value: root.trackPosition
                            enabled: root.seekAvailable
                            opacity: enabled ? 1 : 0.35
                            onReleased: function(value) { root.seekTo(value) }
                          }
                        }

                        Row {
                          anchors.horizontalCenter: parent.horizontalCenter
                          spacing: Style.space(12)
                          PanelActionButton { size: Style.space(30); fontSize: Style.font.icon; iconText: "󰒮"; foreground: root.foreground; fontFamily: root.fontFamily; enabled: root.player && root.player.canGoPrevious; onClicked: root.mediaAction("previous") }
                          PanelActionButton { size: Style.space(30); fontSize: Style.font.iconLarge; iconText: root.player && root.player.isPlaying ? "󰏤" : "󰐊"; foreground: root.foreground; fontFamily: root.fontFamily; enabled: !!root.player; onClicked: root.mediaAction("playPause") }
                          PanelActionButton { size: Style.space(30); fontSize: Style.font.icon; iconText: "󰒭"; foreground: root.foreground; fontFamily: root.fontFamily; enabled: root.player && root.player.canGoNext; onClicked: root.mediaAction("next") }
                        }
                      }
                    }
                  }

                  // -------- right: system + network
                  Column {
                    width: (parent.width - parent.spacing) * 0.45
                    spacing: Style.space(12)

                    Card {
                      width: parent.width
                      height: systemBody.implicitHeight + systemBody.y + Style.space(14)

                      Column {
                        id: systemBody
                        width: parent.width - parent.contentLeftInset - parent.contentRightInset
                        x: parent.contentLeftInset
                        y: parent.contentTopInset
                        spacing: Style.space(10)

                        HeaderText { text: "SYSTEM STATUS" }

                        Column {
                          width: parent.width
                          spacing: Style.space(8)
                          SystemMetric { width: parent.width; label: "CPU"; icon: "󰍛"; value: root.cpuUsage }
                          SystemMetric { width: parent.width; label: "MEMORY"; icon: "󰘚"; value: root.memoryUsage }
                          SystemMetric { width: parent.width; label: "DISK"; icon: "󰋊"; value: root.diskUsage }
                        }
                      }
                    }

                    Card {
                      width: parent.width
                      height: networkBody.implicitHeight + networkBody.y + Style.space(14)

                      Column {
                        id: networkBody
                        width: parent.width - parent.contentLeftInset - parent.contentRightInset
                        x: parent.contentLeftInset
                        y: parent.contentTopInset
                        spacing: Style.space(8)

                        Row {
                          width: parent.width
                          HeaderText { text: "NETWORK" }
                          MutedText {
                            width: parent.width - Style.space(90)
                            horizontalAlignment: Text.AlignRight
                            text: root.networkTypeLabel(root.networkInfo)
                            textFormat: Text.PlainText
                            font.bold: true
                            font.letterSpacing: 1
                            font.pixelSize: Style.font.caption
                            elide: Text.ElideLeft
                          }
                        }

                        Item {
                          width: parent.width
                          height: Style.space(20)
                          MutedText { anchors.left: parent.left; anchors.verticalCenter: parent.verticalCenter; text: "LOCAL IP"; font.bold: true; font.letterSpacing: 1; font.pixelSize: Style.font.caption }
                          LabelText {
                            anchors.right: parent.right
                            anchors.verticalCenter: parent.verticalCenter
                            text: root.networkInfo.ip
                              ? root.networkInfo.ip + (root.networkInfo.prefix ? "/" + root.networkInfo.prefix : "")
                              : "WAITING"
                            textFormat: Text.PlainText
                            font.bold: true
                            font.pixelSize: Style.font.caption
                            elide: Text.ElideLeft
                          }
                        }

                        Item {
                          width: parent.width
                          height: Style.space(20)
                          MutedText { anchors.left: parent.left; anchors.verticalCenter: parent.verticalCenter; text: "GATEWAY"; font.bold: true; font.letterSpacing: 1; font.pixelSize: Style.font.caption }
                          LabelText {
                            anchors.right: parent.right
                            anchors.verticalCenter: parent.verticalCenter
                            text: root.networkInfo.gateway || "—"
                            textFormat: Text.PlainText
                            font.bold: true
                            font.pixelSize: Style.font.caption
                            elide: Text.ElideLeft
                          }
                        }

                        Row {
                          width: parent.width
                          spacing: Style.space(18)
                          Item {
                            width: (parent.width - parent.spacing) / 2
                            height: Style.space(20)
                            MutedText { anchors.left: parent.left; anchors.verticalCenter: parent.verticalCenter; text: "ROUTER"; font.bold: true; font.letterSpacing: 1; font.pixelSize: Style.font.caption }
                            LabelText {
                              anchors.right: parent.right
                              anchors.verticalCenter: parent.verticalCenter
                              text: root.formatPing(root.networkInfo.router_ping_ms)
                              textFormat: Text.PlainText
                              font.bold: true
                              font.pixelSize: Style.font.caption
                            }
                          }
                          Item {
                            width: (parent.width - parent.spacing) / 2
                            height: Style.space(20)
                            MutedText { anchors.left: parent.left; anchors.verticalCenter: parent.verticalCenter; text: "INTERNET"; font.bold: true; font.letterSpacing: 1; font.pixelSize: Style.font.caption }
                            LabelText {
                              anchors.right: parent.right
                              anchors.verticalCenter: parent.verticalCenter
                              text: root.formatPing(root.networkInfo.internet_ping_ms)
                              color: root.networkInfo.internet_ping_ms ? root.foreground : root.accent
                              textFormat: Text.PlainText
                              font.bold: true
                              font.pixelSize: Style.font.caption
                            }
                          }
                        }

                        Rectangle { width: parent.width; height: Style.spacing.hairline; color: root.foreground; opacity: 0.12 }

                        Row {
                          width: parent.width
                          spacing: Style.space(18)
                          Item {
                            width: (parent.width - parent.spacing) / 2
                            height: Style.space(20)
                            MutedText { anchors.left: parent.left; anchors.verticalCenter: parent.verticalCenter; text: "RX"; font.bold: true; font.letterSpacing: 1; font.pixelSize: Style.font.caption }
                            LabelText { anchors.right: parent.right; anchors.verticalCenter: parent.verticalCenter; text: root.formatBytes(root.networkRxRate) + "/s"; textFormat: Text.PlainText; font.bold: true; font.pixelSize: Style.font.caption }
                          }
                          Item {
                            width: (parent.width - parent.spacing) / 2
                            height: Style.space(20)
                            MutedText { anchors.left: parent.left; anchors.verticalCenter: parent.verticalCenter; text: "TX"; font.bold: true; font.letterSpacing: 1; font.pixelSize: Style.font.caption }
                            LabelText { anchors.right: parent.right; anchors.verticalCenter: parent.verticalCenter; text: root.formatBytes(root.networkTxRate) + "/s"; textFormat: Text.PlainText; font.bold: true; font.pixelSize: Style.font.caption }
                          }
                        }
                      }
                    }
                  }
                }
              }
            }
          }

          Item {
            visible: root.currentView === 1
            anchors.fill: parent
            Column {
              width: Math.min(parent.width, Style.space(560))
              anchors.centerIn: parent
              spacing: Style.space(10)
              Column {
                visible: root.sourcePlayers.length > 1
                width: Math.min(parent.width, Style.space(430))
                height: visible ? Style.space(44) : 0
                anchors.horizontalCenter: parent.horizontalCenter
                spacing: Style.space(4)
                MutedText {
                  width: parent.width
                  text: "SOURCE"
                  font.pixelSize: Style.font.caption
                  font.letterSpacing: 1
                  horizontalAlignment: Text.AlignHCenter
                }
                Row {
                  id: sourceSelector
                  width: parent.width
                  height: Style.spacing.controlHeight
                  spacing: Style.space(5)
                  Repeater {
                    model: root.sourceOptions
                    BorderSurface {
                      id: sourceButton
                      required property var modelData
                      readonly property bool selected: root.playerKey(root.player) === String(modelData.value)
                      width: (sourceSelector.width - sourceSelector.spacing * Math.max(0, root.sourceOptions.length - 1))
                        / Math.max(1, root.sourceOptions.length)
                      height: sourceSelector.height
                      radius: Style.cornerRadius
                      color: selected
                        ? Style.selectedFillFor(root.foreground, root.accent)
                        : (sourceMouse.containsMouse ? Style.hoverFillFor(root.foreground, root.accent) : root.panelFill)
                      borderSpec: Border.controlSpec(selected ? "selected" : (sourceMouse.containsMouse ? "hover-cursor" : "normal"), root.foreground, root.accent)

                      LabelText {
                        anchors.fill: parent
                        anchors.leftMargin: sourceButton.contentLeftInset + Style.space(8)
                        anchors.rightMargin: sourceButton.contentRightInset + Style.space(8)
                        text: sourceButton.modelData.label
                        horizontalAlignment: Text.AlignHCenter
                        verticalAlignment: Text.AlignVCenter
                        font.pixelSize: Style.font.bodySmall
                        font.bold: sourceButton.selected
                        elide: Text.ElideRight
                      }

                      MouseArea {
                        id: sourceMouse
                        anchors.fill: parent
                        hoverEnabled: true
                        cursorShape: Qt.PointingHandCursor
                        onClicked: root.selectPlayer(sourceButton.modelData.value)
                      }
                    }
                  }
                }
              }
              BorderSurface {
                width: Style.space(160)
                height: Style.space(160)
                anchors.horizontalCenter: parent.horizontalCenter
                radius: Style.cornerRadius
                color: root.panelFill
                borderSpec: Border.controlSpec("normal", root.foreground, root.accent)
                Image { id: mediaAlbumArt; anchors.fill: parent; anchors.margins: Style.space(3); source: root.player && root.player.trackArtUrl ? root.player.trackArtUrl : ""; fillMode: Image.PreserveAspectCrop; visible: source !== ""; asynchronous: true }
                LabelText { anchors.centerIn: parent; visible: !mediaAlbumArt.visible; text: "󰝚"; font.pixelSize: 56 }
              }
              Column {
                width: parent.width
                spacing: Style.space(4)
                LabelText { width: parent.width; text: root.player ? (root.player.trackTitle || "Unknown title") : "Nothing playing"; horizontalAlignment: Text.AlignHCenter; font.pixelSize: Style.font.heading; font.bold: true; elide: Text.ElideRight }
                MutedText { width: parent.width; text: root.player ? (root.player.trackArtist || root.player.identity || "") : "Start a media player"; horizontalAlignment: Text.AlignHCenter; font.pixelSize: Style.font.body; elide: Text.ElideRight }
                MutedText { width: parent.width; text: root.player ? (root.player.trackAlbum || "") : ""; horizontalAlignment: Text.AlignHCenter; visible: text !== ""; elide: Text.ElideRight }
              }
              Row {
                anchors.horizontalCenter: parent.horizontalCenter
                spacing: Style.space(14)
                PanelActionButton { size: Style.space(38); fontSize: Style.font.icon; iconText: "󰒮"; foreground: root.foreground; fontFamily: root.fontFamily; enabled: root.player && root.player.canGoPrevious; onClicked: root.mediaAction("previous") }
                PanelActionButton { size: Style.space(38); fontSize: Style.font.display; iconText: root.player && root.player.isPlaying ? "󰏤" : "󰐊"; foreground: root.foreground; fontFamily: root.fontFamily; enabled: !!root.player; onClicked: root.mediaAction("playPause") }
                PanelActionButton { size: Style.space(38); fontSize: Style.font.icon; iconText: "󰒭"; foreground: root.foreground; fontFamily: root.fontFamily; enabled: root.player && root.player.canGoNext; onClicked: root.mediaAction("next") }
              }

              Column {
                width: parent.width
                spacing: Style.space(2)
                Row {
                  width: parent.width
                  MutedText { text: "POSITION"; font.pixelSize: Style.font.caption; font.letterSpacing: 1 }
                  MutedText {
                    width: parent.width - Style.space(70)
                    horizontalAlignment: Text.AlignRight
                    text: root.formatDuration(seekSlider.dragging ? seekSlider.liveValue : root.trackPosition)
                      + " / " + root.formatDuration(root.seekAvailable ? root.trackLength : 0)
                    font.pixelSize: Style.font.caption
                  }
                }
                PanelSlider {
                  id: seekSlider
                  width: parent.width
                  bar: root.bar
                  minimum: 0
                  maximum: root.trackLength
                  step: 5
                  knobSize: 0
                  value: root.trackPosition
                  enabled: root.seekAvailable
                  opacity: enabled ? 1 : 0.35
                  onReleased: function(value) { root.seekTo(value) }
                }
              }

              Column {
                width: parent.width
                spacing: Style.space(2)
                Row {
                  width: parent.width
                  MutedText { text: "APP VOLUME"; font.pixelSize: Style.font.caption; font.letterSpacing: 1 }
                  MutedText {
                    width: parent.width - Style.space(88)
                    horizontalAlignment: Text.AlignRight
                    text: Math.round((volumeSlider.dragging ? volumeSlider.liveValue : root.appVolume) * 100) + "%"
                    font.pixelSize: Style.font.caption
                  }
                }
                PanelSlider {
                  id: volumeSlider
                  width: parent.width
                  bar: root.bar
                  minimum: 0
                  maximum: 1
                  step: 0.05
                  knobSize: 0
                  value: root.appVolume
                  enabled: !!root.player && root.player.volumeSupported
                  opacity: enabled ? 1 : 0.35
                  onMoved: function(value) { root.setAppVolume(value) }
                }
              }
            }
          }

          Item {
            visible: root.currentView === 2
            anchors.fill: parent
            Column {
              width: Math.min(parent.width, Style.space(650))
              anchors.centerIn: parent
              spacing: Style.space(28)
              Row {
                anchors.horizontalCenter: parent.horizontalCenter
                spacing: Style.space(28)
                LabelText { text: root.weather ? Model.weatherIcon(root.weather.weather_code, root.weather.is_day) : "󰖐"; font.pixelSize: 86; anchors.verticalCenter: parent.verticalCenter }
                Column {
                  anchors.verticalCenter: parent.verticalCenter
                  spacing: Style.space(5)
                  LabelText { text: root.weather ? Math.round(root.weather.temperature_2m) + "°C" : "--°C"; font.pixelSize: 56; font.bold: true }
                  MutedText { text: root.weatherLocation.toUpperCase(); font.letterSpacing: 1 }
                }
              }
              Row {
                anchors.horizontalCenter: parent.horizontalCenter
                spacing: Style.space(56)
                Column {
                  spacing: Style.space(4)
                  MutedText { text: "FEELS"; font.letterSpacing: 1 }
                  LabelText { text: root.weather ? Math.round(root.weather.apparent_temperature) + "°C" : "--"; font.pixelSize: Style.font.title }
                }
                Column {
                  spacing: Style.space(4)
                  MutedText { text: "WIND"; font.letterSpacing: 1 }
                  LabelText { text: root.weather ? Math.round(root.weather.wind_speed_10m) + " km/h" : "--"; font.pixelSize: Style.font.title }
                }
                Column {
                  spacing: Style.space(4)
                  MutedText { text: "HUMIDITY"; font.letterSpacing: 1 }
                  LabelText { text: root.weather ? Math.round(root.weather.relative_humidity_2m) + "%" : "--"; font.pixelSize: Style.font.title }
                }
              }
              Rectangle { width: parent.width; height: Style.spacing.hairline; color: root.foreground; opacity: 0.12 }
              Row {
                width: parent.width
                spacing: Style.space(8)
                Repeater {
                  model: root.forecast
                  Card {
                    required property var modelData
                    width: (parent.width - parent.spacing * Math.max(0, root.forecast.length - 1)) / Math.max(1, root.forecast.length)
                    height: Style.space(135)
                    Column {
                      anchors.centerIn: parent
                      spacing: Style.space(8)
                      MutedText { anchors.horizontalCenter: parent.horizontalCenter; text: Model.dayLabel(modelData.date); font.letterSpacing: 1 }
                      LabelText { anchors.horizontalCenter: parent.horizontalCenter; text: Model.weatherIcon(modelData.code, 1); font.pixelSize: Style.font.displayLarge }
                      Row {
                        anchors.horizontalCenter: parent.horizontalCenter
                        spacing: Style.space(7)
                        LabelText { text: modelData.high + "°"; font.bold: true }
                        MutedText { text: modelData.low + "°" }
                      }
                    }
                  }
                }
              }
            }
          }

          Item {
            visible: root.currentView === 3
            anchors.fill: parent

            Column {
              width: Math.min(parent.width, Style.space(650))
              anchors.centerIn: parent
              spacing: Style.space(12)

              Card {
                id: marketPrimaryCard
                width: parent.width
                height: Style.space(116)
                property var primaryQuote: root.marketQuote(root.marketPrimarySymbol)
                Column {
                  anchors.fill: parent
                  anchors.margins: parent.contentLeftInset
                  spacing: Style.space(6)
                  Row {
                    width: parent.width
                    HeaderText { text: "PRIMARY · " + root.marketPrimarySymbol }
                    MutedText {
                      width: parent.width - Style.space(170)
                      text: root.formatFreshness(root.marketLastUpdated) + " · " + root.marketState.toUpperCase()
                      horizontalAlignment: Text.AlignRight
                      font.bold: true
                      font.letterSpacing: 1
                      elide: Text.ElideLeft
                    }
                  }
                  Rectangle { width: parent.width; height: Style.spacing.hairline; color: root.foreground; opacity: 0.12 }
                  Row {
                    width: parent.width
                    height: Style.space(42)
                    LabelText {
                      width: parent.width * 0.62
                      anchors.verticalCenter: parent.verticalCenter
                      text: marketPrimaryCard.primaryQuote ? String(marketPrimaryCard.primaryQuote.name || root.marketPrimarySymbol) : root.marketPrimarySymbol
                      font.pixelSize: Style.font.title
                      font.bold: true
                      elide: Text.ElideRight
                    }
                    Column {
                      width: parent.width * 0.38
                      anchors.verticalCenter: parent.verticalCenter
                      spacing: Style.space(2)
                      LabelText {
                        width: parent.width
                        text: root.formatMarketPrice(marketPrimaryCard.primaryQuote)
                        horizontalAlignment: Text.AlignRight
                        font.pixelSize: Style.font.title
                        font.bold: true
                      }
                      LabelText {
                        width: parent.width
                        text: root.formatMarketChange(marketPrimaryCard.primaryQuote)
                        color: root.marketChangeColor(marketPrimaryCard.primaryQuote)
                        horizontalAlignment: Text.AlignRight
                        font.bold: true
                      }
                    }
                  }
                }
                MouseArea {
                  anchors.fill: parent
                  hoverEnabled: true
                  cursorShape: Qt.PointingHandCursor
                  onClicked: root.reloadMarkets("manual")
                }
              }

              Row {
                width: parent.width
                HeaderText { text: "WATCHLIST" }
                MutedText {
                  width: parent.width - Style.space(105)
                  text: root.marketRefreshing ? "REFRESHING…" : (root.marketLastError || "CLICK PRIMARY CARD TO REFRESH")
                  horizontalAlignment: Text.AlignRight
                  font.bold: true
                  font.letterSpacing: 1
                  elide: Text.ElideLeft
                }
              }
              Rectangle { width: parent.width; height: Style.spacing.hairline; color: root.foreground; opacity: 0.12 }

              Repeater {
                model: root.marketSymbols
                Item {
                  required property string modelData
                  property var quote: root.marketQuote(modelData)
                  width: parent.width
                  height: Style.space(29)
                  Row {
                    anchors.fill: parent
                    LabelText {
                      width: parent.width * 0.26
                      anchors.verticalCenter: parent.verticalCenter
                      text: parent.parent.modelData
                      font.bold: parent.parent.modelData === root.marketPrimarySymbol
                    }
                    MutedText {
                      width: parent.width * 0.39
                      anchors.verticalCenter: parent.verticalCenter
                      text: parent.parent.quote ? String(parent.parent.quote.name || "") : "WAITING"
                      elide: Text.ElideRight
                    }
                    LabelText {
                      width: parent.width * 0.22
                      anchors.verticalCenter: parent.verticalCenter
                      text: root.formatMarketPrice(parent.parent.quote)
                      horizontalAlignment: Text.AlignRight
                      font.bold: true
                      elide: Text.ElideLeft
                    }
                    LabelText {
                      width: parent.width * 0.13
                      anchors.verticalCenter: parent.verticalCenter
                      text: root.formatMarketChange(parent.parent.quote)
                      color: root.marketChangeColor(parent.parent.quote)
                      horizontalAlignment: Text.AlignRight
                      font.bold: true
                    }
                  }
                  Rectangle { anchors.bottom: parent.bottom; width: parent.width; height: Style.spacing.hairline; color: root.foreground; opacity: 0.12 }
                }
              }
            }
          }
        }
      }
    }
  }
}
}
