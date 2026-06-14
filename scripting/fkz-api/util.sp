/**
 * FKZ API - Misc helpers
 *
 * OS detection and report-timer teardown.
 */

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
