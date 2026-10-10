//
//  DownloadListView.swift
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
//  Mapping: A2ResourceSearchViewController -> DownloadListView +
//  A2ResourceResultCell -> DownloadResultRow.
//
//  One page serves mod, modpack, resource pack, world and shader categories.
//  Search bar + expandable filter card (platform / category / loader / game
//  version / sort) + paginated result list.
//
//  Two deliberate behaviours carried over from the ObjC original:
//    · Loader and game version are independent dimensions — both apply, they
//      are not an either/or choice.
//    · Category identifiers are not portable between platforms, so switching
//      platform clears selected categories and refetches them.
//  Switching to CurseForge without an API key opens the key sheet; cancelling
//  falls back to the previous platform instead of leaving a dead state.
//

import SwiftUI
import Combine

// MARK: - Helpers

/// 下载量易读格式（1.2M / 3.4K / 567）。
func A2FormatCount(_ count: Int64) -> String {
    if count >= 1_000_000 { return String(format: "%.1fM", Double(count) / 1_000_000) }
    if count >= 1_000 { return String(format: "%.1fK", Double(count) / 1_000) }
    return String(count)
}

// MARK: - View model

@MainActor
final class DownloadListViewModel: ObservableObject {
    static let allPlatforms: [A2ContentPlatform] = [.modrinth, .curseForge]

    let contentClass: A2ContentClass

    @Published var query = ""
    @Published private(set) var platform: A2ContentPlatform
    @Published var filterExpanded = false

    @Published private(set) var categoryOptions: [A2ContentCategory] = []
    @Published private(set) var categoriesFailed = false
    @Published var selectedCategories: Set<String> = []

    @Published private(set) var loaderOptions: [A2ModLoaderType] = []
    @Published var selectedLoader: String?

    @Published private(set) var versionOptions: [String] = []
    @Published private(set) var versionsFailed = false
    @Published var selectedGameVersion: String?

    @Published var sortField: A2ContentSortField = .relevance

    @Published private(set) var items: [A2ContentItem] = []
    @Published private(set) var loading = false
    @Published private(set) var reachedEnd = false
    @Published private(set) var lastError: Error?

    @Published var showCurseForgeKeyPrompt = false
    @Published var toast: ToastMessage?
    @Published private(set) var favoritesVersion = 0

    private var offset = 0
    private var source: A2ContentSource
    private var pendingPlatform: A2ContentPlatform?

    init(contentClass: A2ContentClass) {
        self.contentClass = contentClass
        let preferred = A2ContentSource.preferredPlatform()
        let supportsPreferred = A2ContentSource(for: preferred)
            .supportsContentClass(contentClass)
        let fallback = Self.allPlatforms.first {
            A2ContentSource(for: $0).supportsContentClass(contentClass)
        } ?? preferred
        let initial = supportsPreferred ? preferred : fallback
        platform = initial
        source = A2ContentSource(for: initial)
    }

    // MARK: Derived

    var supportedPlatforms: [A2ContentPlatform] {
        Self.allPlatforms.filter {
            A2ContentSource(for: $0).supportsContentClass(contentClass)
        }
    }

    var state: A2ListState {
        if !items.isEmpty { return .ready }
        if !source.isAvailable {
            return .error(source.unavailableReason ?? "资源源当前不可用")
        }
        if !source.supportsContentClass(contentClass) {
            return .error("\(source.displayName) 暂不支持\(A2ClassDisplayName(contentClass))，请切换其它平台")
        }
        if loading { return .loading }
        if let lastError { return .error("请求失败：\(lastError.localizedDescription)") }
        if reachedEnd { return .empty }
        return .loading
    }

    var filterSummary: String {
        var count = selectedCategories.count
        if selectedLoader != nil { count += 1 }
        if selectedGameVersion != nil { count += 1 }
        return "\(source.displayName) · \(A2SortDisplayName(sortField)) · 筛选 \(count)"
    }

    var allSortFields: [A2ContentSortField] {
        A2AllSortFields().map { A2ContentSortField(rawValue: $0.intValue) ?? .relevance }
    }

    func isFavorite(_ projectID: String) -> Bool {
        _ = favoritesVersion
        return A2DownloadFavorites.shared().isFavorite(projectID)
    }

    func isInstalled(_ projectID: String) -> Bool {
        A2DownloadManifest.shared().isProjectInstalled(projectID)
    }

    // MARK: Platform

    func selectPlatform(_ newPlatform: A2ContentPlatform) {
        guard newPlatform != platform else { return }
        if newPlatform == .curseForge && !A2CurseForgeAPI.hasAPIKey() {
            pendingPlatform = newPlatform
            showCurseForgeKeyPrompt = true
            A2ComponentLog("resource-search: 切 CurseForge 无 Key，弹框索要")
            return
        }
        applyPlatform(newPlatform)
    }

    func dismissCurseForgeKeyPrompt() {
        pendingPlatform = nil
        showCurseForgeKeyPrompt = false
    }

    func confirmCurseForgeKeySaved() {
        showCurseForgeKeyPrompt = false
        let target = pendingPlatform ?? .curseForge
        pendingPlatform = nil
        applyPlatform(target)
    }

    private func applyPlatform(_ newPlatform: A2ContentPlatform) {
        platform = newPlatform
        source = A2ContentSource(for: newPlatform)
        A2ContentSource.setPreferredPlatform(newPlatform)
        A2ComponentLog("resource-search: 平台切换 → \(source.displayName)")
        // 分类标识两家不通用，切换后清空已选分类并重新拉取。
        loadCategories()
        reload()
    }

    // MARK: Loading

    func load() {
        loaderOptions = A2ModLoaderAPI.allLoaderTypes()
            .map { A2ModLoaderType(rawValue: $0.intValue) ?? .fabric }
        loadCategories()
        loadGameVersions()
        reload()
    }

    func loadCategories() {
        categoryOptions = []
        categoriesFailed = false
        selectedCategories.removeAll()
        let cls = contentClass
        source.categories(for: cls) { [weak self] categories, error in
            Task { @MainActor in
                guard let self else { return }
                guard let categories, !categories.isEmpty, error == nil else {
                    A2ComponentLog("resource-search: 分类拉取失败 \(error?.localizedDescription ?? "空结果")")
                    self.categoriesFailed = true
                    return
                }
                self.categoryOptions = categories
            }
        }
    }

    func loadGameVersions() {
        versionOptions = []
        versionsFailed = false
        A2RemoteVersions.fetch(completion: { [weak self] versions, error in
            Task { @MainActor in
                guard let self else { return }
                guard let versions, error == nil else {
                    A2ComponentLog("resource-search: 游戏版本拉取失败 \(error?.localizedDescription ?? "空结果")")
                    self.versionsFailed = true
                    return
                }
                var out: [String] = []
                for version in versions where version.type == "release" {
                    out.append(version.versionID)
                    if out.count >= 8 { break }
                }
                self.versionOptions = out
            }
        })
    }

    func reload() {
        offset = 0
        reachedEnd = false
        loading = false
        lastError = nil
        items = []
        loadMore()
    }

    func loadMore() {
        guard !loading, !reachedEnd else { return }
        guard source.isAvailable, source.supportsContentClass(contentClass) else { return }

        loading = true
        let filter = A2ContentFilter.default()
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        filter.query = trimmed.isEmpty ? nil : trimmed
        filter.gameVersion = selectedGameVersion
        filter.loader = selectedLoader
        filter.categories = Array(selectedCategories)
        filter.sortField = sortField
        filter.offset = offset
        filter.limit = 20

        let cls = contentClass
        source.search(with: filter, contentClass: cls) { [weak self] results, error in
            Task { @MainActor in
                guard let self else { return }
                self.loading = false
                if let error {
                    self.lastError = error
                    A2ComponentLog("resource-search: 搜索失败 \(error.localizedDescription)")
                    return
                }
                let results = results ?? []
                A2ComponentLog("resource-search: 返回 \(results.count) 条 offset=\(self.offset)")
                if results.isEmpty {
                    self.reachedEnd = true
                } else {
                    self.items.append(contentsOf: results)
                    self.offset += results.count
                }
            }
        }
    }

    /// 滚到接近底部时续页。
    func loadMoreIfNeeded(current item: A2ContentItem) {
        guard let index = items.firstIndex(where: { $0 === item }) else { return }
        if index >= items.count - 4 { loadMore() }
    }

    // MARK: Filters

    func toggleCategory(_ identifier: String) {
        guard !identifier.isEmpty else { return }
        if selectedCategories.contains(identifier) {
            selectedCategories.remove(identifier)
        } else {
            selectedCategories.insert(identifier)
        }
        A2ComponentLog("resource-search: 分类筛选变更 \(selectedCategories.count) 项")
        reload()
    }

    func selectLoader(_ identifier: String) {
        selectedLoader = identifier.isEmpty ? nil : identifier
        A2ComponentLog("resource-search: 加载器筛选 = \(identifier.isEmpty ? "全部" : identifier)")
        reload()
    }

    func selectGameVersion(_ version: String) {
        selectedGameVersion = version.isEmpty ? nil : version
        A2ComponentLog("resource-search: 游戏版本筛选 = \(version.isEmpty ? "全部" : version)")
        reload()
    }

    func selectSort(_ field: A2ContentSortField) {
        sortField = field
        A2ComponentLog("resource-search: 排序 = \(A2SortDisplayName(field))")
        reload()
    }

    func resetFilters() {
        selectedCategories.removeAll()
        selectedLoader = nil
        selectedGameVersion = nil
        sortField = .relevance
        A2ComponentLog("resource-search: 重置全部筛选")
        reload()
    }

    func refreshFavorites() {
        favoritesVersion &+= 1
    }
}

// MARK: - Result row

private struct DownloadResultRow: View {
    let item: A2ContentItem
    let favorite: Bool
    let installed: Bool
    let onTap: () -> Void

    var body: some View {
        GlassCard(level: .l2, isTappable: true, onTap: onTap) {
            HStack(alignment: .center, spacing: A2SpaceM) {
                RemoteImageView(urlString: item.iconURL, size: 56, cornerRadius: A2RadiusM)

                VStack(alignment: .leading, spacing: 3) {
                    HStack(alignment: .top) {
                        Text(item.title.isEmpty ? item.projectID : item.title)
                            .font(A2Type.titleCard)
                            .foregroundStyle(Color.cOnSurface)
                            .lineLimit(1)
                        Spacer(minLength: A2SpaceS)
                        Image(systemName: favorite ? "star.fill" : "star")
                            .font(.system(size: 14, weight: .medium))
                            .foregroundStyle(favorite ? Color.cPrimary : Color.cOnSurfaceVariant)
                    }
                    if let author = item.author, !author.isEmpty {
                        Text("by \(author)")
                            .font(A2Type.caption)
                            .foregroundStyle(Color.cOnSurfaceVariant)
                            .lineLimit(1)
                    }
                    Text(item.summary.isEmpty ? "暂无简介" : item.summary)
                        .font(A2Type.subtitleCard)
                        .foregroundStyle(Color.cOnSurfaceVariant)
                        .lineLimit(2)
                    HStack(spacing: A2SpaceS) {
                        if installed {
                            Text("已安装")
                                .font(A2Type.caption)
                                .foregroundStyle(Color.cPrimary)
                                .padding(.horizontal, A2SpaceS)
                                .frame(height: 18)
                                .background(
                                    Color.cPrimary.opacity(0.15),
                                    in: RoundedRectangle(cornerRadius: 9, style: .continuous)
                                )
                        }
                        Text(metaText)
                            .font(A2Type.caption)
                            .foregroundStyle(Color.cOnSurfaceVariant.opacity(0.8))
                            .lineLimit(1)
                    }
                }
                Image(systemName: "chevron.right")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(Color.cOutline)
            }
        }
    }

    private var metaText: String {
        var parts: [String] = []
        for category in item.categories where parts.count < 2 {
            parts.append(category.capitalized)
        }
        let downloads = "\(A2FormatCount(item.downloadCount)) 次下载"
        return parts.isEmpty ? downloads : parts.joined(separator: " · ") + "  ·  " + downloads
    }
}

// MARK: - Screen

struct DownloadListView: View {
    let category: DownloadCategory
    @ObservedObject var router: A2Router = A2Router()
    @StateObject private var model: DownloadListViewModel

    init(category: DownloadCategory, router: A2Router) {
        self.category = category
        self.router = router
        _model = StateObject(wrappedValue: DownloadListViewModel(contentClass: DownloadListView.contentClass(for: category)))
    }

    static func contentClass(for category: DownloadCategory) -> A2ContentClass {
        switch category {
        case .modpack: return .modPack
        case .resourcePack: return .resourcePack
        case .world: return .world
        case .shader: return .shader
        case .mod, .game: return .mod
        }
    }

    private var title: String {
        "搜索\(A2ClassDisplayName(model.contentClass))"
    }

    var body: some View {
        A2PageScaffold(title) {
            searchCard.a2CardEntrance(0)
            filterCard.a2CardEntrance(1)
            resultsCard.a2CardEntrance(2)
        }
        .onAppear {
            if model.items.isEmpty && !model.loading { model.load() }
        }
        .onReceive(NotificationCenter.default.publisher(for: NSNotification.Name.A2FavoritesDidChange)) { _ in
            model.refreshFavorites()
        }
        .sheet(isPresented: $model.showCurseForgeKeyPrompt) {
            CurseForgePromptSheet(
                onSaved: { model.confirmCurseForgeKeySaved() },
                onCancel: { model.dismissCurseForgeKeyPrompt() }
            )
        }
        .toast(item: $model.toast)
    }

    // MARK: Search

    private var searchCard: some View {
        GlassCard {
            HStack(spacing: A2SpaceS) {
                Image(systemName: "magnifyingglass")
                    .foregroundStyle(Color.cOnSurfaceVariant)
                TextField("搜索资源…", text: $model.query)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .frame(minHeight: A2MinTouchTarget)
                    .onSubmit { model.reload() }
                if !model.query.isEmpty {
                    Button {
                        model.query = ""
                        model.reload()
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .foregroundStyle(Color.cOnSurfaceVariant)
                            .frame(minWidth: A2MinTouchTarget, minHeight: A2MinTouchTarget)
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }

    // MARK: Filter card

    private var filterCard: some View {
        GlassCard(level: .l2) {
            VStack(alignment: .leading, spacing: A2SpaceM) {
                Button {
                    withAnimation(.a2Press) { model.filterExpanded.toggle() }
                } label: {
                    HStack(spacing: A2SpaceS) {
                        Text(model.filterSummary)
                            .font(A2Type.caption)
                            .foregroundStyle(Color.cOnSurfaceVariant)
                            .lineLimit(1)
                        Spacer()
                        Image(systemName: model.filterExpanded ? "chevron.up" : "chevron.down")
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundStyle(Color.cOnSurfaceVariant)
                    }
                    .frame(minHeight: 24)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)

                if model.filterExpanded {
                    filterBody
                }
            }
        }
    }

    private var filterBody: some View {
        VStack(alignment: .leading, spacing: A2SpaceM) {
            filterGroup("平台") {
                Picker("平台", selection: Binding(
                    get: { model.platform },
                    set: { model.selectPlatform($0) }
                )) {
                    ForEach(model.supportedPlatforms, id: \.self) { platform in
                        Text(A2ContentSource(for: platform).displayName).tag(platform)
                    }
                }
                .pickerStyle(.segmented)
            }

            filterGroup("资源分类") {
                ChipRow {
                    if model.categoriesFailed {
                        chipPlaceholder("分类加载失败")
                    } else if model.categoryOptions.isEmpty {
                        chipPlaceholder("分类加载中…")
                    } else {
                        ForEach(model.categoryOptions, id: \.identifier) { category in
                            FilterChip(
                                title: category.displayName,
                                selected: model.selectedCategories.contains(category.identifier)
                            ) {
                                model.toggleCategory(category.identifier)
                            }
                        }
                    }
                }
            }

            filterGroup("加载器") {
                ChipRow {
                    FilterChip(title: "全部", selected: model.selectedLoader == nil) {
                        model.selectLoader("")
                    }
                    ForEach(model.loaderOptions, id: \.rawValue) { type in
                        let identifier = A2ModLoaderAPI.identifier(for: type)
                        FilterChip(
                            title: A2ModLoaderAPI.displayName(for: type),
                            selected: model.selectedLoader == identifier
                        ) {
                            model.selectLoader(identifier)
                        }
                    }
                }
            }

            filterGroup("游戏版本") {
                ChipRow {
                    if model.versionsFailed {
                        chipPlaceholder("版本加载失败")
                    } else if model.versionOptions.isEmpty {
                        chipPlaceholder("版本加载中…")
                    } else {
                        FilterChip(title: "全部", selected: model.selectedGameVersion == nil) {
                            model.selectGameVersion("")
                        }
                        ForEach(model.versionOptions, id: \.self) { version in
                            FilterChip(title: version, selected: model.selectedGameVersion == version) {
                                model.selectGameVersion(version)
                            }
                        }
                    }
                }
            }

            filterGroup("排序") {
                ChipRow {
                    ForEach(model.allSortFields, id: \.rawValue) { field in
                        FilterChip(
                            title: A2SortDisplayName(field),
                            selected: model.sortField == field
                        ) {
                            model.selectSort(field)
                        }
                    }
                }
            }

            Button {
                model.resetFilters()
            } label: {
                Text("重置筛选")
                    .font(A2Type.button)
                    .foregroundStyle(Color.cPrimary)
                    .frame(maxWidth: .infinity, minHeight: 38)
                    .overlay {
                        RoundedRectangle(cornerRadius: A2RadiusS, style: .continuous)
                            .stroke(Color.cOutlineVariant, lineWidth: 1)
                    }
            }
            .buttonStyle(A2PressButtonStyle())
        }
    }

    private func filterGroup<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title)
                .font(A2Type.caption)
                .foregroundStyle(Color.cOnSurfaceVariant)
            content()
        }
    }

    private func chipPlaceholder(_ text: String) -> some View {
        Text(text)
            .font(A2Type.caption)
            .foregroundStyle(Color.cOnSurfaceVariant)
    }

    // MARK: Results

    private var resultsCard: some View {
        GlassCard(level: .l2) {
            VStack(alignment: .leading, spacing: A2SpaceS) {
                HStack {
                    Text(model.items.isEmpty ? "" : "共 \(model.items.count) 项")
                        .font(A2Type.caption)
                        .foregroundStyle(Color.cOnSurfaceVariant)
                    Spacer()
                }
                A2StateView(
                    state: model.state,
                    emptyTitle: "没有找到相关资源",
                    emptyHint: "换个关键词或平台再试。",
                    firstRunHint: "首次使用：Modrinth 无需任何配置即可搜索。"
                ) { model.reload() }

                ForEach(model.items, id: \.self) { item in
                    DownloadResultRow(
                        item: item,
                        favorite: model.isFavorite(item.projectID),
                        installed: model.isInstalled(item.projectID),
                        onTap: { router.openProject(item.projectID, contentClass: model.contentClass) }
                    )
                    .onAppear { model.loadMoreIfNeeded(current: item) }
                }

                if model.loading && !model.items.isEmpty {
                    HStack {
                        Spacer()
                        ProgressView()
                        Spacer()
                    }
                    .padding(.vertical, A2SpaceS)
                }
            }
        }
    }
}
