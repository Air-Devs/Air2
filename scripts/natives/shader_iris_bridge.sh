#!/bin/bash
# ★ [SHADER-FAST] shader_iris_bridge.sh — 26.2 Iris↔Metal 桥 一键开关 / 回退
#
#   开:   sh Natives/shader_iris_bridge.sh on     (默认已开)
#   关:   sh Natives/shader_iris_bridge.sh off    (删标记资源; 26.2 退回 classes262/ 老类集)
#   看:   sh Natives/shader_iris_bridge.sh status
#
#   作用对象: JavaApp/libs/others/metallum_agent.jar 内的标记资源 metallum_iris.mode
#   —— 只有 agent 的 routing 会读它(见 MetallumAgent.irisBridgeEnabled)。删除即回退,
#      不影响 classes262iris/ 类集与 natives/ir1/ dylib 的存在(它们只在开关打开时被使用)。
#
#   另外两条运行期覆盖(优先级高于本标记, 无需改包):
#     -Dmetallum.iris.bridge=0|1        (JVM 属性, 启动器/用户可加)
#     AMETHYST_METALLUM_IRIS=0|1        (环境变量)
#
#   ★ 备份/回退: D:\CTF\_510src\_bak_\shaderfast_*/metallum_agent.jar.orig
set -e
HERE="$(cd "$(dirname "$0")" && pwd)"
JAR="$HERE/../JavaApp/libs/others/metallum_agent.jar"
PY=""
for c in python3 python py; do
  if command -v "$c" >/dev/null 2>&1 && "$c" -c 'import zipfile' >/dev/null 2>&1; then PY="$c"; break; fi
done
[ -n "$PY" ] || { echo "need a working python3/python (with zipfile)"; exit 1; }
[ -f "$JAR" ] || { echo "agent jar not found: $JAR"; exit 1; }
# native Windows python 看不懂 MSYS 路径(/d/..) ⇒ 传给它之前转成原生路径(Mac 上无 cygpath, 原样)
JARW="$JAR"
MANW="$HERE/shader_glslang/blaze3d_group.txt"          # ★ [SHADER-BLAZE3D-GROUP]
if command -v cygpath >/dev/null 2>&1; then
  JARW="$(cygpath -w "$JAR")"
  MANW="$(cygpath -w "$MANW")"
fi

case "${1:-status}" in
  on|off)
    "$PY" - "$JARW" "$1" <<'PYEOF'
import zipfile, sys
jar, mode = sys.argv[1], sys.argv[2]
z = zipfile.ZipFile(jar)
order = [i.filename for i in z.infolist()]
data = {i.filename: z.read(i.filename) for i in z.infolist()}
z.close()
MARK = "metallum_iris.mode"
have = MARK in data
if mode == "on":
    if have:
        print("iris bridge: already ON (marker present)"); sys.exit(0)
    data[MARK] = (b"metallum-iris-bridge 26.2 classes262iris natives/ir1 dylib=f83b1b3b\n")
    order.append(MARK)
    tmp = jar + ".tmp"
    with zipfile.ZipFile(tmp, "w", zipfile.ZIP_DEFLATED) as zo:
        for n in order: zo.writestr(n, data[n])
    import shutil, os; shutil.move(tmp, jar)
    print("iris bridge: ON  (marker added; entries=%d)" % len(order))
else:
    if not have:
        print("iris bridge: already OFF (no marker)"); sys.exit(0)
    order = [n for n in order if n != MARK]; data.pop(MARK)
    tmp = jar + ".tmp"
    with zipfile.ZipFile(tmp, "w", zipfile.ZIP_DEFLATED) as zo:
        for n in order: zo.writestr(n, data[n])
    import shutil, os; shutil.move(tmp, jar)
    print("iris bridge: OFF (marker removed; entries=%d)" % len(order))
PYEOF
    ;;
  status)
    "$PY" - "$JARW" "$MANW" <<'PYEOF'
import zipfile, sys, os
z = zipfile.ZipFile(sys.argv[1]); n = z.namelist()
man = sys.argv[2]
group = []
if os.path.isfile(man):
    for ln in open(man, encoding="utf-8"):
        ln = ln.strip()
        if ln and not ln.startswith("#"):
            group.append(ln.split(None, 2)[2])
cls = sum(1 for x in n if x.startswith("classes262iris/"))
ir1 = [x for x in n if x.startswith("natives/ir1/")]
print("marker metallum_iris.mode :", "PRESENT" if "metallum_iris.mode" in n else "absent")
print("classes262iris/ entries   :", cls)
print("natives/ir1/ entries      :", ir1)
print("natives/ios libmetallum   :", "%d B" % len(z.read("natives/ios/libmetallum.dylib")),
      "(26.3 route, must stay 221856)")
# ★ [SHADER-BLAZE3D-GROUP] blaze3d【整组】的镜像位置（缺一 = "半边可见" ⇒ 真机 NoClassDefFoundError）
print("blaze3d group size        :", "%d class(es) (manifest %s)" % (len(group), os.path.basename(man)))
PREFIXES = ("classes262iris/", "classes262/", "")
tot = 0
for pfx in PREFIXES:
    have = sum(1 for c in group if (pfx + c + ".class") in n)
    tot += have
    print("blaze3d-group @ %-16s: %d/%d" % (pfx or "<jar-root>", have, len(group)))
print("blaze3d group mirror total: %d (want %d = %d loc x %d class)"
      % (tot, len(PREFIXES) * len(group), len(PREFIXES), len(group)))
# ★ [IRIS-INTEGRATE] 26.2-iris 走 91 符号那份额外的 native（见 Natives/verify_iris_integrate.py）
MNB = "classes262iris/com/metallum/client/metal/render/bridge/MetalNativeBridge.class"
wire = (MNB in n) and (b"metallum_iris" in z.read(MNB))
print("iris MetalNativeBridge wiring        :", "loadLibrary(\"metallum_iris\") -> Frameworks/libmetallum_iris.dylib (91 sym)" if wire else "OLD: loadLibrary(\"metallum\") shares the 26.3 file")
print("=> 26.2 iris bridge:", "ON" if "metallum_iris.mode" in n and cls else "OFF")
PYEOF
    ;;
  *) echo "usage: $0 on|off|status"; exit 2 ;;
esac
