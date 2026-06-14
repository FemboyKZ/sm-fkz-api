/**
 * FKZ API
 *
 * Wrapper plugin for FKZ API natives/forwards
 * Status updater with GOKZ integration, sends live player and server data to FKZ API.
 *
 * Dependencies (required):
 *   - sm-ext-json (ProjectSky/sm-ext-json)
 *   - sm-ext-websocket (ProjectSky/sm-ext-websocket)
 *   - gokz-core
 *
 * Dependencies (optional):
 *   - SteamWorks (for VAC status detection)
 *
 * Configuration: addons/sourcemod/configs/fkz-api.cfg
 */

#include <sourcemod>
#include <json>
#include <websocket>
#include <gokz/core>

#undef REQUIRE_EXTENSIONS
#include <SteamWorks>
#define REQUIRE_EXTENSIONS

#pragma semicolon 1
#pragma newdecls required

#define PLUGIN_VERSION "2.1.1"
#define MODE_NAME_LEN 32

public Plugin myinfo =
{
	name = "FKZ-API",
	author = "jvnipers",
	description = "Exposes FKZ API fetch/send natives and tracks realtime player/server data.",
	version = PLUGIN_VERSION,
	url = "https://github.com/FemboyKZ/sm-fkz-api"
};

static char g_apiUrl[256];
static char g_apiKey[256];
static char g_serverIp[64];
static char g_tlsCAFile[PLATFORM_MAX_PATH];
static int g_serverPort;
static float g_interval = 10.0;
static int g_failCount;

enum struct GokzData
{
	char mode[MODE_NAME_LEN];
	bool timerRunning;
	bool paused;
	float time;
	int course;
	int teleports;
}

static GokzData g_gokzData[MAXPLAYERS + 1];
static float g_connectTime[MAXPLAYERS + 1];

static Handle g_reportTimer = INVALID_HANDLE;
static char g_osName[16];
static int g_successCount;

static char g_cachedHostname[256];
static char g_cachedVersion[256];
static char g_cachedMMVersion[64];
static int g_cachedTickrate;
static bool g_cachedSecure;
static bool g_cachedSecureAvailable;
static JSONArray g_cachedPlugins = null;

public void OnPluginStart()
{
	LoadConfig();

	if (g_apiUrl[0] == '\0')
	{
		LogMessage("[FKZ] No api_url configured, reporting disabled");
		return;
	}

	LogMessage("[FKZ] v%s loaded - reporting to %s every %.0fs (key=%s)",
		PLUGIN_VERSION, g_apiUrl, g_interval, g_apiKey[0] != '\0' ? "set" : "NOT SET");

	for (int i = 1; i <= MaxClients; i++)
	{
		if (IsClientConnected(i) && !IsFakeClient(i))
		{
			g_connectTime[i] = GetGameTime() - GetClientTime(i);
			if (IsClientInGame(i))
				UpdateGokzData(i);
		}
	}
}

public void OnMapStart()
{
	if (g_apiUrl[0] == '\0')
		return;

	CacheStaticServerInfo();

	StopReportTimer();
	g_reportTimer = CreateTimer(g_interval, Timer_Report, _, TIMER_REPEAT);

	CreateTimer(2.0, Timer_InitialReport);
}

public void OnClientPutInServer(int client)
{
	if (IsFakeClient(client))
		return;

	g_connectTime[client] = GetGameTime();
	ResetGokzData(client);
}

public void OnClientDisconnect(int client)
{
	if (!IsFakeClient(client))
	{
		int humans = 0;
		for (int i = 1; i <= MaxClients; i++)
		{
			if (i != client && IsClientConnected(i) && !IsFakeClient(i))
			{
				humans++;
				break;
			}
		}
		if (humans == 0)
			SendHibernate();
	}

	g_connectTime[client] = 0.0;
	ResetGokzData(client);
}

public int SteamWorks_SteamServersConnected()
{
	g_cachedSecureAvailable = true;
	g_cachedSecure = SteamWorks_IsVACEnabled();
	LogMessage("[FKZ] Steam connected, VAC status: %s", g_cachedSecure ? "secure" : "insecure");
	return 0;
}

public void GOKZ_OnTimerStart_Post(int client, int course)
{
	UpdateGokzData(client);
}

public void GOKZ_OnTimerEnd_Post(int client, int course, float time, int teleportsUsed)
{
	UpdateGokzData(client);
}

public void GOKZ_OnTimerStopped(int client)
{
	UpdateGokzData(client);
}

public void GOKZ_OnPause_Post(int client)
{
	UpdateGokzData(client);
}

public void GOKZ_OnResume_Post(int client)
{
	UpdateGokzData(client);
}

public void GOKZ_OnOptionChanged(int client, const char[] option, any newValue)
{
	if (StrEqual(option, "GOKZ - Mode"))
		UpdateGokzData(client);
}

public Action Timer_Report(Handle timer, any data)
{
	SendReport();
	return Plugin_Continue;
}

public Action Timer_InitialReport(Handle timer, any data)
{
	SendReport();
	return Plugin_Stop;
}

void SendHibernate()
{
	if (g_apiUrl[0] == '\0')
		return;

	JSONObject payload = new JSONObject();

	char ip[64];
	if (g_serverIp[0] != '\0')
		strcopy(ip, sizeof(ip), g_serverIp);
	else
	{
		int hostip = FindConVar("hostip").IntValue;
		FormatEx(ip, sizeof(ip), "%d.%d.%d.%d",
			(hostip >> 24) & 0xFF,
			(hostip >> 16) & 0xFF,
			(hostip >> 8) & 0xFF,
			hostip & 0xFF);
	}
	int port = g_serverPort > 0 ? g_serverPort : FindConVar("hostport").IntValue;

	payload.SetString("ip", ip);
	payload.SetInt("port", port);

	// POST to /servers/status/hibernate
	char url[512];
	FormatEx(url, sizeof(url), "%s/hibernate", g_apiUrl);

	HttpRequest req = new HttpRequest(url);
	req.Timeout = 5000;
	req.FollowRedirect = false;

	if (g_tlsCAFile[0] != '\0')
		req.SetTLSCAFile(g_tlsCAFile);

	if (g_apiKey[0] != '\0')
		req.SetBearerAuth(g_apiKey);

	bool sent = req.PostJson(payload, OnHibernateResponse);
	delete payload;

	if (!sent)
	{
		LogError("[FKZ] Failed to send hibernate signal to %s", url);
		delete req;
	}
	else
	{
		LogMessage("[FKZ] Sent hibernate signal (server empty)");
	}
}

void OnHibernateResponse(HttpRequest http, const char[] body, int statusCode, int bodySize, any value)
{
	if (statusCode != 200)
		LogError("[FKZ] Hibernate signal returned HTTP %d: %.256s", statusCode, body);
}

void SendReport()
{
	for (int i = 1; i <= MaxClients; i++)
	{
		if (IsClientInGame(i) && !IsFakeClient(i))
			UpdateGokzData(i);
	}

	JSONObject payload = BuildPayload();

	HttpRequest req = new HttpRequest(g_apiUrl);
	req.Timeout = 10000;
	req.KeepAlive = true;
	req.FollowRedirect = false;

	if (g_tlsCAFile[0] != '\0')
		req.SetTLSCAFile(g_tlsCAFile);

	if (g_apiKey[0] != '\0')
		req.SetBearerAuth(g_apiKey);

	bool sent = req.PostJson(payload, OnHttpResponse);
	delete payload;

	if (!sent)
	{
		LogError("[FKZ] Failed to dispatch request to %s", g_apiUrl);
		delete req;
	}
}

void OnHttpResponse(HttpRequest http, const char[] body, int statusCode, int bodySize, any value)
{
	if (statusCode == 200)
	{
		if (g_failCount > 0)
			LogMessage("[FKZ] POST recovered after %d failures", g_failCount);
		g_failCount = 0;
		g_successCount++;
		if (g_successCount == 1 || g_successCount % 30 == 0)
			LogMessage("[FKZ] POST OK (count=%d)", g_successCount);
	}
	else if (statusCode == 0)
	{
		g_failCount++;
		LogError("[FKZ] POST transport error to %s: %s (fail #%d)", g_apiUrl, body, g_failCount);
		LogError("[FKZ] Possible causes: DNS failure, connection refused, TLS/certificate error, or network unreachable");
		if (g_tlsCAFile[0] == '\0' && strncmp(g_apiUrl, "https", 5) == 0)
			LogError("[FKZ] HTTPS in use but no tls_ca_file set - Docker containers may lack system CA certs. Set tls_ca_file in config.");
	}
	else
	{
		g_failCount++;
		LogError("[FKZ] POST HTTP %d from %s: %.512s (fail #%d)", statusCode, g_apiUrl, body, g_failCount);
		if (statusCode >= 301 && statusCode <= 308)
			LogError("[FKZ] Redirect detected - update api_url in config to the final URL (e.g. https:// instead of http://)");
	}

	// Handle is freed by the extension after this callback returns.
}

void CacheStaticServerInfo()
{
	DetectOS();

	ConVar cvHostname = FindConVar("hostname");
	if (cvHostname != null)
		cvHostname.GetString(g_cachedHostname, sizeof(g_cachedHostname));
	else
		strcopy(g_cachedHostname, sizeof(g_cachedHostname), "unknown");

	// Game version ("version" is a command, not a ConVar)
	// Output format:
	//   Protocol version 13881 [1575/1575]
	//   Exe version 1.38.8.1 (csgo)
	//   Exe build: ...
	char versionBuf[512];
	ServerCommandEx(versionBuf, sizeof(versionBuf), "version");

	int pos = StrContains(versionBuf, "Exe version ");
	if (pos != -1)
	{
		pos += 12; // skip "Exe version "
		int out = 0;
		while (versionBuf[pos] != '\0' && versionBuf[pos] != ' ' && versionBuf[pos] != '\n' && versionBuf[pos] != '\r' && out < sizeof(g_cachedVersion) - 1)
		{
			g_cachedVersion[out++] = versionBuf[pos++];
		}
		g_cachedVersion[out] = '\0';
	}
	else
	{
		// Fallback: use first line
		strcopy(g_cachedVersion, sizeof(g_cachedVersion), versionBuf);
		int nl = FindCharInString(g_cachedVersion, '\n');
		if (nl != -1)
			g_cachedVersion[nl] = '\0';
		TrimString(g_cachedVersion);
	}

	g_cachedTickrate = RoundToNearest(1.0 / GetTickInterval());

	// Note: on first map load after server start, Steam may not be connected yet.
	g_cachedSecureAvailable = (GetFeatureStatus(FeatureType_Native, "SteamWorks_IsVACEnabled") == FeatureStatus_Available);
	if (g_cachedSecureAvailable)
		g_cachedSecure = SteamWorks_IsVACEnabled();

	ConVar cvMM = FindConVar("metamod_version");
	if (cvMM != null)
		cvMM.GetString(g_cachedMMVersion, sizeof(g_cachedMMVersion));
	else
		g_cachedMMVersion[0] = '\0';

	if (g_cachedPlugins != null)
		delete g_cachedPlugins;
	g_cachedPlugins = BuildPluginsArray();

	LogMessage("[FKZ] Cached static info: hostname=%s, version=%s, tickrate=%d", g_cachedHostname, g_cachedVersion, g_cachedTickrate);
}

JSONObject BuildPayload()
{
	JSONObject payload = new JSONObject();

	JSONObject server = BuildServerObject();
	payload.Set("server", server);
	delete server;

	JSONArray players = BuildPlayersArray();
	payload.Set("players", players);
	delete players;

	return payload;
}

JSONObject BuildServerObject()
{
	JSONObject server = new JSONObject();

	server.SetString("hostname", g_cachedHostname);
	server.SetString("os", g_osName);
	server.SetString("version", g_cachedVersion);
	server.SetInt("tickrate", g_cachedTickrate);

	if (g_cachedSecureAvailable)
		server.SetBool("secure", g_cachedSecure);
	else
		server.SetNull("secure");

	if (g_cachedMMVersion[0] != '\0')
		server.SetString("mm_version", g_cachedMMVersion);

	server.SetString("sm_version", SOURCEMOD_VERSION);
	server.SetBool("gokz_loaded", true);

	if (g_cachedPlugins != null)
	{
		server.Set("plugins", g_cachedPlugins);
	}

	char ip[64];
	if (g_serverIp[0] != '\0')
	{
		strcopy(ip, sizeof(ip), g_serverIp);
	}
	else
	{
		int hostip = FindConVar("hostip").IntValue;
		FormatEx(ip, sizeof(ip), "%d.%d.%d.%d",
			(hostip >> 24) & 0xFF,
			(hostip >> 16) & 0xFF,
			(hostip >> 8) & 0xFF,
			hostip & 0xFF);
	}
	server.SetString("ip", ip);

	int port = g_serverPort > 0 ? g_serverPort : FindConVar("hostport").IntValue;
	server.SetInt("port", port);

	char map[256];
	GetCurrentMap(map, sizeof(map));
	server.SetString("map", map);

	int playerCount = 0;
	int botCount = 0;
	for (int i = 1; i <= MaxClients; i++)
	{
		if (!IsClientConnected(i))
			continue;
		if (IsFakeClient(i))
		{
			botCount++;
			continue;
		}
		playerCount++;
	}
	server.SetInt("players", playerCount);
	server.SetInt("max_players", MaxClients);
	server.SetInt("bot_count", botCount);

	return server;
}

JSONArray BuildPlayersArray()
{
	JSONArray players = new JSONArray();

	for (int i = 1; i <= MaxClients; i++)
	{
		if (!IsClientConnected(i) || IsFakeClient(i))
			continue;

		JSONObject player = new JSONObject();

		char steamid[32];
		if (IsClientAuthorized(i))
			GetClientAuthId(i, AuthId_SteamID64, steamid, sizeof(steamid));
		else
			steamid[0] = '\0';
		player.SetString("steamid", steamid);

		char name[128];
		GetClientName(i, name, sizeof(name));
		player.SetString("name", name);

		char clientIp[64];
		GetClientIP(i, clientIp, sizeof(clientIp));
		player.SetString("ip", clientIp);

		float timeOnServer = 0.0;
		if (g_connectTime[i] > 0.0)
			timeOnServer = GetGameTime() - g_connectTime[i];
		player.SetFloat("time_on_server", timeOnServer);

		bool inGame = IsClientInGame(i);
		player.SetBool("in_game", inGame);

		if (inGame && g_gokzData[i].mode[0] != '\0')
		{
			JSONObject gokz = new JSONObject();
			gokz.SetString("mode", g_gokzData[i].mode);
			gokz.SetBool("timer_running", g_gokzData[i].timerRunning);
			gokz.SetBool("paused", g_gokzData[i].paused);
			gokz.SetFloat("time", g_gokzData[i].time);
			gokz.SetInt("course", g_gokzData[i].course);
			gokz.SetInt("teleports", g_gokzData[i].teleports);
			player.Set("gokz", gokz);
			delete gokz;
		}

		players.Push(player);
		delete player;
	}

	return players;
}

JSONArray BuildPluginsArray()
{
	JSONArray plugins = new JSONArray();

	Handle iter = GetPluginIterator();
	while (MorePlugins(iter))
	{
		Handle plugin = ReadPlugin(iter);
		PluginStatus pluginStatus = GetPluginStatus(plugin);
		if (pluginStatus != Plugin_Running && pluginStatus != Plugin_Paused)
			continue;

		JSONObject pl = new JSONObject();

		char buffer[256];
		GetPluginInfo(plugin, PlInfo_Name, buffer, sizeof(buffer));
		pl.SetString("name", buffer);

		GetPluginInfo(plugin, PlInfo_Version, buffer, sizeof(buffer));
		pl.SetString("version", buffer);

		GetPluginInfo(plugin, PlInfo_Author, buffer, sizeof(buffer));
		pl.SetString("author", buffer);

		GetPluginFilename(plugin, buffer, sizeof(buffer));
		pl.SetString("file", buffer);

		pl.SetString("status", pluginStatus == Plugin_Running ? "running" : "paused");

		plugins.Push(pl);
		delete pl;
	}
	CloseHandle(iter);

	return plugins;
}

void UpdateGokzData(int client)
{
	if (!IsClientInGame(client) || IsFakeClient(client))
		return;

	int mode = GOKZ_GetCoreOption(client, Option_Mode);
	g_gokzData[client].timerRunning = GOKZ_GetTimerRunning(client);
	g_gokzData[client].paused = GOKZ_GetPaused(client);
	g_gokzData[client].time = GOKZ_GetTime(client);
	g_gokzData[client].course = GOKZ_GetCourse(client);
	g_gokzData[client].teleports = GOKZ_GetTeleportCount(client);
	strcopy(g_gokzData[client].mode, MODE_NAME_LEN, gC_ModeNames[mode]);
}

void ResetGokzData(int client)
{
	g_gokzData[client].mode[0] = '\0';
	g_gokzData[client].timerRunning = false;
	g_gokzData[client].paused = false;
	g_gokzData[client].time = 0.0;
	g_gokzData[client].course = 0;
	g_gokzData[client].teleports = 0;
}

void LoadConfig()
{
	char cfgPath[PLATFORM_MAX_PATH];
	BuildPath(Path_SM, cfgPath, sizeof(cfgPath), "configs/fkz-api.cfg");

	File file = OpenFile(cfgPath, "r");
	if (file == null)
	{
		LogError("[FKZ] Config not found: %s", cfgPath);
		return;
	}

	char line[512];
	while (file.ReadLine(line, sizeof(line)))
	{
		TrimString(line);

		if (line[0] == '/' || line[0] == '#' || line[0] == '\0')
			continue;

		char key[64], value[256];
		if (ParseConfigLine(line, key, sizeof(key), value, sizeof(value)))
		{
			if (StrEqual(key, "api_url"))
				strcopy(g_apiUrl, sizeof(g_apiUrl), value);
			else if (StrEqual(key, "api_key"))
				strcopy(g_apiKey, sizeof(g_apiKey), value);
			else if (StrEqual(key, "server_ip"))
				strcopy(g_serverIp, sizeof(g_serverIp), value);
			else if (StrEqual(key, "server_port"))
				g_serverPort = StringToInt(value);
			else if (StrEqual(key, "tls_ca_file"))
				strcopy(g_tlsCAFile, sizeof(g_tlsCAFile), value);
			else if (StrEqual(key, "interval"))
			{
				g_interval = StringToFloat(value);
				if (g_interval < 1.0)
					g_interval = 1.0;
			}
		}
	}

	delete file;
}

bool ParseConfigLine(const char[] line, char[] key, int keyLen, char[] value, int valueLen)
{
	int pos = 0;
	while (line[pos] == ' ' || line[pos] == '\t')
		pos++;

	if (line[pos] == '"')
	{
		pos++;
		int start = pos;
		while (line[pos] != '"' && line[pos] != '\0')
			pos++;
		int len = pos - start;
		if (len >= keyLen)
			len = keyLen - 1;
		strcopy(key, len + 1, line[start]);
		if (line[pos] == '"')
			pos++;
	}
	else
	{
		int start = pos;
		while (line[pos] != ' ' && line[pos] != '\t' && line[pos] != '\0')
			pos++;
		int len = pos - start;
		if (len >= keyLen)
			len = keyLen - 1;
		strcopy(key, len + 1, line[start]);
	}

	while (line[pos] == ' ' || line[pos] == '\t')
		pos++;

	if (line[pos] == '"')
	{
		pos++;
		int start = pos;
		while (line[pos] != '"' && line[pos] != '\0')
			pos++;
		int len = pos - start;
		if (len >= valueLen)
			len = valueLen - 1;
		strcopy(value, len + 1, line[start]);
		return true;
	}

	return false;
}

void DetectOS()
{
	char statusBuf[2048];
	ServerCommandEx(statusBuf, sizeof(statusBuf), "status");

	int pos = StrContains(statusBuf, "\nos", false);
	if (pos != -1)
	{
		int colon = StrContains(statusBuf[pos], ":");
		if (colon != -1)
		{
			char osLine[64];
			strcopy(osLine, sizeof(osLine), statusBuf[pos + colon + 1]);
			TrimString(osLine);

			if (StrContains(osLine, "Linux", false) != -1)
				strcopy(g_osName, sizeof(g_osName), "linux");
			else
				strcopy(g_osName, sizeof(g_osName), "windows");
			return;
		}
	}

	// Fallback: assume linux
	strcopy(g_osName, sizeof(g_osName), "linux");
}

void StopReportTimer()
{
	if (g_reportTimer != INVALID_HANDLE)
	{
		KillTimer(g_reportTimer);
		g_reportTimer = INVALID_HANDLE;
	}
}
