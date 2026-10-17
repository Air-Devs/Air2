package net.kdt.pojavlaunch.tools;

import com.google.gson.Gson;
import com.google.gson.GsonBuilder;
import com.google.gson.annotations.SerializedName;

import java.io.BufferedInputStream;
import java.io.File;
import java.io.FileInputStream;
import java.io.FileOutputStream;
import java.io.IOException;
import java.io.InputStream;
import java.io.OutputStreamWriter;
import java.io.Writer;
import java.lang.reflect.InvocationTargetException;
import java.lang.reflect.Method;
import java.net.URL;
import java.net.URLClassLoader;
import java.nio.charset.StandardCharsets;
import java.security.MessageDigest;
import java.util.ArrayList;
import java.util.Arrays;
import java.util.List;
import java.util.Map;

/**
 * Headless processor runner for the new-format Forge / NeoForge direct installer.
 *
 * The iOS app cannot fork()/exec() a child JVM, so install_profile.json processors
 * (binarypatcher, jarsplitter, FART, jst, ...) are executed in-process via JLI_Launch
 * with this class as the main class, mimicking what the official installer does with
 * its IsolatedClassLoader.
 *
 * Input contract (written by ForgeProcessorExecutor.m):
 *   args[0] = commands.json : [
 *     {
 *       "name":      "human readable step name",
 *       "mainClass": "net.minecraftforge.installertools.ConsoleTool",
 *       "classpath": ["/abs/path/a.jar", ...],     // full processor classpath
 *       "args":      ["--task", ..., ...],         // literal arguments
 *       "outputs":   {"/abs/path/out.jar": "sha1"} // artifacts to verify
 *     }, ...
 *   ]
 *
 *   args[1] = status.json : written after every step for ObjC-side progress polling:
 *     { "ok": true, "completed": 2, "total": 7, "current": "..." }
 *     { "ok": false, "completed": 2, "total": 7, "current": "...",
 *       "error": "...", "failedCommand": "..." }
 *
 * Notes:
 *  - Never calls System.exit(); main() returns normally so JLI_Launch can return
 *    cleanly and the ObjC caller reads the terminal status.json.
 *  - Each processor runs in its own URLClassLoader whose parent is the *platform*
 *    class loader (not the app class loader). This mirrors the official installer's
 *    IsolatedClassLoader: bundle libs (gson/guava/...) never leak into, nor
 *    overshadow, the processor's own declared classpath.
 *  - Processors whose outputs already exist with matching sha1 are skipped
 *    (resume support, aligned with ZL2/HMCL).
 */
public final class ForgeProcessorRunner {

    private ForgeProcessorRunner() {
    }

    /** One processor command, parsed from commands.json. */
    @SuppressWarnings("unused") // fields are populated by Gson
    private static final class Command {
        @SerializedName("name")
        String name;
        @SerializedName("mainClass")
        String mainClass;
        @SerializedName("classpath")
        List<String> classpath;
        @SerializedName("args")
        List<String> args;
        @SerializedName("outputs")
        Map<String, String> outputs;
    }

    /** status.json model. Null fields are omitted by Gson. */
    @SuppressWarnings("unused")
    private static final class Status {
        @SerializedName("ok")
        boolean ok;
        @SerializedName("completed")
        int completed;
        @SerializedName("total")
        int total;
        @SerializedName("current")
        String current;
        @SerializedName("error")
        String error;
        @SerializedName("failedCommand")
        String failedCommand;
    }

    private static final Gson GSON = new GsonBuilder().disableHtmlEscaping().create();

    public static void main(String[] args) {
        if (args == null || args.length < 2) {
            System.err.println("[ForgeProcessorRunner] Usage: ForgeProcessorRunner <commands.json> <status.json>");
            return;
        }
        File commandsFile = new File(args[0]);
        File statusFile = new File(args[1]);

        Status status = new Status();
        status.ok = false;
        status.total = 0;
        status.completed = 0;
        status.current = "";

        try {
            Command[] commands = readCommands(commandsFile);
            status.total = commands.length;
            status.ok = true;
            writeStatus(statusFile, status);

            for (Command command : commands) {
                String displayName = command.name != null && !command.name.isEmpty()
                        ? command.name : command.mainClass;
                status.current = displayName;
                writeStatus(statusFile, status);

                // Skip commands whose outputs are already present and valid (resume).
                if (outputsSatisfied(command)) {
                    System.out.println("[ForgeProcessorRunner] Skipping " + displayName
                            + " (all outputs already present)");
                    status.completed++;
                    writeStatus(statusFile, status);
                    continue;
                }

                try {
                    runCommand(command);
                } catch (Throwable t) {
                    status.ok = false;
                    status.error = describeThrowable(t);
                    status.failedCommand = displayName;
                    writeStatus(statusFile, status);
                    System.err.println("[ForgeProcessorRunner] Processor failed: " + displayName);
                    System.err.println(status.error);
                    return;
                }

                String mismatch = verifyOutputs(command);
                if (mismatch != null) {
                    status.ok = false;
                    status.error = mismatch;
                    status.failedCommand = displayName;
                    writeStatus(statusFile, status);
                    System.err.println("[ForgeProcessorRunner] Output verification failed: " + displayName);
                    System.err.println(mismatch);
                    return;
                }

                status.completed++;
                writeStatus(statusFile, status);
            }

            status.current = "";
            writeStatus(statusFile, status);
            System.out.println("[ForgeProcessorRunner] All " + status.total + " processor(s) finished");
        } catch (Throwable t) {
            // Fatal error (unreadable commands.json, interrupted IO, ...)
            status.ok = false;
            if (status.error == null) {
                status.error = describeThrowable(t);
            }
            writeStatusQuietly(statusFile, status);
            System.err.println("[ForgeProcessorRunner] Fatal: " + status.error);
        }
    }

    private static Command[] readCommands(File file) throws IOException {
        if (!file.isFile()) {
            throw new IOException("commands.json not found: " + file.getAbsolutePath());
        }
        Command[] commands = GSON.fromJson(readUtf8File(file), Command[].class);
        if (commands == null) {
            commands = new Command[0];
        }
        return commands;
    }

    /** Loads the processor main class in an isolated class loader and invokes main(). */
    private static void runCommand(Command command) throws Exception {
        if (command.mainClass == null || command.mainClass.isEmpty()) {
            throw new IOException("Command is missing mainClass");
        }

        List<URL> urls = new ArrayList<URL>();
        if (command.classpath != null) {
            for (String path : command.classpath) {
                File file = new File(path);
                if (!file.isFile()) {
                    throw new IOException("Processor classpath entry missing: " + path);
                }
                urls.add(file.toURI().toURL());
            }
        }

        String[] procArgs = command.args == null
                ? new String[0] : command.args.toArray(new String[0]);

        System.out.println("[ForgeProcessorRunner] Running " + command.mainClass
                + " with " + urls.size() + " classpath entries, args=" + Arrays.toString(procArgs));

        // Parent = platform class loader (parent of the app class loader), mirroring the
        // official Forge installer's IsolatedClassLoader: the app classpath (bundle libs
        // such as gson/guava) is intentionally NOT visible to processors.
        URLClassLoader loader = new URLClassLoader(urls.toArray(new URL[0]),
                ClassLoader.getSystemClassLoader().getParent());
        try {
            Class<?> mainClass = loader.loadClass(command.mainClass);
            Method main = mainClass.getMethod("main", String[].class);
            main.invoke(null, (Object) procArgs);
        } catch (InvocationTargetException e) {
            // Unwrap the real processor exception; rethrow so the caller records it.
            Throwable cause = e.getCause() != null ? e.getCause() : e;
            throw new Exception("Processor " + command.mainClass + " threw: "
                    + describeThrowable(cause), cause);
        } catch (NoSuchMethodException e) {
            throw new Exception("Processor main class has no main(String[]): " + command.mainClass, e);
        } catch (ClassNotFoundException e) {
            throw new Exception("Processor main class not found on its classpath: "
                    + command.mainClass, e);
        } finally {
            try {
                loader.close();
            } catch (IOException ignored) {
            }
        }
    }

    /** @return true when every declared output exists and matches its sha1. */
    private static boolean outputsSatisfied(Command command) {
        if (command.outputs == null || command.outputs.isEmpty()) {
            return false; // nothing declared -> must run
        }
        for (Map.Entry<String, String> entry : command.outputs.entrySet()) {
            File file = new File(entry.getKey());
            if (!file.isFile()) {
                return false;
            }
            String actual = sha1(file);
            if (actual == null || !actual.equalsIgnoreCase(entry.getValue())) {
                return false;
            }
        }
        return true;
    }

    /**
     * Verifies outputs after execution. Corrupt files are deleted so a retry can
     * regenerate them.
     *
     * @return null on success, otherwise a human readable error message.
     */
    private static String verifyOutputs(Command command) {
        if (command.outputs == null || command.outputs.isEmpty()) {
            return null;
        }
        for (Map.Entry<String, String> entry : command.outputs.entrySet()) {
            File file = new File(entry.getKey());
            if (!file.isFile()) {
                return "Output missing after processor ran: " + entry.getKey();
            }
            String actual = sha1(file);
            if (actual == null) {
                return "Failed to hash output: " + entry.getKey();
            }
            if (!actual.equalsIgnoreCase(entry.getValue())) {
                // Delete the corrupt artifact so a retry regenerates it.
                if (!file.delete()) {
                    file.deleteOnExit();
                }
                return "Checksum mismatch for " + entry.getKey()
                        + ": expected " + entry.getValue() + ", got " + actual;
            }
        }
        return null;
    }

    private static String describeThrowable(Throwable t) {
        StringBuilder sb = new StringBuilder();
        sb.append(t.getClass().getName());
        if (t.getMessage() != null) {
            sb.append(": ").append(t.getMessage());
        }
        StackTraceElement[] trace = t.getStackTrace();
        int limit = Math.min(trace.length, 12);
        for (int i = 0; i < limit; i++) {
            sb.append("\n    at ").append(trace[i].toString());
        }
        if (t.getCause() != null && t.getCause() != t) {
            sb.append("\nCaused by ").append(describeThrowable(t.getCause()));
        }
        return sb.toString();
    }

    private static String sha1(File file) {
        InputStream in = null;
        try {
            MessageDigest digest = MessageDigest.getInstance("SHA-1");
            in = new BufferedInputStream(new FileInputStream(file), 65536);
            byte[] buffer = new byte[65536];
            int read;
            while ((read = in.read(buffer)) != -1) {
                digest.update(buffer, 0, read);
            }
            return toHex(digest.digest());
        } catch (Exception e) {
            return null;
        } finally {
            if (in != null) {
                try {
                    in.close();
                } catch (IOException ignored) {
                }
            }
        }
    }

    private static String toHex(byte[] bytes) {
        StringBuilder sb = new StringBuilder(bytes.length * 2);
        for (byte b : bytes) {
            sb.append(Character.forDigit((b >> 4) & 0xF, 16));
            sb.append(Character.forDigit(b & 0xF, 16));
        }
        return sb.toString();
    }

    private static String readUtf8File(File file) throws IOException {
        InputStream in = new FileInputStream(file);
        try {
            java.io.ByteArrayOutputStream out = new java.io.ByteArrayOutputStream();
            byte[] buffer = new byte[8192];
            int read;
            while ((read = in.read(buffer)) != -1) {
                out.write(buffer, 0, read);
            }
            return new String(out.toByteArray(), StandardCharsets.UTF_8);
        } finally {
            in.close();
        }
    }

    /**
     * Atomically rewrites status.json (write to .tmp then rename) so the ObjC side
     * never observes a half-written file while polling.
     */
    private static void writeStatus(File statusFile, Status status) throws IOException {
        Writer writer = null;
        File tmp = new File(statusFile.getAbsolutePath() + ".tmp");
        try {
            writer = new OutputStreamWriter(new FileOutputStream(tmp), StandardCharsets.UTF_8);
            GSON.toJson(status, writer);
            writer.flush();
        } finally {
            if (writer != null) {
                try {
                    writer.close();
                } catch (IOException ignored) {
                }
            }
        }
        if (!tmp.renameTo(statusFile)) {
            // Rename can fail on odd filesystems; fall back to a direct copy.
            copyFile(tmp, statusFile);
            tmp.delete();
        }
    }

    private static void writeStatusQuietly(File statusFile, Status status) {
        try {
            writeStatus(statusFile, status);
        } catch (IOException e) {
            System.err.println("[ForgeProcessorRunner] Failed to write status: " + e);
        }
    }

    private static void copyFile(File src, File dst) throws IOException {
        InputStream in = new FileInputStream(src);
        try {
            FileOutputStream out = new FileOutputStream(dst);
            try {
                byte[] buffer = new byte[8192];
                int read;
                while ((read = in.read(buffer)) != -1) {
                    out.write(buffer, 0, read);
                }
            } finally {
                out.close();
            }
        } finally {
            in.close();
        }
    }
}
