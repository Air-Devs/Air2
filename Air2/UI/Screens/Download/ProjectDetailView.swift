//
//  ProjectDetailView.swift
//  Air2
//
//  Copyright (C) 2026 Air-Devs and contributors.
//
//  This program is free software: you can redistribute it and/or modify
//  it under the terms of the GNU General Public License as published by
//  the Free Software Foundation, either version 3 of the License, or
//  (at your option) any later version.
//
//  This program is distributed in the hope that it will be useful,
//  but WITHOUT ANY WARRANTY; without even the implied warranty of
//  MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE. See the
//  GNU General Public License for more details.
//
//  You should have received a copy of the GNU General Public License
//  along with this program. If not, see <https://www.gnu.org/licenses/gpl-3.0.txt>.
//
//  SPDX-License-Identifier: GPL-3.0-or-later
//
//  Mapping: A2ResourceDetailViewController (+ A2ResourceVersionCell) ->
//  ProjectDetailView. 共用资源详情页 —— 讲清这是什么（头卡 + 简介）、
//  有哪些版本、下到哪。
//
//  Faithful to the ObjC original (behaviour / copy / order / visibility):
//    · 头卡（Low 卡）：真实图标 72pt（A2RemoteImageView）+ 标题 2 行 +
//      作者·下载·关注 meta + 分类展示胶囊（关闭交互，无则整行隐去）+
//      简介摘要 2 行（无则「暂无简介」）+「下载最新版」主按钮；
//    · 简介卡（Surface 卡）：标题「简介」+ 全文简介；
//    · 文件筛选两行（游戏版本 / 加载器）：选项从已拉回的全量版本聚合、
//      客户端过滤（不发二次请求），某维度无可选项则整行隐去，
//      游戏版本数字感知降序（避免 1.9 > 1.21 的字符串误判），加载器保持出现顺序；
//    · 版本行：版本号 + 最新徽标 + 「加载器 · 体积 · 游戏版本」+ 已安装打勾；
//    · 更新检测：装过项目但未装最新版 → 主按钮「更新到 x」（用未筛选的全量版本判最新）；
//    · 禁分发项目不请求版本，给专属空态「该作者禁止第三方分发，请前往官网下载」并禁用主按钮；
//    · 收藏走 A2DownloadFavorites；下载一律交给 A2DownloadTaskCenter，
//      清单回写由中心负责，本页不写 A2DownloadManifest。
//
//  SwiftUI-受限的等价改写：
//    · 原 VC 由调用方注入 A2ContentItem（并用 item.platform 拉版本）；Swift 端签名
//      只有 projectID + contentClass，故这里先用「当前首选平台」拉一次项目详情，再用
//      同一 source 拉版本。projectID 变更由 .task(id:) 兜住，等价于原 VC 一页一实例。
//    · 主题刷新（applyTheme / A2ThemeDidChangeNotification）不移植：SwiftUI 语义色
//      Color.c* 自动跟随明暗。
//    · 空态沿用原版的单一 emptyLabel：中文内联文案，不用 A2StateView（其文案为英文）。
//    · 原版筛选区与版本表直接铺在内容层（无卡片），这里同样是裸 VStack，未套 GlassCard。
//

import SwiftUI
import Combine

// MARK: - Local metrics (not in the token set; mirrored from the ObjC original)

private let a2HeaderIconSize: CGFloat = 72      // kHeaderIconSize
private let a2VersionRowHeight: CGFloat = 64    // tableView.rowHeight

// MARK: - Version list status (mirrors the original emptyLabel visibility rules)

private enum ProjectVersionStatus {
    case loading
    case error(String)
    case disabled
    case empty
    case filteredEmpty
    case ready
}

// MARK: - View model

@MainActor
final class ProjectDetailViewModel: ObservableObject {
    let projectID: String
    let contentClass: A2ContentClass
    /// 版本隔离目录由分类唯一出口推导（统一映射只留一处），对齐 A2VersionFolderForClass。
    let targetSubdir: String

    @Published private(set) var project: A2ContentItem?
    /// 全部版本（筛选前）。更新检测与「下载最新版」都以它为准，避免筛选后误判。
    @Published private(set) var allVersions: [A2ContentVersion] = []
    /// 当前展示（已按筛选条件过滤）的版本。
    @Published private(set) var versions: [A2ContentVersion] = []
    @Published private(set) var loading = false
    @Published private(set) var loadErrorMessage: String?
    @Published private(set) var installedVersionIDs: Set<String> = []
    @Published private(set) var updateTitle = "下载最新版"
    @Published var selectedGameVersion: String?
    @Published var selectedLoader: String?
    @Published private(set) var isFavorite = false
    @Published var toast: ToastMessage?

    private let source: A2ContentSource
    private var didLoad = false

    init(projectID: String, contentClass: A2ContentClass) {
        self.projectID = projectID
        self.contentClass = contentClass
        self.targetSubdir = A2VersionFolderForClass(contentClass)
        // 调用方只透传 projectID / contentClass，平台信息已丢失；用当前首选平台拉详情与版本。
        self.source = A2ContentSource.source(forPlatform: A2ContentSource.preferredPlatform())
    }

    // MARK: Derived

    var pageTitle: String {
        if let title = project?.title, !title.isEmpty { return title }
        return A2ClassDisplayName(contentClass)
    }

    /// 对应原版 emptyLabel 的三态 + 主按钮 enabled 的综合可见性。
    var status: ProjectVersionStatus {
        if loading { return .loading }
        if let message = loadErrorMessage { return .error(message) }
        if project?.downloadable == false { return .disabled }
        if allVersions.isEmpty { return .empty }
        if versions.isEmpty { return .filteredEmpty }
        return .ready
    }

    /// 主按钮可用性：对齐原版 downloadButton.enabled（禁分发 / 无版本时禁用）。
    var canDownload: Bool {
        project?.downloadable == true && !allVersions.isEmpty
    }

    var hasFilterOptions: Bool {
        !gameVersionOptions.isEmpty || !loaderOptions.isEmpty
    }

    /// 游戏版本选项：全量版本聚合去重，数字感知降序（新版在前）。
    var gameVersionOptions: [String] {
        var set = Set<String>()
        for version in allVersions {
            for gameVersion in version.gameVersions where !gameVersion.isEmpty {
                set.insert(gameVersion)
            }
        }
        return set.sorted { $0.compare($1, options: .numeric) == .orderedDescending }
    }

    /// 加载器选项：全量版本聚合去重，保持出现顺序（对齐原实现的 NSMutableOrderedSet）。
    var loaderOptions: [String] {
        var seen = Set<String>()
        var out: [String] = []
        for version in allVersions {
            for loader in version.loaders where !loader.isEmpty {
                if seen.insert(loader).inserted { out.append(loader) }
            }
        }
        return out
    }

    // MARK: Loading

    func load() {
        guard !didLoad else { return }
        didLoad = true
        refreshFavorite()
        loading = true
        loadErrorMessage = nil
        A2ComponentLog("resource-detail: 拉取项目 project=\(projectID)")

        source.project(withID: projectID) { [weak self] item, error in
            Task { @MainActor in
                guard let self else { return }
                if let error {
                    self.loading = false
                    self.loadErrorMessage = "项目加载失败：\(error.localizedDescription)"
                    A2ComponentLog("resource-detail: 项目加载失败 \(error.localizedDescription)")
                    return
                }
                guard let item else {
                    self.loading = false
                    self.loadErrorMessage = "项目加载失败：未找到该项目"
                    A2ComponentLog("resource-detail: 项目为空 project=\(self.projectID)")
                    return
                }
                self.project = item
                self.reloadVersions()
            }
        }
    }

    /// 对应原版 reloadVersions：禁分发不请求版本，直接给专属空态。
    private func reloadVersions() {
        guard let project else { return }
        if !project.downloadable {
            allVersions = []
            versions = []
            loading = false
            refreshInstallState()
            A2ComponentLog("resource-detail: 禁分发 project=\(projectID)，不请求版本")
            return
        }

        A2ComponentLog("resource-detail: 拉取版本 project=\(projectID) class=\(contentClass.rawValue)")
        loading = true
        loadErrorMessage = nil
        source.versions(forProject: projectID, gameVersion: nil, loader: nil) { [weak self] versions, error in
            Task { @MainActor in
                guard let self else { return }
                self.loading = false
                let list = versions ?? []
                if list.isEmpty {
                    self.allVersions = []
                    self.versions = []
                    // 请求失败与「确实没有版本」文案分离。
                    self.loadErrorMessage = error.map { "版本加载失败：\($0.localizedDescription)" }
                    A2ComponentLog("resource-detail: 版本为空 project=\(self.projectID) err=\(error?.localizedDescription ?? "无错误")")
                } else {
                    self.allVersions = list
                    self.loadErrorMessage = nil
                    self.applyFilter()
                }
                self.refreshInstallState()
            }
        }
    }

    /// 按当前筛选条件过滤已拉回的版本（客户端过滤，不发二次请求）。
    private func applyFilter() {
        var out: [A2ContentVersion] = []
        for version in allVersions {
            if let selectedGameVersion, !version.gameVersions.contains(selectedGameVersion) { continue }
            if let selectedLoader, !version.loaders.contains(selectedLoader) { continue }
            out.append(version)
        }
        versions = out
        A2ComponentLog("resource-detail: 筛选 gameVersion=\(selectedGameVersion ?? "全部") loader=\(selectedLoader ?? "全部") -> \(out.count) 个版本")
    }

    // MARK: Filters

    func selectGameVersion(_ value: String) {
        selectedGameVersion = value.isEmpty ? nil : value
        applyFilter()
    }

    func selectLoader(_ value: String) {
        selectedLoader = value.isEmpty ? nil : value
        applyFilter()
    }

    // MARK: Install / update state

    /// 对应原版 refreshUpdateState + 版本行打勾：
    /// 装过项目、且最新版没装 → 主按钮「更新到 x」；用未筛选的全量版本判最新版。
    private func refreshInstallState() {
        let manifest = A2DownloadManifest.shared()
        var ids = Set<String>()
        for version in allVersions where manifest.isVersionInstalled(projectID, versionID: version.versionID) {
            ids.insert(version.versionID)
        }
        installedVersionIDs = ids

        guard let latest = allVersions.first else {
            updateTitle = "下载最新版"
            return
        }
        let installedProject = manifest.isProjectInstalled(projectID)
        let latestInstalled = ids.contains(latest.versionID)
        updateTitle = (installedProject && !latestInstalled)
            ? "更新到 \(latest.versionNumber)"
            : "下载最新版"
    }

    // MARK: Favorites

    func refreshFavorite() {
        isFavorite = A2DownloadFavorites.shared().isFavorite(projectID)
    }

    func toggleFavorite() {
        guard let project else { return }
        let store = A2DownloadFavorites.shared()
        let nowFavorite: Bool
        if store.isFavorite(projectID) {
            store.removeFavorite(withID: projectID)
            nowFavorite = false
        } else {
            store.addFavorite(A2FavoriteItem.item(withContentItem: project))
            nowFavorite = true
        }
        isFavorite = nowFavorite
        A2ComponentLog("resource-detail: \(nowFavorite ? "加入" : "取消")收藏 project=\(projectID)")
        toast = ToastMessage(nowFavorite ? "已加入收藏" : "已取消收藏")
    }

    // MARK: Download

    func downloadLatest() {
        // 始终下最新版，与筛选条件无关。
        guard let version = allVersions.first else {
            toast = ToastMessage("没有可用的版本")
            return
        }
        download(version)
    }

    func download(_ version: A2ContentVersion) {
        guard !version.candidateURLs.isEmpty else {
            toast = ToastMessage("此版本没有可下载的文件（可能作者禁止第三方分发）")
            return
        }

        let fileName: String
        if let name = version.fileName, !name.isEmpty {
            fileName = name
        } else {
            fileName = "\(projectID)-\(version.versionNumber).jar"
        }

        // 落盘路径走唯一出口（A2GamePath），View 不手拼 Documents 路径。
        let path = A2GamePath.path(withGameHome: A2GamePath.defaultGameHome())
        let dest: String
        do {
            dest = try path.downloadDestination(inSubdir: targetSubdir, fileName: fileName)
        } catch {
            toast = ToastMessage(error.localizedDescription)
            return
        }

        toast = ToastMessage("开始下载 \(fileName)")

        let request = A2DownloadRequest()
        // candidateURLs 里已含镜像候选（按设置排序），下载引擎会依次尝试。
        request.candidateURLs = version.candidateURLs.compactMap { URL(string: $0) }
        request.destinationPath = dest
        request.expectedSize = version.fileSize
        request.allowZipFallbackCheck = true

        let taskID = A2DownloadTaskCenter.shared().enqueue(
            withTitle: project?.title ?? projectID,
            subtitle: version.versionNumber.isEmpty ? fileName : version.versionNumber,
            request: request,
            projectID: projectID,
            versionID: version.versionID,
            subdir: targetSubdir
        ) { [weak self] success, error in
            Task { @MainActor in
                guard let self else { return }
                if success {
                    self.toast = ToastMessage("已下载 \(fileName)")
                } else {
                    self.toast = ToastMessage("下载失败：\(error?.localizedDescription ?? "未知错误")")
                }
                // 清单已由中心回写，这里只需刷新勾选与更新态。
                self.refreshInstallState()
            }
        }
        A2ComponentLog("resource-detail: 下载入队 taskID=\(taskID) project=\(projectID) version=\(version.versionID) file=\(fileName)")
    }
}

// MARK: - Screen

struct ProjectDetailView: View {
    let projectID: String
    let contentClass: A2ContentClass

    @StateObject private var model: ProjectDetailViewModel

    init(projectID: String, contentClass: A2ContentClass) {
        self.projectID = projectID
        self.contentClass = contentClass
        _model = StateObject(wrappedValue: ProjectDetailViewModel(projectID: projectID, contentClass: contentClass))
    }

    var body: some View {
        A2PageScaffold(model.pageTitle) {
            headerCard.a2CardEntrance(0)
            summaryCard.a2CardEntrance(1)
            filterSection.a2CardEntrance(2)
            versionSection.a2CardEntrance(3)
        }
        // 收藏入口对齐原版：原 VC 用 addTrailingButtonWithSymbol 挂在导航栏右侧，
        // 故这里同样放在 .toolbar（非头卡内）。
        .toolbar {
            Button {
                model.toggleFavorite()
            } label: {
                Image(systemName: model.isFavorite ? "star.fill" : "star")
                    .font(.system(size: 18, weight: .medium))
                    .frame(minWidth: A2MinTouchTarget, minHeight: A2MinTouchTarget)
            }
            .accessibilityLabel(model.isFavorite ? "已收藏" : "收藏")
        }
        .onAppear { model.load() }
        .onReceive(NotificationCenter.default.publisher(for: A2FavoritesDidChangeNotification)) { _ in
            model.refreshFavorite()
        }
        .toast(item: $model.toast)
    }

    // MARK: Header card (A2CardElevationLow -> .l2)

    private var headerCard: some View {
        GlassCard(level: .l2) {
            VStack(alignment: .leading, spacing: A2SpaceM) {
                HStack(alignment: .top, spacing: A2SpaceM) {
                    // 真实图标：远端拉取，无图时由 RemoteImageView 直接显示占位底。
                    RemoteImageView(
                        urlString: model.project?.iconURL,
                        size: a2HeaderIconSize,
                        cornerRadius: A2RadiusL
                    )
                    VStack(alignment: .leading, spacing: A2SpaceXS) {
                        Text(model.pageTitle)
                            .font(A2Type.titleCard)
                            .foregroundStyle(Color.cOnSurface)
                            .lineLimit(2)
                        if !headerMeta.isEmpty {
                            Text(headerMeta)
                                .font(A2Type.caption)
                                .foregroundStyle(Color.cOnSurfaceVariant)
                                .lineLimit(2)
                        }
                        // 分类标签：复用筛选胶囊样式，仅作展示（关闭交互）；无则整行隐去。
                        if !categoryNames.isEmpty {
                            ChipRow {
                                ForEach(categoryNames, id: \.self) { name in
                                    FilterChip(title: name, isInteractive: false)
                                }
                            }
                        }
                    }
                }

                // 头卡内简介摘要（截断到两行；正文全文在下方独立「简介」卡）。
                Text(summaryText)
                    .font(A2Type.body)
                    .foregroundStyle(Color.cOnSurfaceVariant)
                    .lineLimit(2)
                    .truncationMode(.tail)

                PrimaryButton(title: model.updateTitle) {
                    model.downloadLatest()
                }
                .disabled(!model.canDownload)
                .opacity(model.canDownload ? 1 : 0.4)
            }
        }
    }

    private var headerMeta: String {
        guard let project = model.project else { return "" }
        var bits: [String] = []
        if let author = project.author, !author.isEmpty { bits.append(author) }
        if project.downloadCount > 0 {
            bits.append("\(A2FormatCount(project.downloadCount)) 次下载")
        }
        if project.followCount > 0 {
            bits.append("\(A2FormatCount(project.followCount)) 关注")
        }
        return bits.joined(separator: " · ")
    }

    private var categoryNames: [String] {
        (model.project?.categories ?? []).filter { !$0.isEmpty }
    }

    private var summaryText: String {
        guard let summary = model.project?.summary, !summary.isEmpty else { return "暂无简介" }
        return summary
    }

    // MARK: Summary card (A2CardElevationSurface -> .l1)

    private var summaryCard: some View {
        GlassCard(level: .l1) {
            VStack(alignment: .leading, spacing: A2SpaceS) {
                Text("简介")
                    .font(A2Type.titleCard)
                    .foregroundStyle(Color.cOnSurface)
                Text(summaryText)
                    .font(A2Type.body)
                    .foregroundStyle(Color.cOnSurface)
            }
        }
    }

    // MARK: Filter rows (bare, mirrors the original filterStack)

    @ViewBuilder
    private var filterSection: some View {
        if model.hasFilterOptions {
            VStack(alignment: .leading, spacing: A2SpaceS) {
                filterRow(
                    title: "游戏版本",
                    options: model.gameVersionOptions,
                    selected: model.selectedGameVersion,
                    onSelect: { model.selectGameVersion($0) }
                )
                filterRow(
                    title: "加载器",
                    options: model.loaderOptions,
                    selected: model.selectedLoader,
                    onSelect: { model.selectLoader($0) }
                )
            }
        }
    }

    /// 一行筛选：左边定宽标签，右边横向滚动的一排 chip。该维度无选项则整行隐去。
    @ViewBuilder
    private func filterRow(
        title: String,
        options: [String],
        selected: String?,
        onSelect: @escaping (String) -> Void
    ) -> some View {
        if !options.isEmpty {
            HStack(spacing: A2SpaceM) {
                Text(title)
                    .font(A2Type.caption)
                    .foregroundStyle(Color.cOnSurfaceVariant)
                    .fixedSize(horizontal: true, vertical: false)
                ChipRow {
                    FilterChip(title: "全部", selected: selected == nil) { onSelect("") }
                    ForEach(options, id: \.self) { option in
                        FilterChip(title: option, selected: selected == option) { onSelect(option) }
                    }
                }
            }
        }
    }

    // MARK: Version list (bare, mirrors the original tableView + emptyLabel)

    private var versionSection: some View {
        VStack(alignment: .leading, spacing: 0) {
            switch model.status {
            case .loading:
                ProgressView()
                    .frame(maxWidth: .infinity, minHeight: 120)
            case .error(let message):
                statusText(message, color: Color.cError)
            case .disabled:
                statusText("该作者禁止第三方分发，请前往官网下载", color: Color.cOnSurfaceVariant)
            case .empty:
                statusText("没有可用的版本", color: Color.cOnSurfaceVariant)
            case .filteredEmpty:
                statusText("没有符合筛选条件的版本", color: Color.cOnSurfaceVariant)
            case .ready:
                ForEach(model.versions.indices, id: \.self) { index in
                    let version = model.versions[index]
                    versionRow(
                        version,
                        latest: index == 0,
                        installed: model.installedVersionIDs.contains(version.versionID)
                    )
                }
            }
        }
    }

    private func statusText(_ text: String, color: Color) -> some View {
        Text(text)
            .font(A2Type.caption)
            .foregroundStyle(color)
            .multilineTextAlignment(.center)
            .frame(maxWidth: .infinity, minHeight: 120)
    }

    private func versionRow(_ version: A2ContentVersion, latest: Bool, installed: Bool) -> some View {
        Button {
            model.download(version)
        } label: {
            HStack(alignment: .center, spacing: A2SpaceM) {
                VStack(alignment: .leading, spacing: A2SpaceXS) {
                    HStack(spacing: A2SpaceS) {
                        Text(version.versionNumber)
                            .font(A2Type.subtitleCard)
                            .foregroundStyle(Color.cOnSurface)
                            .lineLimit(1)
                        if latest { latestBadge }
                    }
                    Text(versionMeta(version))
                        .font(A2Type.caption)
                        .foregroundStyle(Color.cOnSurfaceVariant)
                        .lineLimit(1)
                        .truncationMode(.tail)
                }
                Spacer(minLength: A2SpaceS)
                Image(systemName: installed ? "checkmark" : "chevron.right")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(installed ? Color.cPrimary : Color.cOutline)
            }
            .frame(minHeight: a2VersionRowHeight)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private var latestBadge: some View {
        Text("最新")
            .font(A2Type.caption)
            .foregroundStyle(Color.cPrimary)
            .padding(.horizontal, A2SpaceS)
            .frame(height: 18)
            .background(
                Color.cSurfaceContainerHigh,
                in: RoundedRectangle(cornerRadius: A2RadiusS, style: .continuous)
            )
    }

    private func versionMeta(_ version: A2ContentVersion) -> String {
        var bits: [String] = []
        if let loader = version.loaders.first, !loader.isEmpty { bits.append(loader) }
        if version.fileSize > 0 { bits.append(displaySize(version.fileSize)) }
        if !version.gameVersions.isEmpty {
            bits.append(version.gameVersions.joined(separator: ", "))
        }
        return bits.joined(separator: " · ")
    }

    private func displaySize(_ bytes: Int64) -> String {
        if bytes < 1024 { return "\(bytes) B" }
        if bytes < 1024 * 1024 { return String(format: "%.1f KB", Double(bytes) / 1024) }
        return String(format: "%.1f MB", Double(bytes) / 1_048_576)
    }
}
