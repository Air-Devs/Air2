# ============================================================
# Air2 — Java 启动核心构建
#
# 产物：build/air2-launch.jar
#   随 app bundle 交付：scripts/gen_xcodeproj.py 生成的
#   「Build Java Launch Core」脚本阶段会 make 一次并把 jar 拷进
#   Air2.app/Java/（IPA 内路径 Payload/Air2.app/Java/air2-launch.jar）。
#
# 为什么钉死 Java 8：iOS 内嵌 JRE 是 OpenJDK 8/17/21，class 文件必须能被
# 最低那档读（-source 8 -target 8 ⇒ major 52）。BOOTJDK 缺省取
# /usr/libexec/java_home -v 1.8；在 Windows 上没这个可执行文件也没关系，
# 有 javac 在 PATH 即可（调用方显式传 BOOTJDK 时优先用它）。
#
# 依赖：只依赖 JDK（javac/jar）。启动核心**不引入任何第三方库**
# （见 docs/DEPENDENCIES.md），所以这里没有 -cp，也不该有。
# ============================================================
SOURCEDIR := src
OUTPUTDIR := build
JARNAME   := air2-launch

BOOTJDK ?= $(shell /usr/libexec/java_home -v 1.8 2>/dev/null || echo "")
JAVAC   := $(if $(BOOTJDK),$(BOOTJDK)/bin/javac,javac)
JARTOOL := $(if $(BOOTJDK),$(BOOTJDK)/bin/jar,jar)

SOURCES := $(shell find $(SOURCEDIR) -name '*.java' 2>/dev/null)
CLASSES := $(OUTPUTDIR)/classes
TARGET  := $(OUTPUTDIR)/$(JARNAME).jar

.PHONY: all clean jar verify

all: $(TARGET)

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

clean:
	rm -rf $(OUTPUTDIR)
