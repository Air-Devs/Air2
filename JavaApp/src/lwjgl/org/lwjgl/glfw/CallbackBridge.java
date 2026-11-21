package org.lwjgl.glfw;
import java.util.*;

public class CallbackBridge {
    public static final int CLIPBOARD_COPY = 2000;
    public static final int CLIPBOARD_PASTE = 2001;
    
    public static final int EVENT_TYPE_CHAR = 1000;
    public static final int EVENT_TYPE_CHAR_MODS = 1001;
    public static final int EVENT_TYPE_CURSOR_ENTER = 1002;
    public static final int EVENT_TYPE_CURSOR_POS = 1003;
    public static final int EVENT_TYPE_FRAMEBUFFER_SIZE = 1004;
    public static final int EVENT_TYPE_KEY = 1005;
    public static final int EVENT_TYPE_MOUSE_BUTTON = 1006;
    public static final int EVENT_TYPE_SCROLL = 1007;
    public static final int EVENT_TYPE_WINDOW_SIZE = 1008;
    
    public static final int ANDROID_TYPE_GRAB_STATE = 0;
    
    public static final boolean INPUT_DEBUG_ENABLED;
    
    // TODO send grab state event to Android
    
    static {
        INPUT_DEBUG_ENABLED = Boolean.parseBoolean(System.getProperty("glfwstub.debugInput", "false"));

        
/*
        if (isDebugEnabled) {
            //try {
                //debugEventStream = new PrintStream(new File(System.getProperty("user.dir"), "glfwstub_inputeventlog.txt"));
		    debugEventStream = System.out;
            //} catch (FileNotFoundException e) {
            //    e.printStackTrace();
            //}
        }
	
	    //Quick and dirty: debul all key inputs to System.out
*/
    }

    public static native String nativeClipboard(int action, byte[] copy);
    public static native void nativeSetGrabbing(boolean grab);

    /**
     * 显式同步 MC 1.21.9+ 内部的 modifier 缓存。
     *
     * 背景（issue #27，参照 FCL commit 08c0716 修复）：
     *   MC 1.21.9+ 不再仅依赖 key 回调中的 mods 参数，而是通过
     *   InputConstants.isKeyDown(window, GLFW_KEY_LEFT_SHIFT) 等查询当前 modifier 状态。
     *   该状态由 MC 自己维护在一个独立缓存中，只有显式 setModifiers 才能更新，
     *   单纯调用 glfwSetKeyCallback 回调不足以让其生效。
     *
     * 本方法由 native 端 CallbackBridge_nativeSetModifiers 调用，
     * 通过 JNI 反射调用 MC 的 InputConstants 缓存更新接口（与 FCL 实现一致）。
     */
    public static native void nativeSetModifiers(int mods);
}
