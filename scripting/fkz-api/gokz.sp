/**
 * FKZ API - GOKZ per-client data
 *
 * Snapshots a client's GOKZ timer/mode state into g_gokzData.
 */

void UpdateGokzData(int client)
{
    if (!IsClientInGame(client) || IsFakeClient(client))
        return;

    int mode                        = GOKZ_GetCoreOption(client, Option_Mode);
    g_gokzData[client].timerRunning = GOKZ_GetTimerRunning(client);
    g_gokzData[client].paused       = GOKZ_GetPaused(client);
    g_gokzData[client].time         = GOKZ_GetTime(client);
    g_gokzData[client].course       = GOKZ_GetCourse(client);
    g_gokzData[client].teleports    = GOKZ_GetTeleportCount(client);
    strcopy(g_gokzData[client].mode, MODE_NAME_LEN, gC_ModeNames[mode]);
}

void ResetGokzData(int client)
{
    g_gokzData[client].mode[0]      = '\0';
    g_gokzData[client].timerRunning = false;
    g_gokzData[client].paused       = false;
    g_gokzData[client].time         = 0.0;
    g_gokzData[client].course       = 0;
    g_gokzData[client].teleports    = 0;
}
