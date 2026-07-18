// Valeurs compilées au build time via -D dans build_app.sh.
// Exposée via AppVersion.gitCount / AppVersion.gitSha.

#if APP_GIT_COUNT
let _gitCount = APP_GIT_COUNT
#elseif APP_GIT_SHA
let _gitCount = "0"
#else
let _gitCount = "0"
#endif

#if APP_GIT_SHA
let _gitSha = APP_GIT_SHA
#else
let _gitSha = ""
#endif
