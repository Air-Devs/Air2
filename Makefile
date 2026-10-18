#!/bin/bash
#
# Air2 — 顶层构建入口
#
# 结构对照 Air1（Amethyst）的 Makefile，但去掉了它的渲染器编译目标
# （那些依赖 air1 特有的 CMake 树，我们用预编译产物）。
#
# 用法：make help
#

SHELL := /bin/bash
.SHELLFLAGS = -ec
$(VERBOSE).SILENT:

SOURCEDIR   := $(CURDIR)
OUTPUTDIR   := $(SOURCEDIR)/artifacts
NATIVESDIR  := $(SOURCEDIR)/Air2/Player
JAVADIR     := $(SOURCEDIR)/JavaApp
BUILDDIR    := $(SOURCEDIR)/build
DEPENDSDIR  := $(SOURCEDIR)/depends
JREDIR      := $(SOURCEDIR)/java_runtimes

VERSION     := 0.1.0
BRANCH      ?= $(shell git branch --show-current 2>/dev/null || echo unknown)
COMMIT      ?= $(shell git log --oneline -1 2>/dev/null | cut -b 1-7 || echo unknown)
RELEASE     ?= 0

ifeq (1,$(RELEASE))
CMAKE_BUILD_TYPE := Release
else
CMAKE_BUILD_TYPE := Debug
endif

# JRE 版本 —— 对照 Air1：8 / 17 / 21 / 25
JRE_VERSIONS := 8 17 21 25

# ------------------------------------------------------------
help:
	@echo "Air2 $(VERSION)  ($(BRANCH)@$(COMMIT))"
	@echo ""
	@echo "  make bootstrap   准备构建环境"
	@echo "  make deps        下载预编译依赖（Libraries/，约 246MB）"
	@echo "  make jre         下载并处理 JRE（约 440MB）"
	@echo "  make natives     编译原生层（Air2/Player/ → build/）"
	@echo "  make java        编译 Java 启动核心"
	@echo "  make assets      复制资源"
	@echo "  make payload     组装 .app 目录"
	@echo "  make package     打包 IPA"
	@echo "  make all         完整构建（clean + 全部 + package）"
	@echo "  make lint        规范检查"
	@echo "  make check-deps  校验已下载依赖的完整性"
	@echo ""
	@echo "  变量：RELEASE=1  VERBOSE=1"

# ------------------------------------------------------------
bootstrap:
	@echo "==> 准备构建环境"
	@mkdir -p "$(OUTPUTDIR)" "$(BUILDDIR)" "$(DEPENDSDIR)"
	@echo "    完成"

# ------------------------------------------------------------
# 预编译依赖（246MB）
#
# ⚠️ 必须用脚本下载而不是直连 raw.githubusercontent.com：
#    那个域名对大文件会静默截断（curl 返回 0 但文件残缺）。
#    实测 8 个文件被截断过，最严重的只下到 6%。
deps:
	@echo "==> 下载预编译依赖"
	@python3 "$(SOURCEDIR)/scripts/fetch_deps.py"

check-deps:
	@python3 "$(SOURCEDIR)/scripts/fetch_deps.py" --check

# ------------------------------------------------------------
# JRE（约 440MB）
#
# 对照 Air1 的 `jre` 目标：
#   · 下载 jre{8,17,21,25}-ios-aarch64.zip
#   · 解压（注意是两层：zip 里是 .tar.xz）
#   · 校验 lib/server/libjvm.dylib
#   · 删除 bin/include/man/tools.jar/src.zip 等运行时不需要的
#   · 补入自编的 libawt_xawt.dylib
jre: bootstrap
	@echo "==> 下载并处理 JRE"
	@python3 "$(SOURCEDIR)/scripts/fetch_jre.py"
	@echo "==> 复制到产物目录"
	@mkdir -p "$(JREDIR)"
	@for v in $(JRE_VERSIONS); do \
		src="$(DEPENDSDIR)/java-$$v-openjdk"; \
		dst="$(JREDIR)/java-$$v-openjdk"; \
		if [ ! -f "$$src/lib/server/libjvm.dylib" ]; then \
			echo "  ✗ java-$$v-openjdk 缺 libjvm"; exit 1; \
		fi; \
		rm -rf "$$dst"; \
		cp -R "$$src" "$$dst"; \
		echo "  ✓ java-$$v-openjdk"; \
	done

check-jre:
	@python3 "$(SOURCEDIR)/scripts/fetch_jre.py" --check

# ------------------------------------------------------------
natives: bootstrap
	@echo "==> 编译原生层"
	@if [ -f "$(NATIVESDIR)/CMakeLists.txt" ]; then \
		cmake -S "$(NATIVESDIR)" -B "$(BUILDDIR)/natives" \
			-DCMAKE_BUILD_TYPE="$(CMAKE_BUILD_TYPE)" \
			-DCMAKE_OSX_DEPLOYMENT_TARGET=14.0; \
		cmake --build "$(BUILDDIR)/natives" --parallel; \
	else \
		echo "  (cmake/CMakeLists.txt 尚未就绪)"; \
	fi

# ------------------------------------------------------------
java: bootstrap
	@echo "==> 编译 Java 启动核心"
	@if [ -f "$(JAVADIR)/Makefile" ]; then \
		$(MAKE) -C "$(JAVADIR)"; \
	elif [ -f "$(SOURCEDIR)/scripts/build_java.sh" ]; then \
		bash "$(SOURCEDIR)/scripts/build_java.sh"; \
	else \
		echo "  (JavaApp 构建脚本尚未就绪)"; \
	fi

# ------------------------------------------------------------
assets:
	@echo "==> 复制资源"
	@mkdir -p "$(OUTPUTDIR)"
	@if [ -d "$(SOURCEDIR)/Assets" ]; then \
		cp -R "$(SOURCEDIR)/Assets/." "$(OUTPUTDIR)/" 2>/dev/null || true; \
	fi

# ------------------------------------------------------------
# 组装 .app / 打包
#
# 实际的 Xcode 构建由 scripts/package_ipa.sh 负责（用 gen_xcodeproj.py
# 生成的工程）。这里只做前置检查。
payload: natives java
	@echo "==> 检查构建前置条件"
	@[ -d "$(JREDIR)/java-17-openjdk/lib" ] || { echo "  ✗ JRE 未就绪，先跑 make jre"; exit 1; }
	@[ -d "$(SOURCEDIR)/Libraries/Frameworks" ] || { echo "  ✗ 依赖未就绪，先跑 make deps"; exit 1; }
	@echo "  ✓ 前置条件满足"

package: payload
	@echo "==> 打包 IPA"
	@bash "$(SOURCEDIR)/scripts/package_ipa.sh"

# ------------------------------------------------------------
all: clean deps jre payload package
	@echo "==> 构建完成"

# ------------------------------------------------------------
lint:
	@echo "==> 规范检查"
	@bash "$(SOURCEDIR)/scripts/lint_structure.sh"

clean:
	@echo "==> 清理构建产物"
	@rm -rf "$(BUILDDIR)" "$(OUTPUTDIR)"
	@find . -name '.DS_Store' -delete

distclean: clean
	@echo "==> 清理产物与依赖"
	@rm -rf "$(DEPENDSDIR)" "$(JREDIR)"

.PHONY: help bootstrap deps check-deps jre check-jre natives java assets payload package all lint clean distclean
