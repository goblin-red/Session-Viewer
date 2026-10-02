import Cocoa
import SQLite3

// Имя приложения — в стиле сайта goblin.red
private let appName = "GOBL(in) Session Viewer"

// MARK: - Язык интерфейса

enum Lang: String { case en, ru }

/// Язык окна: по умолчанию английский, выбор хранится в настройках приложения.
var currentLang = Lang(rawValue: UserDefaults.standard.string(forKey: "language") ?? "") ?? .en

func tr(_ en: String, _ ru: String) -> String { currentLang == .ru ? ru : en }

let SQLITE_TRANSIENT = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

enum Source { case claude, codex, grok, opencode }

struct SessionItem {
    let kind: Source
    let projectDir: URL
    let cwd: String
    let fileURL: URL
    let cliId: String          // claude: cliSessionId; codex: thread/rollout id
    let title: String
    let createdAt: Int64       // ms
    let lastActivityAt: Int64  // ms
    let model: String
    let sizeBytes: Int64       // размер файла сессии
    // codex-only
    let modelProvider: String
    let sandboxPolicy: String
    let approvalMode: String
    let reasoningEffort: String
    var imported: Bool
    var checked: Bool = false
    var isService = false      // codex: автозапуск (exec) или субагент, а не живой чат
    var origin = "—"           // откуда сессия: Терминал, Десктоп, SDK…

    init(kind: Source, projectDir: URL, cwd: String, fileURL: URL, cliId: String,
         title: String, createdAt: Int64, lastActivityAt: Int64, model: String, sizeBytes: Int64,
         modelProvider: String = "openai", sandboxPolicy: String = "",
         approvalMode: String = "on-request", reasoningEffort: String = "medium",
         imported: Bool) {
        self.kind = kind; self.projectDir = projectDir; self.cwd = cwd; self.fileURL = fileURL
        self.cliId = cliId; self.title = title; self.createdAt = createdAt
        self.lastActivityAt = lastActivityAt; self.model = model; self.sizeBytes = sizeBytes
        self.modelProvider = modelProvider; self.sandboxPolicy = sandboxPolicy
        self.approvalMode = approvalMode; self.reasoningEffort = reasoningEffort
        self.imported = imported
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate, NSTableViewDataSource, NSTableViewDelegate {
    private var window: NSWindow!
    private let sourcePopup = NSPopUpButton()
    private let projectPopup = NSPopUpButton()
    private let tableView = NSTableView()
    private let statusLabel = NSTextField(labelWithString: "")
    private let importButton = NSButton(title: "", target: nil, action: nil)
    private let selectAllButton = NSButton(checkboxWithTitle: "", target: nil, action: nil)
    private let refreshButton = NSButton(title: "", target: nil, action: nil)
    private let moreButton = NSButton(title: "", target: nil, action: nil)
    private let serviceCheckbox = NSButton(checkboxWithTitle: "", target: nil, action: nil)
    private let sourceLabel = NSTextField(labelWithString: "")
    private let projectLabel = NSTextField(labelWithString: "")
    private let languageControl = NSSegmentedControl(labels: ["EN", "RU"], trackingMode: .selectOne, target: nil, action: nil)
    private var hiddenService = 0

    private let pageSize = 50
    private var visibleCount = 50

    private var source: Source = .claude
    private var home: URL { FileManager.default.homeDirectoryForCurrentUser }
    private var projectsRoot: URL {
        source == .claude
            ? home.appendingPathComponent(".claude/projects")
            : home.appendingPathComponent(".codex/sessions")
    }
    private var codexDB: URL { home.appendingPathComponent(".codex/state_5.sqlite") }
    private var allSessions: [String: [SessionItem]] = [:]  // cwd -> sessions
    private var projectKeys: [String] = []
    private var rows: [SessionItem] = []
    private var importedIds: Set<String> = []
    private var storeDir: URL?

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
        buildMenu()
        buildWindow()
        reload()
        NSApp.activate(ignoringOtherApps: true)
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }

    private func buildMenu() {
        let menuBar = NSMenu()
        let appMenuItem = NSMenuItem()
        menuBar.addItem(appMenuItem)
        NSApp.mainMenu = menuBar
        let appMenu = NSMenu()
        appMenu.addItem(NSMenuItem(title: tr("Quit \(appName)", "Выйти из \(appName)"), action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))
        appMenuItem.submenu = appMenu
    }

    private func buildWindow() {
        window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1060, height: 600),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered, defer: false)
        window.title = appName
        window.minSize = NSSize(width: 760, height: 420)
        window.center()

        let root = NSStackView()
        root.orientation = .vertical
        root.spacing = 10
        root.edgeInsets = NSEdgeInsets(top: 14, left: 14, bottom: 14, right: 14)
        root.translatesAutoresizingMaskIntoConstraints = false

        let topRow = NSStackView()
        topRow.orientation = .horizontal
        topRow.spacing = 8
        sourcePopup.addItem(withTitle: "Claude")
        sourcePopup.addItem(withTitle: "Codex")
        sourcePopup.addItem(withTitle: "Grok")
        sourcePopup.addItem(withTitle: "OpenCode")
        sourcePopup.selectItem(at: 0)
        sourcePopup.target = self
        sourcePopup.action = #selector(sourceChanged)
        projectPopup.target = self
        projectPopup.action = #selector(projectChanged)
        refreshButton.target = self
        refreshButton.action = #selector(refreshClicked)
        // логотип Goblin; на старых macOS без поддержки SVG — иконка приложения
        let logo = NSImageView()
        let logoURL = Bundle.main.url(forResource: "logo", withExtension: "svg")
        logo.image = logoURL.flatMap { NSImage(contentsOf: $0) } ?? NSApp.applicationIconImage
        logo.imageScaling = .scaleProportionallyUpOrDown
        logo.widthAnchor.constraint(equalToConstant: 34).isActive = true
        logo.heightAnchor.constraint(equalToConstant: 26).isActive = true
        topRow.addArrangedSubview(logo)
        topRow.addArrangedSubview(sourceLabel)
        topRow.addArrangedSubview(sourcePopup)
        topRow.addArrangedSubview(projectLabel)
        topRow.addArrangedSubview(projectPopup)
        topRow.addArrangedSubview(refreshButton)
        serviceCheckbox.target = self
        serviceCheckbox.action = #selector(refreshClicked)
        serviceCheckbox.isHidden = true
        topRow.addArrangedSubview(serviceCheckbox)
        languageControl.target = self
        languageControl.action = #selector(languageChanged)
        topRow.addArrangedSubview(languageControl)
        projectPopup.setContentHuggingPriority(.defaultLow, for: .horizontal)

        let checkCol = NSTableColumn(identifier: .init("check"))
        checkCol.title = ""
        checkCol.width = 24
        let titleCol = NSTableColumn(identifier: .init("title"))
        titleCol.width = 340
        let folderCol = NSTableColumn(identifier: .init("folder"))
        folderCol.width = 220
        let originCol = NSTableColumn(identifier: .init("origin"))
        originCol.width = 84
        let sizeCol = NSTableColumn(identifier: .init("size"))
        sizeCol.width = 80
        let dateCol = NSTableColumn(identifier: .init("date"))
        dateCol.width = 120
        let stateCol = NSTableColumn(identifier: .init("state"))
        stateCol.width = 130
        // сортировка по клику на заголовок столбца
        titleCol.sortDescriptorPrototype = NSSortDescriptor(key: "title", ascending: true)
        folderCol.sortDescriptorPrototype = NSSortDescriptor(key: "folder", ascending: true)
        originCol.sortDescriptorPrototype = NSSortDescriptor(key: "origin", ascending: true)
        sizeCol.sortDescriptorPrototype = NSSortDescriptor(key: "size", ascending: false)
        dateCol.sortDescriptorPrototype = NSSortDescriptor(key: "date", ascending: false)
        stateCol.sortDescriptorPrototype = NSSortDescriptor(key: "state", ascending: false)
        tableView.addTableColumn(checkCol)
        tableView.addTableColumn(titleCol)
        tableView.addTableColumn(folderCol)
        tableView.addTableColumn(originCol)
        tableView.addTableColumn(sizeCol)
        tableView.addTableColumn(dateCol)
        tableView.addTableColumn(stateCol)
        // лишнюю ширину окна забирают «Первое сообщение» и «Папка»
        for col in tableView.tableColumns {
            let flexible = col === titleCol || col === folderCol
            col.resizingMask = flexible ? [.autoresizingMask, .userResizingMask] : .userResizingMask
        }
        tableView.columnAutoresizingStyle = .uniformColumnAutoresizingStyle
        tableView.intercellSpacing = NSSize(width: 8, height: 2)
        tableView.dataSource = self
        tableView.delegate = self
        tableView.target = self
        tableView.action = #selector(tableClicked)
        tableView.rowHeight = 22
        tableView.usesAlternatingRowBackgroundColors = true
        tableView.allowsMultipleSelection = true

        let scroll = NSScrollView()
        scroll.documentView = tableView
        scroll.hasVerticalScroller = true
        scroll.translatesAutoresizingMaskIntoConstraints = false
        scroll.setContentHuggingPriority(.defaultLow, for: .vertical)

        let bottomRow = NSStackView()
        bottomRow.orientation = .horizontal
        bottomRow.spacing = 12
        selectAllButton.target = self
        selectAllButton.action = #selector(selectAllToggled)
        importButton.target = self
        importButton.action = #selector(importClicked)
        importButton.bezelStyle = .rounded
        importButton.keyEquivalent = "\r"
        moreButton.target = self
        moreButton.action = #selector(loadMoreClicked)
        moreButton.bezelStyle = .rounded
        bottomRow.addArrangedSubview(selectAllButton)
        bottomRow.addArrangedSubview(NSView())
        bottomRow.addArrangedSubview(moreButton)
        bottomRow.addArrangedSubview(importButton)

        statusLabel.lineBreakMode = .byTruncatingMiddle
        statusLabel.textColor = .secondaryLabelColor

        root.addArrangedSubview(topRow)
        root.addArrangedSubview(scroll)
        root.addArrangedSubview(bottomRow)
        root.addArrangedSubview(statusLabel)

        window.contentView = root.superview
        window.contentView = NSView()
        window.contentView!.addSubview(root)
        NSLayoutConstraint.activate([
            root.topAnchor.constraint(equalTo: window.contentView!.topAnchor),
            root.bottomAnchor.constraint(equalTo: window.contentView!.bottomAnchor),
            root.leadingAnchor.constraint(equalTo: window.contentView!.leadingAnchor),
            root.trailingAnchor.constraint(equalTo: window.contentView!.trailingAnchor),
            scroll.heightAnchor.constraint(greaterThanOrEqualToConstant: 300),
        ])
        applyLanguage()
        window.makeKeyAndOrderFront(nil)
        // подогнать столбцы под ширину окна, чтобы «Статус» не уезжал за край
        window.layoutIfNeeded()
        tableView.sizeToFit()
    }

    // MARK: - Язык

    /// Подписи, не зависящие от данных; вызывается при запуске и при смене языка.
    private func applyLanguage() {
        importButton.title = tr("Import selected", "Импортировать выбранные")
        selectAllButton.title = tr("Select all", "Выбрать все")
        refreshButton.title = tr("Refresh", "Обновить")
        serviceCheckbox.title = tr("Automated runs", "Служебные запуски")
        serviceCheckbox.toolTip = tr(
            "Show sessions started by scripts and other agents (codex exec, subagents)",
            "Показывать сессии, которые запускали скрипты и другие агенты (codex exec, субагенты)")
        sourceLabel.stringValue = tr("Source:", "Источник:")
        projectLabel.stringValue = tr("Project:", "Проект:")

        let titles = [
            "title": tr("First message", "Первое сообщение"),
            "folder": tr("Folder", "Папка"),
            "origin": tr("Started in", "Откуда"),
            "size": tr("Size", "Размер"),
            "date": tr("Date", "Дата"),
            "state": tr("Status", "Статус"),
        ]
        for col in tableView.tableColumns {
            if let title = titles[col.identifier.rawValue] { col.title = title }
        }
        tableView.headerView?.needsDisplay = true
        languageControl.selectedSegment = currentLang == .ru ? 1 : 0
        buildMenu()
    }

    @objc private func languageChanged() {
        currentLang = languageControl.selectedSegment == 1 ? .ru : .en
        UserDefaults.standard.set(currentLang.rawValue, forKey: "language")
        applyLanguage()
        reload()
    }

    // MARK: - Data

    private func findStoreDir() -> URL? {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Claude/claude-code-sessions")
        guard let level1 = try? FileManager.default.contentsOfDirectory(at: base, includingPropertiesForKeys: nil)
            .filter({ $0.hasDirectoryPath }).sorted(by: { $0.path < $1.path }), let first = level1.first else { return nil }
        guard let level2 = try? FileManager.default.contentsOfDirectory(at: first, includingPropertiesForKeys: nil)
            .filter({ $0.hasDirectoryPath }).sorted(by: { $0.path < $1.path }), let second = level2.first else { return nil }
        return second
    }

    private func loadImportedIds() {
        importedIds = []
        guard let dir = storeDir,
              let files = try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil) else { return }
        for f in files where f.pathExtension == "json" {
            if let data = try? Data(contentsOf: f),
               let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
               let cli = obj["cliSessionId"] as? String {
                importedIds.insert(cli)
            }
        }
    }

    private func parseSession(file: URL, projectDir: URL) -> SessionItem? {
        guard let fh = FileHandle(forReadingAtPath: file.path) else { return nil }
        defer { try? fh.close() }
        let data = fh.readData(ofLength: 256 * 1024)
        guard !data.isEmpty else { return nil }
        // читаем начало файла: обрыв посреди символа не должен терять сессию
        let text = String(decoding: data, as: UTF8.self)

        var cwd = ""
        var entrypoint = ""
        var title = ""
        var createdAt: Int64 = 0
        var model = "claude-opus-4-8"
        let iso = ISO8601DateFormatter()
        iso.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let isoNoFrac = ISO8601DateFormatter()

        for line in text.split(separator: "\n") {
            guard let d = line.data(using: .utf8),
                  let obj = try? JSONSerialization.jsonObject(with: d) as? [String: Any] else { continue }
            if cwd.isEmpty, let c = obj["cwd"] as? String { cwd = c }
            if entrypoint.isEmpty, let e = obj["entrypoint"] as? String { entrypoint = e }
            if createdAt == 0, let ts = obj["timestamp"] as? String {
                let date = iso.date(from: ts) ?? isoNoFrac.date(from: ts)
                if let date = date { createdAt = Int64(date.timeIntervalSince1970 * 1000) }
            }
            if let msg = obj["message"] as? [String: Any] {
                if let m = msg["model"] as? String { model = m }
                if title.isEmpty, obj["type"] as? String == "user" {
                    var t = ""
                    if let s = msg["content"] as? String { t = s }
                    else if let blocks = msg["content"] as? [[String: Any]] {
                        t = blocks.compactMap { $0["type"] as? String == "text" ? $0["text"] as? String : nil }
                            .joined(separator: " ")
                    }
                    t = t.trimmingCharacters(in: .whitespacesAndNewlines)
                    if !t.isEmpty && !t.hasPrefix("<") && !t.hasPrefix("Caveat:") {
                        title = String(t.prefix(70))
                    }
                }
            }
            if !cwd.isEmpty && !title.isEmpty && createdAt != 0 { break }
        }
        if cwd.isEmpty { return nil }

        let attrs = try? FileManager.default.attributesOfItem(atPath: file.path)
        let mtime = (attrs?[.modificationDate] as? Date) ?? Date()
        let size = (attrs?[.size] as? NSNumber)?.int64Value ?? 0
        if size < 100 { return nil }
        let cliId = file.deletingPathExtension().lastPathComponent
        var item = SessionItem(
            kind: .claude,
            projectDir: projectDir, cwd: cwd, fileURL: file, cliId: cliId,
            title: title.isEmpty ? tr("(no text) ", "(без текста) ") + cliId.prefix(8) : title,
            createdAt: createdAt == 0 ? Int64(mtime.timeIntervalSince1970 * 1000) : createdAt,
            lastActivityAt: Int64(mtime.timeIntervalSince1970 * 1000),
            model: model, sizeBytes: size, imported: importedIds.contains(cliId))
        item.origin = claudeOrigin(entrypoint)
        return item
    }

    // MARK: - Откуда сессия

    private func claudeOrigin(_ entrypoint: String) -> String {
        switch entrypoint {
        case "cli": return tr("Terminal", "Терминал")
        case "claude-desktop": return tr("Desktop", "Десктоп")
        case "": return "—"
        default: return entrypoint.hasPrefix("sdk") ? "SDK" : entrypoint
        }
    }

    private func codexOrigin(_ originator: String, subagent: Bool) -> String {
        if subagent { return tr("Subagent", "Субагент") }
        let o = originator.lowercased()
        if o.contains("desktop") { return tr("Desktop", "Десктоп") }
        if o == "codex-tui" || o == "codex_cli_rs" { return tr("Terminal", "Терминал") }
        if o == "codex_exec" { return tr("Automated", "Автозапуск") }
        if o.contains("sdk") { return "SDK" }
        return originator.isEmpty ? "—" : originator
    }

    // MARK: - Codex

    private func loadCodexImportedIds() {
        importedIds = []
        var db: OpaquePointer?
        guard sqlite3_open_v2(codexDB.path, &db, SQLITE_OPEN_READONLY, nil) == SQLITE_OK else { return }
        defer { sqlite3_close(db) }
        var stmt: OpaquePointer?
        if sqlite3_prepare_v2(db, "SELECT id FROM threads", -1, &stmt, nil) == SQLITE_OK {
            while sqlite3_step(stmt) == SQLITE_ROW {
                if let c = sqlite3_column_text(stmt, 0) { importedIds.insert(String(cString: c)) }
            }
        }
        sqlite3_finalize(stmt)
    }

    private func codexCleanTitle(_ raw: String) -> String {
        let t = codexCleanFull(raw).replacingOccurrences(of: "\n", with: " ")
        return String(t.prefix(70))
    }

    /// Сообщение из записи event_msg. Старый формат: user_message / agent_message.
    /// Новый (Codex 0.15x+): item_completed с item.type UserMessage / AgentMessage.
    private func codexMessage(_ p: [String: Any]) -> (isUser: Bool, text: String)? {
        let type = p["type"] as? String
        if type == "user_message" || type == "agent_message" {
            guard let m = p["message"] as? String else { return nil }
            return (type == "user_message", m)
        }
        guard type == "item_completed",
              let item = p["item"] as? [String: Any],
              let kind = item["type"] as? String, kind == "UserMessage" || kind == "AgentMessage",
              let parts = item["content"] as? [[String: Any]] else { return nil }
        let text = parts.compactMap { $0["text"] as? String }.joined(separator: " ")
        return (kind == "UserMessage", text)
    }

    private func parseCodexSession(file: URL, projectDir: URL) -> SessionItem? {
        guard let fh = FileHandle(forReadingAtPath: file.path) else { return nil }
        defer { try? fh.close() }
        let data = fh.readData(ofLength: 512 * 1024)
        guard !data.isEmpty else { return nil }
        let text = String(decoding: data, as: UTF8.self)

        var cwd = "", id = "", title = "", model = "gpt-5.4"
        var service = false, subagent = false, originator = ""
        var modelProvider = "openai", sandbox = "", approval = "on-request", effort = "medium"
        var createdAt: Int64 = 0
        let iso = ISO8601DateFormatter(); iso.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let isoNoFrac = ISO8601DateFormatter()

        for line in text.split(separator: "\n") {
            guard let d = line.data(using: .utf8),
                  let obj = try? JSONSerialization.jsonObject(with: d) as? [String: Any],
                  let type = obj["type"] as? String,
                  let p = obj["payload"] as? [String: Any] else { continue }
            switch type {
            case "session_meta":
                if let c = p["cwd"] as? String { cwd = c }
                if let i = p["id"] as? String { id = i }
                if let mp = p["model_provider"] as? String { modelProvider = mp }
                if let og = p["originator"] as? String { originator = og }
                if let src = p["source"] {
                    subagent = src is [String: Any]
                    service = subagent || (src as? String) == "exec"
                }
                if let ts = p["timestamp"] as? String {
                    if let date = iso.date(from: ts) ?? isoNoFrac.date(from: ts) {
                        createdAt = Int64(date.timeIntervalSince1970 * 1000)
                    }
                }
            case "turn_context":
                if let m = p["model"] as? String { model = m }
                if let e = p["effort"] as? String { effort = e }
                if let a = p["approval_policy"] as? String { approval = a }
                if let sp = p["sandbox_policy"],
                   let spData = try? JSONSerialization.data(withJSONObject: sp),
                   let spStr = String(data: spData, encoding: .utf8) { sandbox = spStr }
            case "event_msg":
                if title.isEmpty, let m = codexMessage(p), m.isUser { title = codexCleanTitle(m.text) }
            default: break
            }
            if !cwd.isEmpty && !id.isEmpty && !title.isEmpty && !sandbox.isEmpty { break }
        }
        if cwd.isEmpty || id.isEmpty { return nil }

        let attrs = try? FileManager.default.attributesOfItem(atPath: file.path)
        let mtime = (attrs?[.modificationDate] as? Date) ?? Date()
        let size = (attrs?[.size] as? NSNumber)?.int64Value ?? 0
        if sandbox.isEmpty {
            sandbox = "{\"type\":\"workspace-write\",\"writable_roots\":[\"\(cwd)\"],\"network_access\":false,\"exclude_tmpdir_env_var\":false,\"exclude_slash_tmp\":false}"
        }
        var item = SessionItem(
            kind: .codex,
            projectDir: projectDir, cwd: cwd, fileURL: file, cliId: id,
            title: title.isEmpty ? tr("(no text) ", "(без текста) ") + id.prefix(8) : title,
            createdAt: createdAt == 0 ? Int64(mtime.timeIntervalSince1970 * 1000) : createdAt,
            lastActivityAt: Int64(mtime.timeIntervalSince1970 * 1000),
            model: model, sizeBytes: size, modelProvider: modelProvider, sandboxPolicy: sandbox,
            approvalMode: approval, reasoningEffort: effort,
            imported: importedIds.contains(id))
        item.isService = service
        item.origin = codexOrigin(originator, subagent: subagent)
        return item
    }

    // MARK: - Grok и OpenCode (только просмотр)

    private var opencodeDB: URL { home.appendingPathComponent(".local/share/opencode/opencode.db") }

    /// Кладёт сессию в список; служебные прячет, пока не включена галочка.
    private func add(_ item: SessionItem) {
        if item.isService && serviceCheckbox.state != .on {
            hiddenService += 1
            return
        }
        allSessions[item.cwd, default: []].append(item)
    }

    /// Дата ISO 8601 в миллисекундах; понимает доли секунды любой длины.
    private func isoMillis(_ string: String) -> Int64? {
        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = fractional.date(from: string) ?? ISO8601DateFormatter().date(from: string) {
            return Int64(date.timeIntervalSince1970 * 1000)
        }
        // доли секунды длиннее трёх знаков: отбрасываем их
        let trimmed = string.replacingOccurrences(of: #"\.\d+"#, with: "", options: .regularExpression)
        return ISO8601DateFormatter().date(from: trimmed).map { Int64($0.timeIntervalSince1970 * 1000) }
    }

    private func folderSize(_ dir: URL) -> Int64 {
        var total: Int64 = 0
        let en = FileManager.default.enumerator(at: dir, includingPropertiesForKeys: [.fileSizeKey])
        while let f = en?.nextObject() as? URL {
            total += Int64((try? f.resourceValues(forKeys: [.fileSizeKey]))?.fileSize ?? 0)
        }
        return total
    }

    /// Начало разговора: первые `pairs` реплик пользователя с ответами.
    private func formatDialog(_ messages: [(isUser: Bool, text: String)], agent: String, pairs: Int) -> String {
        var out: [String] = []
        var userCount = 0
        for m in messages {
            if m.isUser {
                if userCount >= pairs { break }
                userCount += 1
            }
            let t = m.text.count > 1200 ? String(m.text.prefix(1200)) + "…" : m.text
            out.append((m.isUser ? tr("👤 You: ", "👤 Вы: ") : "🤖 \(agent): ") + t)
        }
        return out.isEmpty ? tr("The session has no text messages", "В сессии нет текстовых сообщений") : out.joined(separator: "\n\n")
    }

    /// Реплики Grok из chat_history.jsonl; служебные вставки (synthetic_reason) пропускаются.
    private func grokMessages(in dir: URL, limit: Int) -> [(isUser: Bool, text: String)] {
        let file = dir.appendingPathComponent("chat_history.jsonl")
        guard let fh = FileHandle(forReadingAtPath: file.path) else { return [] }
        defer { try? fh.close() }
        let text = String(decoding: fh.readData(ofLength: limit), as: UTF8.self)

        var out: [(isUser: Bool, text: String)] = []
        for line in text.split(separator: "\n") {
            guard let d = line.data(using: .utf8),
                  let obj = try? JSONSerialization.jsonObject(with: d) as? [String: Any],
                  let type = obj["type"] as? String, type == "user" || type == "assistant",
                  !(obj["synthetic_reason"] is String) else { continue }
            var t = extractText(obj).trimmingCharacters(in: .whitespacesAndNewlines)
            if type == "user" {
                // реплика лежит внутри <user_query>; блок <user_info> с правилами — служебный
                if let a = t.range(of: "<user_query>"),
                   let b = t.range(of: "</user_query>", options: .backwards), a.upperBound <= b.lowerBound {
                    t = String(t[a.upperBound..<b.lowerBound]).trimmingCharacters(in: .whitespacesAndNewlines)
                } else if t.hasPrefix("<user_info>") {
                    continue
                }
            }
            if !t.isEmpty { out.append((type == "user", t)) }
        }
        return out
    }

    /// Сессии Grok: ~/.grok/sessions/<папка проекта>/<id>/summary.json
    private func loadGrokSessions() -> [SessionItem] {
        let fm = FileManager.default
        let root = home.appendingPathComponent(".grok/sessions")
        func subfolders(_ url: URL) -> [URL] {
            ((try? fm.contentsOfDirectory(at: url, includingPropertiesForKeys: nil)) ?? []).filter { $0.hasDirectoryPath }
        }

        var items: [SessionItem] = []
        for pd in subfolders(root) {
            for dir in subfolders(pd) {
                guard let data = try? Data(contentsOf: dir.appendingPathComponent("summary.json")),
                      let s = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { continue }
                let info = s["info"] as? [String: Any] ?? [:]
                let id = info["id"] as? String ?? dir.lastPathComponent
                let cwd = info["cwd"] as? String ?? pd.lastPathComponent.removingPercentEncoding ?? pd.lastPathComponent

                var title = (s["generated_title"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
                if title.isEmpty, let first = grokMessages(in: dir, limit: 256 * 1024).first(where: { $0.isUser }) {
                    title = String(first.text.replacingOccurrences(of: "\n", with: " ").prefix(70))
                }

                let mtime = ((try? fm.attributesOfItem(atPath: dir.path))?[.modificationDate] as? Date) ?? Date()
                let fallback = Int64(mtime.timeIntervalSince1970 * 1000)
                let created = (s["created_at"] as? String).flatMap(isoMillis) ?? fallback
                let active = ((s["last_active_at"] ?? s["updated_at"]) as? String).flatMap(isoMillis) ?? fallback

                // session_kind пуст у живого чата; headless и subagent — служебные запуски
                let kind = s["session_kind"] as? String ?? ""
                var item = SessionItem(
                    kind: .grok, projectDir: pd, cwd: cwd, fileURL: dir, cliId: id,
                    title: title.isEmpty ? tr("(no text) ", "(без текста) ") + id.prefix(8) : title,
                    createdAt: created, lastActivityAt: active,
                    model: s["current_model_id"] as? String ?? "", sizeBytes: folderSize(dir),
                    imported: false)
                item.isService = !kind.isEmpty
                item.origin = kind.isEmpty ? tr("Terminal", "Терминал") : (kind.hasPrefix("subagent") ? tr("Subagent", "Субагент") : tr("Automated", "Автозапуск"))
                items.append(item)
            }
        }
        return items
    }

    private func grokSummary(of dir: URL, pairs: Int = 10) -> String {
        formatDialog(grokMessages(in: dir, limit: 2 * 1024 * 1024), agent: "Grok", pairs: pairs)
    }

    /// Сессии OpenCode: таблица session в ~/.local/share/opencode/opencode.db
    private func loadOpencodeSessions() -> [SessionItem] {
        var db: OpaquePointer?
        guard sqlite3_open_v2(opencodeDB.path, &db, SQLITE_OPEN_READONLY, nil) == SQLITE_OK else { return [] }
        defer { sqlite3_close(db) }
        func column(_ stmt: OpaquePointer?, _ i: Int32) -> String {
            sqlite3_column_text(stmt, i).map { String(cString: $0) } ?? ""
        }

        // размер сессии — объём её записей в базе
        var sizes: [String: Int64] = [:]
        var stmt: OpaquePointer?
        let sizeSQL = "SELECT session_id, sum(length(CAST(data AS BLOB))) FROM part GROUP BY session_id"
        if sqlite3_prepare_v2(db, sizeSQL, -1, &stmt, nil) == SQLITE_OK {
            while sqlite3_step(stmt) == SQLITE_ROW { sizes[column(stmt, 0)] = sqlite3_column_int64(stmt, 1) }
        }
        sqlite3_finalize(stmt)
        stmt = nil

        var items: [SessionItem] = []
        let sql = "SELECT id, parent_id, directory, title, model, time_created, time_updated FROM session"
        if sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK {
            while sqlite3_step(stmt) == SQLITE_ROW {
                let id = column(stmt, 0), parent = column(stmt, 1), cwd = column(stmt, 2)
                let title = column(stmt, 3).trimmingCharacters(in: .whitespacesAndNewlines)
                let modelData = column(stmt, 4).data(using: .utf8) ?? Data()
                let model = (try? JSONSerialization.jsonObject(with: modelData) as? [String: Any])?["id"] as? String ?? ""

                var item = SessionItem(
                    kind: .opencode, projectDir: URL(fileURLWithPath: cwd),
                    cwd: cwd.isEmpty ? tr("(no folder)", "(без папки)") : cwd, fileURL: opencodeDB, cliId: id,
                    title: title.isEmpty ? tr("(no text) ", "(без текста) ") + id.prefix(12) : title,
                    createdAt: sqlite3_column_int64(stmt, 5), lastActivityAt: sqlite3_column_int64(stmt, 6),
                    model: model, sizeBytes: sizes[id] ?? 0, imported: false)
                // parent_id есть у сессий, которые запускал другой агент
                item.isService = !parent.isEmpty
                item.origin = parent.isEmpty ? "—" : tr("Subagent", "Субагент")
                items.append(item)
            }
        }
        sqlite3_finalize(stmt)
        return items
    }

    private func opencodeSummary(sessionId: String, pairs: Int = 10) -> String {
        var db: OpaquePointer?
        guard sqlite3_open_v2(opencodeDB.path, &db, SQLITE_OPEN_READONLY, nil) == SQLITE_OK else {
            return tr("Could not open the OpenCode database", "Не удалось открыть базу OpenCode")
        }
        defer { sqlite3_close(db) }
        let sql = """
        SELECT m.data, p.data FROM part p JOIN message m ON m.id = p.message_id
        WHERE p.session_id = ? ORDER BY m.time_created, p.time_created
        """
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return tr("Could not read the OpenCode database", "Не удалось прочитать базу OpenCode") }
        defer { sqlite3_finalize(stmt) }
        sqlite3_bind_text(stmt, 1, sessionId, -1, SQLITE_TRANSIENT)

        func json(_ i: Int32) -> [String: Any] {
            guard let c = sqlite3_column_text(stmt, i), let d = String(cString: c).data(using: .utf8) else { return [:] }
            return (try? JSONSerialization.jsonObject(with: d) as? [String: Any]) ?? [:]
        }

        var messages: [(isUser: Bool, text: String)] = []
        while sqlite3_step(stmt) == SQLITE_ROW {
            let part = json(1)
            guard part["type"] as? String == "text", part["synthetic"] as? Bool != true,
                  let t = (part["text"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !t.isEmpty else { continue }
            messages.append((json(0)["role"] as? String == "user", t))
        }
        return formatDialog(messages, agent: "OpenCode", pairs: pairs)
    }

    private func reload() {
        allSessions = [:]
        hiddenService = 0
        let fm = FileManager.default
        if source == .claude {
            storeDir = findStoreDir()
            loadImportedIds()
            guard let projectDirs = try? fm.contentsOfDirectory(at: projectsRoot, includingPropertiesForKeys: nil)
                .filter({ $0.hasDirectoryPath }) else { return }
            for pd in projectDirs {
                guard let files = try? fm.contentsOfDirectory(at: pd, includingPropertiesForKeys: nil)
                    .filter({ $0.pathExtension == "jsonl" }) else { continue }
                for f in files {
                    if let item = parseSession(file: f, projectDir: pd) {
                        allSessions[item.cwd, default: []].append(item)
                    }
                }
            }
        } else if source == .codex {
            loadCodexImportedIds()
            let root = projectsRoot
            let en = fm.enumerator(at: root, includingPropertiesForKeys: nil)
            while let f = en?.nextObject() as? URL {
                guard f.pathExtension == "jsonl",
                      f.lastPathComponent.hasPrefix("rollout-") else { continue }
                if let item = parseCodexSession(file: f, projectDir: f.deletingLastPathComponent()) {
                    add(item)
                }
            }
        } else {
            // Grok и OpenCode: только просмотр, импортировать некуда
            importedIds = []
            (source == .grok ? loadGrokSessions() : loadOpencodeSessions()).forEach(add)
        }
        for k in allSessions.keys { allSessions[k]?.sort { $0.lastActivityAt > $1.lastActivityAt } }
        projectKeys = allSessions.keys.sorted {
            (allSessions[$0]?.first?.lastActivityAt ?? 0) > (allSessions[$1]?.first?.lastActivityAt ?? 0)
        }
        let selected = projectPopup.titleOfSelectedItem
        projectPopup.removeAllItems()
        let total0 = allSessions.values.map(\.count).reduce(0, +)
        projectPopup.addItem(withTitle: tr("All projects  (\(total0))", "Все проекты  (\(total0))"))
        for k in projectKeys {
            let count = allSessions[k]?.count ?? 0
            projectPopup.addItem(withTitle: "\(k)  (\(count))")
        }
        if let sel = selected, let idx = projectPopup.itemTitles.firstIndex(of: sel) {
            projectPopup.selectItem(at: idx)
        }
        projectChanged()
        let total = allSessions.values.map(\.count).reduce(0, +)
        if source == .codex {
            let ok = FileManager.default.fileExists(atPath: codexDB.path)
            statusLabel.stringValue = ok
                ? tr("Codex • projects: \(projectKeys.count), sessions: \(total), automated hidden: \(hiddenService). Storage: ~/.codex/state_5.sqlite",
                     "Codex • проектов: \(projectKeys.count), сессий: \(total), скрыто служебных: \(hiddenService). Хранилище: ~/.codex/state_5.sqlite")
                : tr("⚠️ ~/.codex/state_5.sqlite not found — import is unavailable", "⚠️ ~/.codex/state_5.sqlite не найден — импорт недоступен")
        } else if source == .claude {
            statusLabel.stringValue = storeDir == nil
                ? tr("⚠️ Desktop storage not found — import is unavailable", "⚠️ Хранилище десктопа не найдено — импорт недоступен")
                : tr("Claude • projects: \(projectKeys.count), sessions: \(total). Storage: …/\(storeDir!.lastPathComponent)",
                     "Claude • проектов: \(projectKeys.count), сессий: \(total). Хранилище: …/\(storeDir!.lastPathComponent)")
        } else {
            let name = source == .grok ? "Grok" : "OpenCode"
            let store = source == .grok ? "~/.grok/sessions" : "~/.local/share/opencode/opencode.db"
            statusLabel.stringValue = tr(
                "\(name) • projects: \(projectKeys.count), sessions: \(total), automated hidden: \(hiddenService). View only: \(store)",
                "\(name) • проектов: \(projectKeys.count), сессий: \(total), скрыто служебных: \(hiddenService). Только просмотр: \(store)")
        }
    }

    @objc private func projectChanged() {
        let idx = projectPopup.indexOfSelectedItem
        if idx <= 0 {
            rows = allSessions.values.flatMap { $0 }.sorted { $0.lastActivityAt > $1.lastActivityAt }
        } else if idx - 1 < projectKeys.count {
            rows = allSessions[projectKeys[idx - 1]] ?? []
        } else {
            rows = []
        }
        sortRows()
        selectAllButton.state = .off
        visibleCount = pageSize
        tableView.reloadData()
        updateMoreButton()
    }

    private func updateMoreButton() {
        let shown = min(visibleCount, rows.count)
        if shown < rows.count {
            let remaining = rows.count - shown
            moreButton.title = tr("Show \(min(pageSize, remaining)) more (\(shown) of \(rows.count) shown)",
                                 "Показать ещё \(min(pageSize, remaining)) (показано \(shown) из \(rows.count))")
            moreButton.isHidden = false
        } else {
            moreButton.isHidden = true
        }
    }

    @objc private func loadMoreClicked() {
        visibleCount = min(visibleCount + pageSize, rows.count)
        tableView.reloadData()
        updateMoreButton()
    }

    @objc private func sourceChanged() {
        let sources: [Source] = [.claude, .codex, .grok, .opencode]
        source = sources[max(0, min(sourcePopup.indexOfSelectedItem, sources.count - 1))]
        serviceCheckbox.isHidden = source == .claude
        // импорт есть только у Claude и Codex
        let canImport = source == .claude || source == .codex
        importButton.isEnabled = canImport
        selectAllButton.isEnabled = canImport
        reload()
    }

    @objc private func refreshClicked() { reload() }

    @objc private func selectAllToggled() {
        let on = selectAllButton.state == .on
        for i in rows.indices where !rows[i].imported { rows[i].checked = on }
        tableView.reloadData()
    }

    @objc private func checkboxToggled(_ sender: NSButton) {
        let row = sender.tag
        guard row >= 0 && row < rows.count else { return }
        rows[row].checked = sender.state == .on
    }

    @objc private func importClicked() {
        guard source == .claude || source == .codex else { return }
        if source == .codex { importCodex(); return }
        guard let dir = storeDir else {
            statusLabel.stringValue = tr("⚠️ Desktop storage not found", "⚠️ Хранилище десктопа не найдено")
            return
        }
        let picked = rows.filter { $0.checked && !$0.imported }
        guard !picked.isEmpty else {
            statusLabel.stringValue = tr("Nothing selected", "Ничего не выбрано")
            return
        }
        var ok = 0
        for item in picked {
            let sid = "local_" + UUID().uuidString.lowercased()
            let entry: [String: Any] = [
                "sessionId": sid,
                "cliSessionId": item.cliId,
                "cwd": item.cwd,
                "originCwd": item.cwd,
                "createdAt": item.createdAt,
                "lastActivityAt": item.lastActivityAt,
                "model": item.model,
                "effort": "medium",
                "isArchived": false,
                "title": item.title,
                "permissionMode": "acceptEdits",
                "enabledMcpTools": [String: Bool](),
                "remoteMcpServersConfig": [String](),
            ]
            if let data = try? JSONSerialization.data(withJSONObject: entry),
               (try? data.write(to: dir.appendingPathComponent(sid + ".json"))) != nil {
                ok += 1
            }
        }
        loadImportedIds()
        for key in allSessions.keys {
            for i in (allSessions[key] ?? []).indices {
                allSessions[key]![i].imported = importedIds.contains(allSessions[key]![i].cliId)
                allSessions[key]![i].checked = false
            }
        }
        projectChanged()
        statusLabel.stringValue = tr("Imported: \(ok). Restart the Claude app (⌘Q) to see the sessions.",
                                     "Импортировано: \(ok). Перезапустите приложение Claude (⌘Q), чтобы увидеть сессии.")
    }

    private func importCodex() {
        guard FileManager.default.fileExists(atPath: codexDB.path) else {
            statusLabel.stringValue = tr("⚠️ ~/.codex/state_5.sqlite not found", "⚠️ ~/.codex/state_5.sqlite не найден")
            return
        }
        let picked = rows.filter { $0.checked && !$0.imported }
        guard !picked.isEmpty else {
            statusLabel.stringValue = tr("Nothing selected", "Ничего не выбрано")
            return
        }
        var db: OpaquePointer?
        guard sqlite3_open(codexDB.path, &db) == SQLITE_OK else {
            statusLabel.stringValue = tr("⚠️ Could not open state_5.sqlite", "⚠️ Не удалось открыть state_5.sqlite")
            return
        }
        defer { sqlite3_close(db) }
        let sql = """
        INSERT OR IGNORE INTO threads
        (id, rollout_path, created_at, updated_at, source, model_provider, cwd, title,
         sandbox_policy, approval_mode, model, reasoning_effort, memory_mode,
         has_user_event, first_user_message, preview, cli_version, thread_source)
        VALUES (?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?)
        """
        var ok = 0
        for item in picked {
            var stmt: OpaquePointer?
            guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { continue }
            func text(_ idx: Int32, _ s: String) {
                sqlite3_bind_text(stmt, idx, s, -1, SQLITE_TRANSIENT)
            }
            text(1, item.cliId)
            text(2, item.fileURL.path)
            sqlite3_bind_int64(stmt, 3, item.createdAt / 1000)
            sqlite3_bind_int64(stmt, 4, item.lastActivityAt / 1000)
            text(5, "cli")
            text(6, item.modelProvider)
            text(7, item.cwd)
            text(8, item.title)
            text(9, item.sandboxPolicy)
            text(10, item.approvalMode)
            text(11, item.model)
            text(12, item.reasoningEffort)
            text(13, "enabled")
            sqlite3_bind_int(stmt, 14, 1)
            text(15, item.title)
            text(16, item.title)
            text(17, "")
            text(18, "")
            if sqlite3_step(stmt) == SQLITE_DONE && sqlite3_changes(db) > 0 { ok += 1 }
            sqlite3_finalize(stmt)
        }
        loadCodexImportedIds()
        for key in allSessions.keys {
            for i in (allSessions[key] ?? []).indices {
                allSessions[key]![i].imported = importedIds.contains(allSessions[key]![i].cliId)
                allSessions[key]![i].checked = false
            }
        }
        projectChanged()
        statusLabel.stringValue = tr("Imported: \(ok). Restart Codex to see the sessions.",
                                     "Импортировано: \(ok). Перезапустите Codex, чтобы увидеть сессии.")
    }

    // MARK: - Detail

    private func extractText(_ msg: [String: Any]) -> String {
        if let s = msg["content"] as? String { return s }
        if let blocks = msg["content"] as? [[String: Any]] {
            return blocks.compactMap { $0["type"] as? String == "text" ? $0["text"] as? String : nil }
                .joined(separator: " ")
        }
        return ""
    }

    private func summary(of file: URL, pairs: Int = 10) -> String {
        guard let fh = FileHandle(forReadingAtPath: file.path) else { return tr("Could not open the file", "Не удалось открыть файл") }
        defer { try? fh.close() }
        let data = fh.readData(ofLength: 2 * 1024 * 1024)
        let text = String(decoding: data, as: UTF8.self)

        var out: [String] = []
        var userCount = 0
        var lastRole = ""
        for line in text.split(separator: "\n") {
            guard let d = line.data(using: .utf8),
                  let obj = try? JSONSerialization.jsonObject(with: d) as? [String: Any],
                  let type = obj["type"] as? String, type == "user" || type == "assistant",
                  let msg = obj["message"] as? [String: Any] else { continue }
            var t = extractText(msg).trimmingCharacters(in: .whitespacesAndNewlines)
            if t.isEmpty || t.hasPrefix("<") || t.hasPrefix("Caveat:") { continue }
            if type == "user" {
                if userCount >= pairs { break }
                userCount += 1
            } else if lastRole != "user" {
                continue
            }
            if t.count > 1200 { t = String(t.prefix(1200)) + "…" }
            out.append((type == "user" ? tr("👤 You: ", "👤 Вы: ") : "🤖 Claude: ") + t)
            lastRole = type
        }
        return out.isEmpty ? tr("The session has no text messages", "В сессии нет текстовых сообщений") : out.joined(separator: "\n\n")
    }

    private func codexSummary(of file: URL, pairs: Int = 10) -> String {
        guard let fh = FileHandle(forReadingAtPath: file.path) else { return tr("Could not open the file", "Не удалось открыть файл") }
        defer { try? fh.close() }
        let data = fh.readData(ofLength: 2 * 1024 * 1024)
        let text = String(decoding: data, as: UTF8.self)

        var out: [String] = []
        var userCount = 0
        for line in text.split(separator: "\n") {
            guard let d = line.data(using: .utf8),
                  let obj = try? JSONSerialization.jsonObject(with: d) as? [String: Any],
                  obj["type"] as? String == "event_msg",
                  let p = obj["payload"] as? [String: Any],
                  let m = codexMessage(p) else { continue }
            var t = m.text.trimmingCharacters(in: .whitespacesAndNewlines)
            if t.isEmpty { continue }
            if m.isUser {
                if userCount >= pairs { break }
                userCount += 1
                t = codexCleanFull(t)
            }
            if t.count > 1200 { t = String(t.prefix(1200)) + "…" }
            let entry = (m.isUser ? tr("👤 You: ", "👤 Вы: ") : "🤖 Codex: ") + t
            if out.last != entry { out.append(entry) }
        }
        return out.isEmpty ? tr("The session has no text messages", "В сессии нет текстовых сообщений") : out.joined(separator: "\n\n")
    }

    private func codexCleanFull(_ raw: String) -> String {
        var t = raw
        if let r = t.range(of: "## My request for Codex:") {
            t = String(t[r.upperBound...])
        }
        // голосовой ввод: реплика лежит внутри <input>…</input>
        if let a = t.range(of: "<input>"), let b = t.range(of: "</input>"), a.upperBound <= b.lowerBound {
            t = String(t[a.upperBound..<b.lowerBound])
        }
        return t.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Клик по названию сессии открывает начало разговора.
    @objc private func tableClicked() {
        let row = tableView.clickedRow, col = tableView.clickedColumn
        guard row >= 0 && row < rows.count, col >= 0,
              tableView.tableColumns[col].identifier.rawValue == "title",
              let cell = tableView.view(atColumn: col, row: row, makeIfNecessary: false) else { return }
        let item = rows[row]
        let popover = NSPopover()
        popover.behavior = .transient
        let textView = NSTextView(frame: NSRect(x: 0, y: 0, width: 620, height: 480))
        textView.isEditable = false
        textView.font = NSFont.systemFont(ofSize: 12)
        switch item.kind {
        case .claude: textView.string = summary(of: item.fileURL)
        case .codex: textView.string = codexSummary(of: item.fileURL)
        case .grok: textView.string = grokSummary(of: item.fileURL)
        case .opencode: textView.string = opencodeSummary(sessionId: item.cliId)
        }
        textView.textContainerInset = NSSize(width: 10, height: 10)
        let scroll = NSScrollView(frame: textView.frame)
        scroll.documentView = textView
        scroll.hasVerticalScroller = true
        let vc = NSViewController()
        vc.view = scroll
        popover.contentViewController = vc
        popover.contentSize = NSSize(width: 640, height: 500)
        popover.show(relativeTo: cell.bounds, of: cell, preferredEdge: .maxY)
    }

    // MARK: - Table

    func numberOfRows(in tableView: NSTableView) -> Int { min(visibleCount, rows.count) }

    func tableView(_ tableView: NSTableView, sortDescriptorsDidChange oldDescriptors: [NSSortDescriptor]) {
        sortRows()
        tableView.reloadData()
    }

    /// Сортирует строки по выбранному столбцу; без выбора остаётся порядок «сначала новые».
    private func sortRows() {
        guard let sd = tableView.sortDescriptors.first, let key = sd.key else { return }

        func compare<T: Comparable>(_ a: T, _ b: T) -> ComparisonResult {
            a == b ? .orderedSame : (a < b ? .orderedAscending : .orderedDescending)
        }

        func order(_ a: SessionItem, _ b: SessionItem) -> ComparisonResult {
            switch key {
            case "title": return a.title.localizedCaseInsensitiveCompare(b.title)
            case "folder": return a.cwd.localizedCaseInsensitiveCompare(b.cwd)
            case "origin": return a.origin.localizedCaseInsensitiveCompare(b.origin)
            case "size": return compare(a.sizeBytes, b.sizeBytes)
            case "state": return compare(a.imported ? 1 : 0, b.imported ? 1 : 0)
            default: return compare(a.lastActivityAt, b.lastActivityAt)
            }
        }

        rows.sort { a, b in
            let result = order(a, b)
            // при равенстве — сначала новые
            if result == .orderedSame { return a.lastActivityAt > b.lastActivityAt }
            return sd.ascending ? result == .orderedAscending : result == .orderedDescending
        }
    }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        let item = rows[row]
        switch tableColumn?.identifier.rawValue {
        case "check":
            let btn = NSButton(checkboxWithTitle: "", target: self, action: #selector(checkboxToggled(_:)))
            btn.tag = row
            btn.state = item.checked ? .on : .off
            btn.isEnabled = !item.imported && (item.kind == .claude || item.kind == .codex)
            return btn
        case "title":
            let tf = NSTextField(labelWithString: item.title)
            tf.lineBreakMode = .byTruncatingTail
            tf.textColor = item.imported ? .tertiaryLabelColor : .labelColor
            tf.toolTip = tr("Click to see how the conversation began", "Нажмите, чтобы посмотреть начало разговора")
            return tf
        case "folder":
            let home = FileManager.default.homeDirectoryForCurrentUser.path
            let short = item.cwd.hasPrefix(home) ? "~" + item.cwd.dropFirst(home.count) : item.cwd
            let tf = NSTextField(labelWithString: String(short))
            tf.lineBreakMode = .byTruncatingHead
            tf.textColor = .secondaryLabelColor
            tf.toolTip = item.cwd
            return tf
        case "origin":
            let tf = NSTextField(labelWithString: item.origin)
            tf.textColor = item.origin == tr("Desktop", "Десктоп") ? .systemBlue : .secondaryLabelColor
            return tf
        case "size":
            let size = ByteCountFormatter.string(fromByteCount: item.sizeBytes, countStyle: .file)
            let tf = NSTextField(labelWithString: size)
            tf.alignment = .right
            tf.textColor = .secondaryLabelColor
            return tf
        case "date":
            let df = DateFormatter()
            df.dateFormat = "d MMM HH:mm"
            df.locale = Locale(identifier: currentLang == .ru ? "ru_RU" : "en_US")
            let tf = NSTextField(labelWithString: df.string(from: Date(timeIntervalSince1970: Double(item.lastActivityAt) / 1000)))
            tf.textColor = .secondaryLabelColor
            return tf
        case "state":
            let tf = NSTextField(labelWithString: item.imported ? tr("already in desktop", "уже в десктопе") : "")
            tf.textColor = .systemGreen
            return tf
        default:
            return nil
        }
    }
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.run()
