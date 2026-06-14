/**
 * FKZ API - Global state
 *
 * Shared config, cached server info and per-client tracking data.
 * Included first so all globals are declared before any function uses them.
 */

static char  g_apiUrl[256];
static char  g_apiKey[256];
static char  g_serverIp[64];
static char  g_tlsCAFile[PLATFORM_MAX_PATH];
static int   g_serverPort;
static float g_interval = 10.0;
static int   g_failCount;

enum struct GokzData
{
    char  mode[MODE_NAME_LEN];
    bool  timerRunning;
    bool  paused;
    float time;
    int   course;
    int   teleports;
}

static GokzData  g_gokzData[MAXPLAYERS + 1];
static float     g_connectTime[MAXPLAYERS + 1];

static Handle    g_reportTimer = INVALID_HANDLE;
static char      g_osName[16];
static int       g_successCount;

static char      g_cachedHostname[256];
static char      g_cachedVersion[256];
static char      g_cachedMMVersion[64];
static int       g_cachedTickrate;
static bool      g_cachedSecure;
static bool      g_cachedSecureAvailable;
static JSONArray g_cachedPlugins = null;
