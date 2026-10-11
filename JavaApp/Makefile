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
# 依赖：只依赖 JDK（javac/jar）。
#   · 启动核心（src/launcher/**）**不引入任何第三方库** ⇒ 不用 -cp。
#   · LWJGL 补丁类（src/lwjgl/**）★必须★以「被它覆盖的官方 LWJGL jar」为编译期 -cp：
#     这些类按官方签名覆写 org.lwjgl.*（如本仓 GLFW.java 引用官方 GLFWImage、
#     MemoryUtil、libffi 等），没有 -cp 则 javac 报 "package org.lwjgl does not exist"。
#     该 jar 集已在本仓登记（docs/DEPENDENCIES.md「Java 库 · LWJGL」）且随包
#     （Libraries/Jars/lwjgl-341/）⇒ 这不是新增依赖，只是编译期可见性。
# ============================================================
SOURCEDIR := src/launcher
OUTPUTDIR := build
JARNAME   := air2-launch

# LWJGL 补丁类（★决策：org.lwjgl.* 补丁放 Java 侧、独立 jar★）
LWJGL_SRCDIR  := src/lwjgl
LWJGL_JARNAME := air2-lwjgl-patch

# ★编译期★ classpath：官方 LWJGL jar（补丁类覆盖它们，必须能看到官方签名）。
# 运行期不用它 —— 运行期 classpath 由启动计划给出（libs/lwjgl-<ver>/*）。
LWJGL_CP := ../Libraries/Jars/lwjgl-341

BOOTJDK ?= $(shell /usr/libexec/java_home -v 1.8 2>/dev/null || echo "")
JAVAC   := $(if $(BOOTJDK),$(BOOTJDK)/bin/javac,javac)
JARTOOL := $(if $(BOOTJDK),$(BOOTJDK)/bin/jar,jar)

SOURCES := $(shell find $(SOURCEDIR) -name '*.java' 2>/dev/null)
CLASSES := $(OUTPUTDIR)/classes
TARGET  := $(OUTPUTDIR)/$(JARNAME).jar

LWJGL_SOURCES := $(shell find $(LWJGL_SRCDIR) -name '*.java' 2>/dev/null)
LWJGL_CLASSES := $(OUTPUTDIR)/lwjgl-classes
LWJGL_TARGET  := $(OUTPUTDIR)/$(LWJGL_JARNAME).jar

.PHONY: all lwjgl clean verify verify-lwjgl

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
	  $(JAVAC) -source 8 -target 8 -encoding UTF-8 -Xlint:-options -cp "$(LWJGL_CP)/*" -d $(LWJGL_CLASSES) $(LWJGL_SOURCES); \
	fi
	@rm -f $(LWJGL_TARGET)
	@$(JARTOOL) cf $(LWJGL_TARGET) -C $(LWJGL_CLASSES) . -C $(LWJGL_SRCDIR) META-INF
	@$(JARTOOL) tf $(LWJGL_TARGET) | sed 's/^/    /'

# 补丁 jar 两条判据：
#   ① 不得带 Pojav/Boardwalk 包名（老树 overlay 是 org.lwjgl.*，复用不引入这两个包）；
#   ② ★已落类★必须真在 jar 内（复用的 9 个覆盖类 + 1 个编译期注解补丁）—— 防「以为落了」。
verify-lwjgl: $(LWJGL_TARGET)
	@echo "==> 包内自证（LWJGL 补丁 jar）：扫 net/kdt/pojavlaunch 与 Boardwalk"
	@hits=$$( $(JARTOOL) tf $(LWJGL_TARGET) | grep -cE 'net/kdt/pojavlaunch|Boardwalk' || true ); \
	 echo "    命中 = $$hits"; \
	 [ "$$hits" = "0" ] || { echo "错误：补丁 jar 内仍有 Pojav/Boardwalk 传承类"; exit 1; }
	@echo "==> 复核：应落 9 个 org.lwjgl.* 覆盖类 + javax/annotation/Nullable.class"
	@for c in org/lwjgl/glfw/GLFW.class org/lwjgl/glfw/Callbacks.class \
	          org/lwjgl/glfw/GLFWNativeCocoa.class org/lwjgl/glfw/GLFWNativeEGL.class \
	          org/lwjgl/glfw/CallbackBridge.class org/lwjgl/glfw/GLFWWindowProperties.class \
	          org/lwjgl/stb/STBImageResize.class org/lwjgl/system/Callback.class \
	          org/lwjgl/system/CallbackI.class javax/annotation/Nullable.class ; do \
	   $(JARTOOL) tf $(LWJGL_TARGET) | grep -qx "$$c" || { echo "错误：补丁 jar 缺 $$c"; exit 1; }; \
	 done; \
	 echo "    已落 10 个类（含编译期注解补丁）"

clean:
	rm -rf $(OUTPUTDIR)
