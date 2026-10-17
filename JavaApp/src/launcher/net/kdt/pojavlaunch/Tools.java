package net.kdt.pojavlaunch;

import android.util.ArrayMap;
import com.google.gson.Gson;
import com.google.gson.GsonBuilder;
import java.io.BufferedInputStream;
import java.io.BufferedOutputStream;
import java.io.BufferedWriter;
import java.io.File;
import java.io.FileFilter;
import java.io.FileInputStream;
import java.io.FileNotFoundException;
import java.io.FileOutputStream;
import java.io.FileWriter;
import java.io.InputStream;
import java.io.IOException;
import java.io.InputStream;
import java.io.OutputStream;
import java.io.PrintWriter;
import java.io.StringWriter;
import java.lang.reflect.Field;
import java.lang.reflect.Method;
import java.net.HttpURLConnection;
import java.net.URL;
import java.net.URLClassLoader;
import java.nio.charset.Charset;
import java.util.ArrayList;
import java.util.Arrays;
import java.util.List;
import java.util.Map;
import net.kdt.pojavlaunch.uikit.UIKit;
import net.kdt.pojavlaunch.utils.JSONUtils;
import net.kdt.pojavlaunch.value.DependentLibrary;
import net.kdt.pojavlaunch.value.MinecraftAccount;
import net.kdt.pojavlaunch.value.MinecraftLibraryArtifact;

public final class Tools {
    public static final Gson GLOBAL_GSON = new GsonBuilder().setPrettyPrinting().create();

    public static final String DIR_BUNDLE = System.getenv("BUNDLE_PATH"); // path to "PojavLauncher.app"
    public static final String DIR_GAME_HOME = System.getenv("POJAV_HOME");
    public static final String DIR_GAME_NEW = System.getenv("POJAV_GAME_DIR"); // path to "Library/Application Support/minecraft"
    public static final String DIR_GAME_PROFILE = System.getProperty("user.dir");
    
    public static final String DIR_APP_DATA = System.getenv("POJAV_HOME");
    public static final String DIR_ACCOUNT_NEW = DIR_APP_DATA + "/accounts";

    // New since 2.4.2
    public static final String DIR_HOME_VERSION = DIR_GAME_NEW + "/versions";
    public static final String DIR_HOME_LIBRARY = DIR_GAME_NEW + "/libraries";

    public static final String ASSETS_PATH = DIR_GAME_NEW + "/assets";
    public static final String OBSOLETE_RESOURCES_PATH=DIR_GAME_NEW + "/resources";

    public static void launchMinecraft(MinecraftAccount profile, final JMinecraftVersionList.Version versionInfo, String serverIp) throws Throwable {
        // --- BEGIN AMETHYST UPSTREAM LWJGL 3.4.1 COMPLIANCE OVERRIDE ---
        // 关闭 native libffi 检查（防止 LibFFI <clinit> 中的 NoSuchFieldError）
        // 注意：allocator 由 JavaLauncher.m 通过 -Dorg.lwjgl.system.allocator=system 统一配置，
        // 这里不再重复设置。原代码 System.setProperty("org.lwjgl.system.Allocator", "Custom")
        // 存在两个致命问题导致其从未生效，且会误导调试：
        //   1) 属性名大小写错误：LWJGL 实际读取小写 org.lwjgl.system.allocator，大写 Allocator 被忽略
        //   2) "Custom" 不是 LWJGL 有效 allocator 值（有效值仅 system/jemalloc/rpmalloc）
        System.setProperty("org.lwjgl.system.libffi.enabled", "false");
        System.setProperty("org.lwjgl.system.libffi.initialize", "false"); // Prevents NoSuchFieldError in LibFFI <clinit>

        // spvc / openal 库加载说明：
        // spvc 库名由 JavaLauncher.m 显式设置 -Dorg.lwjgl.spvc.libname=spirv-cross-c-shared.0
        // （参照 catsruledogs/Amethyst-iOS-25，能正常启动 26.2 + Java 25）。
        // LWJGL Library.loadNative 在 macOS 上对 libname 的处理：
        //   - 若 libname 已含 "lib" 前缀和 ".dylib" 后缀，直接使用
        //   - 否则加 "lib" 前缀和 ".dylib" 后缀
        // "spirv-cross-c-shared.0" -> "libspirv-cross-c-shared.0.dylib"（正确，不会二次包装）。
        // spirv-cross 作为共享 dylib 放在根目录 Frameworks/，从 library.path
        // （Frameworks:Frameworks/lwjglXX）的根目录 Frameworks/ 加载。
        //
        // openal 用 LWJGL 默认名加载 libopenal.dylib（libopenal.dylib 直接存在于根目录 Frameworks/），
        // 无需 override。
        //
        // 历史教训：曾尝试移除 spvc.libname override 改用 Makefile 软链接
        // （libspirv-cross.dylib -> libspirv-cross-c-shared.0.dylib）+ LWJGL 默认名 "spirv-cross"，
        // 但 26.2 启动时在 "Now starting game" 阶段 SIGSEGV at get_method_id。根因：软链接方案
        // 依赖构建阶段正确创建符号链接，一旦构建环境差异导致软链接缺失或指向错误，spvc 加载
        // 进入异常状态，JNI 注册状态不一致，get_method_id 访问已损坏类元数据导致 SIGSEGV
        // （而非抛出 UnsatisfiedLinkError）。显式指定完整 SO 名直接定位实际文件，无需软链接，
        // 是最稳妥的方案。
        // --- END AMETHYST UPSTREAM LWJGL 3.4.1 COMPLIANCE OVERRIDE ---

        String[] launchArgs = getMinecraftArgs(profile, versionInfo, serverIp);
        // System.out.println("Minecraft Args: " + Arrays.toString(launchArgs));

        final String launchClassPath = generateLaunchClassPath(versionInfo);

        System.out.println("Args init finished. Now starting game");

        PojavClassLoader loader = (PojavClassLoader) ClassLoader.getSystemClassLoader();
        // add launcher.jar itself
        for (String s : System.getProperty("java.class.path").split(":")) {
            loader.appendToClassPathForInstrumentation(s);
        }
        for (String s : launchClassPath.split(":")) {
            if (!s.isEmpty()) {
                loader.addURL(new File(s).toURI().toURL());
            }
        }
            
        Class<?> clazz = loader.loadClass(versionInfo.mainClass);
        Method method = clazz.getMethod("main", String[].class);
        method.invoke(null, new Object[]{launchArgs});
    }

    public static String[] getMinecraftArgs(MinecraftAccount profile, JMinecraftVersionList.Version versionInfo, String serverIp) {
        String username = profile.username.replace("Demo.", "");
        String versionName = versionInfo.id;
        if (versionInfo.inheritsFrom != null) {
            versionName = versionInfo.inheritsFrom;
        }

        File gameDir = new File(Tools.DIR_GAME_PROFILE);
        gameDir.mkdirs();
        // 确保 logs 目录存在，防止 Log4j RollingRandomAccessFileAppender
        // 因 logs/latest.log 路径不存在而抛出 FileNotFoundException
        new File(gameDir, "logs").mkdirs();

        Map<String, String> varArgMap = new ArrayMap<String, String>();
        varArgMap.put("auth_session", profile.accessToken); // For legacy versions of MC
        varArgMap.put("auth_access_token", profile.accessToken);
        varArgMap.put("auth_player_name", username);
        varArgMap.put("auth_uuid", profile.profileId.replace("-", ""));
        varArgMap.put("auth_xuid", profile.xuid);
        varArgMap.put("assets_root", Tools.ASSETS_PATH);
        varArgMap.put("assets_index_name", versionInfo.assets);
        varArgMap.put("clientid", profile.clientToken);
        varArgMap.put("game_assets", Tools.ASSETS_PATH);
        varArgMap.put("game_directory", gameDir.getAbsolutePath());
        varArgMap.put("user_properties", "{}");
        varArgMap.put("user_type", "mojang");
        varArgMap.put("version_name", versionName);
        varArgMap.put("version_type", versionInfo.type);
        varArgMap.put("natives_directory", System.getProperty("java.library.path"));

        List<String> minecraftArgs = new ArrayList<String>();
        if (versionInfo.arguments != null) {
            // Support Minecraft 1.13+
            // 检测当前账户是否为第三方认证账户（authlib-injector / Yggdrasil）
            // 第三方账户的特征：clientToken 非 "0" 且 xuid 为 null 或 "0"
            // （Microsoft 账户有 xuid，本地账户 clientToken 为 "0"）
            // 对第三方账户，即使版本 JSON 含 --xuid 参数，user_type 也必须保持 "mojang"
            // 而不能改为 "msa"，否则 Minecraft 26.x 内部会按 MSA 流程处理
            // 导致认证失败（无法加载皮肤 / 无法加入服务器 / 崩溃）
            boolean isThirdPartyAccount = !"0".equals(profile.clientToken)
                && (profile.xuid == null || "0".equals(profile.xuid));
            for (Object arg : versionInfo.arguments.game) {
                if (arg instanceof String) {
                    minecraftArgs.add((String) arg);
                    if (arg.equals("--xuid") && !isThirdPartyAccount) {
                        // 仅对 Microsoft 账户（有 xuid）设置 user_type=msa
                        // 第三方账户保持 "mojang"，避免 26.x 认证流程错误
                        varArgMap.put("user_type", "msa");
                    }
                } else {
                    /*
                    JMinecraftVersionList.Arguments.ArgValue argv = (JMinecraftVersionList.Arguments.ArgValue) arg;
                    if (argv.values != null) {
                        minecraftArgs.add(argv.values[0]);
                    } else {
                        
                         for (JMinecraftVersionList.Arguments.ArgValue.ArgRules rule : arg.rules) {
                         // rule.action = allow
                         // TODO implement this
                         }
                         
                    }
                    */
                }
            }
        }
        String[] argsFromJson = JSONUtils.insertJSONValueList(
            splitAndFilterEmpty(
                versionInfo.minecraftArguments == null ?
                fromStringArray(minecraftArgs.toArray(new String[0])):
                versionInfo.minecraftArguments,
                profile
            ), varArgMap
        );

        // FCL 风格：启动后自动加入服务器。serverIp 为空时不追加任何参数，
        // 行为与原启动流程完全一致。版本判定使用解析后的基础 MC 版本号
        // （versionName 优先取 inheritsFrom，避免 modded 版本 id 干扰比较）
        argsFromJson = appendServerArgs(argsFromJson, serverIp, versionName);

        // Tools.dialogOnUiThread(this, "Result args", Arrays.asList(argsFromJson).toString());
        return argsFromJson;
    }

    /**
     * 根据 serverIp 和 MC 版本追加服务器加入参数（FCL/ZL2 风格）。
     * - MC < 1.20：--server <host> --port <port>（端口缺省补 25565）
     * - MC >= 1.20：--quickPlayMultiplayer <host:port>（端口缺省补 :25565）
     * - 地址格式：host / host:port / [ipv6]:port
     * - 解析失败仅告警不加入，不抛出异常
     * - serverIp 为 null 或空字符串时直接返回原参数
     */
    private static String[] appendServerArgs(String[] args, String serverIp, String versionId) {
        if (serverIp == null || serverIp.isEmpty()) {
            return args;
        }
        String trimmed = serverIp.trim();
        if (trimmed.isEmpty()) {
            return args;
        }

        String host = null;
        String port = "25565"; // 默认端口

        // 地址解析：支持 host / host:port / [ipv6]:port
        if (trimmed.startsWith("[")) {
            // IPv6 形如 [::1]:25565 或 [::1]
            int close = trimmed.indexOf("]");
            if (close <= 0) {
                System.err.println("[Tools] Invalid server address (unterminated IPv6 bracket): " + serverIp);
                return args;
            }
            host = trimmed.substring(1, close);
            if (close + 1 < trimmed.length()) {
                // 括号后应跟 :port
                String rest = trimmed.substring(close + 1);
                if (rest.startsWith(":")) {
                    String portStr = rest.substring(1);
                    if (!portStr.isEmpty()) {
                        port = portStr;
                    }
                } else if (!rest.isEmpty()) {
                    System.err.println("[Tools] Invalid server address (unexpected chars after IPv6 bracket): " + serverIp);
                    return args;
                }
            }
        } else {
            // 普通地址：以最后一个 : 分割端口
            int lastColon = trimmed.lastIndexOf(":");
            if (lastColon > 0) {
                host = trimmed.substring(0, lastColon);
                String portStr = trimmed.substring(lastColon + 1);
                if (!portStr.isEmpty()) {
                    port = portStr;
                }
            } else {
                host = trimmed;
            }
        }

        if (host == null || host.isEmpty()) {
            System.err.println("[Tools] Invalid server address (empty host): " + serverIp);
            return args;
        }

        List<String> argList = new ArrayList<String>(Arrays.asList(args));
        // 版本判定：MC < 1.20 用 --server/--port，MC >= 1.20 用 --quickPlayMultiplayer
        if (versionId.compareTo("1.20") < 0) {
            argList.add("--server");
            argList.add(host);
            argList.add("--port");
            argList.add(port);
            System.out.println("[Tools] Auto-join server (legacy): " + host + ":" + port);
        } else {
            argList.add("--quickPlayMultiplayer");
            argList.add(host + ":" + port);
            System.out.println("[Tools] Auto-join server (quickPlay): " + host + ":" + port);
        }
        return argList.toArray(new String[0]);
    }

    public static String fromStringArray(String[] strArr) {
        StringBuilder builder = new StringBuilder();
        for (int i = 0; i < strArr.length; i++) {
            if (i > 0) builder.append(" ");
            builder.append(strArr[i]);
        }

        return builder.toString();
    }

    private static String[] splitAndFilterEmpty(String argStr, MinecraftAccount profile) {
        List<String> strList = new ArrayList<String>();
        if(profile.username.startsWith("Demo.")) {
            strList.add("--demo");
        }
        for (String arg : argStr.split(" ")) {
            if (!arg.isEmpty()) {
                strList.add(arg);
            }
        }
        return strList.toArray(new String[0]);
    }

    public static String artifactToPath(DependentLibrary library) {
        if (library.downloads != null &&
            library.downloads.artifact != null &&
            library.downloads.artifact.path != null)
            return library.downloads.artifact.path;
        String[] libInfos = library.name.split(":");
        // ★ [DEMINE] 原为 libInfos[1]/[2] 直接下标：库名不足三段(非标准 Maven 坐标)时
        //   ArrayIndexOutOfBoundsException 会冒泡到 main 线程 ⇒ 未捕获处理器 System.exit(1) 杀掉 App。
        if (libInfos.length < 3) {
            System.err.println("[DEMINE] artifactToPath: non-3-part library name: " + library.name);
            return library.name.replaceAll("\\.", "/") + ".jar";
        }
        return libInfos[0].replaceAll("\\.", "/") + "/" + libInfos[1] + "/" + libInfos[2] + "/" + libInfos[1] + "-" + libInfos[2] + ".jar";
    }

/*
    private static String getLWJGL3ClassPath() {
        StringBuilder libStr = new StringBuilder();
        File lwjgl3Folder = new File(Tools.DIR_GAME_NEW, "lwjgl3");
        if (/* info.arguments != null && @lwjgl3Folder.exists()) {
            for (File file: lwjgl3Folder.listFiles()) {
                if (file.getName().endsWith(".jar")) {
                    libStr.append(file.getAbsolutePath() + ":");
                }
            }
            // Remove the ':' at the end
            libStr.setLength(libStr.length() - 1);
        }
        return libStr.toString();
    }
*/
    public static String generateLaunchClassPath(JMinecraftVersionList.Version info) {
        StringBuilder libStr = new StringBuilder(); //versnDir + "/" + version + "/" + version + ".jar:";

        String[] classpath = generateLibClasspath(info);

        // Debug: LWJGL 3 override
        // File lwjgl2Folder = new File(Tools.MAIN_PATH, "lwjgl2");

        /*
         File lwjgl3Folder = new File(Tools.MAIN_PATH, "lwjgl3");
         if (lwjgl3Folder.exists()) {
         for (File file: lwjgl3Folder.listFiles()) {
         if (file.getName().endsWith(".jar")) {
         libStr.append(file.getAbsolutePath() + ":");
         }
         }
         } else if (lwjgl2Folder.exists()) {
         for (File file: lwjgl2Folder.listFiles()) {
         if (file.getName().endsWith(".jar")) {
         libStr.append(file.getAbsolutePath() + ":");
         }
         }
         }
         */

        for (String perJar : classpath) {
            if (!new File(perJar).exists()) {
                System.out.println("Ignored non-exists file: " + perJar);
                continue;
            }
            libStr.append(perJar + ":");
        }
        libStr.append(DIR_HOME_VERSION + "/" + info.id + "/" + info.id + ".jar");

        return libStr.toString();
    }
    
    public static void moveInside(String from, String to) {
        File fromFile = new File(from);
        for (File fromInside : fromFile.listFiles()) {
            moveRecursive(fromInside.getAbsolutePath(), to);
        }
        fromFile.delete();
    }

    public static void moveRecursive(String from, String to) {
        moveRecursive(new File(from), new File(to));
    }

    public static void moveRecursive(File from, File to) {
        File toFrom = new File(to, from.getName());
        try {
            if (from.isDirectory()) {
                for (File child : from.listFiles()) {
                    moveRecursive(child, toFrom);
                }
            }
        } finally {
            from.getParentFile().mkdirs();
            from.renameTo(toFrom);
        }
    }

    public static void preProcessLibraries(DependentLibrary[] libraries) {
        // Ignore some libraries since they are unsupported (jinput, text2speech) or unused (LWJGL)
        // Support for text2speech is not planned, so skip it for now.
        for (int i = 0; i < libraries.length; i++) {
            DependentLibrary libItem = libraries[i];
            if (libItem.name.startsWith("com.mojang:text2speech") ||
                //libItem.name.startsWith("net.java.jinput") ||
                libItem.name.startsWith("net.java.dev.jna:platform:") ||
                libItem.name.startsWith("org.lwjgl") ||
                libItem.name.startsWith("tv.twitch")) {
                    libItem._skip = true;
                    continue;
            }

            // ★ [DEMINE] 原为 libItem.name.split(":")[2] 直接下标：库名不足三段时
            //   ArrayIndexOutOfBoundsException 冒泡到 main ⇒ System.exit(1) 杀掉 App。缺段则跳过该库。
            String[] libNameParts = libItem.name.split(":");
            if (libNameParts.length < 3) {
                System.err.println("[DEMINE] preProcessLibraries: non-3-part library name: " + libItem.name);
                continue;
            }
            String[] version = libNameParts[2].split("\\.");
            if (libItem.name.startsWith("net.java.dev.jna:jna:")) {
                // 强制将 JNA 替换为 5.13.0 以保证 iOS 兼容性。
                // MC 26.3+ 要求 JNA 5.17.0，但其 darwin-aarch64 libjnidispatch 在 iOS 上
                // 加载 IOKit/CoreFoundation 后会导致 native crash/卡死（26.2 + JNA 5.13.0 正常）。
                // MC 不直接使用 JNA API（通过 oshi 间接使用），5.13.0 的 API 完全兼容。
                // PatchJNAAgent 会替换 Platform.class，与 JNA jar 版本无关。
                if (Integer.parseInt(version[0]) == 5 && Integer.parseInt(version[1]) == 13 && Integer.parseInt(version[2]) == 0) continue;
                System.out.println("[Tools] Replacing JNA " + version[0] + "." + version[1] + "." + version[2] + " with 5.13.0 for iOS compatibility");

createLibraryInfo(libItem);
                libItem.name = "net.java.dev.jna:jna:5.13.0";
                libItem.downloads.artifact.path = "net/java/dev/jna/jna/5.13.0/jna-5.13.0.jar";
                libItem.downloads.artifact.url = "https://libraries.minecraft.net/net/java/dev/jna/jna/5.13.0/jna-5.13.0.jar";
            } else if (libItem.name.startsWith("org.ow2.asm:asm-all:")) {
                if(Integer.parseInt(version[0]) >= 5) continue;
                //System.out.println("Library " + libItem.name + " has been changed to version 5.0.4");
                createLibraryInfo(libItem);
                libItem.name = "org.ow2.asm:asm-all:5.0.4";
                libItem.url = null;
                libItem.downloads.artifact.path = "org/ow2/asm/asm-all/5.0.4/asm-all-5.0.4.jar";
                libItem.downloads.artifact.sha1 = "e6244859997b3d4237a552669279780876228909";
                libItem.downloads.artifact.url = "https://repo1.maven.org/maven2/org/ow2/asm/asm-all/5.0.4/asm-all-5.0.4.jar";
            }
        }
    }

    private static void createLibraryInfo(DependentLibrary library) {
        if(library.downloads == null || library.downloads.artifact == null)
            library.downloads = new DependentLibrary.LibraryDownloads(new MinecraftLibraryArtifact());
    }

    public static String[] generateLibClasspath(JMinecraftVersionList.Version info) {
        List<String> libDir = new ArrayList<String>();

        preProcessLibraries(info.libraries);
        for (DependentLibrary libItem : info.libraries) {
            if (libItem._skip) continue;
            String fullPath = Tools.DIR_HOME_LIBRARY + "/" + artifactToPath(libItem);
            if (!libDir.contains(fullPath)) {
                libDir.add(fullPath);
            }
        }
        return libDir.toArray(new String[0]);
    }

    public static JMinecraftVersionList.Version getVersionInfo(String versionName) {
        try {
            JMinecraftVersionList.Version customVer = Tools.GLOBAL_GSON.fromJson(read(DIR_HOME_VERSION + "/" + versionName + "/" + versionName + ".json"), JMinecraftVersionList.Version.class);
            if (customVer.inheritsFrom == null || customVer.inheritsFrom.equals(customVer.id)) {
                return customVer;
            } else {
                JMinecraftVersionList.Version inheritsVer = Tools.GLOBAL_GSON.fromJson(read(DIR_HOME_VERSION + "/" + customVer.inheritsFrom + "/" + customVer.inheritsFrom + ".json"), JMinecraftVersionList.Version.class);
                inheritsVer.inheritsFrom = inheritsVer.id;
                
                insertSafety(inheritsVer, customVer,
                             "assetIndex", "assets", "id",
                             "mainClass", "minecraftArguments",
                             "releaseTime", "time", "type"
                             );

                // Go through the libraries, remove the ones overridden by the custom version
                List<DependentLibrary> inheritLibraryList = new ArrayList<>(Arrays.asList(inheritsVer.libraries));
                outer_loop:
                for(DependentLibrary library : customVer.libraries){
                    // Clean libraries overridden by the custom version
                    // ★ [DEMINE] 无冒号时 lastIndexOf 返回 -1 ⇒ substring(0,-1) 抛
                    //   StringIndexOutOfBoundsException 冒泡到 main ⇒ System.exit(1)。缺冒号则用全名。
                    int libColonIdx = library.name.lastIndexOf(":");
                    String libName = libColonIdx >= 0 ? library.name.substring(0, libColonIdx) : library.name;

                    for(DependentLibrary inheritLibrary : inheritLibraryList) {
                        // ★ [DEMINE] 同上。
                        int inheritColonIdx = inheritLibrary.name.lastIndexOf(":");
                        String inheritLibName = inheritColonIdx >= 0 ? inheritLibrary.name.substring(0, inheritColonIdx) : inheritLibrary.name;

                        if(libName.equals(inheritLibName)){
                            System.out.println("Library " + libName + ": Replaced version " +
                                    libName.substring(libName.lastIndexOf(":") + 1) + " with " +
                                    inheritLibName.substring(inheritLibName.lastIndexOf(":") + 1));

                            // Remove the library , superseded by the overriding libs
                            inheritLibraryList.remove(inheritLibrary);
                            continue outer_loop;
                        }
                    }
                }

                // Fuse libraries
                inheritLibraryList.addAll(Arrays.asList(customVer.libraries));
                inheritsVer.libraries = inheritLibraryList.toArray(new DependentLibrary[0]);
                preProcessLibraries(inheritsVer.libraries);

                // Inheriting Minecraft 1.13+ with append custom args
                if (inheritsVer.arguments != null && customVer.arguments != null) {
                    List totalArgList = new ArrayList();
                    totalArgList.addAll(Arrays.asList(inheritsVer.arguments.game));
                    
                    int nskip = 0;
                    for (int i = 0; i < customVer.arguments.game.length; i++) {
                        if (nskip > 0) {
                            nskip--;
                            continue;
                        }
                        
                        Object perCustomArg = customVer.arguments.game[i];
                        if (perCustomArg instanceof String) {
                            String perCustomArgStr = (String) perCustomArg;
                            // Check if there is a duplicate argument on combine
                            if (perCustomArgStr.startsWith("--") && totalArgList.contains(perCustomArgStr)) {
                                // ★ [DEMINE] i 为末元素时 game[i+1] 越界 ArrayIndexOutOfBoundsException
                                //   冒泡到 main ⇒ System.exit(1) 杀掉 App。越界则跳过该参数。
                                if (i + 1 >= customVer.arguments.game.length) {
                                    continue;
                                }
                                perCustomArg = customVer.arguments.game[i + 1];
                                if (perCustomArg instanceof String) {
                                    perCustomArgStr = (String) perCustomArg;
                                    // If the next is argument value, skip it
                                    if (!perCustomArgStr.startsWith("--")) {
                                        nskip++;
                                    }
                                }
                            } else {
                                totalArgList.add(perCustomArgStr);
                            }
                        } else if (!totalArgList.contains(perCustomArg)) {
                            totalArgList.add(perCustomArg);
                        }
                    }

                    inheritsVer.arguments.game = totalArgList.toArray(new Object[0]);
                }

                return inheritsVer;
            }
        } catch (Exception e) {
            throw new RuntimeException(e);
        }
    }

    // Prevent NullPointerException
    private static void insertSafety(JMinecraftVersionList.Version targetVer, JMinecraftVersionList.Version fromVer, String... keyArr) {
        for (String key : keyArr) {
            Object value = null;
            try {
                Field fieldA = fromVer.getClass().getField(key);
                value = fieldA.get(fromVer);
                if (((value instanceof String) && !((String) value).isEmpty()) || value != null) {
                    Field fieldB = targetVer.getClass().getField(key);
                    fieldB.set(targetVer, value);
                }
            } catch (Throwable th) {
                System.err.println("Unable to insert " + key + "=" + value);
                th.printStackTrace();
            }
        }
    }
    
    public static String convertStream(InputStream inputStream) throws IOException {
        return convertStream(inputStream, Charset.forName("UTF-8"));
    }
    
    public static String convertStream(InputStream inputStream, Charset charset) throws IOException {
        String out = "";
        int len;
        byte[] buf = new byte[512];
        while((len = inputStream.read(buf))!=-1) {
            out += new String(buf,0,len,charset);
        }
        return out;
    }

    public static void copy(final InputStream input, final OutputStream output) throws IOException {
        final byte[] buffer = new byte[8192];
        int n = 0;
        while ((n = input.read(buffer)) != -1) {
            output.write(buffer, 0, n);
        }
    }

    public static File lastFileModified(String dir) {
        File fl = new File(dir);

        File[] files = fl.listFiles(new FileFilter() {
                public boolean accept(File file) {
                    return file.isFile();
                }
            });

        long lastMod = Long.MIN_VALUE;
        File choice = null;
        for (File file : files) {
            if (file.lastModified() > lastMod) {
                choice = file;
                lastMod = file.lastModified();
            }
        }

        return choice;
    }

    public static String read(InputStream is) throws IOException {
        String out = "";
        int len;
        byte[] buf = new byte[512];
        while((len = is.read(buf))!=-1) {
            out += new String(buf,0,len);
        }
        return out;
    }

    public static String read(String path) throws IOException {
        return read(new FileInputStream(path));
    }

    public static void write(String path, byte[] content) throws IOException
    {
        File outPath = new File(path);
        outPath.getParentFile().mkdirs();
        outPath.createNewFile();

        BufferedOutputStream fos = new BufferedOutputStream(new FileOutputStream(path));
        fos.write(content, 0, content.length);
        fos.close();
    }

    public static void write(String path, String content) throws IOException {
        write(path, content.getBytes());
    }
}
