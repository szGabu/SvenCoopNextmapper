#include <amxmodx>
#include <amxmisc>
#include <hamsandwich>
#include <fakemeta>
#include <engine>
#include <hlsdk_const>

#pragma semicolon   1
#pragma dynamic     32768

#define PLUGIN_NAME	                    "Sven Co-op Nextmapper & Anti-Rush"
#define PLUGIN_VERSION	                "1.0.0-25w17a"
#define PLUGIN_AUTHOR	                "szGabu"

#define SF_FADE_OUT                     0x0003
#define FL_NOWEAPONS                    (1<<27)

#define SVENGINE_MAX_EDICS              8192

#define GAME_END_CLASSNAME              "game_end"
#define CHANGELEVEL_CLASSNAME           "trigger_changelevel"

#define RELAY_ENTNAME					"trigger_relay"
#define RELAY_TARGETNAME				"amxx_nextmapper_utsuhoreuiji"

#define GAMEEND_ENTNAME					"game_end"
#define GAMEEND_TARGETNAME				"amxx_nextmapper_sanaekochiya"

#define BEACON_MODEL                    "models/w_adrenaline.mdl"
#define BEACON_CLASSNAME                "trigger_changelevel_beacon"

#define DEBUG_ALWAYS_WAIT               false

#define ANTIRUSH_STATE_INVALID          -1  // plugin is disabled or in an unknown state
#define ANTIRUSH_STATE_PRE_INIT         0   // plugin is enabled, but no players have joined yet
#define ANTIRUSH_STATE_INIT             1   // plugin is in initializacion state, waiting for more players 
#define ANTIRUSH_STATE_MIDGAME          2   // game has started, normal sven stuff happens here
#define ANTIRUSH_STATE_END              3   // someone reached the end, telling players the map is about to change
#define ANTIRUSH_STATE_INTERMISSION     4   // map is changing, no further actions will be performed
#define ANTIRUSH_STATE_SHOULD_RESTART   5   // everyone left midgame! we are restarting the map

#define CLOCK_TASKID					177784

new g_cvarEnabled, g_cvarAntiRush, g_cvarAntiRushWaitStart, g_cvarAntiRushWaitEnd, g_cvarAntiRushEndPercentage, g_cvarAntiRushIgnoreBots, g_cvarMapManagerPlugin;
new g_cvarSurvivalEnabled;
new g_iPluginFlags, g_iMapState = ANTIRUSH_STATE_INVALID;
new g_sDesiredNextMap[64];
new g_bOldMap = false;
new g_bDebugAlwaysWait = false;
new g_hPlayerState[MAX_PLAYERS+1] = {-1, ...};
new g_hLastExitUsed = 0;
new g_hRelayEnt = 0, g_hGameEndEnt = 0;
new g_hBeaconEnt[MAX_PLAYERS+1] = {-1, ...};
new g_hScreenFadeMessage = 0;
new bool:g_bAmxxSurvivalModeEnabled = false;
new bool:g_bShouldSpawnNormally = false;
new g_iShouldTransitionNowTo = -1;
new Float:g_fSecondsPassed = 0.0;
new g_szMapManagerPlugin[MAX_NAME_LENGTH] = "";
new Array:g_aInexistingMapExits;

public plugin_init()
{
    register_plugin(PLUGIN_NAME, PLUGIN_VERSION, PLUGIN_AUTHOR);

    if(!is_running("svencoop"))
        set_fail_state("[AMXX] Sven Co-op Nextmapper & Anti-Rush can only run in Sven Co-op!");

    g_cvarEnabled = register_cvar("amx_sven_nextmapper_enabled", "1");
    g_cvarAntiRush = register_cvar("amx_sven_antirush_enabled", "1");
    g_cvarAntiRushWaitStart = register_cvar("amx_sven_antirush_wait_start", "30.0");
    g_cvarAntiRushWaitEnd = register_cvar("amx_sven_antirush_wait_end", "60.0");
    g_cvarAntiRushEndPercentage = register_cvar("amx_sven_antirush_end_percentage", "80.0");
    g_cvarAntiRushIgnoreBots = register_cvar("amx_sven_antirush_ignore_bots", "0");
    g_cvarMapManagerPlugin = register_cvar("amx_sven_antirush_map_manager_plugin", "");
    g_cvarSurvivalEnabled = get_cvar_pointer("mp_survival_mode");

    register_cvar("amx_sven_nextmapper_version", PLUGIN_VERSION);

    g_iPluginFlags = plugin_flags();
    g_hScreenFadeMessage = get_user_msgid("ScreenFade");

    register_clcmd("gibme", "PlayerCmd_Suicide");
    register_clcmd("kill", "PlayerCmd_Suicide");

    if(g_iPluginFlags & AMX_FLAG_DEBUG)
        g_bDebugAlwaysWait = DEBUG_ALWAYS_WAIT;
}

public plugin_end()
{
    if(task_exists(CLOCK_TASKID))
        remove_task(CLOCK_TASKID);
}

public plugin_precache()
{
    precache_model(BEACON_MODEL);
}

public PlayerCmd_Suicide(iClient)
{
    if(g_hPlayerState[iClient] > 0)
        return PLUGIN_HANDLED;

    g_hPlayerState[iClient] = -1;
    return PLUGIN_CONTINUE;
}

public plugin_cfg()
{
    if(g_iPluginFlags & AMX_FLAG_DEBUG)
        server_print("[DEBUG] %s::plugin_cfg() - Called", __BINARY__);

    if(get_pcvar_bool(g_cvarEnabled))
    {
        new sMapName[32];
        get_mapname(sMapName, charsmax(sMapName));
        new sMapConfigPath[1024];
        formatex(sMapConfigPath, charsmax(sMapConfigPath), "maps/%s.cfg", sMapName);
        if(g_iPluginFlags & AMX_FLAG_DEBUG)
            server_print("[DEBUG] %s::plugin_cfg() - Trying to read file %s", __BINARY__, sMapConfigPath);
        static hFile, sLine[100];
        if((hFile = fopen(sMapConfigPath, "r")))
        {
            while (!feof(hFile))
            {
                fgets(hFile, sLine, charsmax(sLine));
                trim(sLine);

                if(containi(sLine, "nextmap") == 0)
                {
                    copy(g_sDesiredNextMap, charsmax(g_sDesiredNextMap), sLine);
                    replace(g_sDesiredNextMap, charsmax(g_sDesiredNextMap), "nextmap ", "");
                    if(g_iPluginFlags & AMX_FLAG_DEBUG)
                        server_print("[DEBUG] %s::plugin_cfg() - This map is old, next map should be %s", __BINARY__, g_sDesiredNextMap);

                    if(is_map_valid(g_sDesiredNextMap))
                    {
                        RegisterHam(Ham_Use, GAME_END_CLASSNAME, "LevelEnd_ByUse");
                        g_bOldMap = true;
                    }
                }
            }
            fclose(hFile);
        }
        else if(g_iPluginFlags & AMX_FLAG_DEBUG)
            server_print("[DEBUG] %s::plugin_cfg() - Can't open file %s. Assuming normal map", __BINARY__, sMapConfigPath);

        if(get_pcvar_bool(g_cvarAntiRush))
        {
            RegisterHam(Ham_Use, CHANGELEVEL_CLASSNAME, "LevelEnd_ByUse");
            //register_forward(FM_Touch, "Event_Touch_Pre", false); // HamSandwich Hook is no longer working working.
            RegisterHam(Ham_Touch, CHANGELEVEL_CLASSNAME, "LevelEnd_ByTouch");

            if(g_iPluginFlags & AMX_FLAG_DEBUG)
                server_print("[DEBUG] %s::plugin_cfg() - Registering hooks.", __BINARY__);

            RegisterHam(Ham_Spawn, "player", "Event_PlayerSpawn_Pre");

            if(g_iPluginFlags & AMX_FLAG_DEBUG)
                server_print("[DEBUG] %s::plugin_cfg() - Setting g_iMapState to ANTIRUSH_STATE_PRE_INIT.", __BINARY__);
            g_iMapState = ANTIRUSH_STATE_PRE_INIT;

            if(g_iPluginFlags & AMX_FLAG_DEBUG)
                server_print("[DEBUG] %s::plugin_cfg() - Running clock.", __BINARY__);
            set_task(1.0, "clock_function", CLOCK_TASKID, _, _, "b");

            SetupNeededEnts();

            get_pcvar_string(g_cvarMapManagerPlugin, g_szMapManagerPlugin, charsmax(g_cvarMapManagerPlugin));
        }
    }
}

public pfn_keyvalue(iEnt)
{
    new szClassname[32], szKeyName[32], szKeyValue[32];
    copy_keyvalue(szClassname, charsmax(szClassname), szKeyName, charsmax(szKeyName), szKeyValue, charsmax(szKeyValue));
    if(equali(szClassname, CHANGELEVEL_CLASSNAME))
    {
        if(equali(szKeyName, "map"))
        {
            new szMapPath[PLATFORM_MAX_PATH];
            formatex(szMapPath, charsmax(szMapPath), "maps/%s.bsp", szKeyValue);
            if(!file_exists(szMapPath, true))
            {
                server_print("[ALERT] %s::pfn_keyvalue() - Map %s missing from the maps folder. Exit will be treated as 'game_end'", __BINARY__, szKeyValue);

                if(_:g_aInexistingMapExits == 0)
                    g_aInexistingMapExits = ArrayCreate();

                ArrayPushCell(g_aInexistingMapExits, iEnt);
            }
        }
    }
}

public OnConfigsExecuted()
{
    if(g_iPluginFlags & AMX_FLAG_DEBUG)
        server_print("[DEBUG] %s::OnConfigsExecuted() - Called", __BINARY__);

    g_bAmxxSurvivalModeEnabled = (get_cvar_pointer("amx_survival_enabled") > 0 && (get_cvar_pointer("amx_survival_mode") > 0 && get_pcvar_num(get_cvar_pointer("amx_survival_mode")) > 0)) ;
    server_print("[NOTICE] %s::OnConfigsExecuted() - %s is free to download and distribute! If you paid for this plugin YOU GOT SCAMMED. Visit https://github.com/szGabu for all my plugins.", __BINARY__, PLUGIN_NAME);
}

/**
 * Creates and configures necessary game entities for plugin functionality.
 *
 * @return void
 */
public SetupNeededEnts()
{
    g_hRelayEnt = engfunc(EngFunc_CreateNamedEntity, engfunc(EngFunc_AllocString, RELAY_ENTNAME));
    g_hGameEndEnt = engfunc(EngFunc_CreateNamedEntity, engfunc(EngFunc_AllocString, GAMEEND_ENTNAME));

    if(!g_hRelayEnt || !g_hGameEndEnt || !pev_valid(g_hRelayEnt) || !pev_valid(g_hGameEndEnt))
    {
        server_print("[CRITICAL] %s::SetupNeededEnts() - Failed to create needed ents. Stopping.", __BINARY__);
        set_fail_state("Failed to create needed ents");
    }

    dllfunc(DLLFunc_Spawn, g_hRelayEnt);
    set_pev(g_hRelayEnt, pev_targetname, RELAY_TARGETNAME);

    
    dllfunc(DLLFunc_Spawn, g_hGameEndEnt);
    set_pev(g_hGameEndEnt, pev_targetname, GAMEEND_TARGETNAME);
}

public client_disconnected(iClient)
{
    if(!get_pcvar_bool(g_cvarAntiRush) || (get_pcvar_bool(g_cvarAntiRushIgnoreBots) && is_user_bot(g_cvarAntiRushIgnoreBots)) )
        return;

    set_task(0.1, "RecheckPlayerCountOnLeft");

    g_hPlayerState[iClient] = -1;
}

public RecheckPlayerCountOnLeft()
{
    if(GetPlayerCount() == 0 && g_iMapState == ANTIRUSH_STATE_MIDGAME)
    {
        if(g_iPluginFlags & AMX_FLAG_DEBUG)
        {
            server_print("[DEBUG] %s::client_disconnected() - g_iMapState is ANTIRUSH_STATE_MIDGAME", __BINARY__);
            server_print("[DEBUG] %s::client_disconnected() - Setting g_iMapState to ANTIRUSH_STATE_SHOULD_RESTART", __BINARY__);
            server_print("[DEBUG] %s::client_disconnected() - GetPlayerCount() is %d", __BINARY__, GetPlayerCount());
        }
        g_iMapState = ANTIRUSH_STATE_SHOULD_RESTART;
        server_cmd("restart");
    }
}

public client_putinserver(iClient)
{
    if(!get_pcvar_bool(g_cvarAntiRush) || (get_pcvar_bool(g_cvarAntiRushIgnoreBots) && is_user_bot(iClient)))
        return;

    if(g_iMapState == ANTIRUSH_STATE_PRE_INIT)
    {
        if(g_iPluginFlags & AMX_FLAG_DEBUG)
        {
            server_print("[DEBUG] %s::client_putinserver() - g_iMapState is ANTIRUSH_STATE_PRE_INIT", __BINARY__);
            server_print("[DEBUG] %s::client_putinserver() - Setting g_iMapState to ANTIRUSH_STATE_INIT", __BINARY__);
        }

        g_iMapState = ANTIRUSH_STATE_INIT;
    }
}

public PlayerReachedEndMap(iClient, iExit, bool:bShouldCreateBeacon)
{
    if(g_iPluginFlags & AMX_FLAG_DEBUG)
        server_print("[DEBUG] %s::PlayerReachedEndMap() - Called on %N and %d", __BINARY__, iClient, iExit);

    if(!pev_valid(iClient) || !pev_valid(iExit))
    {
        if(g_iPluginFlags & AMX_FLAG_DEBUG)
        {
            server_print("[WARNING] %s::PlayerReachedEndMap() - Can't continue with execution because of of these is false", __BINARY__, iClient, iExit);
            server_print("[WARNING] %s::PlayerReachedEndMap() - pev_valid(%d) = %d", __BINARY__, iClient, pev_valid(iClient));
            server_print("[WARNING] %s::PlayerReachedEndMap() - pev_valid(%d) = %d", __BINARY__, iExit, pev_valid(iExit));
        }
        return;
    }

    g_hLastExitUsed = iExit;
    if(g_iPluginFlags & AMX_FLAG_DEBUG)
        server_print("[DEBUG] %s::PlayerReachedEndMap() - iExit IS %d!!!!", __BINARY__, iExit);
    g_hPlayerState[iClient] = iExit;
    if(g_iPluginFlags & AMX_FLAG_DEBUG)
        server_print("[DEBUG] %s::PlayerReachedEndMap() - g_hPlayerState[%d] is %d", __BINARY__, iClient, g_hPlayerState[iClient]);

    set_pev(iClient, pev_flags, pev(iClient, pev_flags) | FL_FROZEN | FL_GODMODE | FL_NOTARGET | FL_NOWEAPONS | FL_DORMANT);
    set_pev(iClient, pev_solid, SOLID_NOT);
    set_pev(iClient, pev_movetype, MOVETYPE_NONE);

    if(bShouldCreateBeacon)
        Player_CreateTransitionBeacon(iClient, iExit);
}

Player_CreateTransitionBeacon(iClient, iExit)
{
    if(!pev_valid(iClient) || !pev_valid(iExit))
        return;

    if(!is_user_alive(iClient))
        return;
    
    g_hBeaconEnt[iClient] = engfunc(EngFunc_CreateNamedEntity, engfunc(EngFunc_AllocString, "info_target"));
    if(!pev_valid(g_hBeaconEnt[iClient]))
    {
        server_print("[ERROR] %s::Player_CreateTransitionBeacon() - Failed to create transition Beacon!", __BINARY__);
        return;
    }

    dllfunc(DLLFunc_Spawn, g_hBeaconEnt[iClient]);
    set_pev(g_hBeaconEnt[iClient], pev_classname, BEACON_CLASSNAME);
    set_pev(g_hBeaconEnt[iClient], pev_owner, iExit);

    engfunc(EngFunc_SetModel, g_hBeaconEnt[iClient], BEACON_MODEL);
    set_pev(g_hBeaconEnt[iClient], pev_effects, EF_NODRAW);
    set_pev(g_hBeaconEnt[iClient], pev_solid, SOLID_TRIGGER);
    set_pev(g_hBeaconEnt[iClient], pev_movetype, MOVETYPE_TOSS);

    new Float:fOrigin[3];
    pev(iClient, pev_origin, fOrigin);
    
    // Set trigger size (slightly larger than player bounds)
    new Float:fMins[3], Float:fMaxs[3];
    pev(iClient, pev_mins, fMins);
    pev(iClient, pev_maxs, fMaxs);
    fMins[0] -= 8.0;
    fMins[1] -= 8.0;
    fMins[2] -= 8.0;
    fMaxs[0] += 8.0;
    fMaxs[1] += 8.0;
    fMaxs[2] += 8.0;

    // According to documentation online, origin must go BEFORE the size
    engfunc(EngFunc_SetOrigin, g_hBeaconEnt[iClient], fOrigin);
    engfunc(EngFunc_SetSize, g_hBeaconEnt[iClient], fMins, fMaxs);

    if(g_iPluginFlags & AMX_FLAG_DEBUG)
        server_print("[DEBUG] %s::Player_CreateTransitionBeacon() - Successfully created beacon: %d", __BINARY__, g_hBeaconEnt[iClient]);
}

public Event_Touch_Pre(iEnt, iOther)
{
    if(g_iShouldTransitionNowTo == iEnt)
    {
        if(ArrayFindValue(g_aInexistingMapExits, iEnt) >= 0)
            ExecuteHamB(Ham_Use, g_hGameEndEnt, g_hGameEndEnt, g_hGameEndEnt, 1, 1.0);
        else
            return FMRES_IGNORED;
    }

    if(iEnt && iOther && iEnt >= MaxClients && iOther <= MaxClients && pev_valid(iEnt) && pev_valid(iOther))
    {
        new sClassname[32];
        pev(iEnt, pev_classname, sClassname, charsmax(sClassname));
        if(equali(sClassname, BEACON_CLASSNAME))
            return LevelEnd_ByTouchBeaconPlayer(iEnt, iOther);
        else if(equali(sClassname, CHANGELEVEL_CLASSNAME))
            return LevelEnd_ByTouch(iEnt, iOther);
    }

    return FMRES_IGNORED;
}

public LevelEnd_ByTouch(iEnt, iOther)
{
    if(!is_user_connected(iOther))
        return HAM_IGNORED;

    //blocked back transition
    if(pev(iEnt, pev_solid) == SOLID_BSP) 
    {
        if(g_iPluginFlags & AMX_FLAG_DEBUG)
            server_print("[DEBUG] %s::LevelEnd_ByTouch() - Player %N wanted to touch a solid changelevel block", __BINARY__, iOther);
        return HAM_IGNORED;
    }

    if(pev(iEnt, pev_spawnflags) & SF_CHANGELEVEL_USEONLY == 0 && (iOther > 0 && iOther <= MaxClients))
    {
        if(g_iMapState == ANTIRUSH_STATE_MIDGAME)
        {
            new sName[MAX_NAME_LENGTH];
            get_user_name(iOther, sName, charsmax(sName));
            client_print(0, print_chat, "* %s reached the end of the map.", sName);
            
            if(g_iPluginFlags & AMX_FLAG_DEBUG)
            {
                server_print("[DEBUG] %s::LevelEnd_ByTouch() - g_hPlayerState[%d] is %d", __BINARY__, iOther, g_hPlayerState[iOther]);
                server_print("[DEBUG] %s::LevelEnd_ByTouch() - g_iMapState is ANTIRUSH_STATE_MIDGAME", __BINARY__);
                server_print("[DEBUG] %s::LevelEnd_ByTouch() - Setting g_iMapState to ANTIRUSH_STATE_END", __BINARY__);
            }

            g_iMapState = ANTIRUSH_STATE_END;
        }


        if(g_hPlayerState[iOther] == -1)
        {
            if(g_iPluginFlags & AMX_FLAG_DEBUG)
                server_print("[DEBUG] %s::LevelEnd_ByTouch() - Going to call PlayerReachedEndMap(%d, %d, false)", __BINARY__, iOther, iEnt, false);
            PlayerReachedEndMap(iOther, iEnt, false);
        }

        return HAM_SUPERCEDE;
    }
    
    return HAM_IGNORED;
}

public LevelEnd_ByTouchBeaconPlayer(iEnt, iOther)
{
    if(g_iPluginFlags & AMX_FLAG_DEBUG)
        server_print("[DEBUG] %s::LevelEnd_ByTouchBeaconPlayer() - Called on %d", __BINARY__, iEnt);

    if(iOther >= 0 && iOther <= MaxClients && g_iMapState == ANTIRUSH_STATE_END)
    {
        if(g_hPlayerState[iOther] > 0)
            return FMRES_IGNORED;
        else
        {
            if(pev(iEnt, pev_owner) > 0 && g_hPlayerState[iOther] == -1)
                PlayerReachedEndMap(iOther, pev(iEnt, pev_owner), false);
        }
    }

    return FMRES_IGNORED;
}

public LevelEnd_ByUse(iEnt, iCaller, iActivator, iUseType, Float:fValue)
{
    if(!pev_valid(iEnt) || !pev_valid(iCaller))
        return HAM_IGNORED;

    if(pev(iEnt, pev_solid) == SOLID_BSP)
        return HAM_IGNORED;

    if(iCaller > 0 && iCaller <= MaxClients)
    {
        if(g_iMapState == ANTIRUSH_STATE_MIDGAME)
        {
            new sName[MAX_NAME_LENGTH];
            get_user_name(iCaller, sName, charsmax(sName));
            client_print(0, print_chat, "* %s reached the end of the map.", sName);
            if(g_iPluginFlags & AMX_FLAG_DEBUG)
            {
                server_print("[DEBUG] %s::LevelEnd_ByUse() - g_hPlayerState[%d] is %d", __BINARY__, iCaller, g_hPlayerState[iCaller]);
                server_print("[DEBUG] %s::LevelEnd_ByUse() - g_iMapState is ANTIRUSH_STATE_MIDGAME", __BINARY__);
                server_print("[DEBUG] %s::LevelEnd_ByUse() - Setting g_iMapState to ANTIRUSH_STATE_END", __BINARY__);
            }
            g_iMapState = ANTIRUSH_STATE_END;
        }

        if(g_hPlayerState[iCaller] == -1)
        {
            PlayerReachedEndMap(iCaller, iEnt, true);

            new sClassname[16];
            pev(iEnt, pev_classname, sClassname, charsmax(sClassname));

            if(g_iPluginFlags & AMX_FLAG_DEBUG)
                server_print("[DEBUG] %s::LevelEnd_ByUse() - classname: %s", __BINARY__, sClassname);
        
            if(equal(sClassname, GAME_END_CLASSNAME))
            {
                if(strlen(g_szMapManagerPlugin) > 0)
                {
                    // ugly hack to prevent a map manager to 
                    // trigger a votemap when we are waiting for players
                    if(g_iPluginFlags & AMX_FLAG_DEBUG)
                        server_print("[DEBUG] %s::LevelEnd_ByUse() - Trying to pause Map Manager Plugin (%s)", __BINARY__, g_szMapManagerPlugin);

                    pause("ac", g_szMapManagerPlugin);
                    server_exec();
                }
            }
        }
        return HAM_SUPERCEDE;
    }

    //special case if we have the g_bOldMap flag set
    if(g_bOldMap)
    {
        if(g_iPluginFlags & AMX_FLAG_DEBUG)
            server_print("[DEBUG] %s::LevelEnd_ByUse() - This is an old map and the previous conditons didn't met. Changing to %s", __BINARY__,  g_sDesiredNextMap);

        engine_changelevel(g_sDesiredNextMap);
    }

    return HAM_IGNORED;
}

//runs every second
public clock_function()
{
    switch(g_iMapState)
    {
        case ANTIRUSH_STATE_INIT:
        {
            if(g_fSecondsPassed > get_pcvar_float(g_cvarAntiRushWaitStart))
            {
                if(g_iPluginFlags & AMX_FLAG_DEBUG)
                {
                    server_print("[DEBUG] %s::clock_function() - g_iMapState is ANTIRUSH_STATE_INIT", __BINARY__);
                    server_print("[DEBUG] %s::clock_function() - Disabling hook and spawning", __BINARY__);
                }

                if(g_iPluginFlags & AMX_FLAG_DEBUG)
                    server_print("[DEBUG] %s::clock_function() - Setting g_bShouldSpawnNormally to true", __BINARY__);

                g_bShouldSpawnNormally = true;

                if(g_iPluginFlags & AMX_FLAG_DEBUG)
                    server_print("[DEBUG] %s::clock_function() - Setting g_iMapState to ANTIRUSH_STATE_MIDGAME", __BINARY__);

                g_iMapState = ANTIRUSH_STATE_MIDGAME;
                g_fSecondsPassed = 0.0;

                FadeOut();

                if(strlen(g_szMapManagerPlugin) > 0)
                {
                   //we are in ANTIRUSH_STATE_MIDGAME, we must resume the map manager
                   if(g_iPluginFlags & AMX_FLAG_DEBUG)
                       server_print("[DEBUG] %s::clock_function() - Trying to Map Manager Plugin (%s)", __BINARY__, g_szMapManagerPlugin);
                
                   unpause("ac", g_szMapManagerPlugin);
                }

                if(g_bAmxxSurvivalModeEnabled)
                    server_cmd("amx_survival_activate_now");

                return;
            }

            for(new iClient=1;iClient <= MaxClients;iClient++)
            {
                if(is_user_connected(iClient))
                {
                    message_begin(MSG_ONE, g_hScreenFadeMessage, {0, 0, 0}, iClient);
                    write_short(0);
                    write_short(0);
                    write_short(SF_FADE_ONLYONE);
                    write_byte(0);
                    write_byte(0);
                    write_byte(0);
                    write_byte(255);
                    message_end();
                }
            }

            set_hudmessage(200, 100, 0, -1.0, -1.0, 0, 1.0, 1.2, 0.0);
            show_hudmessage(0,  "Waiting for players...");
            g_fSecondsPassed++;
        }
        case ANTIRUSH_STATE_END:
        {
            // needs retest
            // you're free to play around with this
            // what if there's multiple exits?
            // newer maps might softlock regardless
            // if(!g_bOldMap && GetPlayersInLimbo() == 0)
            // {
            //     // g_bOldMap must be FALSE otherwise the map 
            //     // could softlock in not repeatable triggers
            //     if(g_iPluginFlags & AMX_FLAG_DEBUG)
            //     {
            //         server_print("[DEBUG] %s::clock_function() -  All players in limbo left the server", __BINARY__);
            //         server_print("[DEBUG] %s::clock_function() -  g_iMapState is ANTIRUSH_STATE_END", __BINARY__);
            //         server_print("[DEBUG] %s::clock_function() -  Setting g_iMapState to ANTIRUSH_STATE_MIDGAME", __BINARY__);
            //     }
            //     g_iMapState = ANTIRUSH_STATE_MIDGAME;
            //     return;
            // }

            new iLimboPercentage = (GetPlayersInLimbo()*100)/GetPlayerCount();

            if(g_iPluginFlags & AMX_FLAG_DEBUG)
                server_print("[DEBUG] %s::clock_function() - percentage of players in limbo %d%%", __BINARY__, iLimboPercentage);

            if(g_fSecondsPassed == get_pcvar_float(g_cvarAntiRushWaitEnd) || (!g_bDebugAlwaysWait && iLimboPercentage > get_pcvar_float(g_cvarAntiRushEndPercentage)))
            {
                //antirush shouldn't wait more players
                if(g_iPluginFlags & AMX_FLAG_DEBUG)
                {
                    server_print("[DEBUG] %s::clock_function() - TIME UP, attempting to changemap", __BINARY__);
                    server_print("[DEBUG] %s::clock_function() - g_iMapState is ANTIRUSH_STATE_END", __BINARY__);
                    server_print("[DEBUG] %s::clock_function() - Setting g_iMapState to ANTIRUSH_STATE_INTERMISSION", __BINARY__);
                }
                g_iMapState = ANTIRUSH_STATE_INTERMISSION;
                end_map();
                return;
            }
            set_hudmessage(200, 100, 0, -1.0, -1.0, 0, 1.0, 1.2, 0.0);
            show_hudmessage(0, "Map changing in %d seconds", floatround(get_pcvar_float(g_cvarAntiRushWaitEnd) - g_fSecondsPassed));
            g_fSecondsPassed++;
        }
    }
}

/**
 * Game started, open your eyes.
 *
 * @return void
 */
FadeOut()
{
    for(new iClient = 1; iClient <= MaxClients; iClient++)
    {
        if(is_user_connected(iClient) && pev_valid(iClient))
        {
            client_print(iClient, print_center, "");
            message_begin(MSG_ONE, g_hScreenFadeMessage, _, iClient);
            write_short(0);
            write_short(0);
            write_short(SF_FADE_OUT);
            write_byte(0);
            write_byte(0);
            write_byte(0);
            write_byte(0);
            message_end();

            set_pev(iClient, pev_flags, pev(iClient, pev_flags) & ~(FL_FROZEN | FL_GODMODE | FL_NOTARGET));
        }
    }
}

public end_map()
{
    //check which exit should we do
    if(g_bOldMap)
    {
        if(g_iPluginFlags & AMX_FLAG_DEBUG)
            server_print("[DEBUG] %s::end_map() - This is an old map. Changing to %s", __BINARY__, g_sDesiredNextMap);

        engine_changelevel(g_sDesiredNextMap);
    }
    else 
    {
        if(g_iPluginFlags & AMX_FLAG_DEBUG)
            server_print("[DEBUG] %s::end_map() - This is a new map", __BINARY__);
        //if we store the changelevel id and trigger it we
        //might keep the inventory if the mapper wishes to
        new iMapExit[SVENGINE_MAX_EDICS] = 0;
        for(new iClient=1;iClient <= MaxClients;iClient++)
        {
            if(g_iPluginFlags & AMX_FLAG_DEBUG)
                server_print("[DEBUG] %s::end_map() - g_hPlayerState[%d] is %d", __BINARY__, iClient, g_hPlayerState[iClient]);
            if(g_hPlayerState[iClient] > 0)
                iMapExit[g_hPlayerState[iClient]]++;
        }

        new iDesiredChangelevelEnt = 0;
        new iLastChecks = 0;
        for(new iCursor = 0; iCursor < SVENGINE_MAX_EDICS; iCursor++)
        {
            if(iMapExit[iCursor] > iLastChecks)
            {
                if(g_iPluginFlags & AMX_FLAG_DEBUG)
                    server_print("iMapExit[%d] is %d", iCursor, iMapExit[iCursor]);
                iDesiredChangelevelEnt = iCursor;
                iLastChecks = iMapExit[iCursor];
            }
        }

        if(g_iPluginFlags & AMX_FLAG_DEBUG)
            server_print("[DEBUG] %s::end_map() - Desired changelevel entity is %d", __BINARY__, iDesiredChangelevelEnt);

        // this prevents funi xd players from trying to softlock the map
        // tho' there may still be a way to do it
        if(!iDesiredChangelevelEnt)
            iDesiredChangelevelEnt = g_hLastExitUsed;

        // check if there's at least 1 player alive and connected
        new iUser = 0;
        for(new iClient=1;iClient <= MaxClients;iClient++)
        {
            if(is_user_connected(iClient) && is_user_alive(iClient) && pev_valid(iClient))
            {
                iUser = iClient;
                break;
            }
        }

        if(iUser)
        {
            if(g_iPluginFlags & AMX_FLAG_DEBUG)
                server_print("[DEBUG] %s::end_map() - Executed Changelevel", __BINARY__);

            g_iShouldTransitionNowTo = iDesiredChangelevelEnt; //this makes the fmres touch to actually go through

            for(new iClient=1;iClient <= MaxClients;iClient++)
            {
                if(is_user_connected(iClient) && is_user_alive(iClient) && pev_valid(iClient))
                {
                    set_pev(iClient, pev_flags, pev(iClient, pev_flags) & ~(FL_FROZEN | FL_GODMODE | FL_NOTARGET | FL_NOWEAPONS | FL_DORMANT));
                    set_pev(iClient, pev_solid, SOLID_SLIDEBOX);
                    set_pev(iClient, pev_movetype, MOVETYPE_WALK);
                }
            }

            ExecuteHam(Ham_Use, iDesiredChangelevelEnt, g_hRelayEnt, g_hRelayEnt, 1, 0.0);
            ExecuteHam(Ham_Use, iDesiredChangelevelEnt, iUser, iUser, 1, 0.0);
        }
        else
        {
            //we don't have an user!
            //everyone left?
            if(g_iPluginFlags & AMX_FLAG_DEBUG)
            {
                server_print("[DEBUG] %s::end_map() - g_iMapState is ANTIRUSH_STATE_MIDGAME", __BINARY__);
                server_print("[DEBUG] %s::end_map() - Setting g_iMapState to ANTIRUSH_STATE_SHOULD_RESTART", __BINARY__);
            }

            g_iMapState = ANTIRUSH_STATE_SHOULD_RESTART;
            server_cmd("restart");
        }
    }
}

public Event_PlayerSpawn_Pre(iClient)
{  
    if(g_iPluginFlags & AMX_FLAG_DEBUG)
    {
        server_print("[DEBUG] %s::Event_PlayerSpawn_Pre() - Called on Player %d", __BINARY__, iClient);
        server_print("[DEBUG] %s::Event_PlayerSpawn_Pre() - Value of g_bShouldSpawnNormally is %b", __BINARY__,  g_bShouldSpawnNormally);
    }
        
    if(!g_bShouldSpawnNormally)
        set_task(0.1, "FreezePlayer", get_user_userid(iClient));

    return HAM_IGNORED;
}

public FreezePlayer(iUserId)
{
    new iClient = find_player_ex(FindPlayer_MatchUserId, iUserId);
    if(iClient && is_user_connected(iClient) && pev_valid(iClient))
    {
        if(g_iPluginFlags & AMX_FLAG_DEBUG)
            server_print("[DEBUG] %s::FreezePlayer() - Called on Player %d", __BINARY__, iClient);
        
        set_pev(iClient, pev_flags, pev(iClient, pev_flags) | FL_FROZEN | FL_GODMODE | FL_NOTARGET);
    }
}

stock GetPlayerCount()
{
    new iCount = 0;
    for(new iClient=1;iClient <= MaxClients;iClient++)
    {
        if(is_user_connected(iClient))
        {
            if(get_pcvar_bool(g_cvarSurvivalEnabled) || g_bAmxxSurvivalModeEnabled)
            {
                if(!is_user_alive(iClient) || (is_user_bot(iClient) && get_pcvar_bool(g_cvarAntiRushIgnoreBots)))
                    continue;
                iCount++;
            }
            else
            {
                if(is_user_bot(iClient) && get_pcvar_bool(g_cvarAntiRushIgnoreBots))
                    continue;
                iCount++;
            }
        }
    }
    return iCount;
}

stock GetPlayersInLimbo()
{
    new iCount = 0;
    for(new iClient=1;iClient <= MaxClients;iClient++)
    {
        if(is_user_connected(iClient) && g_hPlayerState[iClient] > 0)
        {
            if((is_user_bot(iClient) && get_pcvar_bool(g_cvarAntiRushIgnoreBots)))
                continue;
            iCount++;
        }
    }
    return iCount;
}