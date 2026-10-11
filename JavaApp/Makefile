# ============================================================
# Air2 — Java 侧构建（启动核心 + LWJGL 补丁类）
#
# 两个产物（★两件事，互不混同★）：
#   build/air2-launch.jar         自研启动核心（src/launcher/）—— 消费启动计划、派发主类
#   build/air2-lwjgl-patch.jar    org.lwjgl.* 补丁类（src/lwjgl/）—— 层 2，按需逐片落位
# 随 app bundle 交付：scripts/gen_xcodeproj.py 生成的
#   「Build Java Launch Core」脚本阶段会 make 一次并把两个 jar 拷进
#   Air2.app/Java/（IPA 内路径 Payload/Air2.app/Java/…）。
#
# 为什么钉死 Java 8：iOS 内嵌 JRE 是 OpenJDK 8/17/21，class 文件必须能被
# 最低那档读（-source 8 -target 8 ⇒ major 52）。BOOTJDK 缺省取
# /usr/libexec/java_home -v 1.8；在 Windows 上没这个可执行文件也没关系，
# 有 javac 在 PATH 即可（调用方显式传 BOOTJDK 时优先用它）。
#
# 依赖：只依赖 JDK（javac/jar）。启动核心与补丁类都**不引入任何第三方库**
# （见 docs/DEPENDENCIES.md），所以这里没有 -cp，也不该有。
# ============================================================
SOURCEDIR := src/launcher
OUTPUTDIR := build
JARNAME   := air2-launch

# LWJGL 补丁类（★决策：org.lwjgl.* 补丁放 Java 侧、独立 jar★）
LWJGL_SRCDIR  := src/lwjgl
LWJGL_JARNAME := air2-lwjgl-patch

BOOTJDK ?= $(shell /usr/libexec/java_home -v 1.8 2>/dev/null || echo "")
JAVAC   := $(if $(BOOTJDK),$(BOOTJDK)/bin/javac,javac)
JARTOOL := $(if $(BOOTJDK),$(BOOTJDK)/bin/jar,jar)

SOURCES := $(shell find $(SOURCEDIR) -name '*.java' 2>/dev/null)
CLASSES := $(OUTPUTDIR)/classes
TARGET  := $(OUTPUTDIR)/$(JARNAME).jar

LWJGL_SOURCES := $(shell find $(LWJGL_SRCDIR) -name '*.java' 2>/dev/null)
LWJGL_CLASSES := $(OUTPUTDIR)/lwjgl-classes
LWJGL_TARGET  := $(OUTPUTDIR)/$(LWJGL_JARNAME).jar

.PHONY: all lwjgl clean verify verify-lwjgl ownglfw verify-ownglfw

all: $(TARGET) lwjgl

$(TARGET): $(SOURCES)
	@test -n "$(SOURCES)" || { echo "错误：$(SOURCEDIR) 下没有 .java"; exit 1; }
	@rm -rf $(CLASSES) && mkdir -p $(CLASSES)
	@echo "==> javac $(JAVAC)"
	@$(JAVAC) -source 8 -target 8 -encoding UTF-8 -Xlint:-options -d $(CLASSES) $(SOURCES)
	@echo "==> jar -> $@"
	@rm -f $(TARGET)
	@$(JARTOOL) cf $(TARGET) -C $(CLASSES) .
	@$(JARTOOL) tf $(TARGET) | wc -l | tr -d ' ' | sed 's/^/    条目数: /'

# 包内自证：jar 里不得出现任何 Pojav / Boardwalk 传承的类。
# 命中非 0 即失败 —— 这条是「Java 侧已换成自研」的机器判据，不靠人眼。
verify: $(TARGET)
	@echo "==> 包内自证：扫 net/kdt/pojavlaunch 与 Boardwalk"
	@hits=$$( $(JARTOOL) tf $(TARGET) | grep -cE 'net/kdt/pojavlaunch|Boardwalk' || true ); \
	 echo "    命中 = $$hits"; \
	 [ "$$hits" = "0" ] || { echo "错误：jar 内仍有 Pojav/Boardwalk 传承类"; exit 1; }

# LWJGL 补丁 jar：类 + META-INF 清单（清单让「哪几片已落」在包内可判）。
# ★源目录里可能暂时一个 .java 都没有★（补丁逐片落位）⇒ 不报错，只出空壳 + 清单。
lwjgl: $(LWJGL_TARGET)

$(LWJGL_TARGET): $(LWJGL_SOURCES)
	@rm -rf $(LWJGL_CLASSES) && mkdir -p $(LWJGL_CLASSES)
	@echo "==> LWJGL 补丁 jar -> $@（$(words $(LWJGL_SOURCES)) 个 .java）"
	@if [ -n "$(LWJGL_SOURCES)" ]; then \
	  $(JAVAC) -source 8 -target 8 -encoding UTF-8 -Xlint:-options -d $(LWJGL_CLASSES) $(LWJGL_SOURCES); \
	fi
	@rm -f $(LWJGL_TARGET)
	@$(JARTOOL) cf $(LWJGL_TARGET) -C $(LWJGL_CLASSES) . -C $(LWJGL_SRCDIR) META-INF
	@$(JARTOOL) tf $(LWJGL_TARGET) | sed 's/^/    /'

# 补丁 jar 同一条判据（补丁类必须是净室实现，不得带 Pojav/Boardwalk 包名）。
verify-lwjgl: $(LWJGL_TARGET)
	@echo "==> 包内自证（LWJGL 补丁 jar）：扫 net/kdt/pojavlaunch 与 Boardwalk"
	@hits=$$( $(JARTOOL) tf $(LWJGL_TARGET) | grep -cE 'net/kdt/pojavlaunch|Boardwalk' || true ); \
	 echo "    命中 = $$hits"; \
	 [ "$$hits" = "0" ] || { echo "错误：补丁 jar 内仍有 Pojav/Boardwalk 传承类"; exit 1; }

# ------------------------------------------------------------------
# [A2-OWNGLFW-1] 自研 org.lwjgl.glfw.* 最小集（净室线，独立于上面的复用线补丁 jar）。
# 与复用线的 air2-lwjgl-patch.jar 并存但互不混同：本 jar 用于日后「整块替换」。
# 编译期需要官方 jar 提供 SPI/Struct 类型；运行时由 libs/lwjgl-<ver>/* 提供。
ownglfw: verify-ownglfw

verify-ownglfw:
	@echo "==> 自研 GLFW 自证（编译 + 薄 JNI 符号对齐 + 包内自证）"
	@python3 scripts/ownglfw_verify.py

clean:
	rm -rf $(OUTPUTDIR)
