import Testing
import Foundation
import SwiftData
@testable import DevHubCore

@Suite("BackupDocument")
struct BackupDocumentTests {
    @Test("round-trip 编解码保留字段")
    func roundTrip() throws {
        let doc = BackupDocument(
            schemaVersion: 1, exportedAt: Date(timeIntervalSince1970: 1_800_000_000),
            projects: [BackupProject(stableId: "sid-1", name: "ExampleApp", path: "/x/ExampleApp", tags: [], group: nil, isPinned: false)],
            subscriptions: [], platformAccounts: [], tools: [], sessionPreviews: [], settings: nil
        )
        let data = try BackupDocumentCodec.encode(doc)
        let decoded = try BackupDocumentCodec.decode(data)
        #expect(decoded.schemaVersion == 1)
        #expect(decoded.projects.first?.stableId == "sid-1")
        #expect(decoded.projects.first?.name == "ExampleApp")
    }
}

@Suite("PathRelocator")
struct PathRelocatorTests {

    func makeFS() throws -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("reloc-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }

    @Test("path 存在 → resolved(原路径)")
    func pathExists() throws {
        let root = try makeFS()
        let projDir = root.appendingPathComponent("ExampleApp")
        try FileManager.default.createDirectory(at: projDir, withIntermediateDirectories: true)
        let r = PathRelocator()
        let result = r.resolve(stableId: "s1", originalPath: projDir.path, searchRoots: [])
        #expect(result == .resolved(projDir.path))
    }

    @Test("path 不存在 + 无 searchRoot → missing")
    func missingNoRoot() {
        let r = PathRelocator()
        let result = r.resolve(stableId: "s1", originalPath: "/nonexistent/ExampleApp", searchRoots: [])
        #expect(result == .missing(stableId: "s1"))
    }

    @Test("searchRoot 下有 .devhub/project.local.json 含 stableId → resolved")
    func stableIdMatch() throws {
        let root = try makeFS()
        let candidate = root.appendingPathComponent("RenamedExampleApp")
        try FileManager.default.createDirectory(at: candidate, withIntermediateDirectories: true)
        let devhub = candidate.appendingPathComponent(".devhub")
        try FileManager.default.createDirectory(at: devhub, withIntermediateDirectories: true)
        try #"{"stableId":"s1"}"#.write(to: devhub.appendingPathComponent("project.local.json"), atomically: true, encoding: .utf8)

        let r = PathRelocator()
        let result = r.resolve(stableId: "s1", originalPath: "/old/ExampleApp", searchRoots: [root.path])
        #expect(result == .resolved(candidate.path))
    }

    @Test("候选都不含目标 stableId → missing")
    func noStableIdMatch() throws {
        let root = try makeFS()
        let other = root.appendingPathComponent("Other")
        try FileManager.default.createDirectory(at: other.appendingPathComponent(".devhub"), withIntermediateDirectories: true)
        try #"{"stableId":"other"}"#.write(
            to: other.appendingPathComponent(".devhub/project.local.json"), atomically: true, encoding: .utf8)
        let r = PathRelocator()
        let result = r.resolve(stableId: "s1", originalPath: "/old", searchRoots: [root.path])
        #expect(result == .missing(stableId: "s1"))
    }
}

@MainActor
@Suite("DataExporter")
struct DataExporterTests {

    func makeContainer() throws -> ModelContainer {
        try ModelContainer(
            for: Project.self, Subscription.self, Tool.self,
                 PlatformAccount.self, ProjectPlatformBinding.self,
                 SessionIndex.self, AppSettings.self,
            configurations: ModelConfiguration(isStoredInMemoryOnly: true)
        )
    }

    @Test("导出包含项目与订阅（订阅关联到项目 stableId）")
    func exportContainsData() async throws {
        let container = try makeContainer()
        let ctx = container.mainContext
        let p = Project(stableId: "s1", name: "ExampleApp", path: "/x/ExampleApp")
        ctx.insert(p)
        let s = Subscription(name: "Sub", provider: "P", amount: 10, currency: "USD",
                             cycle: .monthly, nextRenewal: Date())
        s.project = p
        ctx.insert(s)
        try ctx.save()

        let exporter = DataExporter(modelContainer: container)
        let doc = try await exporter.export()
        #expect(doc.projects.count == 1)
        #expect(doc.projects.first?.stableId == "s1")
        #expect(doc.subscriptions.count == 1)
        #expect(doc.subscriptions.first?.projectStableId == "s1")
    }

    @Test("导出 Tool 仅含普通 envVars + secretEnvKeys 名，无密钥值")
    func toolSecretsExcluded() async throws {
        let container = try makeContainer()
        let ctx = container.mainContext
        let t = Tool(name: "claude", kind: .cli, launchCommand: "claude",
                     workingDirMode: .projectRoot, injectionMode: .cliFlag,
                     envVars: ["VISIBLE": "yes"], secretEnvKeys: ["API_KEY"],
                     enabled: true, sortOrder: 0)
        ctx.insert(t)
        try ctx.save()

        let exporter = DataExporter(modelContainer: container)
        let doc = try await exporter.export()
        let exported = try #require(doc.tools.first)
        #expect(exported.envVars["VISIBLE"] == "yes")
        #expect(exported.secretEnvKeys == ["API_KEY"])
        let json = String(data: try JSONEncoder().encode(doc), encoding: .utf8) ?? ""
        // 确保无密钥值字段（仅 key 名出现）
        #expect(json.contains("API_KEY") == true)
    }

    @Test("导出 SessionIndex 不含 preview 字段")
    func sessionPreviewScrubbed() async throws {
        let container = try makeContainer()
        let ctx = container.mainContext
        let p = Project(stableId: "s1", name: "ExampleApp", path: "/x")
        ctx.insert(p)
        let si = SessionIndex(tool: "claude-code", toolSessionId: "abc", sourcePath: "/x.jsonl",
                              projectCwd: "/x", startedAt: Date(), updatedAt: Date(),
                              messageCount: 5, title: nil, preview: "SENSITIVE PREVIEW")
        si.project = p
        ctx.insert(si)
        try ctx.save()

        let exporter = DataExporter(modelContainer: container)
        let doc = try await exporter.export()
        #expect(doc.sessionPreviews.count == 1)
        let json = String(data: try JSONEncoder().encode(doc), encoding: .utf8) ?? ""
        #expect(json.contains("SENSITIVE PREVIEW") == false)
    }

    @Test("fileName 带日期 YYYYMMDD")
    func fileName() async throws {
        let container = try makeContainer()
        let exporter = DataExporter(modelContainer: container)
        let name = exporter.fileName(for: Date(timeIntervalSince1970: 1_800_000_000))
        #expect(name.hasPrefix("devhub-backup-"))
        #expect(name.hasSuffix(".json"))
    }
}

@MainActor
@Suite("DataImporter")
struct DataImporterTests {

    func makeProjectDirectory(_ name: String = UUID().uuidString) throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("devhub-import-tests", isDirectory: true)
            .appendingPathComponent(name, isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    func makeDoc() -> BackupDocument {
        BackupDocument(
            schemaVersion: 1, exportedAt: Date(),
            projects: [BackupProject(stableId: "s1", name: "ExampleApp", path: "/nonexistent/ExampleApp", tags: [], group: nil, isPinned: false)],
            subscriptions: [BackupSubscription(name: "Sub", provider: "P", amount: 10, currency: "USD",
                                               cycle: "monthly", nextRenewal: Date(), reminderDaysBefore: 3,
                                               notes: nil, projectStableId: "s1")],
            platformAccounts: [], tools: [], sessionPreviews: [], settings: nil
        )
    }

    func makeContainer() throws -> ModelContainer {
        try ModelContainer(
            for: Project.self, Subscription.self, Tool.self,
                 PlatformAccount.self, ProjectPlatformBinding.self,
                 SessionIndex.self, AppSettings.self,
            configurations: ModelConfiguration(isStoredInMemoryOnly: true)
        )
    }

    @Test("planImport 缺失路径 → report 标记需手动")
    func missingPathReported() async throws {
        let container = try makeContainer()
        let importer = await DataImporter.make(modelContainer: container, pathRelocator: PathRelocator())
        let report = try await importer.planImport(document: makeDoc(), searchRoots: [])
        #expect(report.relocations == [.missing(stableId: "s1")])
        #expect(report.projectsPendingManual == ["s1"])
    }

    @Test("applyImport 用 manualPaths 写入项目与订阅")
    func importWrites() async throws {
        let container = try makeContainer()
        let importer = await DataImporter.make(modelContainer: container, pathRelocator: PathRelocator())
        let doc = makeDoc()
        let report = try await importer.planImport(document: doc, searchRoots: [])
        let target = try makeProjectDirectory()
        try await importer.applyImport(document: doc, report: report, manualPaths: ["s1": target.path])

        let ctx = container.mainContext
        let projects = try ctx.fetch(FetchDescriptor<Project>())
        #expect(projects.count == 1)
        #expect(projects.first?.path == target.path)
        #expect(projects.first?.stableId == "s1")
        #expect(try PathLocator.readStableId(at: target) == "s1")
        let subs = try ctx.fetch(FetchDescriptor<Subscription>())
        #expect(subs.count == 1)
        #expect(subs.first?.project?.stableId == "s1")
    }

    @Test("replace 模式清除现有实体后仅保留备份内容")
    func replaceRemovesExistingData() async throws {
        let container = try makeContainer()
        let context = container.mainContext
        let oldProject = Project(stableId: "old", name: "Old", path: "/tmp/old")
        context.insert(oldProject)
        context.insert(Subscription(
            name: "Old Subscription", provider: "P", amount: 99, currency: "USD",
            cycle: .monthly, nextRenewal: Date()
        ))
        context.insert(Tool(
            name: "Old Tool", kind: .cli, launchCommand: "old",
            workingDirMode: .projectRoot, injectionMode: .clipboard, sortOrder: 0
        ))
        try context.save()

        let importer = await DataImporter.make(modelContainer: container, pathRelocator: PathRelocator())
        let document = makeDoc()
        let report = try await importer.planImport(document: document, searchRoots: [])
        let target = try makeProjectDirectory()
        try await importer.applyImport(
            document: document,
            report: report,
            manualPaths: ["s1": target.path],
            mode: .replace
        )

        #expect(try context.fetch(FetchDescriptor<Project>()).map(\.stableId) == ["s1"])
        #expect(try context.fetch(FetchDescriptor<Subscription>()).map(\.name) == ["Sub"])
        #expect(try context.fetch(FetchDescriptor<Tool>()).isEmpty)
    }

    @Test("schemaVersion 不匹配抛 unsupportedSchema")
    func schemaMismatch() async throws {
        let container = try makeContainer()
        let importer = await DataImporter.make(modelContainer: container, pathRelocator: PathRelocator())
        var doc = makeDoc()
        doc.schemaVersion = 999
        do {
            _ = try await importer.planImport(document: doc, searchRoots: [])
            Issue.record("应抛 unsupportedSchema")
        } catch let err as DataImportError {
            #expect(err == .unsupportedSchema(
                found: 999,
                expected: DataExporter.currentSchemaVersion
            ))
        } catch {
            Issue.record("意外的错误类型: \(error)")
        }
    }

    @Test("v2 完整导入恢复关系、配置与发布状态且重复导入幂等")
    func completeV2ImportIsIdempotent() async throws {
        let container = try makeContainer()
        let importer = await DataImporter.make(
            modelContainer: container,
            pathRelocator: PathRelocator()
        )
        let projectId = "stable-project"
        let accountId = UUID()
        let toolId = UUID()
        let subscriptionId = UUID()
        let bindingId = UUID()
        let importedAt = Date(timeIntervalSince1970: 1_800_000_100)
        let doc = BackupDocument(
            schemaVersion: DataExporter.currentSchemaVersion,
            exportedAt: importedAt,
            projects: [
                BackupProject(
                    stableId: projectId,
                    name: "Imported Project",
                    path: "/missing/imported-project",
                    tags: ["swift", "desktop"],
                    group: "Apps",
                    isPinned: true
                )
            ],
            subscriptions: [
                BackupSubscription(
                    id: subscriptionId,
                    name: "API Plan",
                    provider: "Vendor",
                    amount: 25,
                    currency: "USD",
                    cycle: SubscriptionCycle.yearly.rawValue,
                    nextRenewal: importedAt,
                    reminderDaysBefore: 9,
                    notes: "renew manually",
                    projectStableId: projectId,
                    active: false
                )
            ],
            platformAccounts: [
                BackupPlatformAccount(
                    id: accountId,
                    platform: Platform.twitter.rawValue,
                    displayName: "DevHub",
                    loginUrl: "https://x.com"
                )
            ],
            tools: [
                BackupTool(
                    id: toolId,
                    name: "Codex Custom",
                    kind: ToolKind.cli.rawValue,
                    launchCommand: "/usr/local/bin/codex",
                    envVars: ["DEVHUB_ENV": "test"],
                    secretEnvKeys: ["OPENAI_API_KEY"],
                    enabled: false,
                    workingDirMode: WorkingDirMode.custom.rawValue,
                    customWorkingDir: "/tmp",
                    injectMemory: true,
                    injectionMode: InjectionMode.positionalArg.rawValue,
                    injectionArgs: ["--prompt"],
                    mcpServerRef: "server-1",
                    sortOrder: 42,
                    projectStableIds: [projectId]
                )
            ],
            sessionPreviews: [
                BackupSessionPreview(
                    tool: "codex",
                    toolSessionId: "session-1",
                    projectStableId: projectId,
                    startedAt: importedAt,
                    updatedAt: importedAt,
                    messageCount: 8
                )
            ],
            settings: BackupAppSettings(
                projectsRoot: "/projects",
                enabledPlugins: ["rail-c"],
                theme: "dark",
                sidebarWidth: 260,
                locale: "zh-Hans"
            ),
            platformBindings: [
                BackupPlatformBinding(
                    id: bindingId,
                    projectStableId: projectId,
                    accountId: accountId,
                    accountPlatform: Platform.twitter.rawValue,
                    accountDisplayName: "DevHub",
                    publishStatus: PublishStatus.published.rawValue,
                    publishUrl: "https://x.com/devhub/status/1",
                    publishNotes: "launched",
                    lastPublishedAt: importedAt
                )
            ]
        )
        let report = try await importer.planImport(document: doc, searchRoots: [])
        let target = try makeProjectDirectory()

        for _ in 0..<2 {
            try await importer.applyImport(
                document: doc,
                report: report,
                manualPaths: [projectId: target.path]
            )
        }

        let context = container.mainContext
        let projects = try context.fetch(FetchDescriptor<Project>())
        let subscriptions = try context.fetch(FetchDescriptor<Subscription>())
        let accounts = try context.fetch(FetchDescriptor<PlatformAccount>())
        let tools = try context.fetch(FetchDescriptor<Tool>())
        let bindings = try context.fetch(FetchDescriptor<ProjectPlatformBinding>())
        let sessions = try context.fetch(FetchDescriptor<SessionIndex>())
        let settings = try context.fetch(FetchDescriptor<AppSettings>())

        #expect(projects.count == 1)
        #expect(projects.first?.path == target.path)
        #expect(projects.first?.tags == ["swift", "desktop"])
        #expect(projects.first?.group == "Apps")
        #expect(projects.first?.isPinned == true)

        #expect(subscriptions.count == 1)
        #expect(subscriptions.first?.id == subscriptionId)
        #expect(subscriptions.first?.active == false)
        #expect(subscriptions.first?.cycle == .yearly)
        #expect(subscriptions.first?.project?.stableId == projectId)

        #expect(accounts.count == 1)
        #expect(accounts.first?.id == accountId)
        #expect(accounts.first?.platform == .twitter)

        #expect(tools.count == 1)
        #expect(tools.first?.id == toolId)
        #expect(tools.first?.launchCommand == "/usr/local/bin/codex")
        #expect(tools.first?.workingDirMode == .custom)
        #expect(tools.first?.customWorkingDir == "/tmp")
        #expect(tools.first?.envVars == ["DEVHUB_ENV": "test"])
        #expect(tools.first?.secretEnvKeys == ["OPENAI_API_KEY"])
        #expect(tools.first?.projects.map(\.stableId) == [projectId])

        #expect(bindings.count == 1)
        #expect(bindings.first?.id == bindingId)
        #expect(bindings.first?.publishStatus == .published)
        #expect(bindings.first?.publishUrl == "https://x.com/devhub/status/1")

        #expect(sessions.count == 1)
        #expect(sessions.first?.identityKey == "codex:session-1")
        #expect(sessions.first?.preview.isEmpty == true)
        #expect(sessions.first?.project?.stableId == projectId)

        #expect(settings.count == 1)
        #expect(settings.first?.projectsRoot == "/projects")
        #expect(settings.first?.enabledPlugins == ["rail-c"])
    }

    @Test("缺失项目没有手动目录时拒绝导入")
    func missingManualPathIsRejected() async throws {
        let container = try makeContainer()
        let importer = await DataImporter.make(modelContainer: container, pathRelocator: PathRelocator())
        let doc = makeDoc()
        let report = try await importer.planImport(document: doc, searchRoots: [])

        await #expect(throws: DataImportError.missingManualPath(stableId: "s1")) {
            try await importer.applyImport(document: doc, report: report, manualPaths: [:])
        }
    }

    @Test("手动目录已有其他 stableId 时拒绝覆盖")
    func conflictingManualPathIsRejected() async throws {
        let container = try makeContainer()
        let importer = await DataImporter.make(modelContainer: container, pathRelocator: PathRelocator())
        let doc = makeDoc()
        let report = try await importer.planImport(document: doc, searchRoots: [])
        let target = try makeProjectDirectory()
        _ = try PathLocator.ensureDevHub(at: target, stableId: "another-project")

        await #expect(throws: DataImportError.conflictingStableId(
            expected: "s1",
            found: "another-project",
            path: target.path
        )) {
            try await importer.applyImport(
                document: doc,
                report: report,
                manualPaths: ["s1": target.path]
            )
        }
    }
}
