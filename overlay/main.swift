// Perch Overlay — the island lives in the notch band.
//
// On a notched display the panel is flush with the top edge of the screen, so
// it reads as part of the camera housing: the collapsed state is a black band
// exactly as tall as the notch, with the pet in the left wing and the running
// count in the right wing. Expanding grows the panel downward, iPhone style.
// On an external display without a notch it falls back to a floating bar just
// under the menu bar.
//
// It owns no state: the DSH plugin posts presentation-ready JSON to
// 127.0.0.1:47823 and this panel only renders it. Every user-facing string
// arrives already localized.
//
// Wake: hover, click, or ⌥⌘P. Close: click, move away, right-click → Quit.

import AppKit
import AVFoundation
import Carbon.HIToolbox
import Network
import SwiftUI

// MARK: - Palette

private enum Ink {
  static let panel = Color.black
  static let card = Color(red: 0x0b / 255, green: 0x0c / 255, blue: 0x0e / 255)
  static let ink = Color(red: 0xec / 255, green: 0xee / 255, blue: 0xf1 / 255)
  static let dim = Color(red: 0x8b / 255, green: 0x90 / 255, blue: 0x99 / 255)
  static let faint = Color(red: 0x5c / 255, green: 0x62 / 255, blue: 0x6a / 255)
  static let green = Color(red: 0x4a / 255, green: 0xde / 255, blue: 0x80 / 255)
  static let amber = Color(red: 0xf5 / 255, green: 0xc4 / 255, blue: 0x51 / 255)
  static let sky = Color(red: 0x7d / 255, green: 0xd3 / 255, blue: 0xfc / 255)
  static let hairline = Color.white.opacity(0.10)
}

private let dshBundleId = "com.deepseek.dsh"
private let listenPort: UInt16 = 47823
private let wingWidth: CGFloat = 56
private let headHeight: CGFloat = 32
private let rowHeight: CGFloat = 42
private let footHeight: CGFloat = 26
private let barHeight: CGFloat = 32
private let barWidth: CGFloat = 208
private let expandedWidth: CGFloat = 400
private let doneWidth: CGFloat = 320

/// Bring DSH forward; the helper cannot deep-link to one Session.
private func activateDSH() {
  guard let app = NSRunningApplication.runningApplications(withBundleIdentifier: dshBundleId).first else { return }
  app.activate(options: [.activateAllWindows])
}

// MARK: - Wire types

struct Row: Codable, Identifiable, Equatable {
  let key: String
  let kind: String
  let title: String
  let tag: String
  let action: String
  let startedAt: Double
  var id: String { key }
}

struct Done: Codable, Equatable {
  let seq: Int
  let title: String
  let summary: String
  let current: Bool
}

struct Payload: Codable, Equatable {
  let headline: String
  let headAction: String
  let footer: String
  let rows: [Row]
  let done: Done?
  let clear: Bool?
  /// Active DSH locale, `zh` or `en`; selects the custom notification text.
  let locale: String?
}

/// Notification preferences pushed by the plugin's Host half from the bundle
/// patch (`config.notify`), so the helper needs no settings file of its own.
struct NotifySettings: Codable, Equatable {
  let system: Bool
  let voice: Bool
}

struct LocalizedText: Codable, Equatable {
  let zh: String
  let en: String

  func forLocale(_ locale: String?) -> String {
    (locale ?? "en").lowercased().hasPrefix("zh") ? zh : en
  }
}

struct Settings: Codable, Equatable {
  let notify: NotifySettings
  let text: LocalizedText
}

/// Discriminates a settings POST from a state POST on the same endpoint.
struct Envelope: Decodable {
  let kind: String?
}

/// Screen band facts, owned by the app delegate and mirrored into the store.
struct Geometry: Equatable {
  var topInset: CGFloat = 0
  var notchWidth: CGFloat = 0

  var hasNotch: Bool { notchWidth > 0 }
  var bandHeight: CGFloat { hasNotch ? topInset : barHeight }
  var collapsedWidth: CGFloat { hasNotch ? notchWidth + wingWidth * 2 : barWidth }
}

// MARK: - Store

final class Store: ObservableObject {
  @Published var payload = Payload(headline: "", headAction: "", footer: "", rows: [], done: nil, clear: nil, locale: nil) {
    didSet { onChange?() }
  }
  @Published var expanded = false {
    didSet { onChange?() }
  }
  @Published var geometry = Geometry()
  @Published var pinned = false
  @Published var blink = false

  var onChange: (() -> Void)?

  var visibleRows: [Row] { Array(payload.rows.prefix(5)) }
  var hasRows: Bool { !payload.rows.isEmpty }
  var showDone: Bool { payload.done != nil && payload.clear != true }
  var isVisible: Bool { payload.clear != true }
  var showsBody: Bool { showDone || expanded }

  var size: CGSize {
    let band = geometry.bandHeight
    if let done = payload.done {
      let width = done.current ? geometry.collapsedWidth : max(doneWidth, geometry.collapsedWidth)
      return CGSize(width: width, height: band + headHeight + (done.current || done.summary.isEmpty ? 0 : 22))
    }
    guard expanded else {
      return CGSize(width: geometry.collapsedWidth, height: band)
    }
    let rows = CGFloat(min(payload.rows.count, 5))
    return CGSize(width: max(expandedWidth, geometry.collapsedWidth), height: band + headHeight + rows * rowHeight + footHeight)
  }

  func apply(_ next: Payload) {
    if next.clear == true {
      payload = Payload(headline: "", headAction: "", footer: "", rows: [], done: nil, clear: true, locale: nil)
      expanded = false
      pinned = false
      return
    }
    payload = next
    if !hasRows && payload.done == nil { expanded = false; pinned = false }
  }
}

// MARK: - Pixel drawing

struct Pixel: View {
  let grid: [String]
  let color: Color
  let scale: CGFloat

  var body: some View {
    Canvas { context, _ in
      for (y, line) in grid.enumerated() {
        for (x, char) in line.enumerated() where char == "#" {
          context.fill(
            Path(CGRect(x: CGFloat(x) * scale, y: CGFloat(y) * scale, width: scale, height: scale)),
            with: .color(color)
          )
        }
      }
    }
    .frame(width: CGFloat(grid.first?.count ?? 0) * scale, height: CGFloat(grid.count) * scale)
  }
}

struct Pet: View {
  let blinking: Bool
  let sleeping: Bool

  var body: some View {
    ZStack {
      Pixel(grid: [
        "..#####..",
        ".#######.",
        "#########",
        "#########",
        "#########",
        ".#######.",
        "..#####..",
      ], color: sleeping ? Ink.green.opacity(0.55) : Ink.green, scale: 2)
      HStack(spacing: 6) {
        Rectangle().fill(Ink.panel).frame(width: 2, height: sleeping ? 1 : (blinking ? 2 : 4))
        Rectangle().fill(Ink.panel).frame(width: 2, height: sleeping ? 1 : (blinking ? 2 : 4))
      }
    }
    .frame(width: 18, height: 14)
    .accessibilityHidden(true)
  }
}

struct Mark: View {
  let kind: String

  var body: some View {
    switch kind {
    case "job":
      Pixel(grid: ["....", "####", "....", "####"], color: Ink.amber, scale: 2.5)
    case "subagent":
      Pixel(grid: [".#..", ".#..", "####", ".#.."], color: Ink.sky, scale: 2.5)
    default:
      Pixel(grid: [".##.", ".##.", ".##."], color: Ink.green, scale: 2.5)
    }
  }
}

struct Check: View {
  var body: some View {
    Pixel(grid: [".....#", "....#.", "#..#..", ".#....", "......"], color: Ink.green, scale: 2)
  }
}

// MARK: - Notch shape

/// Square at the top edge (it must merge with the housing), rounded below.
struct NotchShape: InsettableShape {
  let radius: CGFloat
  var inset: CGFloat = 0

  func inset(by amount: CGFloat) -> NotchShape {
    NotchShape(radius: max(0, radius - amount), inset: inset + amount)
  }

  func path(in rect: CGRect) -> Path {
    let box = rect.insetBy(dx: inset, dy: inset)
    let r = min(radius, box.height / 2, box.width / 2)
    var path = Path()
    path.move(to: CGPoint(x: box.minX, y: box.minY))
    path.addLine(to: CGPoint(x: box.maxX, y: box.minY))
    path.addLine(to: CGPoint(x: box.maxX, y: box.maxY - r))
    path.addQuadCurve(
      to: CGPoint(x: box.maxX - r, y: box.maxY),
      control: CGPoint(x: box.maxX, y: box.maxY)
    )
    path.addLine(to: CGPoint(x: box.minX + r, y: box.maxY))
    path.addQuadCurve(
      to: CGPoint(x: box.minX, y: box.maxY - r),
      control: CGPoint(x: box.minX, y: box.maxY)
    )
    path.closeSubpath()
    return path
  }
}

// MARK: - The island

/// The notch band. On a notched display content lives in the two wings, so the
/// camera housing stays visually untouched in the middle.
struct Band: View {
  @ObservedObject var store: Store
  let compact: Bool

  private var geometry: Geometry { store.geometry }

  var body: some View {
    HStack(spacing: 7) { left; Spacer(minLength: 0); right }
      .padding(.horizontal, geometry.hasNotch ? 14 : 10)
      .frame(width: store.size.width, height: geometry.bandHeight)
  }

  @ViewBuilder private var left: some View {
    if store.showDone, let done = store.payload.done, !geometry.hasNotch {
      Check()
      Text(done.title)
        .font(.system(size: 11.5, design: .monospaced))
        .foregroundColor(Ink.ink)
        .lineLimit(1)
    } else if geometry.hasNotch {
      Pet(blinking: store.blink, sleeping: !store.hasRows || store.showDone)
    } else {
      Pet(blinking: store.blink, sleeping: !store.hasRows)
      Text(store.payload.headline)
        .font(.system(size: 11.5, design: .monospaced))
        .foregroundColor(Ink.ink)
        .lineLimit(1)
    }
  }

  @ViewBuilder private var right: some View {
    if geometry.hasNotch {
      if store.hasRows && !store.showDone {
        Text("\(store.payload.rows.count)")
          .font(.system(size: 11, design: .monospaced))
          .foregroundColor(Ink.dim)
      }
    } else if !store.showDone && !store.payload.headAction.isEmpty {
      Text(store.payload.headAction)
        .font(.system(size: 10.5, design: .monospaced))
        .foregroundColor(Ink.dim)
        .lineLimit(1)
        .frame(maxWidth: 52, alignment: .trailing)
    }
  }
}

struct Head: View {
  @ObservedObject var store: Store

  var body: some View {
    HStack(spacing: 7) { content }
      .padding(.horizontal, 14)
      .frame(width: store.size.width, height: headHeight)
  }

  @ViewBuilder private var content: some View {
    if let done = store.payload.done {
      Check()
      Text(done.title)
        .font(.system(size: 11.5, design: .monospaced))
        .foregroundColor(Ink.ink)
        .lineLimit(1)
    } else {
      Text(store.payload.headline)
        .font(.system(size: 11.5, design: .monospaced))
        .foregroundColor(Ink.ink)
        .lineLimit(1)
      Spacer(minLength: 4)
      if !store.payload.headAction.isEmpty {
        Text(store.payload.headAction)
          .font(.system(size: 10.5, design: .monospaced))
          .foregroundColor(Ink.dim)
          .lineLimit(1)
          .frame(maxWidth: 62, alignment: .trailing)
      }
    }
  }
}

struct DoneLine: View {
  @ObservedObject var store: Store
  let summary: String

  var body: some View {
    Text("└── " + summary)
      .font(.system(size: 10.5, design: .monospaced))
      .foregroundColor(Ink.dim)
      .lineLimit(1)
      .truncationMode(.tail)
      .frame(maxWidth: .infinity, alignment: .leading)
      .padding(.horizontal, 14)
      .frame(height: 22, alignment: .center)
  }
}

struct RowView: View {
  let row: Row
  let now: Date

  private func elapsed() -> String {
    guard row.startedAt > 0 else { return "" }
    let seconds = max(0, Int(now.timeIntervalSince(Date(timeIntervalSince1970: row.startedAt / 1000))))
    let minutes = seconds / 60
    let hours = minutes / 60
    if hours > 0 { return "\(hours)h " + String(format: "%02dm", minutes % 60) }
    if minutes > 0 { return "\(minutes)m " + String(format: "%02ds", seconds % 60) }
    return "\(seconds)s"
  }

  private func actionLine() -> Text {
    Text("└── ").foregroundColor(Ink.faint)
      + Text(row.tag).foregroundColor(Ink.faint)
      + Text(" · ").foregroundColor(Ink.faint)
      + Text(row.action).foregroundColor(Ink.dim)
  }

  var body: some View {
    Button(action: { activateDSH() }) {
      HStack(alignment: .top, spacing: 9) {
        Mark(kind: row.kind).padding(.top, 3)
        VStack(alignment: .leading, spacing: 2) {
          HStack(spacing: 8) {
            Text(row.title)
              .font(.system(size: 12, design: .monospaced))
              .foregroundColor(Ink.ink)
              .lineLimit(1)
              .truncationMode(.tail)
            Spacer(minLength: 4)
            Text(elapsed())
              .font(.system(size: 10.5, design: .monospaced))
              .foregroundColor(Ink.dim)
              .lineLimit(1)
          }
          actionLine()
        }
      }
      .padding(.horizontal, 10)
      .padding(.vertical, 5)
      .frame(maxWidth: .infinity, alignment: .leading)
      .contentShape(Rectangle())
    }
    .buttonStyle(.plain)
  }
}

struct Rows: View {
  @ObservedObject var store: Store

  var body: some View {
    TimelineView(.periodic(from: .now, by: 1)) { context in
      VStack(spacing: 1) {
        ForEach(store.visibleRows) { row in
          RowView(row: row, now: context.date)
        }
      }
      .padding(.horizontal, 4)
      .padding(.top, 2)
    }
  }
}

struct Foot: View {
  @ObservedObject var store: Store

  var body: some View {
    HStack {
      Spacer()
      Button(action: { activateDSH() }) {
        Text(store.payload.footer + " ›")
          .font(.system(size: 10.5, design: .monospaced))
          .foregroundColor(Ink.dim)
          .padding(.horizontal, 6)
          .padding(.vertical, 3)
      }
      .buttonStyle(.plain)
    }
    .padding(.horizontal, 8)
    .frame(height: footHeight)
  }
}

struct Island: View {
  @ObservedObject var store: Store
  @Environment(\.accessibilityReduceMotion) private var reduceMotion

  private var compact: Bool { !store.showsBody }
  private var cornerRadius: CGFloat { store.geometry.hasNotch ? (compact ? 14 : 22) : 16 }
  private var outlineWidth: CGFloat { compact ? 0 : 1 }

  var body: some View {
    let shape = NotchShape(radius: cornerRadius)
    let fill: Color = store.geometry.hasNotch ? Ink.panel : Ink.card
    return stack
      .frame(width: store.size.width, height: store.size.height, alignment: .top)
      .background(shape.fill(fill))
      .overlay(shape.strokeBorder(Ink.hairline, lineWidth: outlineWidth))
      .shadow(color: .black.opacity(compact ? 0 : 0.45), radius: compact ? 0 : 14, x: 0, y: 6)
      .contentShape(Rectangle())
      .onTapGesture { toggle() }
      .animation(reduceMotion ? nil : .easeOut(duration: 0.18), value: store.expanded)
  }

  @ViewBuilder private var stack: some View {
    VStack(spacing: 0) {
      Band(store: store, compact: compact)
      if let done = store.payload.done {
        Head(store: store)
        if !done.current && !done.summary.isEmpty {
          DoneLine(store: store, summary: done.summary)
        }
      } else if store.expanded {
        Head(store: store)
        Rows(store: store)
        Foot(store: store)
      }
    }
  }

  private func toggle() {
    store.pinned.toggle()
    store.expanded = store.pinned
  }
}

// MARK: - Preferences

/// User-editable settings, persisted in UserDefaults. The bundle patch only
/// seeds the first run; afterwards the settings window owns them, so a change
/// applies immediately without a DSH restart.
final class Preferences: ObservableObject {
  static let shared = Preferences()

  private enum Key {
    static let system = "perch.notify.system"
    static let voice = "perch.notify.voice"
    static let zh = "perch.text.zh"
    static let en = "perch.text.en"
    static let voiceZh = "perch.voice.zh"
    static let voiceEn = "perch.voice.en"
    static let rate = "perch.voice.rate"
    static let customized = "perch.customized"
  }

  private let defaults = UserDefaults.standard
  private(set) var customized: Bool

  @Published var system: Bool { didSet { save() } }
  @Published var voice: Bool { didSet { save() } }
  @Published var zh: String { didSet { save() } }
  @Published var en: String { didSet { save() } }
  /// Voice identifiers; empty means the system default for that language.
  @Published var voiceZh: String { didSet { save() } }
  @Published var voiceEn: String { didSet { save() } }
  /// 0.3 – 0.7, `AVSpeechUtteranceDefaultSpeechRate` is 0.5.
  @Published var rate: Double { didSet { save() } }

  private init() {
    customized = defaults.bool(forKey: Key.customized)
    system = defaults.object(forKey: Key.system) as? Bool ?? true
    voice = defaults.object(forKey: Key.voice) as? Bool ?? true
    zh = defaults.string(forKey: Key.zh) ?? "任务完成"
    en = defaults.string(forKey: Key.en) ?? "Task complete"
    voiceZh = defaults.string(forKey: Key.voiceZh) ?? ""
    voiceEn = defaults.string(forKey: Key.voiceEn) ?? ""
    rate = defaults.object(forKey: Key.rate) as? Double ?? 0.5

    // A voice can disappear (removed in System Settings, or a reserved one that
    // never spoke); fall back to the system default instead of leaving the
    // picker blank. Assignments here do not fire `didSet`, so this is not a
    // user customization.
    if !voiceZh.isEmpty, !VoiceCatalog.options(prefix: "zh").contains(where: { $0.id == voiceZh }) {
      voiceZh = ""
    }
    if !voiceEn.isEmpty, !VoiceCatalog.options(prefix: "en").contains(where: { $0.id == voiceEn }) {
      voiceEn = ""
    }
  }

  /// The patch's config seeds the very first run only.
  func seed(_ settings: Settings) {
    guard !customized else { return }
    system = settings.notify.system
    voice = settings.notify.voice
    zh = settings.text.zh
    en = settings.text.en
  }

  func text(forLocale locale: String?) -> String {
    isChinese(locale) ? zh : en
  }

  func voiceIdentifier(forLocale locale: String?) -> String {
    isChinese(locale) ? voiceZh : voiceEn
  }

  func isChinese(_ locale: String?) -> Bool {
    (locale ?? "en").lowercased().hasPrefix("zh")
  }

  func reset() {
    defaults.removeObject(forKey: Key.customized)
    customized = false
    system = true
    voice = true
    zh = "任务完成"
    en = "Task complete"
    voiceZh = ""
    voiceEn = ""
    rate = 0.5
  }

  var settings: Settings {
    Settings(notify: NotifySettings(system: system, voice: voice), text: LocalizedText(zh: zh, en: en))
  }

  func json() -> Data {
    (try? JSONEncoder().encode(settings)) ?? Data("{}".utf8)
  }

  /// Property observers do not run during `init`, so the first assignment never
  /// marks a seeded value as a customization.
  private func save() {
    customized = true
    defaults.set(true, forKey: Key.customized)
    defaults.set(system, forKey: Key.system)
    defaults.set(voice, forKey: Key.voice)
    defaults.set(zh, forKey: Key.zh)
    defaults.set(en, forKey: Key.en)
    defaults.set(voiceZh, forKey: Key.voiceZh)
    defaults.set(voiceEn, forKey: Key.voiceEn)
    defaults.set(rate, forKey: Key.rate)
  }
}

// MARK: - Voice


/// Spoken reminder for a finished task. The banner is deliberately NOT posted
/// here: macOS refuses notifications from an ad-hoc signed helper ("not
/// allowed for this application"), so the DSH page posts the banner through
/// its own signed app instead. This class only speaks.
final class Notifier: NSObject {
  private let synthesizer = AVSpeechSynthesizer()

  /// Called when the bundle patch's config arrives; seeds the first run only.
  func apply(_ next: Settings) {
    Preferences.shared.seed(next)
    Notifier.log("settings seeded system=\(next.notify.system) voice=\(next.notify.voice) zh=\(next.text.zh) en=\(next.text.en)")
  }

  /// Current settings, served to the page over `GET /settings` so both halves
  /// share one source of truth for the custom text.
  func json() -> Data {
    Preferences.shared.json()
  }

  /// Speak one line in the locale's own voice; used for the reminder and for
  /// the settings window's preview button.
  func say(_ text: String, locale: String?) {
    speak(text, locale: locale)
  }

  /// Called once per completion; the flashed (current-session) case is silent.
  func announce(_ done: Done, locale: String?) {
    let prefs = Preferences.shared
    guard !done.current, prefs.voice else { return }
    speak(prefs.text(forLocale: locale), locale: locale)
  }

  private func speak(_ text: String, locale: String?) {
    let prefs = Preferences.shared
    let code = prefs.isChinese(locale) ? "zh-CN" : "en-US"
    let identifier = prefs.voiceIdentifier(forLocale: locale)
    let voice = identifier.isEmpty
      ? AVSpeechSynthesisVoice(language: code)
      : AVSpeechSynthesisVoice(identifier: identifier) ?? AVSpeechSynthesisVoice(language: code)
    let utterance = AVSpeechUtterance(string: text)
    utterance.voice = voice ?? AVSpeechSynthesisVoice(language: code)
    utterance.rate = Float(prefs.rate)
    synthesizer.speak(utterance)
    Notifier.log("speech: \(text) voice=\(voice?.name ?? code) [\(voice?.language ?? code)] rate=\(prefs.rate)")
  }

  /// `open` discards stderr, so the same line also lands in
  /// ~/Library/Logs/PerchOverlay.log (trimmed at 256 KiB).
  static func log(_ line: String) {
    let stamped = "\(ISO8601DateFormatter().string(from: Date())) \(line)\n"
    FileHandle.standardError.write(stamped.data(using: .utf8) ?? Data())
    let url = FileManager.default
      .homeDirectoryForCurrentUser
      .appendingPathComponent("Library/Logs/PerchOverlay.log")
    let data = Data(stamped.utf8)
    if let handle = try? FileHandle(forWritingTo: url) {
      handle.seekToEndOfFile()
      handle.write(data)
      let size = handle.offsetInFile
      try? handle.close()
      if size > 256 * 1024 { try? FileManager.default.removeItem(at: url) }
    } else {
      try? data.write(to: url)
    }
  }
}

// MARK: - Local HTTP receiver
// MARK: - Local HTTP receiver


final class Server {
  private var listener: NWListener?
  private let onPayload: (Payload) -> Void
  private let onSettings: (Settings) -> Void
  private let settingsJSON: () -> Data
  private var connections: [ObjectIdentifier: Accumulator] = [:]

  final class Accumulator {
    var data = Data()
  }

  init(
    onPayload: @escaping (Payload) -> Void,
    onSettings: @escaping (Settings) -> Void,
    settingsJSON: @escaping () -> Data
  ) {
    self.onPayload = onPayload
    self.onSettings = onSettings
    self.settingsJSON = settingsJSON
  }

  func start() {
    do {
      let listener = try NWListener(using: .tcp, on: NWEndpoint.Port(rawValue: listenPort)!)
      listener.newConnectionHandler = { [weak self] connection in
        self?.accept(connection)
      }
      listener.start(queue: .main)
      self.listener = listener
    } catch {
      FileHandle.standardError.write("perch-overlay: cannot listen: \(error)\n".data(using: .utf8) ?? Data())
    }
  }

  private func accept(_ connection: NWConnection) {
    guard isLoopback(connection.endpoint) else {
      connection.cancel()
      return
    }
    let key = ObjectIdentifier(connection)
    let accumulator = Accumulator()
    connections[key] = accumulator
    connection.stateUpdateHandler = { [weak self] state in
      switch state {
      case .failed, .cancelled: self?.connections.removeValue(forKey: key)
      default: break
      }
    }
    connection.start(queue: .main)
    read(connection, accumulator)
  }

  private func isLoopback(_ endpoint: NWEndpoint) -> Bool {
    guard case let .hostPort(host, _) = endpoint else { return false }
    switch host {
    case .ipv4(let address): return address == .loopback
    case .ipv6(let address): return address.isLoopback
    default: return false
    }
  }

  private func read(_ connection: NWConnection, _ accumulator: Accumulator) {
    connection.receive(minimumIncompleteLength: 1, maximumLength: 1 << 20) { [weak self] chunk, _, done, error in
      guard let self else { return }
      if let chunk { accumulator.data.append(chunk) }
      if self.handle(connection, accumulator) { return }
      if done || error != nil {
        connection.cancel()
        return
      }
      self.read(connection, accumulator)
    }
  }

  private func handle(_ connection: NWConnection, _ accumulator: Accumulator) -> Bool {
    let data = accumulator.data
    guard let headerEnd = data.range(of: Data("\r\n\r\n".utf8)) else { return false }
    let headerText = String(decoding: data[..<headerEnd.lowerBound], as: UTF8.self)
    let requestLine = headerText.split(separator: "\r\n").first.map(String.init) ?? ""
    let isOptions = requestLine.hasPrefix("OPTIONS ")
    let isSettingsRead = requestLine.hasPrefix("GET /settings")
    var contentLength = 0
    for line in headerText.split(separator: "\r\n") {
      let parts = line.split(separator: ":", maxSplits: 1)
      guard parts.count == 2, parts[0].lowercased() == "content-length" else { continue }
      contentLength = Int(parts[1].trimmingCharacters(in: .whitespaces)) ?? 0
    }
    let bodyStart = headerEnd.upperBound
    if !isOptions && data.distance(from: bodyStart, to: data.endIndex) < contentLength { return false }

    if isSettingsRead {
      respond(connection, status: "200 OK", type: "application/json", body: settingsJSON())
      return true
    }
    if !isOptions {
      let body = data.subdata(in: bodyStart..<data.endIndex)
      let envelope = try? JSONDecoder().decode(Envelope.self, from: body)
      if envelope?.kind == "settings" {
        if let settings = try? JSONDecoder().decode(Settings.self, from: body) {
          onSettings(settings)
        }
      } else if let payload = try? JSONDecoder().decode(Payload.self, from: body) {
        onPayload(payload)
      }
    }
    respond(connection)
    return true
  }

  private func respond(_ connection: NWConnection, status: String = "204 No Content", type: String? = nil, body: Data = Data()) {
    var head = "HTTP/1.1 \(status)\r\n"
      + "Access-Control-Allow-Origin: *\r\n"
      + "Access-Control-Allow-Methods: POST, GET, OPTIONS\r\n"
      + "Access-Control-Allow-Headers: content-type\r\n"
      + "Content-Length: \(body.count)\r\n"
      + "Connection: close\r\n"
    if let type { head += "Content-Type: \(type)\r\n" }
    head += "\r\n"
    var payload = Data(head.utf8)
    payload.append(body)
    connection.send(content: payload, completion: .contentProcessed { _ in
      connection.cancel()
    })
  }
}

// MARK: - Panel

final class IslandPanel: NSPanel {
  override var canBecomeKey: Bool { false }
  override var canBecomeMain: Bool { false }
}

// MARK: - Hover

/// `.activeAlways` tracking: a non-activating panel never becomes key, so
/// SwiftUI's `onHover` (which needs the key window) would never fire.
final class HoverCatcher: NSView {
  var onHover: ((Bool) -> Void)?
  private var area: NSTrackingArea?

  override func hitTest(_ point: NSPoint) -> NSView? { nil }

  override func updateTrackingAreas() {
    super.updateTrackingAreas()
    if let area { removeTrackingArea(area) }
    let next = NSTrackingArea(
      rect: bounds,
      options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect],
      owner: self,
      userInfo: nil
    )
    addTrackingArea(next)
    area = next
  }

  override func mouseEntered(with event: NSEvent) { onHover?(true) }
  override func mouseExited(with event: NSEvent) { onHover?(false) }
}

// MARK: - Settings window

/// One entry of the system voice list, flattened for the picker.
struct VoiceOption: Identifiable, Hashable {
  let id: String
  let title: String
}

enum VoiceCatalog {
  static func options(prefix: String) -> [VoiceOption] {
    AVSpeechSynthesisVoice.speechVoices()
      .filter { $0.language.lowercased().hasPrefix(prefix) }
      // Siri's natural voices are reserved for Siri: an utterance built from
      // one silently falls back to the default voice, so offering them would
      // only produce "I picked it and nothing changed".
      .filter { !$0.identifier.hasPrefix("com.apple.siri.") }
      .sorted { ($0.language, $0.name) < ($1.language, $1.name) }
      .map { voice in
        let quality: String
        switch voice.quality {
        case .premium: quality = "高级"
        case .enhanced: quality = "增强"
        default: quality = "默认"
        }
        return VoiceOption(
          id: voice.identifier,
          title: "\(voice.name) · \(voice.language) · \(quality)"
        )
      }
  }
}

/// The visual half of the configuration: what the patch can seed, a person can
/// edit here. Every control writes straight into `Preferences`, so the next
/// completion already uses the new wording and voice.
struct SettingsView: View {
  @ObservedObject var prefs = Preferences.shared
  let preview: (String, String) -> Void

  var body: some View {
    VStack(alignment: .leading, spacing: 12) {
      section("任务完成时")
      Toggle("系统通知横幅（由 DeepSeek Harness 发出）", isOn: $prefs.system)
      Toggle("语音播报", isOn: $prefs.voice)

      Divider()
      section("声音")
      pickerRow(label: "中文音色", selection: $prefs.voiceZh, prefix: "zh")
      pickerRow(label: "英文音色", selection: $prefs.voiceEn, prefix: "en")
      HStack(spacing: 8) {
        Text("语速")
          .font(.system(size: 12))
          .frame(width: 56, alignment: .leading)
        Slider(value: $prefs.rate, in: 0.3...0.7)
        Text(String(format: "%.2f", prefs.rate))
          .font(.system(size: 11, design: .monospaced))
          .foregroundColor(.secondary)
          .frame(width: 32, alignment: .trailing)
      }
      HStack(spacing: 8) {
        Button("安装更多音色…") { openAccessibilitySettings() }
          .controlSize(.small)
        Spacer()
      }

      Divider()
      section("提醒文字")
      textRow(label: "中文", text: $prefs.zh, locale: "zh")
      textRow(label: "英文", text: $prefs.en, locale: "en")

      Text("横幅需要 macOS 允许 DeepSeek Harness 发通知（系统设置 → 通知）。按 DSH 当前界面语言选用上面某一行文字与对应音色；音色为空即用系统默认嗓音。\n标「增强 / 高级」的是下载版音色，更好听；Siri 音色只给 Siri 用，未列出。")
        .font(.system(size: 10.5))
        .foregroundColor(.secondary)
        .fixedSize(horizontal: false, vertical: true)

      HStack {
        Button("恢复默认") { prefs.reset() }
        Spacer()
      }
    }
    .padding(18)
    .frame(width: 480)
  }

  private func section(_ title: String) -> some View {
    Text(title)
      .font(.system(size: 11, weight: .semibold))
      .foregroundColor(.secondary)
  }

  private func pickerRow(label: String, selection: Binding<String>, prefix: String) -> some View {
    HStack(spacing: 8) {
      Text(label)
        .font(.system(size: 12))
        .frame(width: 56, alignment: .leading)
      Picker("", selection: selection) {
        Text("系统默认").tag("")
        ForEach(VoiceCatalog.options(prefix: prefix)) { option in
          Text(option.title).tag(option.id)
        }
      }
      .labelsHidden()
      Button("试听") { preview(prefs.text(forLocale: prefix), prefix) }
        .controlSize(.small)
    }
  }

  private func textRow(label: String, text: Binding<String>, locale: String) -> some View {
    HStack(spacing: 8) {
      Text(label)
        .font(.system(size: 12))
        .frame(width: 56, alignment: .leading)
      TextField("", text: text)
        .textFieldStyle(.roundedBorder)
        .font(.system(size: 12))
      Button("试听") { preview(text.wrappedValue, locale) }
        .controlSize(.small)
    }
  }

  /// Extra voices are installed in System Settings, not by us.
  private func openAccessibilitySettings() {
    if let url = URL(string: "x-apple.systempreferences:com.apple.preference.universalaccess") {
      NSWorkspace.shared.open(url)
    }
  }
}

final class SettingsWindowController {
  private var window: NSWindow?

  func show(preview: @escaping (String, String) -> Void) {
    if let window {
      NSApp.activate(ignoringOtherApps: true)
      window.makeKeyAndOrderFront(nil)
      return
    }
    let window = NSWindow(
      contentRect: NSRect(x: 0, y: 0, width: 460, height: 320),
      styleMask: [.titled, .closable],
      backing: .buffered,
      defer: false
    )
    window.title = "栖岛 · 设置"
    window.isReleasedWhenClosed = false
    let host = NSHostingView(rootView: SettingsView(preview: preview))
    window.contentView = host
    host.layoutSubtreeIfNeeded()
    let fitting = host.fittingSize
    window.setContentSize(NSSize(width: max(480, fitting.width), height: fitting.height))
    window.center()
    self.window = window
    NSApp.activate(ignoringOtherApps: true)
    window.makeKeyAndOrderFront(nil)
  }
}

// MARK: - App


final class AppDelegate: NSObject, NSApplicationDelegate {
  let store = Store()
  private var panel: IslandPanel?
  private var server: Server?
  private var lastPayloadAt = Date()
  private var doneTimer: DispatchWorkItem?
  private var lastDoneSeq = -1
  private var blinkOn = false
  private var hoverToken = 0
  private var hotKey: EventHotKeyRef?
  private var menu: NSMenu?
  private let notifier = Notifier()
  private let settingsWindow = SettingsWindowController()

  func applicationDidFinishLaunching(_ notification: Notification) {
    NSApp.setActivationPolicy(.accessory)
    buildPanel()
    buildMenu()
    store.geometry = geometry(for: targetScreen())
    store.onChange = { [weak self] in self?.sync() }
    server = Server(
      onPayload: { [weak self] payload in self?.consume(payload) },
      onSettings: { [weak self] settings in self?.notifier.apply(settings) },
      settingsJSON: { [weak self] in self?.notifier.json() ?? Data("{}".utf8) }
    )
    server?.start()
    installHotKey()
    installRightClick()
    Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in self?.tick() }
    Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in self?.blink() }
    Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in self?.reconcileHover() }
    NotificationCenter.default.addObserver(
      forName: NSApplication.didChangeScreenParametersNotification,
      object: nil,
      queue: .main
    ) { [weak self] _ in self?.rescreen() }
    sync()
  }

  private func buildPanel() {
    let panel = IslandPanel(
      contentRect: NSRect(x: 0, y: 0, width: barWidth, height: barHeight),
      styleMask: [.borderless, .nonactivatingPanel],
      backing: .buffered,
      defer: false
    )
    panel.isOpaque = false
    panel.backgroundColor = .clear
    panel.hasShadow = false
    panel.level = .statusBar
    panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
    panel.hidesOnDeactivate = false
    panel.isMovableByWindowBackground = false
    panel.acceptsMouseMovedEvents = true
    panel.isReleasedWhenClosed = false
    let host = NSHostingView(rootView: Island(store: store))
    host.autoresizingMask = [.width, .height]
    let catcher = HoverCatcher(frame: host.bounds)
    catcher.autoresizingMask = [.width, .height]
    catcher.onHover = { [weak self] inside in self?.handleHover(inside) }
    host.addSubview(catcher)
    panel.contentView = host
    self.panel = panel
  }

  private func buildMenu() {
    let menu = NSMenu()
    menu.addItem(withTitle: "打开 DeepSeek Harness", action: #selector(menuOpenDSH), keyEquivalent: "")
      .target = self
    menu.addItem(withTitle: "展开 / 收起", action: #selector(menuToggle), keyEquivalent: "")
      .target = self
    menu.addItem(withTitle: "设置…", action: #selector(menuSettings), keyEquivalent: "")
      .target = self
    menu.addItem(.separator())
    menu.addItem(withTitle: "退出 Perch", action: #selector(menuQuit), keyEquivalent: "")
      .target = self
    self.menu = menu
  }

  @objc private func menuOpenDSH() { activateDSH() }

  @objc private func menuToggle() {
    store.pinned.toggle()
    store.expanded = store.pinned
  }

  @objc private func menuSettings() {
    settingsWindow.show { [weak self] text, locale in
      self?.notifier.say(text, locale: locale)
    }
  }

  @objc private func menuQuit() { NSApp.terminate(nil) }

  private func installRightClick() {
    NSEvent.addLocalMonitorForEvents(matching: [.rightMouseDown]) { [weak self] event in
      guard let self, let panel = self.panel, event.window == panel, let menu = self.menu else { return event }
      NSMenu.popUpContextMenu(menu, with: event, for: panel.contentView!)
      return nil
    }
  }

  /// ⌥⌘P toggles the card from anywhere; no accessibility permission needed.
  private func installHotKey() {
    var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
    InstallEventHandler(
      GetApplicationEventTarget(),
      { _, _, context in
        guard let context else { return noErr }
        Unmanaged<AppDelegate>.fromOpaque(context).takeUnretainedValue().hotKeyPressed()
        return noErr
      },
      1,
      &spec,
      Unmanaged.passUnretained(self).toOpaque(),
      nil
    )
    let hotKeyID = EventHotKeyID(signature: OSType(0x5045_5243), id: 1)
    let status = RegisterEventHotKey(
      UInt32(kVK_ANSI_P),
      UInt32(cmdKey | optionKey),
      hotKeyID,
      GetApplicationEventTarget(),
      0,
      &hotKey
    )
    if status != noErr {
      FileHandle.standardError.write("perch: hotkey registration failed (\(status))\n".data(using: .utf8) ?? Data())
    }
  }

  private func hotKeyPressed() {
    store.pinned.toggle()
    store.expanded = store.pinned
  }

  private func consume(_ payload: Payload) {
    lastPayloadAt = Date()
    Notifier.log("state rows=\(payload.rows.count) done=\(payload.done?.seq ?? 0) clear=\(payload.clear == true) locale=\(payload.locale ?? "-")")
    store.apply(payload)
    if let done = payload.done, done.seq != lastDoneSeq {
      lastDoneSeq = done.seq
      notifier.announce(done, locale: payload.locale)
      doneTimer?.cancel()
      let work = DispatchWorkItem { [weak self] in
        guard let self, let current = self.store.payload.done, current.seq == done.seq else { return }
        self.store.payload = Payload(headline: "", headAction: "", footer: "", rows: [], done: nil, clear: nil, locale: nil)
        self.sync()
      }
      doneTimer = work
      DispatchQueue.main.asyncAfter(deadline: .now() + (done.current ? 0.8 : 2.5), execute: work)
    }
    sync()
  }

  /// Safety net: a missed `mouseExited` (window resize, fast pointer) must never
  /// leave the card stuck open.
  private func reconcileHover() {
    guard store.expanded, !store.pinned, let panel, panel.isVisible else { return }
    if !panel.frame.contains(NSEvent.mouseLocation) {
      store.expanded = false
    }
  }

  private func blink() {
    blinkOn.toggle()
    store.blink = blinkOn
  }

  /// Hide only when the page stops talking (reload, plugin disabled, DSH quit).
  private func tick() {
    if store.isVisible, Date().timeIntervalSince(lastPayloadAt) > 20 {
      store.payload = Payload(headline: "", headAction: "", footer: "", rows: [], done: nil, clear: true, locale: nil)
      sync()
    }
  }

  private func rescreen() {
    store.geometry = geometry(for: targetScreen())
    sync()
  }

  private func sync() {
    guard let panel else { return }
    let size = store.size
    let screen = targetScreen()
    let top = screen.frame.maxY
    let frame = NSRect(
      x: screen.frame.midX - size.width / 2,
      y: top - size.height,
      width: size.width,
      height: size.height
    )
    if store.isVisible {
      panel.setFrame(frame, display: true)
      panel.orderFrontRegardless()
    } else {
      panel.orderOut(nil)
    }
  }

  /// The notch: the gap between the two drawable auxiliary areas at the top.
  private func geometry(for screen: NSScreen) -> Geometry {
    var geometry = Geometry()
    geometry.topInset = screen.safeAreaInsets.top > 0
      ? screen.safeAreaInsets.top
      : max(0, screen.frame.maxY - screen.visibleFrame.maxY)
    if let left = screen.auxiliaryTopLeftArea, let right = screen.auxiliaryTopRightArea {
      let width = right.minX - left.maxX
      if width > 40 { geometry.notchWidth = width }
    }
    return geometry
  }

  private func targetScreen() -> NSScreen {
    if let notched = NSScreen.screens.first(where: { $0.auxiliaryTopLeftArea != nil }) { return notched }
    return NSScreen.main ?? NSScreen.screens[0]
  }

  private func handleHover(_ inside: Bool) {
    guard store.payload.done == nil else { return }
    hoverToken += 1
    let token = hoverToken
    if inside {
      if store.expanded { return }
      DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak self] in
        guard let self, self.hoverToken == token, self.store.payload.done == nil else { return }
        self.store.expanded = true
      }
    } else if !store.pinned {
      store.expanded = false
    }
  }
}

let application = NSApplication.shared
let delegate = AppDelegate()
application.delegate = delegate
application.run()
