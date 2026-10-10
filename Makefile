SHELL := /bin/bash
.SHELLFLAGS = -ec
$(VERBOSE).SILENT:

# ============================================================
# Air2 — 顶层构建入口
# 用法：make help
# ============================================================

# 用 make 内建的 CURDIR，不要用 printf %q 转义路径：
# %q 会把空格写成 `\ `，于是 "Application\ Support/..." 变成一个字面
# 文件名，下面 `bash "$(SOURCEDIR)/scripts/..."` 会因为找不到文件而失败。
# 工作目录一旦含空格，make lint / make package 全部跑不起来。
SOURCEDIR   := $(CURDIR)
OUTPUTDIR   := $(SOURCEDIR)/artifacts
NATIVESDIR  := $(SOURCEDIR)/Natives
JAVADIR     := $(SOURCEDIR)/JavaApp
BUILDDIR    := $(SOURCEDIR)/build

VERSION     := 0.1.0
BRANCH      ?= $(shell git branch --show-current 2>/dev/null || echo unknown)
COMMIT      ?= $(shell git log --oneline -1 2>/dev/null | cut -b 1-7 || echo unknown)
PLATFORM    ?= 2          # 1=iOS Simulator, 2=Device
RELEASE     ?= 0
SDL_HOST    := $(shell uname -s)

ifeq (1,$(RELEASE))
CMAKE_BUILD_TYPE := Release
else
CMAKE_BUILD_TYPE := Debug
endif

export VERSION BRANCH COMMIT CMAKE_BUILD_TYPE

.PHONY: help bootstrap natives java package clean distclean lint

help:
	@echo "Air2 $(VERSION)  ($(BRANCH)@$(COMMIT))"
	@echo ""
	@echo "  make bootstrap   拉取子模块与预编译依赖"
	@echo "  make natives     编译原生层 (Natives/ → build/)"
	@echo "  make java        编译 Java 启动核心 (→ lwjgl.jar)"
	@echo "  make package     打包 IPA → artifacts/Air2.ipa"
	@echo "  make lint        目录与文件规范检查"
	@echo "  make clean       清理构建产物"
	@echo "  make distclean   清理构建产物与依赖"
	@echo ""
	@echo "  变量：RELEASE=1  PLATFORM=[1|2]  VERBOSE=1"

# ------------------------------------------------------------
bootstrap:
	@echo "==> 拉取子模块"
	git submodule update --init --recursive || true
	@echo "==> 检查预编译依赖"
	@mkdir -p "$(OUTPUTDIR)" "$(BUILDDIR)"

# ------------------------------------------------------------
natives: bootstrap
	@echo "==> 编译原生层"
	@mkdir -p "$(NATIVESDIR)/build"
	@if [ -f "$(NATIVESDIR)/CMakeLists.txt" ]; then \
		cmake -S "$(NATIVESDIR)" -B "$(NATIVESDIR)/build" \
			-DCMAKE_BUILD_TYPE="$(CMAKE_BUILD_TYPE)"; \
		cmake --build "$(NATIVESDIR)/build"; \
	else \
		echo "  (Natives/CMakeLists.txt 尚未就绪)"; \
	fi

# ------------------------------------------------------------
java: bootstrap
	@echo "==> 编译 Java 启动核心"
	@if [ -f "$(JAVADIR)/Makefile" ]; then \
		$(MAKE) -C "$(JAVADIR)"; \
	else \
		echo "  (JavaApp/Makefile 尚未就绪)"; \
	fi

# ------------------------------------------------------------
# 真相源 = 文件系统 + Package.swift，pbxproj 是瞬时产物。
# 打包前一律重生成工程，不依赖入库的副本；
# 删除入库副本是另一次 PR 的决策，本次仅停止依赖它。
package: natives java
	@echo "==> 重生成 Xcode 工程（瞬时产物）"
	@python3 "$(SOURCEDIR)/scripts/gen_xcodeproj.py"
	@echo "==> 打包 IPA"
	@mkdir -p "$(OUTPUTDIR)"
	@if [ -d "$(SOURCEDIR)/Air2.xcodeproj" ]; then \
		bash "$(SOURCEDIR)/scripts/package_ipa.sh"; \
	else \
		echo "  (Air2.xcodeproj 尚未就绪)"; \
	fi

# ------------------------------------------------------------
lint:
	@echo "==> 规范检查"
	@bash "$(SOURCEDIR)/scripts/lint_structure.sh"

# ------------------------------------------------------------
clean:
	@echo "==> 清理构建产物"
	@rm -rf "$(BUILDDIR)" "$(NATIVESDIR)/build" "$(JAVADIR)/build"
	@find . -name '.DS_Store' -delete

distclean: clean
	@echo "==> 清理产物与依赖"
	@rm -rf "$(OUTPUTDIR)"
