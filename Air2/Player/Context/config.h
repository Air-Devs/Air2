// Configuration macros

/* #undef CONFIG_RELEASE */

#if !(CONFIG_RELEASE)
# define CONFIG_RELEASE 0
#endif
 
#if CONFIG_RELEASE
# define CONFIG_TYPE "release"
#else
# define CONFIG_TYPE "development"
#endif

/* #undef CONFIG_BRANCH */
/* #undef CONFIG_COMMIT */
/* ★CI★ 这两行原本是 CMake 配置占位（"@CONFIG_BRANCH@" / "@CONFIG_COMMIT@"），
   但仓库里没有跑 configure 这一步 ⇒ 编译直接报 expected identifier or '('。
   保留下面的 #ifndef 兜底（"unknown"），语义不变。 */

#ifndef CONFIG_BRANCH
# define CONFIG_BRANCH "unknown"
#endif
#ifndef CONFIG_COMMIT
# define CONFIG_COMMIT "unknown"
#endif

/* #undef CONFIG_CURSEFORGE_API_KEY */ "@CONFIG_CURSEFORGE_API_KEY@"

#ifndef CONFIG_CURSEFORGE_API_KEY 
# define CONFIG_CURSEFORGE_API_KEY nil
#endif

