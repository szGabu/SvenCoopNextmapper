#include <amxmodx>
#include <amxmisc>
#include <hamsandwich>
#include <fakemeta>
#include <engine>
#include <hlsdk_const>

#pragma semicolon   1
#pragma dynamic     32768

#define TASKID_CLOCKFUNCTION			177784
#define TASKID_FREEZEPLAYER			    248778
#define TASKID_RECHECKPLAYERCOUNT       318779

#define PLUGIN_NAME	                    "Sven Co-op Nextmapper & Anti-Rush"
#define PLUGIN_VERSION	                "RC-25w23a"
#define PLUGIN_AUTHOR	                "szGabu"

// env_fade Spawn Flags
#define SF_FADE_OUT                     0x0003

// Player Flags
#define FL_NOWEAPONS                    (1<<27)

// Custom Flags
#define FL_PLAYERBEACON                 512

// Svengine
#define SVENGINE_MAX_EDICS              8192

#define CHANGELEVEL_CLASSNAME           "trigger_changelevel"
#define GAMEEND_CLASSNAME				"game_end"

#define BEACON_ENTNAME                  "trigger_multiple"
#define BEACON_CLASSNAME                "trigger_changelevel_beacon"

#define DEBUG_ALWAYS_WAIT               false

#define IsValidUserIndex(%1)            (1 <= (%1) <= MaxClients)

new g_cvarEnabled;
new g_cvarAntiRush;
new g_cvarAntiRushWaitStart;
new g_cvarAntiRushWaitStartAmount;
new g_cvarAntiRushWaitEnd;
new g_cvarAntiRushWaitEndPercentage;

new bool:g_bPluginEnabled;
new bool:g_bAntiRushEnabled;
new Float:g_fAntiRushWaitStart;
new g_iAntiRushWaitStartAmount;
new Float:g_fAntiRushWaitEnd;
new Float:g_fAntiRushWaitEndPercentage;

enum MapState {
    ANTIRUSH_STATE_INVALID = -1,   // plugin is disabled or in an unknown state
    ANTIRUSH_STATE_PRE_INIT = 0,   // plugin is enabled, but no players have joined yet
    ANTIRUSH_STATE_INIT = 1,       // plugin is in initializacion state, waiting for more players
    ANTIRUSH_STATE_MIDGAME,        // game has started, normal sven stuff happens here
    ANTIRUSH_STATE_END,            // someone reached the end, telling players the map is about to change
    ANTIRUSH_STATE_INTERMISSION,   // map is changing, no further actions will be performed
    ANTIRUSH_STATE_SHOULD_RESTART, // everyone left midgame! we are restarting the map
};

new MapState:g_hMapState = ANTIRUSH_STATE_INVALID;
new g_sDesiredNextMap[64];
new g_bOldMap = false;
new g_bDebugAlwaysWait = false;
new g_hPlayerState[MAX_PLAYERS+1] = {-1, ...};
new g_hLastExitUsed = 0;
new g_hBeaconEnt[MAX_PLAYERS+1] = {-1, ...};
new g_hScreenFadeMessage = 0;
new bool:g_bThirdPartySurvivalEnabled = false;
new bool:g_bShouldSpawnNormally = false;
new bool:g_bBeaconThinkHook = false;
new Float:g_fSecondsPassed = 0.0;
new Array:g_aInexistingMapExits;

new g_iWaitForPlayers = 0;

new g_iPluginFlags;

public plugin_init()
{
    register_plugin(PLUGIN_NAME, PLUGIN_VERSION, PLUGIN_AUTHOR);

    if(!is_running("svencoop"))
        set_fail_state("[AMXX] Sven Co-op Nextmapper & Anti-Rush can only run in Sven Co-op!");

    g_cvarEnabled = create_cvar("amx_sven_nextmapper_enabled", "1", FCVAR_NONE, "Enables the Plugin", true, 0.0, true, 1.0);
    g_cvarAntiRush = create_cvar("amx_sven_antirush_enabled", "1", FCVAR_NONE, "Determines if the plugin should activate the anti-rush functionality.", true, 0.0, true, 1.0);
    g_cvarAntiRushWaitStart = create_cvar("amx_sven_antirush_wait_start", "60.0", FCVAR_NONE, "How many seconds a map should wait before letting people play.", true, 0.0);
    g_cvarAntiRushWaitStartAmount = create_cvar("amx_sven_antirush_wait_start_amount", "-1", FCVAR_NONE, "How many players must be connected to start immediately. 0 to disable, -1 to use the amount of players of the previous map when it ended.", true, -1.0, true, 32.0);
    g_cvarAntiRushWaitEnd = create_cvar("amx_sven_antirush_wait_end", "60.0", FCVAR_NONE, "How many seconds a map should wait before changing should a player reaches the end.", true, 0.0);
    g_cvarAntiRushWaitEndPercentage = create_cvar("amx_sven_antirush_end_percentage", "80.0", FCVAR_NONE, "How many people (%) should reach the end to immediately change the map.", true, 0.0, true, 100.0);

    AutoExecConfig();

    g_hScreenFadeMessage = get_user_msgid("ScreenFade");

    register_clcmd("gibme", "PlayerCmd_Suicide");
    register_clcmd("kill", "PlayerCmd_Suicide");

    g_iPluginFlags = plugin_flags();

    if(g_iPluginFlags & AMX_FLAG_DEBUG)
        g_bDebugAlwaysWait = DEBUG_ALWAYS_WAIT;
}

public plugin_precache()
{
    precache_model("models/w_crowbar.mdl");
}

public server_changelevel()
{
    server_print("[DEBUG] %s::server_changelevel() - Storing %d to file", __BINARY__, get_playersnum());
    store_player_count_to_file(get_playersnum());
}

public plugin_end()
{
    if(task_exists(TASKID_CLOCKFUNCTION))
        remove_task(TASKID_CLOCKFUNCTION);

    if(task_exists(TASKID_FREEZEPLAYER))
        remove_task(TASKID_FREEZEPLAYER);

    if(task_exists(TASKID_RECHECKPLAYERCOUNT))
        remove_task(TASKID_RECHECKPLAYERCOUNT);
}

public plugin_cfg()
{
    if(g_iPluginFlags & AMX_FLAG_DEBUG)
        server_print("[DEBUG] %s::plugin_cfg() - Called", __BINARY__);

    bind_pcvar_num(g_cvarEnabled, g_bPluginEnabled);
    bind_pcvar_num(g_cvarAntiRush, g_bAntiRushEnabled);
    bind_pcvar_float(g_cvarAntiRushWaitStart, g_fAntiRushWaitStart);
    bind_pcvar_num(g_cvarAntiRushWaitStartAmount, g_iAntiRushWaitStartAmount);
    bind_pcvar_float(g_cvarAntiRushWaitEnd, g_fAntiRushWaitEnd);
    bind_pcvar_float(g_cvarAntiRushWaitEndPercentage, g_fAntiRushWaitEndPercentage);

    if(g_bPluginEnabled)
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
                        RegisterHam(Ham_Use, GAMEEND_CLASSNAME, "HamForward_GameEndUse_Pre");

                        new iEnt = -1;

                        while ((iEnt = find_ent_by_class(iEnt, "game_end")))
                        {
                            if(pev(iEnt, pev_flags) & FL_CUSTOMENTITY)
                                continue; //we don't want to mess up with other plugins' ents

                            new szTargetName[MAX_NAME_LENGTH], szTarget[MAX_NAME_LENGTH];
                            new Float:fOrigin[3];
                            
                            pev(iEnt, pev_origin, fOrigin);
                            pev(iEnt, pev_targetname, szTargetName, charsmax(szTargetName));
                            pev(iEnt, pev_target, szTarget, charsmax(szTarget));
                            
                            new iNewChangeLevel = engfunc(EngFunc_CreateNamedEntity, engfunc(EngFunc_AllocString, CHANGELEVEL_CLASSNAME));
                            if (iNewChangeLevel) 
                            {
                                set_pev(iNewChangeLevel, pev_origin, fOrigin);
                                
                                if(strlen(szTargetName) > 0)
                                    set_pev(iNewChangeLevel, pev_targetname, szTargetName);
                                
                                if(strlen(szTarget) > 0)
                                    set_pev(iNewChangeLevel, pev_target, szTarget);
                                
                                DispatchKeyValue(iNewChangeLevel, "map", g_sDesiredNextMap);
                                
                                set_pev(iNewChangeLevel, pev_spawnflags, pev(iNewChangeLevel, pev_spawnflags) | SF_CHANGELEVEL_USEONLY);
                        
                                dllfunc(DLLFunc_Spawn, iNewChangeLevel);
                                
                                remove_entity(iEnt);
                            }
                        }
                        
                        g_bOldMap = true;
                    }
                }
            }
            fclose(hFile);
        }
        else if(g_iPluginFlags & AMX_FLAG_DEBUG)
            server_print("[DEBUG] %s::plugin_cfg() - Can't open file %s. Assuming normal map", __BINARY__, sMapConfigPath);

        if(g_bAntiRushEnabled)
        {
            RegisterHam(Ham_Use, CHANGELEVEL_CLASSNAME, "HamForward_GameEndUse_Pre");
            RegisterHam(Ham_Touch, CHANGELEVEL_CLASSNAME, "HamForward_GameEndTouch_Pre");
            RegisterHam(Ham_Touch, BEACON_ENTNAME, "HamForward_MultipleTouch_Pre");

            if(g_iPluginFlags & AMX_FLAG_DEBUG)
                server_print("[DEBUG] %s::plugin_cfg() - Registering hooks.", __BINARY__);

            RegisterHam(Ham_Spawn, "player", "HamForward_PlayerSpawn_Pre");

            if(g_iPluginFlags & AMX_FLAG_DEBUG)
                server_print("[DEBUG] %s::plugin_cfg() - Setting g_hMapState to ANTIRUSH_STATE_PRE_INIT.", __BINARY__);

            g_hMapState = ANTIRUSH_STATE_PRE_INIT;

            if(g_iPluginFlags & AMX_FLAG_DEBUG)
                server_print("[DEBUG] %s::plugin_cfg() - Running clock.", __BINARY__);

            if(g_iAntiRushWaitStartAmount > 0)
                g_iWaitForPlayers = g_iAntiRushWaitStartAmount;
            else if(g_iAntiRushWaitStartAmount == -1)
                g_iWaitForPlayers = read_player_count_from_file();
            else 
                g_iWaitForPlayers = -1;

            set_task(1.0, "Task_ClockFunction", TASKID_CLOCKFUNCTION, _, _, "b");

            g_bThirdPartySurvivalEnabled = (get_cvar_pointer("amx_survival_enabled") > 0 && (get_cvar_pointer("amx_survival_mode") > 0 && get_pcvar_num(get_cvar_pointer("amx_survival_mode")) > 0)) ;
        }
    }
}

public OnConfigsExecuted()
{
    register_cvar("amx_sven_nextmapper_version", PLUGIN_VERSION, FCVAR_SERVER);
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
            new bFileExists = file_exists(szMapPath, true);

            if(!bFileExists)
            {
                server_print("[ALERT] %s::pfn_keyvalue() - Map ^"%s.bsp^" missing from the maps folder. Exit will be treated as 'game_end'", __BINARY__, szKeyValue);

                if(_:g_aInexistingMapExits == 0)
                    g_aInexistingMapExits = ArrayCreate();

                ArrayPushCell(g_aInexistingMapExits, iEnt);
            }
        }
    }
}

public client_disconnected(iClient)
{
    if(!g_bAntiRushEnabled)
        return;

    if(!task_exists(TASKID_RECHECKPLAYERCOUNT))
        set_task(1.0, "Task_RecheckPlayerCountOnLeft", TASKID_RECHECKPLAYERCOUNT);

    g_hPlayerState[iClient] = -1;
}

public client_putinserver(iClient)
{
    if(!g_bAntiRushEnabled)
        return;

    switch(g_hMapState)
    {
        case ANTIRUSH_STATE_PRE_INIT:
        {
            if(g_iPluginFlags & AMX_FLAG_DEBUG)
            {
                server_print("[DEBUG] %s::client_putinserver() - g_hMapState is ANTIRUSH_STATE_PRE_INIT", __BINARY__);
                server_print("[DEBUG] %s::client_putinserver() - Setting g_hMapState to ANTIRUSH_STATE_INIT", __BINARY__);
            }

            g_hMapState = ANTIRUSH_STATE_INIT;

            CheckForQuickStart();
        }
        case ANTIRUSH_STATE_INIT:
        {
            CheckForQuickStart();
        }
    }
}

CheckForQuickStart()
{
    if(g_iPluginFlags & AMX_FLAG_DEBUG)
    {
        server_print("[DEBUG] %s::CheckForQuickStart() - g_iWaitForPlayers is %d", __BINARY__, g_iWaitForPlayers);
        server_print("[DEBUG] %s::CheckForQuickStart() - get_playersnum() is %d", __BINARY__, get_playersnum());
    }

    if(g_iWaitForPlayers >= 0 && get_playersnum() >= g_iWaitForPlayers)
        g_fSecondsPassed = g_fAntiRushWaitStart-5;
}

public PlayerCmd_Suicide(iClient)
{
    if(g_hPlayerState[iClient] > 0)
        return PLUGIN_HANDLED;

    g_hPlayerState[iClient] = -1;
    return PLUGIN_CONTINUE;
}

public Task_RecheckPlayerCountOnLeft()
{
    new iPlayerCount = get_playersnum_ex(GetPlayers_IncludeConnecting);
    
    if(iPlayerCount == 0 && g_hMapState == ANTIRUSH_STATE_MIDGAME)
    {
        if(g_iPluginFlags & AMX_FLAG_DEBUG)
        {
            server_print("[DEBUG] %s::Task_RecheckPlayerCountOnLeft() - g_hMapState is ANTIRUSH_STATE_MIDGAME", __BINARY__);
            server_print("[DEBUG] %s::Task_RecheckPlayerCountOnLeft() - Setting g_hMapState to ANTIRUSH_STATE_SHOULD_RESTART", __BINARY__);
            server_print("[DEBUG] %s::Task_RecheckPlayerCountOnLeft() - iPlayerCount is %d", __BINARY__, iPlayerCount);
        }

        g_hMapState = ANTIRUSH_STATE_SHOULD_RESTART;
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
    
    g_hBeaconEnt[iClient] = engfunc(EngFunc_CreateNamedEntity, engfunc(EngFunc_AllocString, BEACON_ENTNAME));

    if(!pev_valid(g_hBeaconEnt[iClient]))
    {
        server_print("[ERROR] %s::Player_CreateTransitionBeacon() - Failed to create transition Beacon!", __BINARY__);
        return;
    }

    dllfunc(DLLFunc_Spawn, g_hBeaconEnt[iClient]);
    set_pev(g_hBeaconEnt[iClient], pev_classname, BEACON_CLASSNAME);
    set_pev(g_hBeaconEnt[iClient], pev_owner, iExit);
    set_pev(g_hBeaconEnt[iClient], pev_iuser1, iClient);
    set_pev(g_hBeaconEnt[iClient], pev_iuser4, FL_PLAYERBEACON);

    engfunc(EngFunc_SetModel, g_hBeaconEnt[iClient], "models/w_crowbar.mdl");

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
    entity_set_origin(g_hBeaconEnt[iClient], fOrigin);
    entity_set_size(g_hBeaconEnt[iClient], fMins, fMaxs);

    if(!g_bBeaconThinkHook)
    {
        RegisterHam(Ham_Think, BEACON_ENTNAME, "HamForward_MultipleThink_Pre");
        g_bBeaconThinkHook = true;
    }

    if(g_iPluginFlags & AMX_FLAG_DEBUG)
        server_print("[DEBUG] %s::Player_CreateTransitionBeacon() - Successfully created beacon: %d", __BINARY__, g_hBeaconEnt[iClient]);
}

public HamForward_GameEndTouch_Pre(iEnt, iOther)
{
    if(!is_user_connected(iOther))
        return HAM_IGNORED;

    //blocked back transition
    if(pev(iEnt, pev_solid) == SOLID_BSP) 
    {
        if(g_iPluginFlags & AMX_FLAG_DEBUG)
            server_print("[DEBUG] %s::HamForward_GameEndTouch_Pre() - Player %N wanted to touch a solid changelevel block", __BINARY__, iOther);

        return HAM_IGNORED;
    }

    if(pev(iEnt, pev_spawnflags) & SF_CHANGELEVEL_USEONLY == 0 && (iOther > 0 && iOther <= MaxClients))
    {
        if(g_hMapState == ANTIRUSH_STATE_MIDGAME)
        {
            new sName[MAX_NAME_LENGTH];
            get_user_name(iOther, sName, charsmax(sName));
            client_print(0, print_chat, "* %s reached the end of the map.", sName);
            
            if(g_iPluginFlags & AMX_FLAG_DEBUG)
            {
                server_print("[DEBUG] %s::HamForward_GameEndTouch_Pre() - g_hPlayerState[%d] is %d", __BINARY__, iOther, g_hPlayerState[iOther]);
                server_print("[DEBUG] %s::HamForward_GameEndTouch_Pre() - g_hMapState is ANTIRUSH_STATE_MIDGAME", __BINARY__);
                server_print("[DEBUG] %s::HamForward_GameEndTouch_Pre() - Setting g_hMapState to ANTIRUSH_STATE_END", __BINARY__);
            }

            g_hMapState = ANTIRUSH_STATE_END;
        }


        if(g_hPlayerState[iOther] == -1)
        {
            if(g_iPluginFlags & AMX_FLAG_DEBUG)
                server_print("[DEBUG] %s::HamForward_GameEndTouch_Pre() - Going to call PlayerReachedEndMap(%d, %d, false)", __BINARY__, iOther, iEnt, false);

            PlayerReachedEndMap(iOther, iEnt, false);
        }

        return HAM_SUPERCEDE;
    }
    
    return HAM_IGNORED;
}

public HamForward_MultipleTouch_Pre(iEnt, iOther)
{
    if(pev(iEnt, pev_iuser4) & FL_PLAYERBEACON && iOther >= 0 && iOther <= MaxClients)
    {
        if(g_iPluginFlags & AMX_FLAG_DEBUG)
            server_print("[DEBUG] %s::HamForward_MultipleTouch_Pre() - Called on %d (toucher: %N). iEnt iUser4 value: %d", __BINARY__, iEnt, iOther, pev(iEnt, pev_iuser4));

        if(g_hMapState == ANTIRUSH_STATE_END)
        {
            if(g_hPlayerState[iOther] == 0)
            {
                new iExit = pev(iEnt, pev_owner);
                if(iExit > 0 && g_hPlayerState[iOther] == -1)
                    PlayerReachedEndMap(iOther, iExit, false);
            }
        }
    }

    return HAM_IGNORED;
}

public HamForward_MultipleThink_Pre(iEnt)
{
    if(pev(iEnt, pev_iuser4, FL_PLAYERBEACON))
    {
        new iBeaconClient = pev(iEnt, pev_iuser1);
        if(is_user_connected(iBeaconClient))
        {
            new Float:fOrigin[3];
            pev(iBeaconClient, pev_origin, fOrigin);

            new Float:fMins[3], Float:fMaxs[3];
            pev(iBeaconClient, pev_mins, fMins);
            pev(iBeaconClient, pev_maxs, fMaxs);
            fMins[0] -= 8.0;
            fMins[1] -= 8.0;
            fMins[2] -= 8.0;
            fMaxs[0] += 8.0;
            fMaxs[1] += 8.0;
            fMaxs[2] += 8.0;

            entity_set_origin(iEnt, fOrigin);
            entity_set_size(iEnt, fMins, fMaxs);
        }
    }
}

public HamForward_GameEndUse_Pre(iEnt, iCaller, iActivator, iUseType, Float:fValue)
{
    if(!pev_valid(iEnt) || !pev_valid(iCaller))
        return HAM_IGNORED;

    if(pev(iEnt, pev_solid) == SOLID_BSP)
        return HAM_IGNORED;

    if(iCaller > 0 && iCaller <= MaxClients)
    {
        if(g_hMapState == ANTIRUSH_STATE_MIDGAME)
        {
            new sName[MAX_NAME_LENGTH];
            get_user_name(iCaller, sName, charsmax(sName));
            client_print(0, print_chat, "* %s reached the end of the map.", sName);

            if(g_iPluginFlags & AMX_FLAG_DEBUG)
            {
                server_print("[DEBUG] %s::HamForward_GameEndUse_Pre() - g_hPlayerState[%d] is %d", __BINARY__, iCaller, g_hPlayerState[iCaller]);
                server_print("[DEBUG] %s::HamForward_GameEndUse_Pre() - g_hMapState is ANTIRUSH_STATE_MIDGAME", __BINARY__);
                server_print("[DEBUG] %s::HamForward_GameEndUse_Pre() - Setting g_hMapState to ANTIRUSH_STATE_END", __BINARY__);
            }

            g_hMapState = ANTIRUSH_STATE_END;
        }

        if(g_hPlayerState[iCaller] == -1)
        {
            PlayerReachedEndMap(iCaller, iEnt, true);

            new sClassname[16];
            pev(iEnt, pev_classname, sClassname, charsmax(sClassname));

            if(g_iPluginFlags & AMX_FLAG_DEBUG)
                server_print("[DEBUG] %s::HamForward_GameEndUse_Pre() - classname: %s", __BINARY__, sClassname);
        }
        return HAM_SUPERCEDE;
    }

    //special case if we have the g_bOldMap flag set
    if(g_bOldMap)
    {
        if(g_iPluginFlags & AMX_FLAG_DEBUG)
            server_print("[DEBUG] %s::HamForward_GameEndUse_Pre() - This is an old map and the previous conditons didn't met. Changing to %s", __BINARY__,  g_sDesiredNextMap);

        engine_changelevel(g_sDesiredNextMap);
    }

    return HAM_IGNORED;
}

//runs every second
public Task_ClockFunction()
{
    switch(g_hMapState)
    {
        case ANTIRUSH_STATE_INIT:
        {
            if(g_fSecondsPassed > g_fAntiRushWaitStart)
            {
                if(g_iPluginFlags & AMX_FLAG_DEBUG)
                {
                    server_print("[DEBUG] %s::Task_ClockFunction() - g_hMapState is ANTIRUSH_STATE_INIT", __BINARY__);
                    server_print("[DEBUG] %s::Task_ClockFunction() - Disabling hook and spawning", __BINARY__);
                    server_print("[DEBUG] %s::Task_ClockFunction() - Setting g_bShouldSpawnNormally to true", __BINARY__);
                    server_print("[DEBUG] %s::Task_ClockFunction() - Setting g_hMapState to ANTIRUSH_STATE_MIDGAME", __BINARY__);
                }

                g_bShouldSpawnNormally = true;
                g_hMapState = ANTIRUSH_STATE_MIDGAME;
                g_fSecondsPassed = 0.0;

                SpawnNow();

                if(g_bThirdPartySurvivalEnabled)
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

            if(g_fAntiRushWaitStart - g_fSecondsPassed < 5)
            {
                set_hudmessage(200, 100, 0, -1.0, -1.0, 0, 1.0, 1.2, 0.0);
                show_hudmessage(0,  "Prepare to play!");
            }
            else
            {
                set_hudmessage(0, 100, 200, -1.0, -1.0, 0, 1.0, 1.2, 0.0);
                show_hudmessage(0,  "Waiting for players...");
            }
            
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
            //         server_print("[DEBUG] %s::Task_ClockFunction() -  All players in limbo left the server", __BINARY__);
            //         server_print("[DEBUG] %s::Task_ClockFunction() -  g_hMapState is ANTIRUSH_STATE_END", __BINARY__);
            //         server_print("[DEBUG] %s::Task_ClockFunction() -  Setting g_hMapState to ANTIRUSH_STATE_MIDGAME", __BINARY__);
            //     }
            //     g_hMapState = ANTIRUSH_STATE_MIDGAME;
            //     return;
            // }

            new iLimboPercentage = (GetPlayersInLimbo()*100)/get_playersnum_ex(GetPlayers_ExcludeDead);

            if(g_iPluginFlags & AMX_FLAG_DEBUG)
                server_print("[DEBUG] %s::Task_ClockFunction() - percentage of players in limbo %d%%", __BINARY__, iLimboPercentage);

            if(g_fSecondsPassed == g_fAntiRushWaitEnd || (!g_bDebugAlwaysWait && iLimboPercentage > g_fAntiRushWaitEndPercentage))
            {
                //antirush shouldn't wait more players
                if(g_iPluginFlags & AMX_FLAG_DEBUG)
                {
                    server_print("[DEBUG] %s::Task_ClockFunction() - TIME UP, attempting to changemap", __BINARY__);
                    server_print("[DEBUG] %s::Task_ClockFunction() - g_hMapState is ANTIRUSH_STATE_END", __BINARY__);
                    server_print("[DEBUG] %s::Task_ClockFunction() - Setting g_hMapState to ANTIRUSH_STATE_INTERMISSION", __BINARY__);
                }

                g_hMapState = ANTIRUSH_STATE_INTERMISSION;
                end_map();
                return;
            }
            set_hudmessage(200, 100, 0, -1.0, -1.0, 0, 1.0, 1.2, 0.0);
            show_hudmessage(0, "Map changing in %d seconds", floatround(g_fAntiRushWaitEnd - g_fSecondsPassed));
            g_fSecondsPassed++;
        }
        case ANTIRUSH_STATE_SHOULD_RESTART:
        {
            server_cmd("restart");
        }
    }
}

/**
 * Game started, open your eyes.
 *
 * @return void
 */
stock SpawnNow()
{
    for(new iClient = 1; iClient <= MaxClients; iClient++)
    {
        if(pev_valid(iClient) == 2)
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

            ExecuteHamB(Ham_Spawn, iClient);
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
            if(is_user_connected(iClient) && is_user_alive(iClient))
            {
                iUser = iClient;
                break;
            }
        }

        if(iUser)
        {
            if(g_iPluginFlags & AMX_FLAG_DEBUG)
                server_print("[DEBUG] %s::end_map() - Executed Changelevel", __BINARY__);

            for(new iClient=1;iClient <= MaxClients;iClient++)
            {
                if(is_user_connected(iClient) && is_user_alive(iClient))
                {
                    set_pev(iClient, pev_flags, pev(iClient, pev_flags) & ~(FL_FROZEN | FL_GODMODE | FL_NOTARGET | FL_NOWEAPONS | FL_DORMANT));
                    set_pev(iClient, pev_solid, SOLID_SLIDEBOX);
                    set_pev(iClient, pev_movetype, MOVETYPE_WALK);
                }
            }

            if(pev(iDesiredChangelevelEnt, pev_spawnflags) & SF_CHANGELEVEL_USEONLY)
                ExecuteHam(Ham_Use, iDesiredChangelevelEnt, iUser, iUser, 1, 0.0);
            else
                ExecuteHam(Ham_Touch, iDesiredChangelevelEnt, iUser);
        }
        else
        {
            //we don't have an user!
            //everyone left?
            if(g_iPluginFlags & AMX_FLAG_DEBUG)
            {
                server_print("[DEBUG] %s::end_map() - g_hMapState is ANTIRUSH_STATE_MIDGAME", __BINARY__);
                server_print("[DEBUG] %s::end_map() - Setting g_hMapState to ANTIRUSH_STATE_SHOULD_RESTART", __BINARY__);
            }

            g_hMapState = ANTIRUSH_STATE_SHOULD_RESTART;
        }
    }
}

public HamForward_PlayerSpawn_Pre(iClient)
{  
    if(iClient)
    {
        if(g_iPluginFlags & AMX_FLAG_DEBUG)
        {
            server_print("[DEBUG] %s::HamForward_PlayerSpawn_Pre() - Called on Player %d", __BINARY__, iClient);
            server_print("[DEBUG] %s::HamForward_PlayerSpawn_Pre() - Value of g_bShouldSpawnNormally is %b", __BINARY__,  g_bShouldSpawnNormally);
        }

        if(!g_bShouldSpawnNormally)
            return HAM_SUPERCEDE;
        
        //RequestFrame("FrameNext_AttemptFreezePlayer", TASKID_FREEZEPLAYER + get_user_userid(iClient));
    }

    return HAM_IGNORED;
}

public FrameNext_AttemptFreezePlayer(iTaskId)
{
    new iUserId = iTaskId - TASKID_FREEZEPLAYER;
    new iClient = find_player_ex(FindPlayer_MatchUserId, iUserId);
    if(iClient && is_user_connected(iClient) && !g_bShouldSpawnNormally)
    {
        if(g_iPluginFlags & AMX_FLAG_DEBUG)
            server_print("[DEBUG] %s::FrameNext_AttemptFreezePlayer() - Called on Player %d", __BINARY__, iClient);
        
        set_pev(iClient, pev_flags, pev(iClient, pev_flags) | FL_FROZEN | FL_GODMODE | FL_NOTARGET);
    }
}

stock GetPlayersInLimbo()
{
    new iCount = 0;
    for(new iClient=1;iClient <= MaxClients;iClient++)
    {
        if(is_user_connected(iClient) && g_hPlayerState[iClient] > 0)
            iCount++;
    }
    return iCount;
}

#define PLAYERCOUNT_DATA_FILE "player_count.dat"

stock read_player_count_from_file()
{
    new szConfigDir[128];
    new szFilePath[256];
    
    get_configsdir(szConfigDir, charsmax(szConfigDir));
    formatex(szFilePath, charsmax(szFilePath), "%s/%s", szConfigDir, PLAYERCOUNT_DATA_FILE);
    
    if (!file_exists(szFilePath, true))
        return 0;
    
    new iFile = fopen(szFilePath, "r");
    if (!iFile)
    {
        fclose(iFile);
        return 0;
    }
    
    new szBuffer[32];
    if (fgets(iFile, szBuffer, charsmax(szBuffer)))
    {
        fclose(iFile);
        delete_file(szFilePath, true);
        return str_to_num(szBuffer);
    } 

    fclose(iFile);
    return 0;
}

stock store_player_count_to_file(iPlayerCount)
{
    new szConfigDir[128];
    new szFilePath[256];
    
    get_configsdir(szConfigDir, charsmax(szConfigDir));
    formatex(szFilePath, charsmax(szFilePath), "%s/%s", szConfigDir, PLAYERCOUNT_DATA_FILE);
    
    new iFile = fopen(szFilePath, "w");
    if (!iFile)
    {
        log_amx("ERROR: Could not open file for writing: %s", szFilePath);
        return;
    }
    
    // Write player count to file
    fprintf(iFile, "%d", iPlayerCount);
    fclose(iFile);
}