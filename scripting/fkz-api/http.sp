/**
 * FKZ API - HTTP reporting
 *
 * Dispatches the status report and hibernate signal to the API,
 * plus their response handlers.
 */

void SendHibernate()
{
    if (g_apiUrl[0] == '\0')
        return;

    JSONObject payload = new JSONObject();

    char       ip[64];
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

    HttpRequest req    = new HttpRequest(url);
    req.Timeout        = 5000;
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

    JSONObject  payload = BuildPayload();

    HttpRequest req     = new HttpRequest(g_apiUrl);
    req.Timeout         = 10000;
    req.KeepAlive       = true;
    req.FollowRedirect  = false;

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
