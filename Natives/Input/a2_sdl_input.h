// a2_sdl_input.h —— 26.3 输入镜像桥（控件/手势事件 → SDL 事件队列）
#ifndef A2_SDL_INPUT_H
#define A2_SDL_INPUT_H

/// 指针位置（逻辑点，屏幕坐标）
void a2_sdl_input_cursor(double x, double y);
/// 鼠标键：button 用 GLFW 编号（0=左 1=右）
void a2_sdl_input_button(int button, int down);
/// 键盘：glfwKey 用 GLFW 键码
void a2_sdl_input_key(int glfwKey, int down);
/// 是否可用（26.3 才有 SdlInputBridge；其它版本返回 0）
int  a2_sdl_input_active(void);

#endif
