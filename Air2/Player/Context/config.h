// Configuration macros
//
// 对应 cmake/config.h.in 的 configure_file 产物：CI 既不跑 cmake 也不注入
// CONFIG_* 变量，因此这里保留「全部未定义」的形态 —— 即 cmake 把
// #cmakedefine 展开成 /* #undef ... */ 注释的结果。
// 注意注释后面不能再跟值（"@CONFIG_BRANCH@" 之类），否则会变成裸 token 编不过。

/* #undef CONFIG_RELEASE */

#if !(CONFIG_RELEASE)
# define CONFIG_RELEASE 0
#endif

#if CONFIG_RELEASE
# define CONFIG_TYPE "release"
#else
# define CONFIG_TYPE "development"
#endif

#ifndef CONFIG_BRANCH
# define CONFIG_BRANCH "unknown"
#endif
#ifndef CONFIG_COMMIT
# define CONFIG_COMMIT "unknown"
#endif

#ifndef CONFIG_CURSEFORGE_API_KEY
# define CONFIG_CURSEFORGE_API_KEY nil
#endif
