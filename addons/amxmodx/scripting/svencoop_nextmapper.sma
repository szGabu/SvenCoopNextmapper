#include <amxmodx>
#include <amxmisc>
#include <hamsandwich>
#include <fakemeta>
#include <engine>
#include <hlsdk_const>

#define PLUGIN_NAME	                    "Sven Co-op Nextmapper & Anti-Rush"
#define PLUGIN_VERSION	                "1.0.0"
#define PLUGIN_AUTHOR	                "szGabu"

#define SF_FADE_OUT                     0x0003
#define FL_NOWEAPONS                    (1<<27)

#define SVENGINE_MAX_EDICS              8192

#define GAME_END_CLASSNAME              "game_end"
#define CHANGELEVEL_CLASSNAME           "trigger_changelevel"

#define RELAY_ENTNAME					"trigger_relay"
#define RELAY_TARGETNAME				"amxx_nextmapper_utsuhoreuiji"

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

#if AMXX_VERSION_NUM < 183
#define MAX_PLAYERS                     32
#define MAX_NAME_LENGTH                 32
#define MaxClients                      get_maxplayers()
#endif

#pragma dynamic     32768
#pragma semicolon   1

new g_cvarEnabled, g_cvarAntiRush, g_cvarAntiRushWaitStart, g_cvarAntiRushWaitEnd, g_cvarAntiRushEndPercentage, g_cvarAntiRushIgnoreBots;
new g_cvarSurvivalEnabled;
new g_iPluginFlags, g_iMapState = ANTIRUSH_STATE_INVALID;
new g_sDesiredNextMap[64];
new g_bOldMap = false;
new g_bDebugAlwaysWait = false;
new g_hPlayerState[MAX_PLAYERS+1] = {-1, ...};
new g_hLastExitUsed = 0;
new g_hRelayEnt = 0;
new g_hBeaconEnt[MAX_PLAYERS+1] = {-1, ...};
new g_hScreenFadeMessage = 0;
new g_bGalileoRunning = false;
new bool:g_bAmxxSurvivalModeEnabled = false;
new bool:g_bShouldSpawnNormally = false;
new Float:g_fSecondsPassed = 0.0;

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
    g_cvarSurvivalEnabled = get_cvar_pointer("mp_survival_mode");

    register_cvar("amx_sven_nextmapper_version", PLUGIN_VERSION);

    g_iPluginFlags = plugin_flags();
    g_hScreenFadeMessage = get_user_msgid("ScreenFade");

    register_clcmd("gibme", "PlayerCmd_Suicide");
    register_clcmd("kill", "PlayerCmd_Suicide");

    g_bGalileoRunning = get_cvar_pointer("gal_srv_start") != 0;

    if(g_iPluginFlags & AMX_FLAG_DEBUG)
        g_bDebugAlwaysWait = DEBUG_ALWAYS_WAIT;
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
        server_print("[DEBUG] svencoop_nextmapper.amxx::plugin_cfg() - Called");

    if(get_pcvar_bool(g_cvarEnabled))
    {
        new sMapName[32];
        get_mapname(sMapName, charsmax(sMapName));
        new sMapConfigPath[1024];
        formatex(sMapConfigPath, charsmax(sMapConfigPath), "maps/%s.cfg", sMapName);
        if(g_iPluginFlags & AMX_FLAG_DEBUG)
            server_print("[DEBUG] svencoop_nextmapper.amxx::plugin_cfg() - Trying to read file %s", sMapConfigPath);
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
                        server_print("[DEBUG] svencoop_nextmapper.amxx::plugin_cfg() - This map is old, next map should be %s", g_sDesiredNextMap);

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
            server_print("[DEBUG] svencoop_nextmapper.amxx::plugin_cfg() - Can't open file %s. Assuming normal map", sMapConfigPath);

        if(get_pcvar_bool(g_cvarAntiRush))
        {
            RegisterHam(Ham_Use, CHANGELEVEL_CLASSNAME, "LevelEnd_ByUse");
            register_forward(FM_Touch, "Event_Touch_Pre", false); // HamSandwich Hook is no longer working working.

            if(g_iPluginFlags & AMX_FLAG_DEBUG)
                server_print("[DEBUG] svencoop_nextmapper.amxx::plugin_cfg() - Registering hooks.");

            RegisterHam(Ham_Spawn, "player", "Event_PlayerSpawn_Pre");

            if(g_iPluginFlags & AMX_FLAG_DEBUG)
                server_print("[DEBUG] svencoop_nextmapper.amxx::plugin_cfg() - Setting g_iMapState to ANTIRUSH_STATE_PRE_INIT.");
            g_iMapState = ANTIRUSH_STATE_PRE_INIT;

            if(g_iPluginFlags & AMX_FLAG_DEBUG)
                server_print("[DEBUG] svencoop_nextmapper.amxx::plugin_cfg() - Running clock.");
            set_task(1.0, "clock_function", _, _, _, "b");

            SetupNeededEnts();
        }
    }
}

public OnConfigsExecuted()
{
    if(g_iPluginFlags & AMX_FLAG_DEBUG)
        server_print("[DEBUG] svencoop_nextmapper.amxx::OnConfigsExecuted() - Called");

    g_bAmxxSurvivalModeEnabled = (get_cvar_pointer("amx_survival_enabled") > 0 && (get_cvar_pointer("amx_survival_mode") > 0 && get_pcvar_num(get_cvar_pointer("amx_survival_mode")) > 0)) ;
}

/**
 * Creates and configures necessary game entities for plugin functionality.
 * Sets up respawn triggers, relay entities, and vote handling entities.
 *
 * @return void
 */
public SetupNeededEnts()
{
	g_hRelayEnt = engfunc(EngFunc_CreateNamedEntity, engfunc(EngFunc_AllocString, RELAY_ENTNAME));
	dllfunc(DLLFunc_Spawn, g_hRelayEnt);
	set_pev(g_hRelayEnt, pev_targetname, RELAY_TARGETNAME);

	server_print("[NOTICE] %s is free to download and distribute! If you paid for this plugin YOU GOT SCAMMED. Visit https://github.com/szGabu for all my plugins.", PLUGIN_NAME);
}

public client_disconnected(iClient)
{
    if(!get_pcvar_bool(g_cvarAntiRush) || (get_pcvar_bool(g_cvarAntiRushIgnoreBots) && is_user_bot(g_cvarAntiRushIgnoreBots)) )
        return;

    RequestFrame("RecheckPlayerCountOnLeft");

    g_hPlayerState[iClient] = -1;
}

public RecheckPlayerCountOnLeft()
{
    if(get_player_count() == 0 && g_iMapState == ANTIRUSH_STATE_MIDGAME)
    {
        if(g_iPluginFlags & AMX_FLAG_DEBUG)
        {
            server_print("[DEBUG] svencoop_nextmapper.amxx::client_disconnected() - g_iMapState is ANTIRUSH_STATE_MIDGAME");
            server_print("[DEBUG] svencoop_nextmapper.amxx::client_disconnected() - Setting g_iMapState to ANTIRUSH_STATE_SHOULD_RESTART");
            server_print("[DEBUG] svencoop_nextmapper.amxx::client_disconnected() - get_player_count() is %d", get_player_count());
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
            server_print("[DEBUG] svencoop_nextmapper.amxx::client_putinserver() - g_iMapState is ANTIRUSH_STATE_PRE_INIT");
            server_print("[DEBUG] svencoop_nextmapper.amxx::client_putinserver() - Setting g_iMapState to ANTIRUSH_STATE_INIT");
        }

        g_iMapState = ANTIRUSH_STATE_INIT;

        if(g_bGalileoRunning)
        {
            //prevent players from rtv'ing in ANTIRUSH_STATE_INIT phase
            if(g_iPluginFlags & AMX_FLAG_DEBUG)
                server_print("[DEBUG] svencoop_nextmapper.amxx::client_putinserver() - Trying to pause Galileo");

            pause("ac", "galileo.amxx");
            server_exec();
        }
    }
}

public player_reached_endmap(iClient, iExit, bool:bShouldCreateBeacon)
{
    g_hLastExitUsed = iExit;
    if(g_iPluginFlags & AMX_FLAG_DEBUG)
        server_print("[DEBUG] svencoop_nextmapper.amxx::player_reached_endmap() - iExit IS %d!!!!", iExit);
    g_hPlayerState[iClient] = iExit;
    if(g_iPluginFlags & AMX_FLAG_DEBUG)
        server_print("[DEBUG] svencoop_nextmapper.amxx::player_reached_endmap() - g_hPlayerState[%d] is %d", iClient, g_hPlayerState[iClient]);

    set_pev(iClient, pev_flags, pev(iClient, pev_flags) | FL_FROZEN | FL_GODMODE | FL_NOTARGET | FL_NOWEAPONS | FL_DORMANT);
    set_pev(iClient, pev_solid, SOLID_NOT);
    set_pev(iClient, pev_movetype, MOVETYPE_NONE);

    if(bShouldCreateBeacon)
        Player_CreateTransitionBeacon(iClient, iExit);
}

Player_CreateTransitionBeacon(iClient, iExit)
{
    if(!is_user_alive(iClient))
        return;
    
    g_hBeaconEnt[iClient] = engfunc(EngFunc_CreateNamedEntity, engfunc(EngFunc_AllocString, "info_target"));
    dllfunc(DLLFunc_Spawn, g_hBeaconEnt[iClient]);
    set_pev(g_hBeaconEnt[iClient], pev_classname, BEACON_CLASSNAME);
    set_pev(g_hBeaconEnt[iClient], pev_owner, iExit);

    if (!g_hBeaconEnt[iClient])
    {
        server_print("ERROR: Failed to create trasition beacon!");
        return;
    }

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
        server_print("[DEBUG] svencoop_nextmapper.amxx::Player_CreateTransitionBeacon() - Successfully created beacon: %d", g_hBeaconEnt[iClient]);
}

public Event_Touch_Pre(iEnt, iOther)
{
    if(iEnt && iOther && iEnt >= MaxClients && iOther <= MaxClients)
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
    //blocked back transition
    if(pev(iEnt, pev_solid) == SOLID_BSP) 
        return HAM_IGNORED;

    if(pev(iEnt, pev_spawnflags) & SF_CHANGELEVEL_USEONLY == 0 && (iOther > 0 && iOther <= MaxClients))
    {
        if(g_iMapState == ANTIRUSH_STATE_MIDGAME)
        {
            new sName[MAX_NAME_LENGTH];
            get_user_name(iOther, sName, charsmax(sName));
            client_print(0, print_chat, "* %s reached the end of the map.", sName);
            
            if(g_iPluginFlags & AMX_FLAG_DEBUG)
            {
                server_print("[DEBUG] svencoop_nextmapper.amxx::LevelEnd_ByTouch() - g_hPlayerState[%d] is %d", iOther, g_hPlayerState[iOther]);
                server_print("[DEBUG] svencoop_nextmapper.amxx::LevelEnd_ByTouch() - g_iMapState is ANTIRUSH_STATE_MIDGAME");
                server_print("[DEBUG] svencoop_nextmapper.amxx::LevelEnd_ByTouch() - Setting g_iMapState to ANTIRUSH_STATE_END");
            }

            g_iMapState = ANTIRUSH_STATE_END;
        }

        if(g_hPlayerState[iOther] == -1)
            player_reached_endmap(iOther, iEnt, false);

        return HAM_SUPERCEDE;
    }
    
    return HAM_IGNORED;
}

public LevelEnd_ByTouchBeaconPlayer(iEnt, iOther)
{
    if(g_iPluginFlags & AMX_FLAG_DEBUG)
        server_print("[DEBUG] svencoop_nextmapper.amxx::LevelEnd_ByTouchBeaconPlayer() - Called on %d", iEnt);

    if(iOther >= 0 && iOther <= MaxClients && g_iMapState == ANTIRUSH_STATE_END)
    {
        if(g_hPlayerState[iOther] > 0)
            return FMRES_IGNORED;
        else
        {
            if(pev(iEnt, pev_owner) > 0 && g_hPlayerState[iOther] == -1)
                player_reached_endmap(iOther, pev(iEnt, pev_owner), false);
        }
    }

    return FMRES_IGNORED;
}

public LevelEnd_ByUse(iEnt, iCaller, iActivator, iUseType, Float:fValue)
{
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
                server_print("[DEBUG] svencoop_nextmapper.amxx::LevelEnd_ByUse() - g_hPlayerState[%d] is %d", iCaller, g_hPlayerState[iCaller]);
                server_print("[DEBUG] svencoop_nextmapper.amxx::LevelEnd_ByUse() - g_iMapState is ANTIRUSH_STATE_MIDGAME");
                server_print("[DEBUG] svencoop_nextmapper.amxx::LevelEnd_ByUse() - Setting g_iMapState to ANTIRUSH_STATE_END");
            }
            g_iMapState = ANTIRUSH_STATE_END;
        }

        if(g_hPlayerState[iCaller] == -1)
        {
            player_reached_endmap(iCaller, iEnt, true);

            new sClassname[16];
            pev(iEnt, pev_classname, sClassname, charsmax(sClassname));

            if(g_iPluginFlags & AMX_FLAG_DEBUG)
                server_print("[DEBUG] svencoop_nextmapper.amxx::LevelEnd_ByUse() - classname: %s", sClassname);
        
            if(equal(sClassname, GAME_END_CLASSNAME))
            {
                if(g_bGalileoRunning)
                {
                    // ugly hack to prevent addons_zz's Galileo to 
                    // trigger a votemap when we are waiting for players
                    if(g_iPluginFlags & AMX_FLAG_DEBUG)
                        server_print("[DEBUG] svencoop_nextmapper.amxx::LevelEnd_ByUse() - Trying to pause Galileo");

                    pause("ac", "galileo.amxx");
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
            server_print("[DEBUG] svencoop_nextmapper.amxx::LevelEnd_ByUse() - This is an old map and the previous conditons didn't met. Changing to %s", g_sDesiredNextMap);
        #if AMXX_VERSION_NUM < 183
        server_cmd("changelevel %s", g_sDesiredNextMap);
        #else
        engine_changelevel(g_sDesiredNextMap);
        #endif
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
                    server_print("[DEBUG] svencoop_nextmapper.amxx::clock_function() - g_iMapState is ANTIRUSH_STATE_INIT");
                    server_print("[DEBUG] svencoop_nextmapper.amxx::clock_function() - Disabling hook and spawning");
                }

                g_bShouldSpawnNormally = true;

                if(g_iPluginFlags & AMX_FLAG_DEBUG)
                    server_print("[DEBUG] svencoop_nextmapper.amxx::clock_function() - Ham Hook Disabled");

                if(g_iPluginFlags & AMX_FLAG_DEBUG)
                    server_print("[DEBUG] svencoop_nextmapper.amxx::clock_function() - Setting g_iMapState to ANTIRUSH_STATE_MIDGAME");

                g_iMapState = ANTIRUSH_STATE_MIDGAME;
                g_fSecondsPassed = 0.0;

                FadeOut();

                if(g_bGalileoRunning)
                {
                   //we are in ANTIRUSH_STATE_MIDGAME, we must resume galileo
                   if(g_iPluginFlags & AMX_FLAG_DEBUG)
                       server_print("[DEBUG] svencoop_nextmapper.amxx::clock_function() - Trying to unpause Galileo");
                
                   unpause("ac", "galileo.amxx");
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
            // if(!g_bOldMap && get_players_in_limbo() == 0)
            // {
            //     // g_bOldMap must be FALSE otherwise the map 
            //     // could softlock in not repeatable triggers
            //     if(g_iPluginFlags & AMX_FLAG_DEBUG)
            //     {
            //         server_print("[DEBUG] svencoop_nextmapper.amxx::clock_function() -  All players in limbo left the server");
            //         server_print("[DEBUG] svencoop_nextmapper.amxx::clock_function() -  g_iMapState is ANTIRUSH_STATE_END");
            //         server_print("[DEBUG] svencoop_nextmapper.amxx::clock_function() -  Setting g_iMapState to ANTIRUSH_STATE_MIDGAME");
            //     }
            //     g_iMapState = ANTIRUSH_STATE_MIDGAME;
            //     return;
            // }

            new iLimboPercentage = (get_players_in_limbo()*100)/get_player_count();

            if(g_iPluginFlags & AMX_FLAG_DEBUG)
                server_print("[DEBUG] svencoop_nextmapper.amxx::clock_function() - percentage of players in limbo %d%%", iLimboPercentage);

            if(g_fSecondsPassed == get_pcvar_float(g_cvarAntiRushWaitEnd) || (!g_bDebugAlwaysWait && iLimboPercentage > get_pcvar_float(g_cvarAntiRushEndPercentage)))
            {
                //antirush shouldn't wait more players
                if(g_iPluginFlags & AMX_FLAG_DEBUG)
                {
                    server_print("[DEBUG] svencoop_nextmapper.amxx::clock_function() - TIME UP, attempting to changemap");
                    server_print("[DEBUG] svencoop_nextmapper.amxx::clock_function() - g_iMapState is ANTIRUSH_STATE_END");
                    server_print("[DEBUG] svencoop_nextmapper.amxx::clock_function() - Setting g_iMapState to ANTIRUSH_STATE_INTERMISSION");
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
        if(is_user_connected(iClient))
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
            server_print("[DEBUG] svencoop_nextmapper.amxx::end_map() - This is an old map. Changing to %s", g_sDesiredNextMap);
        #if AMXX_VERSION_NUM < 183
        server_cmd("changelevel %s", g_sDesiredNextMap);
        #else
        engine_changelevel(g_sDesiredNextMap);
        #endif
    }
    else 
    {
        if(g_iPluginFlags & AMX_FLAG_DEBUG)
            server_print("[DEBUG] svencoop_nextmapper.amxx::end_map() - This is a new map");
        //if we store the changelevel id and trigger it we
        //might keep the inventory if the mapper wishes to
        new iMapExit[SVENGINE_MAX_EDICS] = 0;
        for(new iClient=1;iClient <= MaxClients;iClient++)
        {
            if(g_iPluginFlags & AMX_FLAG_DEBUG)
                server_print("g_hPlayerState[%d] is %d", iClient, g_hPlayerState[iClient]);
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
            server_print("[DEBUG] svencoop_nextmapper.amxx::end_map() - Desired changelevel entity is %d", iDesiredChangelevelEnt);

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
                server_print("[DEBUG] svencoop_nextmapper.amxx::end_map() - EXECUTED CHANGELEVEL");

            ExecuteHam(Ham_Use, iDesiredChangelevelEnt, g_hRelayEnt, g_hRelayEnt, 1, 0.0);

            // sven coop now crashes when multiple changelevels occur in the same frame:
            // ExecuteHam(Ham_Touch, iDesiredChangelevelEnt, g_hRelayEnt);
            // ExecuteHam(Ham_Use, iDesiredChangelevelEnt, iUser, iUser, 1, 0.0);
            // ExecuteHam(Ham_Touch, iDesiredChangelevelEnt, iUser);
            if(g_iPluginFlags & AMX_FLAG_DEBUG)
            {
                server_print("[DEBUG] svencoop_nextmapper.amxx::end_map() - Failed to changelevel? ");
                server_print("[DEBUG] svencoop_nextmapper.amxx::end_map() - Debug iDesiredChangelevelEnt:");
                new sClassname[32];
                pev(iDesiredChangelevelEnt, pev_classname, sClassname, charsmax(sClassname));
                server_print("[DEBUG] svencoop_nextmapper.amxx::end_map() - classname: %s", sClassname);
            }
        }
        else
        {
            //we don't have an user!
            //everyone left?
            if(g_iPluginFlags & AMX_FLAG_DEBUG)
            {
                server_print("[DEBUG] svencoop_nextmapper.amxx::end_map() - g_iMapState is ANTIRUSH_STATE_MIDGAME");
                server_print("[DEBUG] svencoop_nextmapper.amxx::end_map() - Setting g_iMapState to ANTIRUSH_STATE_SHOULD_RESTART");
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
        server_print("[DEBUG] svencoop_nextmapper.amxx::Event_PlayerSpawn_Pre() - Called on Player %d", iClient);
        server_print("[DEBUG] svencoop_nextmapper.amxx::Event_PlayerSpawn_Pre() - Value of g_bShouldSpawnNormally is %b", g_bShouldSpawnNormally);
    }
        
    if(!g_bShouldSpawnNormally)
        RequestFrame("FreezePlayer", iClient);

    return HAM_IGNORED;
}

public FreezePlayer(iClient)
{
    if(g_iPluginFlags & AMX_FLAG_DEBUG)
        server_print("[DEBUG] svencoop_nextmapper.amxx::FreezePlayer() - Called on Player %d", iClient);
    
    if(is_user_connected(iClient))
        set_pev(iClient, pev_flags, pev(iClient, pev_flags) | FL_FROZEN | FL_GODMODE | FL_NOTARGET);
}

stock get_player_count()
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

stock get_players_in_limbo()
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

#if AMXX_VERSION_NUM < 183
stock get_pcvar_bool(const iHandle)
{
	return get_pcvar_num(iHandle) != 0;
}
#endif