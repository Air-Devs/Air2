// Configuration macros

/* #undef CONFIG_RELEASE */ 1

#if !(CONFIG_RELEASE)
# define CONFIG_RELEASE 0
#endif
 
#if CONFIG_RELEASE
# define CONFIG_TYPE "release"
#else
# define CONFIG_TYPE "development"
#endif

/* #undef CONFIG_BRANCH */ "@CONFIG_BRANCH@"
/* #undef CONFIG_COMMIT */ "@CONFIG_COMMIT@"

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

